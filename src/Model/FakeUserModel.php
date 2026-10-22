<?php

namespace Model;

use Core\AI;
use Core\Config;
use Core\Database\DB;
use function getGameElapsedSeconds;
use function getGameSpeed;
use function make_seed;


class FakeUserModel
{
    /**
     * Bot villages that get an AI step per automation tick. The job runs every
     * 90 seconds, so this is ~40 villages per 90 seconds = enough to walk the
     * whole bot population in a few minutes on a normal world.
     */
    const AI_VILLAGES_PER_RUN = 40;

    /**
     * Most AI steps a single village may catch up with in one tick. A village
     * that was skipped for hours would otherwise burn its whole store (and its
     * whole building queue) in one go.
     */
    const MAX_CATCHUP_STEPS = 6;

    public function handleFakeUsers()
    {
        if (!$this->canRun()) return;
        $db = DB::getInstance();
        // The war columns are read by the AI step below (Core\AI::isDefending),
        // so make sure they exist before the first bot is processed - a missing
        // column would raise a warning, and in CLI a warning is an exception.
        $war = new BotWarModel();
        $war->ensureSchema();
        $interval = mt_rand(3600, 10800);
        $stmt = $db->query("SELECT id FROM users WHERE access=3 AND lastHeroExpCheck <= " . (time() - $interval) . " LIMIT 10");
        while ($row = $stmt->fetch_assoc()) {
            $db->query("UPDATE users SET lastHeroExpCheck=" . time() . " WHERE id={$row['id']}");
            $exp = mt_rand(10, 50) * ceil(getGameSpeed() / 100);
            $db->query("UPDATE hero SET exp=exp+$exp WHERE uid={$row['id']}");
        }
        if (getGameSpeed() <= 10) {
            $interval = mt_rand(600, 3600);
        } else if (getGameSpeed() <= 100) {
            $interval = mt_rand(200, 400);
        } else if (getGameSpeed() <= 1000) {
            $interval = mt_rand(100, 250);
        } else {
            $interval = mt_rand(50, 150);
        }
        // Fair rotation over *all* bot villages. Without the ORDER BY, MySQL
        // returned the rows in primary-key order, so every tick the same ~30
        // lowest kid numbers were the only ones eligible (each of them stays
        // stamped for $checkInterval seconds) and every other bot village never
        // got an AI step at all - that is the "half the bots grow, the rest
        // stand still" symptom. Oldest first means every village gets its turn
        // and the ones that waited longest are served first.
        $checkInterval = 200;
        $time = time() - $checkInterval;
        $now = time();
        $results = $db->query("SELECT kid, lastVillageCheck
                               FROM vdata v
                               WHERE lastVillageCheck < $time
                                 AND (SELECT access FROM users WHERE id=v.owner)=3
                               ORDER BY lastVillageCheck ASC, kid ASC
                               LIMIT " . self::AI_VILLAGES_PER_RUN);
        while ($row = $results->fetch_assoc()) {
            $db->query("UPDATE vdata SET lastVillageCheck=$now WHERE kid={$row['kid']}");
            if ($row['lastVillageCheck'] <= 10) continue;
            // A village that was skipped for a while catches up, but only up to
            // a point: a burst of steps is not the goal of the feature.
            $count = (int)ceil(($now - $row['lastVillageCheck']) / $interval);
            if ($count > self::MAX_CATCHUP_STEPS) {
                $count = self::MAX_CATCHUP_STEPS;
            }
            AI::doSomethingRandom($row['kid'], $count);
        }

        // War and economy: these used to have no equivalent at all, so the bots
        // never left their village and never spent a single coin of gold.
        if ($war->isEnabled()) {
            $war->defendThreatenedVillages();
            $war->processRaids();
        }
        // Farming runs even when raiding is off: it is what keeps a bot growing
        // once its own production is spent on troops (see BotWarModel::processOasisFarming).
        $war->processOasisFarming();
        $war->spendGold();
    }

    private function canRun()
    {
        if (getGameElapsedSeconds() <= 0 || !Config::getProperty("dynamic", "fakeAccountProcess")) return false;
        make_seed();
        return true;
    }

    public function handleFakeUserExpands()
    {
        if (!$this->canRun()) return;
        if (getGameSpeed() <= 10) {
            $elapsedSeconds = getGameElapsedSeconds();
            if ($elapsedSeconds <= 4 * 86400) {
                $interval = 3 * 86400;
            } else if ($elapsedSeconds <= 15 * 86400) {
                $interval = 7 * 86400;
            } else if ($elapsedSeconds <= 45 * 86400) {
                $interval = 5 * 86400;
            } else {
                $interval = 15 * 86400;
            }
        } else {
            $interval = (mt_rand(65, 165) / 100) * 86400;
        }
        $limit = 5;
        $time = time() - $interval;
        $db = DB::getInstance();
        $register = new RegisterModel();
        // Oldest first, like the AI step above: without the ORDER BY the same
        // low ids were returned every run and the rest of the bots never
        // expanded at all.
        $result = $db->query("SELECT id, race, lastVillageExpand
                              FROM users
                              WHERE access=3 AND lastVillageExpand<=$time
                              ORDER BY lastVillageExpand ASC, id ASC
                              LIMIT $limit");
        while ($row = $result->fetch_assoc()) {
            $db->query("UPDATE users SET lastVillageExpand=" . ($time + $interval) . " WHERE id={$row['id']}");
            if ($row['lastVillageExpand'] == 0) {
                continue;
            }
            $count = ceil((time() - $row['lastVillageExpand']) / $interval);
            // Clustered expansion: the new village goes next to the bot's capital
            // (and preferably next to oases), so the villages can support each
            // other and feed the main one, instead of being scattered at random.
            $find = $register->generateFakeUserVillageNear($row['id'], $count);
            if (!empty($find)) {
                $villages = explode(",", $find);
                $db->query("UPDATE available_villages SET occupied=1 WHERE kid IN($find)");
                foreach ($villages as $kid) {
                    $register->createNewVillage($row['id'], $row['race'], $kid);
                }
            }
        }
    }
}

