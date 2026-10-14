<?php

namespace Game\Buildings;

use Core\Config;
use Core\Database\DB;
use Game\Formulas;
use const SORT_ASC;
use function in_array;

class AutoUpgradeAI
{
    /**
     * Order in which a fake player fills its empty building slots.
     *
     * This used to be a shuffled list, which is why bots ended up with crannies
     * and no barracks: a bot without a rally point (16) can never send a raid and
     * a bot without a barracks (19) can never train the troops for one. The order
     * below builds the war machine first, then the economy, then the extras - a
     * new village gets a rally point and a barracks within its first day.
     */
    const BUILDING_PRIORITY = [
        16, // rally point  - nothing can leave the village without it
        19, // barracks     - trains the army
        10, // warehouse    - resources are lost at the cap
        11, // granary
        23, // cranny       - the only defence a small village has
        40, // wall         - handled by the caller as the wall slot
        22, // academy      - unlocks better troops (research)
        13, // smithy       - upgrades troops
        15, // main building - faster building
        20, // stable
        21, // workshop
        17, // marketplace
        18, // embassy
        34, // trapper (Teuton)
        35, // brewery
        36, // great warehouse
        37, // great granary
        24, // town hall
        25, // residence
        26, // palace
        27, // trade office
        28, // great barracks
        29, // great stable
        30, // tournament square
        44, // horse drinking trough
        45, // great workshop
        14, // tournament square (alt id)
    ];

    private $buildings = [], $resources = [], $buildingsStatic = [];
    private $capital = false, $hasPlus = false, $isWW = false, $skipWorkers = false;
    private $kid, $race = 5;
    private $main_building_lvl = 0, $creationTime = 0, $maxstore = 0, $maxcrop = 0, $croploading = 0, $cropProduction = 0, $upkeep = 0;
    private $workers = ['buildsNum' => 0, 'fieldsNum' => 0, 'master' => 0, 'WW' => 0];
    public function skipWorkers(){
        $this->skipWorkers = true;
    }
    public function __construct($kid, &$resources, &$buildings, $hasPlus, $race, $village)
    {
        $this->kid = $kid;
        $this->race = $race;
        $this->resources = &$resources;
        $this->buildings = &$buildings;
        $this->capital = $village['capital'];
        $this->hasPlus = $hasPlus;
        $this->creationTime = $village['created'];
        $this->maxstore = $village['maxstore'];
        $this->maxcrop = $village['maxcrop'];
        $this->isWW = $village['isWW'];
        $this->cropProduction = $village['cropp'];
        $this->upkeep = $village['upkeep'];
        $this->buildingsStatic = $this->buildings;
        for ($i = 19; $i <= 38; ++$i) {
            if ($this->buildings[$i]['item_id'] == 15) {
                $this->main_building_lvl = $this->buildings[$i]['level'];
            }
        }
        $this->croploading = $this->getCropLoading($this->kid, $this->isWW, $this->buildingsStatic);
        $db = DB::getInstance();
        $this->workers = [
            'fieldsNum' => (int)$db->fetchScalar("SELECT COUNT(id) FROM building_upgrade WHERE kid=$kid AND building_field <= 18 AND isMaster=0"),
            'buildsNum' => (int)$db->fetchScalar("SELECT COUNT(id) FROM building_upgrade WHERE kid=$kid AND building_field > 18 AND isMaster=0"),
            'master' => (int)$db->fetchScalar("SELECT COUNT(id) FROM building_upgrade WHERE kid=$kid AND isMaster=1"),
            'WW' => (int)$db->fetchScalar("SELECT COUNT(id) FROM building_upgrade WHERE kid=$kid AND building_field=99"),
        ];
    }

