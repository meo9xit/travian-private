<?php

use Core\Database\DB;
use Game\Formulas;
use Game\ResourcesHelper;
use Model\VillageModel;

$isInternal = defined("ROOT_PATH");
if (!$isInternal) {
    require_once(__DIR__ . DIRECTORY_SEPARATOR . "include" . DIRECTORY_SEPARATOR . "bootstrap.php");
}
set_time_limit(0);
ignore_user_abort(true);

/**
 * Repairs the crop economy of a world that was affected by the negative crop
 * bug (crop stuck on 0 although the fields produce, market deliveries / NPC
 * trades / gold packages never showing up).
 *
 * It does three things for every village:
 *  1. storage capacity: a village whose maxcrop (or maxstore) is below a level 0
 *     granary (warehouse) can never keep resources, because
 *     ResourcesHelper::updateVillageResources() caps every update at that
 *     value. The capacity is recomputed from the granary/warehouse buildings,
 *     the same way src/fixes/fixStorages.php does it.
 *  2. a negative crop is reset to 0 (it is a debt the UI cannot render and it
 *     only eats everything added afterwards). New code never stores it again.
 *  3. upkeep + crop production are recalculated so the stock bar and the crop
 *     balance are consistent again.
 */
$db = DB::getInstance();
$villageModel = new VillageModel();

$capacityOf = function (array $buildings) {
    $store = 0;
    $cropStore = 0;
    for ($i = 19; $i <= 40; ++$i) {
        if (!isset($buildings[$i])) {
            continue;
        }
        $item = (int)$buildings[$i]['item_id'];
        $level = (int)$buildings[$i]['level'];
        if ($item == 10) {
            $store += Formulas::storeCAP($level);
        } else if ($item == 38) {
            $store += Formulas::bigStoreCAP($level);
        } else if ($item == 11) {
            $cropStore += Formulas::storeCAP($level);
        } else if ($item == 39) {
            $cropStore += Formulas::bigStoreCAP($level);
        }
    }
    return [$store, $cropStore];
};

$minStore = Formulas::storeCAP(0);
$checked = 0;
$repairedCapacity = 0;
$repairedCrop = 0;
$starving = [];

$stmt = $db->query("SELECT kid, owner, isWW, pop, crop, cropp, maxstore, maxcrop, extraMaxstore, extraMaxcrop, upkeep FROM vdata");
while ($row = $stmt->fetch_assoc()) {
    ++$checked;
    $kid = (int)$row['kid'];

    // 1) heal storage capacity of real villages only (Natars / farm villages
    //    are owned by 0/1 and use the special crop handling).
    if ($row['owner'] > 1) {
        list($store, $cropStore) = $capacityOf($villageModel->getBuildingsAssoc($kid));
        if ((float)$row['maxstore'] < $minStore) {
            $maxstore = max($minStore, $store + Formulas::storeCAP(20) * (int)$row['extraMaxstore']);
            $db->query("UPDATE vdata SET maxstore=$maxstore WHERE kid=$kid");
            ++$repairedCapacity;
        }
        if ((float)$row['maxcrop'] < $minStore) {
            $maxcrop = max($minStore, $cropStore + Formulas::storeCAP(20) * (int)$row['extraMaxcrop']);
            $db->query("UPDATE vdata SET maxcrop=$maxcrop WHERE kid=$kid");
            ++$repairedCapacity;
        }
    }

    // 2) crop is a stock, never a debt.
    if ((float)$row['crop'] < 0) {
        $db->query("UPDATE vdata SET crop=0 WHERE kid=$kid");
        ++$repairedCrop;
    }

    // 3) recompute upkeep first (updateVillageResources reads vdata.upkeep),
    //    then production + the resource accrual.
    ResourcesHelper::updateVillageUpkeep((int)$row['owner'], $kid, $row['isWW'] == 1);
    ResourcesHelper::updateVillageResources($kid, FALSE);

    $after = $db->query("SELECT crop, cropp, pop, upkeep, maxcrop FROM vdata WHERE kid=$kid")->fetch_assoc();
    if (!$after) {
        continue;
    }
    $balance = (float)$after['cropp'] - (float)$after['pop'] - (float)$after['upkeep'];
    if ($balance <= 0) {
        $starving[$kid] = [
            'balance' => $balance,
            'cropp'   => (float)$after['cropp'],
            'pop'     => (float)$after['pop'],
            'upkeep'  => (float)$after['upkeep'],
            'crop'    => (float)$after['crop'],
            'maxcrop' => (float)$after['maxcrop'],
        ];
    }
}

uasort($starving, function ($a, $b) {
    return $a['balance'] <=> $b['balance'];
});
$starving = array_slice($starving, 0, 10, TRUE);

$report = [];
$report[] = "Villages checked: $checked";
$report[] = "Storage capacity repaired: $repairedCapacity";
$report[] = "Negative crop reset to 0: $repairedCrop";
if (sizeof($starving)) {
    $report[] = "Villages whose upkeep is still above their crop production (they will show crop = 0 until the troops die or the crop fields / oasis are upgraded):";
    foreach ($starving as $kid => $info) {
        $report[] = sprintf("  kid %d: crop production %.0f/h, population %.0f, upkeep %.0f => balance %.0f/h, crop %.0f / %.0f",
            $kid, $info['cropp'], $info['pop'], $info['upkeep'], $info['balance'], $info['crop'], $info['maxcrop']);
    }
} else {
    $report[] = "No village has a negative crop balance: crop grows normally everywhere now.";
}
$GLOBALS['cropFixReport'] = implode(PHP_EOL, $report);

if (!$isInternal) {
    echo implode(PHP_EOL, $report), PHP_EOL;
    echo 'Patch done.', time();
}
