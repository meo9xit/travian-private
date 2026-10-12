<?php

namespace Model;

use Core\Config;
use Core\Database\DB;
use Core\Log;
use Game\GoldHelper;
use function getCustom;

/**
 * Paid automatic farm-list raiding.
 *
 * A player pays gold once (config: gold->autoRaidGold, default 250) and from
 * then on every village that is marked in ANY of their farm lists is raided
 * automatically, every N minutes - N chosen by the player. The purchase lasts
 * for the rest of the round: the flag lives on the user row, and a new round
 * starts from a fresh schema, so nothing has to expire it.
 *
 * The stock silver based auto raid (FarmListModel::processAutoRaid, driven by
 * custom->autoRaidEnabled) is left untouched; this is a separate, premium path
 * driven by custom->autoRaidPremiumEnabled.
 */
class AutoRaidModel
{
    /** Bounds for the interval the player may pick, in minutes. */
    const MIN_MINUTES = 5;
    const MAX_MINUTES = 1440;
    const DEFAULT_MINUTES = 15;

    /** How many farm lists one automation tick may serve. */
    const LISTS_PER_RUN = 25;

    /** ensureSchema() runs once per request. */
    private static $schemaChecked = false;

    public function isEnabled()
    {
        return (bool)getCustom('autoRaidPremiumEnabled');
    }

    public function getPrice()
    {
        $price = Config::getProperty("gold", "autoRaidGold");
        return $price > 0 ? (int)$price : 250;
    }

    public function clampMinutes($minutes)
    {
        $minutes = (int)$minutes;
        if ($minutes < self::MIN_MINUTES) return self::MIN_MINUTES;
        if ($minutes > self::MAX_MINUTES) return self::MAX_MINUTES;
        return $minutes;
    }

    /**
     * The two columns this feature needs. Added here rather than only in the
     * schema so that worlds installed before this feature existed keep working
     * without a manual migration; the ALTER runs at most once per request.
     */
    public function ensureSchema()
    {
        if (self::$schemaChecked) {
            return;
        }
        self::$schemaChecked = true;
        $db = DB::getInstance();
        if (!$db->fetchScalar("SHOW COLUMNS FROM users LIKE 'autoRaidPaid'")) {
            $db->query("ALTER TABLE users ADD COLUMN `autoRaidPaid` INT(11) NOT NULL DEFAULT '0'");
        }
        if (!$db->fetchScalar("SHOW COLUMNS FROM users LIKE 'autoRaidMinutes'")) {
            $db->query("ALTER TABLE users ADD COLUMN `autoRaidMinutes` SMALLINT(5) UNSIGNED NOT NULL DEFAULT '0'");
        }
    }

    public function isActive($uid)
    {
        $this->ensureSchema();
        $db = DB::getInstance();
        return (int)$db->fetchScalar("SELECT autoRaidPaid FROM users WHERE id=" . (int)$uid) > 0;
    }

    public function getMinutes($uid)
    {
        $this->ensureSchema();
        $db = DB::getInstance();
        $minutes = (int)$db->fetchScalar("SELECT autoRaidMinutes FROM users WHERE id=" . (int)$uid);
        return $minutes > 0 ? $this->clampMinutes($minutes) : self::DEFAULT_MINUTES;
    }

    public function getPurchasedAt($uid)
    {
        $this->ensureSchema();
        $db = DB::getInstance();
        return (int)$db->fetchScalar("SELECT autoRaidPaid FROM users WHERE id=" . (int)$uid);
    }