    private function isWorkersBusy($isField, $isWWQueue = FALSE)
    {
        $config = Config::getInstance();
        $hasPlus = $this->hasPlus;
        $maxTasks = $hasPlus ? 2 : 1; //its with wonder
        $fieldsNum = $this->workers['fieldsNum'];
        $buildsNum = $this->workers['buildsNum'];
        $master = $this->workers['master'];
        if($isWWQueue){
            $maxTasks = 2;
        }
        if ($this->race == 1) {
            return [
                'isMasterBusy' => $master >= ($this->isWW ? $config->masterBuilder->maxTasksInWonder : $config->masterBuilder->maxTasksInNoneWonder),
                'isBusy' => (($isField) ? ($fieldsNum >= $maxTasks) : ($buildsNum >= $maxTasks)) || ($fieldsNum + $buildsNum) >= 3,
                'isPlusUsed' => ($hasPlus ? ($isField ? ($fieldsNum > 0) : ($buildsNum > 0)) : FALSE),
            ];
        }
        return [
            'isMasterBusy' => $master >= ($this->isWW ? $config->masterBuilder->maxTasksInWonder : $config->masterBuilder->maxTasksInNoneWonder),
            'isBusy' => ($buildsNum + $fieldsNum) >= $maxTasks,
            'isPlusUsed' => ($hasPlus ? (($buildsNum + $fieldsNum) > 0) : FALSE),
        ];
    }

    private function isBuildingResourcesAvailable($gid, $lvl)
    {
        $costs = Formulas::buildingUpgradeCosts($gid, $lvl);
        $cur_res = $this->resources;
        for ($i = 0; $i < 4; ++$i) {
            if ($cur_res[$i] < $costs[$i]) {
                return FALSE;
            }
        }
        return TRUE;
    }

    public function newBuilding($rand_field, $gid = false)
    {
        if (!$this->skipWorkers && $this->isWorkersBusy($rand_field <= 18)['isBusy']) return false;
        $db = DB::getInstance();
        $helper = new BuildingHelper();
        if ($rand_field == 39) {
            $hasResources = $this->isBuildingResourcesAvailable(16, 1);
            if ($hasResources && $helper->canCreateNewBuild($this->capital, 5, 16, $this->buildings) == 1) {
                if (!$this->buildings[$rand_field]['item_id']) {
                    $this->buildings[$rand_field]['item_id'] = 16;
                    $db->query("UPDATE fdata SET f{$rand_field}t=16 WHERE kid=" . $this->kid);
                    $this->addUpgrade($rand_field);
                    return true;
                }
                return false;
            }
            return false;
        }
        if ($rand_field == 40) {
            $buildingGID = Formulas::getWallID($this->race);
            $hasResources = $this->isBuildingResourcesAvailable($buildingGID, 1);
            if ($hasResources && $helper->canCreateNewBuild($this->capital, 5, $buildingGID, $this->buildings) == 1) {
                if (!$this->buildings[$rand_field]['item_id']) {
                    $this->buildings[$rand_field]['item_id'] = $buildingGID;
                    $db->query("UPDATE fdata SET f{$rand_field}t=$buildingGID WHERE kid=" . $this->kid);
                    $this->addUpgrade($rand_field);
                    return true;
                }
                return false;
            }
            return false;
        }
        $rand_arr = self::BUILDING_PRIORITY;
        if ($gid) {
            $rand_arr = [$gid];
        }
        // No shuffle: the list above is the plan. Every candidate is still
        // checked against resources, prerequisites and the build limits, so this
        // only decides *what to try first*, never bypasses a rule.
        foreach ($rand_arr as $gid) {
            if ($gid == 16 && $rand_field != 39) {
                continue;
            }
            $hasResources = $this->isBuildingResourcesAvailable($gid, 1);
            if ($hasResources && $helper->checkArtifactDependencies(0, 1, $this->kid, $gid, false, 0) == 0 && $helper->canCreateNewBuild($this->capital, 5, $gid, $this->buildings) == 1) {
                if (!$this->buildings[$rand_field]['item_id']) {
                    $this->buildings[$rand_field]['item_id'] = $gid;
                    $db->query("UPDATE fdata SET f{$rand_field}t=$gid WHERE kid=" . $this->kid);
                    $this->addUpgrade($rand_field);
                    return true;
                }
                return false;
            }
        }
        return false;
    }

