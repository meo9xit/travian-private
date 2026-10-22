<?php

namespace Model;

use Core\Config;
use Core\Database\DB;
use Core\Log;
use Game\Formulas;
use Game\GoldHelper;
use Game\SpeedCalculator;
use function getCustom;
use function getGameElapsedSeconds;
use function miliseconds;

/**
 * War behaviour for the fake (AI) players.
 *
 * The stock AI only builds and trains randomly (Core\AI + AutoUpgradeAI); it has
 * no concept of an enemy, so bots never leave their village. This model gives
 * them one:
 *
 *  * raiding: villages with a rally point send their offensive units at Natar
 *    farm villages (the game's own farm targets) and at villages of players who
 *    are past the protection and big enough to be worth attacking
 *    (custom->botAttackMinPopulation, default 800 population). Defensive units
 *    always stay home.
 *  * gold: bots spend the gold they accumulate on Plus and on production boosts,
 *    through the same GoldHelper::decreaseGold() the players use.
 *
 * Everything is driven from the automation engine (Core\Jobs\Launcher ->
 * Automation::autoFarmlist -> FakeUserModel), so it works without a session:
 * the pieces that need one (GoldHelper::buyPlus) are reimplemented here against
 * the user row.
 */
class BotWarModel
{
    /** Bot villages considered per automation tick. */
    const VILLAGES_PER_RUN = 30;

    /** Raids sent per automation tick, across all bots. */
    const RAIDS_PER_RUN = 15;

    /** Only attack when our offence is this many times their defence. */
    const MIN_OFFENCE_RATIO = 2.0;

    /** Seconds between two raid rounds for the same bot. */
    const RAID_COOLDOWN = 900;

    /** Gold spending run at most once per this many seconds. */
    const GOLD_COOLDOWN = 3600;

    /** A scout report stays valid for this long before the bot spies again. */
    const SCOUT_VALIDITY = 6 * 3600;

    /** Bot villages considered for oasis farming per automation tick. */
    const OASIS_VILLAGES_PER_RUN = 20;

    /** Oasis raids sent per automation tick, across all bots. */
    const OASIS_RAIDS_PER_RUN = 10;

    /** Seconds before the same bot is considered for farming again. */
    const OASIS_ROTATION = 900;

    /** Seconds before the same bot farms the same oasis again. */
    const OASIS_COOLDOWN = 1800;

    /** Units in a "collect" run once the oasis has no defenders left. */
    const OASIS_COLLECT_UNITS = 10;

    /** How far (map tiles) a bot looks for a free oasis. */
    const OASIS_MAX_DISTANCE = 12;

    /** Oases inspected per farming attempt, so a too-strong one can be skipped. */
    const OASIS_CANDIDATES = 6;

    /** Only clear a guarded oasis when our offence is this many times its guards. */
    const OASIS_CLEAR_RATIO = 2.0;

    /** Share of the farming runs that go for a guarded oasis (the rest collect). */
    const OASIS_CLEAR_CHANCE = 35;

    /** Above this share of the store the loot would be capped away: not worth it. */
    const STORE_FULL_RATIO = 0.95;

    private static $schemaChecked = false;

    public function isEnabled()
    {
        return (bool)getCustom('botWarEnabled');
    }

    public function minTargetPopulation()
    {
        $pop = (int)Config::getProperty("custom", "botAttackMinPopulation");
        return $pop > 0 ? $pop : 800;
    }

    public function maxTravelSeconds()
    {
        $seconds = (int)Config::getProperty("game", "botMaxRaidTravelSeconds");
        return $seconds > 0 ? $seconds : 8 * 3600;
    }

    public function getRaidCooldown()
    {
        $seconds = (int)Config::getProperty("game", "botRaidCooldownSeconds");
        return $seconds > 0 ? $seconds : self::RAID_COOLDOWN;
    }