    /**
     * @return array ['ok' => bool, 'error' => string, 'gold' => int|null]
     */
    public function buy($uid, $minutes)
    {
        $uid = (int)$uid;
        $db = DB::getInstance();
        if (!$this->isEnabled()) {
            return ['ok' => false, 'error' => 'Auto raid is disabled on this server.'];
        }
        $this->ensureSchema();
        if ($this->isActive($uid)) {
            return ['ok' => false, 'error' => 'You already own auto raid for this round.'];
        }
        $minutes = $this->clampMinutes($minutes);
        $price = $this->getPrice();
        // decreaseGold() is the game's own gold sink: it takes from gift_gold
        // first, then bought_gold, and is a no-op (always succeeds) when
        // custom->serverIsFreeGold is on.
        if (!GoldHelper::decreaseGold($uid, $price)) {
            return ['ok' => false, 'error' => 'Not enough gold. Auto raid costs ' . $price . ' gold.'];
        }
        $db->query("UPDATE users SET autoRaidPaid=" . time() . ", autoRaidMinutes=$minutes WHERE id=$uid");
        Log::addLog($uid, "autoRaidPremium:buy", sprintf("minutes=%d price=%d", $minutes, $price));
        return ['ok' => true, 'error' => null, 'gold' => $this->getGold($uid), 'minutes' => $minutes, 'price' => $price];
    }

    public function updateMinutes($uid, $minutes)
    {
        $uid = (int)$uid;
        if (!$this->isActive($uid)) {
            return ['ok' => false, 'error' => 'You do not own auto raid yet.'];
        }
        $minutes = $this->clampMinutes($minutes);
        $db = DB::getInstance();
        $db->query("UPDATE users SET autoRaidMinutes=$minutes WHERE id=$uid");
        // The new interval applies from the next tick.
        $db->query("UPDATE farmlist SET randSec=" . ($minutes * 60) . " WHERE owner=$uid");
        Log::addLog($uid, "autoRaidPremium:minutes", sprintf("minutes=%d", $minutes));
        return ['ok' => true, 'error' => null, 'minutes' => $minutes];
    }

    public function getGold($uid)
    {
        $db = DB::getInstance();
        $gold = $db->fetchScalar("SELECT gift_gold+bought_gold FROM users WHERE id=" . (int)$uid);
        return (int)$gold;
    }

    /**
     * One automation tick: raid every farm list of every player who bought the
     * feature, as long as that list's own interval has elapsed. All targets
     * marked in the list are attacked (FarmListModel::autoRaidFarmList walks
     * every raidlist slot), no silver is charged.
     *
     * @return int number of farm lists that sent at least one raid
     */
    public function processPremiumAutoRaid()
    {
        if (!$this->isEnabled()) {
            return 0;
        }
        $this->ensureSchema();
        $db = DB::getInstance();
        $now = time();
        $served = 0;
        $result = $db->query("SELECT f.id AS lid, f.kid, f.owner, f.lastRaid,
                                     u.autoRaidMinutes, u.vacationActiveTil, u.access,
                                     (SELECT fd.f39 FROM fdata fd WHERE fd.kid=f.kid) AS rallyPointLevel
                              FROM farmlist f, users u
                              WHERE f.owner=u.id
                                AND u.autoRaidPaid > 0
                                AND u.autoRaidMinutes > 0
                                AND f.lastRaid + (u.autoRaidMinutes * 60) <= $now
                                AND u.access IN (0, 1)
                              ORDER BY f.lastRaid ASC
                              LIMIT " . self::LISTS_PER_RUN);
        $farmList = new FarmListModel();
        while ($row = $result->fetch_assoc()) {
            // Stamp first: a failing raid must not make the next tick retry in a
            // tight loop, and this also keeps two engine ticks from overlapping.
            $db->query("UPDATE farmlist SET lastRaid=" . $now . ", randSec=" . ($row['autoRaidMinutes'] * 60) . " WHERE id={$row['lid']}");
            if ($row['vacationActiveTil'] > $now) {
                continue;
            }
            // Troops can only leave a village that has a rally point.
            if (!$row['rallyPointLevel']) {
                continue;
            }
            $sent = $farmList->autoRaidFarmList($row['lid'], $row['owner'], $row['kid'], true);
            if ($sent > 0) {
                ++$served;
            }
        }
        if ($served > 0) {
            Log::addLog(0, "autoRaidPremium:tick", sprintf("%d farm list(s) raided", $served));
        }
        return $served;
    }
}