    private function takeResources($gid, $lvl)
    {
        $kid = $this->kid;
        $resources = Formulas::buildingUpgradeCosts($gid, $lvl);
        for ($i = 0; $i < 4; ++$i) {
            $this->resources[$i] = max($this->resources[$i] - $resources[$i], 0);
        }
        DB::getInstance()->query("UPDATE vdata SET wood=IF(wood-{$resources[0]} > 0, wood-{$resources[0]}, 0), clay=IF(clay-{$resources[1]} > 0, clay-{$resources[1]}, 0), iron=IF(iron-{$resources[2]} > 0, iron-{$resources[2]}, 0), crop=IF(crop-{$resources[3]} > 0, crop-{$resources[3]}, 0) WHERE kid=$kid");
    }

    private function addUpgrade($field)
    {
        $this->workers[$field <= 18 ? 'fieldsNum' : 'buildsNum']++;
        if($this->buildings[$field]['item_id'] == 40){
            $this->workers['WW']++;
        }
        $this->buildings[$field]['level']++; //increase temporary level to prevent double upgrade
        $commence = time();
        if ($this->race == 1) {
            if ($field > 18 && $this->workers['buildsNum'] > 0) {
                $commence = $this->getLastCommence($field <= 18);
            } else if ($field <= 18 && $this->workers['fieldsNum'] > 0) {
                $commence = $this->getLastCommence($field <= 18);
            }
        } else {
            $commence = $this->getLastCommence($field <= 18);
        }
        $this->takeResources($this->buildings[$field]['item_id'], $this->buildings[$field]['level']);
        $commence += Formulas::buildingUpgradeTime($this->buildings[$field]['item_id'], $this->buildings[$field]['level'], $this->main_building_lvl, $this->isWW);
        $db = DB::getInstance();
        $db->query("INSERT INTO building_upgrade (kid, building_field, isMaster, start_time, commence) VALUES ({$this->kid}, {$field}, 0, ".time().", {$commence})");
        $this->croploading = $this->getCropLoading($this->kid, $this->isWW, $this->buildingsStatic);
    }

    private function getLastCommence($isField)
    {
        $kid = $this->kid;
        $db = DB::getInstance();
        if ($isField) {
            $commence = $db->fetchScalar("SELECT commence FROM building_upgrade WHERE kid=$kid AND building_field <= 18 AND isMaster=0 ORDER BY commence DESC LIMIT 1");
        } else {
            $commence = $db->fetchScalar("SELECT commence FROM building_upgrade WHERE kid=$kid AND building_field > 18 AND isMaster=0 ORDER BY commence DESC LIMIT 1");
        }
        if ($commence) {
            return (int) $commence;
        }
        return time();
    }

    private function getUpgradeState($building_field)
    {
        $db = DB::getInstance();
        $kid = $this->kid;
        return (int)$db->fetchScalar("SELECT COUNT(id) FROM building_upgrade WHERE kid=$kid AND building_field=$building_field");
    }