    /**
     * One column: when this bot last sent a raid round. Added on first use so
     * worlds installed before this feature keep working (same approach as
     * AutoRaidModel::ensureSchema()).
     */
    public function ensureSchema()
    {
        if (self::$schemaChecked) {
            return;
        }
        self::$schemaChecked = true;
        $db = DB::getInstance();
        if (!$db->fetchScalar("SHOW COLUMNS FROM users LIKE 'botLastRaid'")) {
            $db->query("ALTER TABLE users ADD COLUMN `botLastRaid` INT(11) NOT NULL DEFAULT '0'");
        }
        if (!$db->fetchScalar("SHOW COLUMNS FROM users LIKE 'botLastGold'")) {
            $db->query("ALTER TABLE users ADD COLUMN `botLastGold` INT(11) NOT NULL DEFAULT '0'");
        }
        if (!$db->fetchScalar("SHOW COLUMNS FROM users LIKE 'botDefendUntil'")) {
            $db->query("ALTER TABLE users ADD COLUMN `botDefendUntil` INT(11) NOT NULL DEFAULT '0'");
        }
        // When this bot was last *considered* for oasis farming - stamped even
        // when nothing could be sent, so a bot with no army cannot park itself at
        // the front of the queue and starve the others.
        if (!$db->fetchScalar("SHOW COLUMNS FROM users LIKE 'botLastFarm'")) {
            $db->query("ALTER TABLE users ADD COLUMN `botLastFarm` INT(11) NOT NULL DEFAULT '0'");
        }
        // Which villages this bot has already scouted (and when), so it spies on a
        // player once and then attacks instead of spying forever.
        $db->query("CREATE TABLE IF NOT EXISTS bot_scout (
                        uid INT(11) NOT NULL,
                        to_kid INT(6) NOT NULL,
                        scout_time INT(11) NOT NULL DEFAULT '0',
                        PRIMARY KEY (uid, to_kid)
                    ) ENGINE=MyISAM DEFAULT CHARSET=utf8mb4");
        // Which oasis this bot farms and when. An oasis only holds a few thousand
        // resources, so without this the bot would strip the same one every tick
        // and get nothing after the first hit.
        $db->query("CREATE TABLE IF NOT EXISTS bot_oasis (
                        uid INT(11) NOT NULL,
                        kid INT(6) NOT NULL,
                        last_raid INT(11) NOT NULL DEFAULT '0',
                        PRIMARY KEY (uid, kid)
                    ) ENGINE=MyISAM DEFAULT CHARSET=utf8mb4");
    }

    // ------------------------------------------------------------- raiding ----