    private function resolveDependencies($dependency)
    {
        if ($dependency == 1) {
            //increase crop production
        } else if ($dependency == 2) {
            $warehouses = [
                10 => [],
                38 => [],
            ];
            for ($i = 19; $i <= 38; ++$i) {
                if ($this->buildings[$i]['item_id'] == 10 || $this->buildings[$i]['item_id'] == 38) {
                    $warehouses[$this->buildings[$i]['item_id']][] = $i;
                }
            }
            $flag = false;
            foreach ($warehouses[10] as $index) {
                if ($this->upgradeIndex($index, false)) {
                    $flag = true;
                    break;
                }
            }
            if (!$flag) {
                foreach ($warehouses[38] as $index) {
                    if ($this->upgradeIndex($index, false)) {
                        break;
                    }
                }
            }
            //need to increase warehouse level
        } else if ($dependency == 22) {
            //create warehouse
            for ($i = 19; $i <= 38; ++$i) {
                if ($this->buildings[$i]['item_id'] == 0) {
                    if (!$this->newBuildingAtIndex($i, 10)) {
                        $this->newBuildingAtIndex($i, 38);
                    }
                    break;
                }
            }
        } else if ($dependency == 3) {
            //need to increase granny level
            $warehouses = [
                11 => [],
                39 => [],
            ];
            for ($i = 19; $i <= 38; ++$i) {
                if ($this->buildings[$i]['item_id'] == 11 || $this->buildings[$i]['item_id'] == 39) {
                    $warehouses[$this->buildings[$i]['item_id']][] = $i;
                }
            }
            $flag = false;
            foreach ($warehouses[11] as $index) {
                if ($this->upgradeIndex($index, false)) {
                    $flag = true;
                    break;
                }
            }
            if (!$flag) {
                foreach ($warehouses[39] as $index) {
                    if ($this->upgradeIndex($index, false)) {
                        break;
                    }
                }
            }
        } else if ($dependency == 33) {
            //create granny
            for ($i = 19; $i <= 38; ++$i) {
                if ($this->buildings[$i]['item_id'] == 0) {
                    if (!$this->newBuildingAtIndex($i, 11)) {
                        $this->newBuildingAtIndex($i, 39);
                    }
                    break;
                }
            }
        }
        return false;
    }

    private function newBuildingAtIndex($field, $gid)
    {
        return $this->newBuilding($field, $gid);
    }

    private function upgradeIndex($field, $resolveDependencies = true)
    {
        if (!$this->skipWorkers && $this->isWorkersBusy($field <= 18)['isBusy']) return false;
        $helper = new BuildingHelper();
        $max = Formulas::buildingMaxLvl($this->buildings[$field]['item_id'], $this->capital, false);
        $level = $this->buildings[$field]['level'];
        $level += $this->getUpgradeState($field);
        if ($level >= $max) return false;
        $freeCrop = $this->cropProduction + $this->upkeep - $this->getCropLoading($this->kid, $this->isWW, $this->buildings);
        $dependencies = $helper->checkDependencies($this->buildings[$field]['item_id'], $level, $this->isWW, $freeCrop, $this->maxstore, $this->maxcrop);
        if ($dependencies <> 0) {
            if ($resolveDependencies) {
                return $this->resolveDependencies($dependencies);
            }
            return false;
        } else {
            $hasResources = $this->isBuildingResourcesAvailable($this->buildings[$field]['item_id'], $level + 1);
            if ($hasResources) {
                $this->addUpgrade($field);
                return true;
            }
        }
        return false;
    }

    private function getCropLoading($kid, $isWW, $buildings)
    {
        $db = DB::getInstance();
        $upgrades = $db->query("SELECT building_field FROM building_upgrade WHERE isMaster=0 AND kid=" . $kid);
        if (!$upgrades->num_rows) {
            return 0;
        }
        $cu = 0;
        $tmp = [];
        while ($row = $upgrades->fetch_assoc()) {
            if (!isset($tmp[$row['building_field']])) {
                $tmp[$row['building_field']] = 0;
            }
            ++$tmp[$row['building_field']];
            $level = $buildings[$row['building_field']]['level'] + $tmp[$row['building_field']];
            $cu += Formulas::buildingCropConsumption($buildings[$row['building_field']]['item_id'], $level, $isWW);
        }
        return $cu;
    }

    /**
     * Resource fields are worth pushing to round numbers: a level 10 field is
     * twice the production of a level 5 one, and a bot with a real economy is
     * the one that can pay for an army. Below the first milestone the bots focus
     * on fields, above it they share time with the buildings.
     */
    const FIELD_MILESTONES = [5, 8, 10, 12, 15, 18, 20];

    /**
     * The next field that should be raised: the lowest level among the resource
     * fields, so all 18 climb together and none is left behind.
     *
     * @return int field index 1..18, or 0 when everything is at the milestone
     */
    private function pickResourceField()
    {
        $milestone = 0;
        foreach (self::FIELD_MILESTONES as $step) {
            $milestone = $step;
            $done = true;
            for ($field = 1; $field <= 18; ++$field) {
                if (($this->buildings[$field]['level'] + $this->getUpgradeState($field)) < $step) {
                    $done = false;
                    break;
                }
            }
            if (!$done) {
                break;
            }
        }
        $best = 0;
        $bestLevel = PHP_INT_MAX;
        for ($field = 1; $field <= 18; ++$field) {
            $level = $this->buildings[$field]['level'] + $this->getUpgradeState($field);
            if ($level >= $milestone) {
                continue;
            }
            if ($level < $bestLevel) {
                $bestLevel = $level;
                $best = $field;
            }
        }
        return $best;
    }

    public function upgrade()
    {
        // Alternate between the economy and the buildings instead of picking a
        // random slot: fields first while they are behind, then the war
        // buildings. (Kept as a choice between two candidates - which one is
        // actually upgradable is decided by upgradeIndex() below.)
        $field = $this->pickResourceField();
        $earlyGame = (time() - $this->creationTime) < 5400;
        if ($field > 0 && ($earlyGame || mt_rand(1, 100) <= 70)) {
            $rand_field = $field;
        } else {
            // Buildings, in the order of BUILDING_PRIORITY: find the empty slot
            // that comes first in the plan, otherwise upgrade the lowest one.
            $rand_field = $this->pickBuildingField();
        }
        if ($rand_field <= 0) {
            $rand_field = $field > 0 ? $field : mt_rand(1, 18);
        }
        if ($this->isWW && in_array($rand_field, [21, 26, 30, 31, 32])) return false;
        if ($this->buildings[$rand_field]['item_id'] <= 0) {
            return $this->newBuilding($rand_field);
        }
        $levels = [];
        foreach($this->buildings as $index => $build){
            if($build['item_id'] == 0 || ($build['level'] == 0 && $index > 18)) continue;
            if(!isset($levels[$build['level']])){
                $levels[$build['level']] = [];
            }
            $levels[$build['level']][] = $index;
        }
        ksort($levels, SORT_ASC);
        if(sizeof($levels)){
            foreach($levels as $level => $childs){
                foreach($childs as $field){
                    if($this->upgradeIndex($field, true)){
                        return true;
                    }
                }
            }
        }
        return false;
    }

    /**
     * An empty building slot, chosen by BUILDING_PRIORITY: the slot number does
     * not matter (any free slot can host any building), so the first plan entry
     * that is not built yet wins. Falls back to the lowest built building.
     *
     * @return int field index 19..40
     */
    private function pickBuildingField()
    {
        $built = [];
        for ($field = 19; $field <= 40; ++$field) {
            if (($this->buildings[$field]['item_id'] ?? 0) > 0) {
                $built[$this->buildings[$field]['item_id']] = true;
            }
        }
        $empty = [];
        for ($field = 19; $field <= 40; ++$field) {
            if (($this->buildings[$field]['item_id'] ?? 0) <= 0) {
                $empty[] = $field;
            }
        }
        if (sizeof($empty)) {
            foreach (self::BUILDING_PRIORITY as $gid) {
                if (isset($built[$gid])) {
                    continue;
                }
                // The rally point lives in a fixed slot (39) in this codebase.
                $slot = $gid == 16 ? 39 : $empty[0];
                if ($gid == 16 && (($this->buildings[39]['item_id'] ?? 0) > 0)) {
                    continue;
                }
                if ($gid == 40 && (($this->buildings[40]['item_id'] ?? 0) > 0)) {
                    continue;
                }
                return $slot;
            }
            return $empty[0];
        }
        // Nothing free: raise the lowest built building.
        $best = 0;
        $bestLevel = PHP_INT_MAX;
        for ($field = 19; $field <= 40; ++$field) {
            if (($this->buildings[$field]['item_id'] ?? 0) <= 0) {
                continue;
            }
            $level = $this->buildings[$field]['level'];
            if ($level < $bestLevel) {
                $bestLevel = $level;
                $best = $field;
            }
        }
        return $best;
    }
}