    /**
     * @return int number of raids sent
     */
    public function processRaids()
    {
        if (!$this->isEnabled()) {
            return 0;
        }
        $this->ensureSchema();
        $db = DB::getInstance();
        $now = time();
        $cooldown = $this->getRaidCooldown();
        $sent = 0;

        // Only bot villages that can actually attack: a rally point, units at
        // home, and an owner who is neither protected nor on vacation.
        $result = $db->query("SELECT v.kid, v.owner, u.race, u.botLastRaid
                              FROM vdata v
                              JOIN users u ON u.id = v.owner
                              WHERE u.access = 3
                                AND u.protection < $now
                                AND u.vacationActiveTil < $now
                                AND u.botLastRaid + $cooldown <= $now
                                AND (SELECT fd.f39 FROM fdata fd WHERE fd.kid = v.kid) > 0
                                AND EXISTS (SELECT 1 FROM units un WHERE un.kid = v.kid
                                            AND (un.u1+un.u2+un.u3+un.u4+un.u5+un.u6+un.u7+un.u8+un.u9+un.u10) > 0)
                              ORDER BY u.botLastRaid ASC
                              LIMIT " . self::VILLAGES_PER_RUN);
        while ($row = $result->fetch_assoc()) {
            if ($sent >= self::RAIDS_PER_RUN) {
                break;
            }
            // Stamp first, so a failure cannot put the bot in a retry loop.
            $db->query("UPDATE users SET botLastRaid=$now WHERE id={$row['owner']}");
            $sent += $this->raidFromVillage($row['kid'], $row['owner'], $row['race'], self::RAIDS_PER_RUN - $sent);
        }
        if ($sent > 0) {
            Log::addLog(0, "botWar:raids", sprintf("%d raid(s) sent", $sent));
        }
        return $sent;
    }

    /**
     * @return int raids sent from this village
     */
    private function raidFromVillage($kid, $owner, $race, $budget)
    {
        $db = DB::getInstance();
        $units = $db->query("SELECT * FROM units WHERE kid=$kid")->fetch_assoc();
        if (!$units) {
            return 0;
        }
        // Split: the strongest offensive unit it actually has goes out,
        // everything else guards the village.
        $offenceNr = $this->pickOffensiveSlot($race, $units);
        if ($offenceNr <= 0 || (int)$units['u' . $offenceNr] <= 0) {
            return 0;
        }
        $available = (int)$units['u' . $offenceNr];
        // Keep a third at home as a reserve.
        $sendable = (int)floor($available * 2 / 3);
        if ($sendable <= 0) {
            return 0;
        }
        $stats = BattleModel::unitCombatStats($race, $offenceNr);
        if ($stats['off'] <= 0) {
            return 0;
        }
        $ourOffence = $sendable * $stats['off'];

        $targets = $this->findTargets($kid, $owner);
        $sent = 0;
        foreach ($targets as $target) {
            if ($sent >= $budget) {
                break;
            }
            // Scout a real player before hitting him: the report is what the
            // player sees first ("someone is watching me"), and it is also how a
            // bot is supposed to know what it is walking into. Farms and other
            // bots are cheap enough to attack directly.
            if ($this->shouldScoutFirst($owner, $target)) {
                if ($this->sendSpy($kid, $target['kid'], $owner, $race)) {
                    $this->rememberScout($owner, $target['kid']);
                }
                // One action per round: the raid follows once the report is in.
                break;
            }
            $defence = $this->estimateDefence($target['kid']);
            if ($ourOffence < $defence * self::MIN_OFFENCE_RATIO) {
                // Not worth it (yet): leave this target for a stronger day.
                continue;
            }
            $unitsToSend = array_fill(1, 11, 0);
            $unitsToSend[$offenceNr] = $sendable;
            if (!$this->sendRaid($kid, $target['kid'], $owner, $race, $unitsToSend)) {
                continue;
            }
            ++$sent;
            // That army is on its way now; the next round uses what is left.
            break;
        }
        return $sent;
    }

    /**
     * Is this a target the bot should spy on before attacking, and has it not
     * done so recently? Only real players (not Natar farms, not other bots) are
     * worth the scout.
     */
    private function shouldScoutFirst($owner, array $target)
    {
        if ($target['isFarm'] == 1 || (int)$target['owner_access'] == 3 || (int)$target['owner'] <= 1) {
            return false;
        }
        $db = DB::getInstance();
        $last = (int)$db->fetchScalar("SELECT scout_time FROM bot_scout
                                       WHERE uid=" . (int)$owner . " AND to_kid=" . (int)$target['kid']);
        return $last + self::SCOUT_VALIDITY <= time();
    }

    private function rememberScout($owner, $toKid)
    {
        $db = DB::getInstance();
        $db->query("REPLACE INTO bot_scout (uid, to_kid, scout_time) VALUES ("
            . (int)$owner . ", " . (int)$toKid . ", " . time() . ")");
    }

    /**
     * The tribe's scout: the unit that cannot attack (offence 0) but is the
     * fastest. Roman and Teuton keep it in slot 4, Gaul in slot 3 - picking it by
     * the game's own numbers avoids hardcoding that.
     */
    public function pickScoutSlot($race)
    {
        $best = 0;
        $bestSpeed = -1;
        for ($nr = 1; $nr <= 10; ++$nr) {
            $stats = BattleModel::unitCombatStats($race, $nr);
            if ($stats['off'] > 0) {
                continue; // a fighting unit is not a scout
            }
            $speed = Formulas::uSpeed(nrToUnitId($nr, $race));
            if ($speed > $bestSpeed) {
                $bestSpeed = $speed;
                $best = $nr;
            }
        }
        return $best;
    }

    /**
     * One scout, spyType 0 (military intelligence: wall + troops, which is what
     * BattleModel puts in the report for that value).
     */
    public function sendSpy($fromKid, $toKid, $owner, $race)
    {
        $db = DB::getInstance();
        $scoutNr = $this->pickScoutSlot($race);
        if ($scoutNr <= 0) {
            return false;
        }
        $units = $db->query("SELECT * FROM units WHERE kid=$fromKid")->fetch_assoc();
        if (!$units || (int)$units['u' . $scoutNr] <= 0) {
            return false;
        }
        $farmList = new FarmListModel();
        $calc = new SpeedCalculator();
        $calc->setTournamentSqLvl($farmList->getTournamentSqLvl($fromKid));
        $calc->setArtefactEffect(ArtefactsModel::getArtifactEffectByType($owner, $fromKid, ArtefactsModel::ARTIFACT_INCREASE_SPEED));
        $calc->setFrom($fromKid);
        $calc->hasCata(false);
        $calc->setTo($toKid);
        $calc->setMinSpeed([Formulas::uSpeed(nrToUnitId($scoutNr, $race))]);
        $seconds = $calc->calc();
        if ($seconds > $this->maxTravelSeconds()) {
            return false;
        }
        $unitsToSend = array_fill(1, 11, 0);
        $unitsToSend[$scoutNr] = 1;
        if (!Units::modifyUnits($fromKid, $unitsToSend)) {
            return false;
        }
        $miliseconds = miliseconds();
        $move = new MovementsModel();
        $result = $move->addMovement($fromKid,
            $toKid,
            $race,
            $unitsToSend,
            0,
            0,
            0, // spyType 0: wall and troops
            0,
            0,
            MovementsModel::ATTACKTYPE_SPY,
            $miliseconds,
            $miliseconds + 1000 * $seconds);
        Log::addLog($owner, "botWar:spy", sprintf("from %s to %s", $fromKid, $toKid));
        return (bool)$result;
    }

    /**
     * Share of the raid rounds that go after a big player instead of a Natar
     * farm. Farms are the safe income; the players are the point of the exercise
     * ("thực sự nguy hiểm"), so both have to happen over time.
     */
    public function playerRaidShare()
    {
        $share = (int)Config::getProperty("custom", "botPlayerRaidShare");
        if ($share <= 0 || $share > 100) {
            $share = 50;
        }
        return $share;
    }

    /**
     * The slot the bot attacks with: the best attack value among the offensive
     * units it actually has at home. Slots holding only defensive troops (a
     * Phalanx, a Spearman, a Ram) are never sent out, and a unit the bot has not
     * researched yet is ignored instead of blocking the raid.
     *
     * @param array|null $units the row from the units table, or null to ignore counts
     */
    public function pickOffensiveSlot($race, array $units = null)
    {
        $best = 0;
        $bestValue = 0;
        for ($nr = 1; $nr <= 10; ++$nr) {
            if ($units !== null && (int)($units['u' . $nr] ?? 0) <= 0) {
                continue;
            }
            $stats = BattleModel::unitCombatStats($race, $nr);
            if ($stats['off'] <= $stats['def_i'] && $stats['off'] <= $stats['def_c']) {
                continue; // a defensive unit: it stays home
            }
            if ($stats['off'] > $bestValue) {
                $bestValue = $stats['off'];
                $best = $nr;
            }
        }
        return $best;
    }

    /**
     * Candidate villages, cheapest first: Natar farms are free income, then the
     * big players (the ones worth scaring), then other bots.
     *
     * @return array<int, array{kid:int, owner:int, pop:int, isFarm:int}>
     */
    private function findTargets($kid, $owner)
    {
        $db = DB::getInstance();
        $minPop = $this->minTargetPopulation();
        $now = time();
        $xy = Formulas::kid2xy($kid);
        $maxDistance = (int)Config::getProperty("game", "botMaxRaidDistance");
        if ($maxDistance <= 0) {
            $maxDistance = 60;
        }
        // Wrapped distance, same formula the farm list uses.
        $totalCoordinate = 1 + (2 * MAP_SIZE);
        $totalCoordinate2 = 1 + (3 * MAP_SIZE);
        $distance = "SQRT(POW(((w.x-{$xy['x']}+{$totalCoordinate2})%{$totalCoordinate} - " . MAP_SIZE . "), 2) + POW(((w.y-{$xy['y']}+{$totalCoordinate2})%{$totalCoordinate} - " . MAP_SIZE . "), 2))";

        // Two queries on purpose. A single query ordered "farms first" filled the
        // whole LIMIT with Natar farms on a live world, so a player was never
        // even a candidate - the bots farmed forever and never attacked anyone.
        $common = "FROM vdata v
                   JOIN users u ON u.id = v.owner
                   JOIN wdata w ON w.id = v.kid
                   WHERE v.owner <> $owner
                     AND v.isWW = 0
                     AND u.protection < $now
                     AND u.vacationActiveTil < $now
                     AND $distance <= $maxDistance";

        $targets = [];
        // Farms: the safe income, nearest first.
        $result = $db->query("SELECT v.kid, v.owner, v.pop, v.isFarm, u.total_pop AS owner_pop,
                                     u.access AS owner_access, $distance AS dist
                              $common AND v.isFarm = 1
                              ORDER BY dist ASC LIMIT 15");
        while ($row = $result->fetch_assoc()) {
            $row['kid'] = (int)$row['kid'];
            $row['owner'] = (int)$row['owner'];
            $row['isFarm'] = (int)$row['isFarm'];
            $targets[] = $row;
        }
        // Players and other bots: big enough to be worth the trip.
        $result = $db->query("SELECT v.kid, v.owner, v.pop, v.isFarm, u.total_pop AS owner_pop,
                                     u.access AS owner_access, $distance AS dist
                              $common
                                AND v.isFarm = 0
                                AND v.owner > 1
                                AND (u.total_pop >= $minPop OR u.access = 3)
                              ORDER BY u.total_pop DESC, dist ASC LIMIT 15");
        while ($row = $result->fetch_assoc()) {
            $row['kid'] = (int)$row['kid'];
            $row['owner'] = (int)$row['owner'];
            $row['isFarm'] = (int)$row['isFarm'];
            $targets[] = $row;
        }
        // Half of the rounds put the players first, so the bots also go after the
        // big accounts - that is the point of the feature. The rest of the rounds
        // take the nearest farm, which is what keeps them fed.
        if (mt_rand(1, 100) <= $this->playerRaidShare()) {
            usort($targets, function ($a, $b) {
                $aPlayer = ($a['isFarm'] == 0 && $a['owner_access'] != 3) ? 1 : 0;
                $bPlayer = ($b['isFarm'] == 0 && $b['owner_access'] != 3) ? 1 : 0;
                if ($aPlayer != $bPlayer) {
                    return $bPlayer - $aPlayer;
                }
                if ($a['owner_pop'] != $b['owner_pop']) {
                    return $b['owner_pop'] - $a['owner_pop'];
                }
                return $a['dist'] <=> $b['dist'];
            });
        } else {
            usort($targets, function ($a, $b) {
                if ($a['isFarm'] != $b['isFarm']) {
                    return $b['isFarm'] - $a['isFarm'];
                }
                return $a['dist'] <=> $b['dist'];
            });
        }
        return $targets;
    }

    /**
     * What is waiting in that village: its units plus the wall. Deliberately
     * simple - it is a go/no-go filter, not a battle simulation, and the real
     * fight is still resolved by BattleModel when the troops arrive.
     */
    public function estimateDefence($kid)
    {
        $db = DB::getInstance();
        $row = $db->query("SELECT u.race, u.u1, u.u2, u.u3, u.u4, u.u5, u.u6, u.u7, u.u8, u.u9, u.u10,
                                  (SELECT fd.f40 FROM fdata fd WHERE fd.kid = u.kid) AS wallLevel,
                                  (SELECT fd.f40t FROM fdata fd WHERE fd.kid = u.kid) AS wallType
                           FROM units u WHERE u.kid = $kid")->fetch_assoc();
        if (!$row) {
            return 0;
        }
        $defence = 0;
        for ($nr = 1; $nr <= 10; ++$nr) {
            $count = (int)$row['u' . $nr];
            if ($count <= 0) {
                continue;
            }
            $stats = BattleModel::unitCombatStats((int)$row['race'], $nr);
            // Assume the worst for us: the defender's better armour value.
            $defence += $count * max($stats['def_i'], $stats['def_c']);
        }
        $wallLevel = (int)$row['wallLevel'];
        $wallType = (int)$row['wallType'];
        if ($wallLevel > 0 && $wallType > 0) {
            // Formulas::wallPower() takes the tribe (1..7) and returns a
            // percentage, not a multiplier: 100 * (k^lvl - 1). The units row
            // carries the village's tribe, and the wall building id must not be
            // passed here (that used to raise "Undefined offset: 33").
            $wallBonus = 1 + Formulas::wallPower((int)$row['race'], $wallLevel) / 100;
            $defence = (int)round($defence * $wallBonus);
        }
        // A village always defends itself a little (BattleModel::BASE_VILLAGE_DEF).
        return $defence + BattleModel::BASE_VILLAGE_DEF;
    }

    /**
     * Same mechanics the farm list uses (SpeedCalculator + addMovement), so a
     * bot raid is indistinguishable from a player raid once it is in flight.
     */
    public function sendRaid($fromKid, $toKid, $owner, $race, array $unitsToSend)
    {
        $db = DB::getInstance();
        $farmList = new FarmListModel();
        $calc = new SpeedCalculator();
        $calc->setTournamentSqLvl($farmList->getTournamentSqLvl($fromKid));
        $calc->setArtefactEffect(ArtefactsModel::getArtifactEffectByType($owner, $fromKid, ArtefactsModel::ARTIFACT_INCREASE_SPEED));
        $calc->setFrom($fromKid);
        $calc->hasCata(false);
        $calc->setTo($toKid);
        $speeds = [];
        for ($nr = 1; $nr <= 10; ++$nr) {
            if (!empty($unitsToSend[$nr])) {
                $speeds[] = Formulas::uSpeed(nrToUnitId($nr, $race));
            }
        }
        if (!sizeof($speeds)) {
            return false;
        }
        $calc->setMinSpeed($speeds);
        $seconds = $calc->calc();
        if ($seconds > $this->maxTravelSeconds()) {
            return false;
        }
        if (!Units::modifyUnits($fromKid, $unitsToSend)) {
            return false;
        }
        $miliseconds = miliseconds();
        $move = new MovementsModel();
        $result = $move->addMovement($fromKid,
            $toKid,
            $race,
            $unitsToSend,
            0,
            0,
            0,
            0,
            0,
            MovementsModel::ATTACKTYPE_RAID,
            $miliseconds,
            $miliseconds + 1000 * $seconds);
        Log::addLog($owner, "botWar:raid",
            sprintf("from %s to %s units=%s travel=%ds", $fromKid, $toKid,
                implode(",", array_filter($unitsToSend)), $seconds));
        return (bool)$result;
    }

    // ---------------------------------------------------------------- oases ----

    /**
     * Oasis farming: the income a bot has besides its own fields.
     *
     * An unoccupied oasis stores a few thousand resources and regenerates on its
     * own, which is exactly what a bot needs once it has spent its production on
     * troops and stops growing. Two phases per oasis:
     *
     *  - the oasis still has guards (the game spawns up to 15, see
     *    OasesModel::oasesTrainV3): one big wave, because a small run would be
     *    wiped out and the oasis would stay closed. The wave is only sent when
     *    the army is clearly stronger than the guards (botOasisClearRatio), so a
     *    bot does not throw its troops away on an oasis it cannot take;
     *  - the guards are gone: small recurring runs (botOasisCollectUnits, 10 by
     *    default) that carry the resources home.
     *
     * Every bot gets its turn: the rotation is by users.botLastFarm, and that
     * stamp is written whether or not a raid went out, so a bot with no army
     * cannot block the queue for the others.
     *
     * Only oases nobody owns are used (owner = 0 AND did = 0), so this never
     * steals from a player who has captured one.
     *
     * @return int number of oasis raids sent
     */
    public function processOasisFarming()
    {
        if (!getCustom('botOasisFarmEnabled')) {
            return 0;
        }
        $this->ensureSchema();
        $db = DB::getInstance();
        $now = time();
        $sent = 0;
        $seen = [];
        $rotation = $this->oasisRotation();
        // Fair rotation over the bots, oldest attempt first. The stamp below is
        // written even when nothing could be sent, so a bot without an army (or
        // without a free oasis in range) cannot sit at the front of the queue
        // forever and eat the whole per-run budget - that is how half the world's
        // bots ended up with no income at all.
        $result = $db->query("SELECT v.kid, v.owner, u.race
                              FROM vdata v
                              JOIN users u ON u.id = v.owner
                              WHERE u.access = 3
                                AND u.protection < $now
                                AND u.vacationActiveTil < $now
                                AND u.botLastFarm + $rotation <= $now
                                AND (SELECT fd.f39 FROM fdata fd WHERE fd.kid = v.kid) > 0
                                AND EXISTS (SELECT 1 FROM units un WHERE un.kid = v.kid
                                            AND (un.u1+un.u2+un.u3+un.u4+un.u5+un.u6+un.u7+un.u8+un.u9+un.u10) > 0)
                              ORDER BY u.botLastFarm ASC, v.kid ASC
                              LIMIT " . self::OASIS_VILLAGES_PER_RUN);
        while ($row = $result->fetch_assoc()) {
            if ($sent >= self::OASIS_RAIDS_PER_RUN) {
                break;
            }
            $uid = (int)$row['owner'];
            // One attempt per bot per round, even when it owns several villages.
            if (isset($seen[$uid])) {
                continue;
            }
            $seen[$uid] = true;
            // Stamp first, so one bot cannot take the whole budget on every tick.
            $db->query("UPDATE users SET botLastFarm=$now WHERE id=$uid");
            $sent += $this->farmOasisFromVillage((int)$row['kid'], $uid, (int)$row['race']);
        }
        if ($sent > 0) {
            Log::addLog(0, "botWar:oasis", sprintf("%d oasis raid(s) sent", $sent));
        }
        return $sent;
    }

    /**
     * @return int 1 when a raid was sent from this village
     */
    private function farmOasisFromVillage($kid, $owner, $race)
    {
        $db = DB::getInstance();
        $village = $db->query("SELECT wood, clay, iron, maxstore FROM vdata WHERE kid=$kid")->fetch_assoc();
        if (!$village) {
            return 0;
        }
        // A full store turns the run into a loss: the loot is capped away and the
        // troops are gone from home for nothing.
        if ($this->isStoreFull($village)) {
            return 0;
        }
        $units = $db->query("SELECT * FROM units WHERE kid=$kid")->fetch_assoc();
        if (!$units) {
            return 0;
        }
        $offensive = [];
        for ($nr = 1; $nr <= 10; ++$nr) {
            $count = (int)($units['u' . $nr] ?? 0);
            if ($count <= 0) {
                continue;
            }
            $stats = BattleModel::unitCombatStats($race, $nr);
            if ($stats['off'] <= 0 || ($stats['off'] <= $stats['def_i'] && $stats['off'] <= $stats['def_c'])) {
                continue; // a defensive unit never leaves the village
            }
            $offensive[$nr] = $count;
        }
        if (!sizeof($offensive)) {
            return 0;
        }
        $ourOffence = $this->offenceStrength($race, $offensive);
        $free = [];
        $guarded = [];
        foreach ($this->pickOasisTargets($kid, $owner) as $oasis) {
            if ($oasis['guards'] > 0) {
                $guarded[] = $oasis;
            } else {
                $free[] = $oasis;
            }
        }
        // A cleared oasis is instant income; a guarded one is the "clear it
        // first" phase, so it is only started on a share of the runs - otherwise
        // the bots would only ever collect from the oases that are already open
        // and no new one would ever be cleared.
        $candidates = $free;
        if (sizeof($guarded) && mt_rand(1, 100) <= $this->oasisClearChance()) {
            $candidates = array_merge($guarded, $free);
        }
        foreach ($candidates as $oasis) {
            $toSend = array_fill(1, 11, 0);
            if ($oasis['guards'] > 0) {
                // Never walk into a fight the army cannot win: a wiped wave
                // leaves the oasis closed *and* the bot without an army.
                if ($ourOffence < $this->estimateDefence($oasis['kid']) * $this->oasisClearRatio()) {
                    continue; // too strong for now: try the next candidate
                }
                // Guards: send everything that can attack, or the run dies and
                // the oasis never opens up.
                foreach ($offensive as $nr => $count) {
                    $toSend[$nr] = $count;
                }
            } else {
                // Empty: a small collect run, spread over the offensive slots.
                $left = $this->oasisCollectUnits();
                foreach ($offensive as $nr => $count) {
                    if ($left <= 0) {
                        break;
                    }
                    $toSend[$nr] = min($count, $left);
                    $left -= $toSend[$nr];
                }
            }
            if (!array_sum($toSend)) {
                continue;
            }
            if (!$this->sendRaid($kid, $oasis['kid'], $owner, $race, $toSend)) {
                continue;
            }
            $db->query("REPLACE INTO bot_oasis (uid, kid, last_raid) VALUES ("
                . (int)$owner . ", " . $oasis['kid'] . ", " . time() . ")");
            return 1;
        }
        return 0;
    }

    /**
     * Free oases this bot has not stripped recently, cheapest first: the ones
     * without guards (instant income) before the guarded ones. The LEFT JOIN on
     * bot_oasis keeps oases the bot has never touched in the running; the
     * cooldown is what stops it from raiding the same empty oasis every tick.
     *
     * @return array<int, array{kid:int, guards:int, dist:float}>
     */
    private function pickOasisTargets($kid, $owner)
    {
        $db = DB::getInstance();
        $xy = Formulas::kid2xy($kid);
        $totalCoordinate = 1 + (2 * MAP_SIZE);
        $totalCoordinate2 = 1 + (3 * MAP_SIZE);
        $distance = "SQRT(POW(((w.x-{$xy['x']}+{$totalCoordinate2})%{$totalCoordinate} - " . MAP_SIZE . "), 2) + POW(((w.y-{$xy['y']}+{$totalCoordinate2})%{$totalCoordinate} - " . MAP_SIZE . "), 2))";
        $maxDistance = $this->oasisMaxDistance();
        $cooldown = $this->oasisCooldown();
        $now = time();
        $guards = "COALESCE(gu.u1,0)+COALESCE(gu.u2,0)+COALESCE(gu.u3,0)+COALESCE(gu.u4,0)+COALESCE(gu.u5,0)"
            . "+COALESCE(gu.u6,0)+COALESCE(gu.u7,0)+COALESCE(gu.u8,0)+COALESCE(gu.u9,0)+COALESCE(gu.u10,0)";
        $result = $db->query("SELECT o.kid, $guards AS guards, $distance AS dist
                              FROM odata o
                              JOIN wdata w ON w.id = o.kid
                              LEFT JOIN units gu ON gu.kid = o.kid
                              LEFT JOIN bot_oasis b ON b.kid = o.kid AND b.uid = " . (int)$owner . "
                              WHERE o.owner = 0 AND o.did = 0
                                AND (b.last_raid IS NULL OR b.last_raid + $cooldown <= $now)
                                AND $distance <= $maxDistance
                              ORDER BY ($guards > 0) ASC, dist ASC
                              LIMIT " . self::OASIS_CANDIDATES);
        $out = [];
        while ($row = $result->fetch_assoc()) {
            $row['kid'] = (int)$row['kid'];
            $row['guards'] = (int)$row['guards'];
            $out[] = $row;
        }
        return $out;
    }

    /** Attack power of the units a bot is about to send. */
    private function offenceStrength($race, array $units)
    {
        $total = 0;
        foreach ($units as $nr => $count) {
            $stats = BattleModel::unitCombatStats($race, $nr);
            $total += $count * $stats['off'];
        }
        return $total;
    }

    /** Wood, clay and iron at the cap: a farming run would only fill the void. */
    private function isStoreFull(array $village)
    {
        $max = (int)$village['maxstore'];
        if ($max <= 0) {
            return false;
        }
        foreach (['wood', 'clay', 'iron'] as $resource) {
            if ((float)$village[$resource] < $max * self::STORE_FULL_RATIO) {
                return false;
            }
        }
        return true;
    }

    public function oasisCollectUnits()
    {
        $units = (int)getCustom('botOasisCollectUnits');
        return $units > 0 ? $units : self::OASIS_COLLECT_UNITS;
    }

    public function oasisMaxDistance()
    {
        $distance = (int)getCustom('botOasisMaxDistance');
        return $distance > 0 ? $distance : self::OASIS_MAX_DISTANCE;
    }

    /** Seconds between two farming attempts of the same bot. */
    public function oasisRotation()
    {
        $seconds = (int)getCustom('botOasisRotationSeconds');
        return $seconds > 0 ? $seconds : self::OASIS_ROTATION;
    }

    /** Seconds before the same bot may strip the same oasis again. */
    public function oasisCooldown()
    {
        $seconds = (int)getCustom('botOasisCooldownSeconds');
        return $seconds > 0 ? $seconds : self::OASIS_COOLDOWN;
    }

    /** How much stronger than the guards a clearing wave has to be. */
    public function oasisClearRatio()
    {
        $ratio = (float)getCustom('botOasisClearRatio');
        return $ratio > 0 ? $ratio : self::OASIS_CLEAR_RATIO;
    }

    /** Share of the runs that go for a guarded oasis instead of a free one. */
    public function oasisClearChance()
    {
        $chance = (int)getCustom('botOasisClearChance');
        return ($chance > 0 && $chance <= 100) ? $chance : self::OASIS_CLEAR_CHANCE;
    }

    // ---------------------------------------------------------------- gold ----

    /**
     * Bots spend the gold they accumulate (dailyGold, quests, medals):
     * a Plus account first, then a production boost on the village that has none.
     * GoldHelper is session bound, but the gold accounting itself is not - so the
     * balances go through GoldHelper::decreaseGold() and only the "add the
     * effect" part is repeated here.
     *
     * @return int number of purchases
     */
    public function spendGold()
    {
        if (!getCustom('botSpendGoldEnabled')) {
            return 0;
        }
        $this->ensureSchema();
        $config = Config::getInstance();
        $db = DB::getInstance();
        $now = time();
        $bought = 0;

        $result = $db->query("SELECT id, gift_gold + bought_gold AS gold, plus, b1, b2, b3, b4
                              FROM users
                              WHERE access = 3
                                AND botLastGold + " . self::GOLD_COOLDOWN . " <= $now
                                AND gift_gold + bought_gold >= " . (int)$config->gold->plusGold . "
                              ORDER BY botLastGold ASC, id ASC
                              LIMIT 40");
        while ($row = $result->fetch_assoc()) {
            $uid = (int)$row['id'];
            $db->query("UPDATE users SET botLastGold=$now WHERE id=$uid");
            // Plus only when it has run out, otherwise the bot would extend Plus
            // forever and never buy the production boost.
            if ((int)$row['plus'] <= $now) {
                $till = $now + $config->gold->plusAccountDurationSeconds;
                if (GoldHelper::decreaseGold($uid, $config->gold->plusGold)) {
                    $db->query("UPDATE users SET plus=$till WHERE id=$uid");
                    ++$bought;
                }
                continue;
            }
            // Plus is running: push production on the first resource without it.
            for ($resource = 1; $resource <= 4; ++$resource) {
                if ((int)$row['b' . $resource] > $now) {
                    continue;
                }
                $till = $now + $config->gold->productionBoostDurationSeconds;
                if (GoldHelper::decreaseGold($uid, $config->gold->productionBoostGold)) {
                    $db->query("UPDATE users SET b$resource=$till WHERE id=$uid");
                    ++$bought;
                }
                break;
            }
        }
        if ($bought > 0) {
            Log::addLog(0, "botWar:gold", sprintf("%d purchase(s)", $bought));
        }
        return $bought;
    }

    // ------------------------------------------------------------- defence ----

    /**
     * Bots that are being attacked train defenders instead of attackers. Called
     * from the automation tick; cheap because it only looks at incoming
     * movements of the last day.
     *
     * @return int number of bot villages that switched to defence
     */
    public function defendThreatenedVillages()
    {
        if (!$this->isEnabled()) {
            return 0;
        }
        $db = DB::getInstance();
        $since = (time() - 86400) * 1000;
        $result = $db->query("SELECT DISTINCT v.owner
                              FROM movement m
                              JOIN vdata v ON v.kid = m.to_kid
                              JOIN users u ON u.id = v.owner
                              WHERE u.access = 3 AND m.mode = 0 AND m.start_time >= $since
                              LIMIT 30");
        $owners = [];
        while ($row = $result->fetch_assoc()) {
            $owners[] = (int)$row['owner'];
        }
        if (!sizeof($owners)) {
            return 0;
        }
        // Mark them so the AI trains guards (see Core\AI::chooseUnit()).
        $db->query("UPDATE users SET botDefendUntil=" . (time() + 3600) . " WHERE id IN (" . implode(",", $owners) . ")");
        return sizeof($owners);
    }
}
