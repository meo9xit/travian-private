<?php

namespace Core;

use function array_map;
use function array_merge;
use Controller\Build\TroopBuilding;
use Core\Config;
use Core\Database\DB;
use Game\Buildings\AutoUpgradeAI;
use Game\Formulas;
use Game\Hero\HeroHelper;
use function getGameSpeed;
use function method_exists;
use Model\ArtefactsModel;
use Model\BattleModel;
use Model\TrainingModel;
use Model\VillageModel;
use function nrToUnitId;
use function shuffle;
use function unitIdToNr;

class AI_MAIN
{
    const RESOURCES_RATE = 2 / 3;
    // Bots used to skip research entirely, which capped every one of them at the
    // first tier of troops - a bot army that cannot be upgraded is not a threat.
    const SKIP_RESEARCH = FALSE;
    const SKIP_WORKERS = TRUE;

    private $village             = [];
    private $user                = [];
    private $researches          = [];
    private $smithy              = [];
    private $resources           = [0, 0, 0, 0];
    private $hero_percents       = [0, 0];
    private $aiBuilder;
    private $training_buildings  = [
        'barracks'      => [],
        'stable'        => [],
        'workshop'      => [],
        'horseDrinking' => 0,
        'smithyLevel'   => 0,
        'academyLevel'  => 0,
        'available'     => [],
    ];
    private $art_eff             = 1;
    private $smithyUpgradesCount = 0;


    public function __construct($kid)
    {
        $db = DB::getInstance();
        $village = $db->query("SELECT kid, wood, clay, iron, crop, owner, isWW, capital, created, maxstore, maxcrop, cropp, upkeep, isWW FROM vdata WHERE kid=$kid");
        if (!$village->num_rows) {
            return;
        }
        $this->village = $village->fetch_assoc();
        if ($this->village['isWW']) return;

        $this->user = $db->query("SELECT race, plus, fasterTraining FROM users WHERE id={$this->village['owner']}")->fetch_assoc();

        $this->calculateResources();

        $this->hero_percents = (new HeroHelper())->calcTrainEffect($db->fetchScalar("SELECT helmet FROM inventory WHERE uid={$this->village['owner']}"));
        $this->art_eff = ArtefactsModel::getArtifactEffectByType($this->village['owner'], $kid, ArtefactsModel::ARTIFACT_INCREASE_TRAINING_SPEED);

        $this->researches = $db->query("SELECT * FROM tdata WHERE kid=$kid")->fetch_assoc();
        $this->smithy = $db->query("SELECT * FROM smithy WHERE kid=$kid")->fetch_assoc();
        $this->smithyUpgradesCount = (int)$db->fetchScalar("SELECT COUNT(id) FROM research WHERE mode=0 AND kid=$kid");

        $this->buildings = (new VillageModel())->getBuildingsAssoc($kid);
        $this->populateTrainingBuildings();
        $this->aiBuilder = new AutoUpgradeAI($kid,
            $this->resources,
            $this->buildings,
            $this->user['plus'] > time(),
            $this->user['race'],
            $this->village);
        if (self::SKIP_WORKERS) {
            $this->aiBuilder->skipWorkers();
        }

    }

    private function calculateResources()
    {
        $this->resources = array_map(function ($x) {
            return $x * self::RESOURCES_RATE;
        },
            [$this->village['wood'], $this->village['clay'], $this->village['iron'], $this->village['crop']]);
    }

    private function populateTrainingBuildings()
    {
        for ($i = 19; $i <= 38; ++$i) {
            $build = $this->buildings[$i];
            if (!$build['item_id'] || $build['level'] <= 0) continue;
            if ($build['item_id'] == 19 || $build['item_id'] == 29) {
                $this->training_buildings['barracks'][] = $build;
            } else if ($build['item_id'] == 20 || $build['item_id'] == 30) {
                $this->training_buildings['stable'][] = $build;
            } else if ($build['item_id'] == 21) {
                $this->training_buildings['workshop'][] = $build;
            } else if ($build['item_id'] == 41) {
                $this->training_buildings['horseDrinking'] = $build['level'];
            } else if ($build['item_id'] == 13) {
                $this->training_buildings['smithyLevel'] = $build['level'];
            } else if ($build['item_id'] == 22) {
                $this->training_buildings['academyLevel'] = $build['level'];
            }
        }
        $available = [];
        if (sizeof($this->training_buildings['barracks'])) {
            $available = array_merge($available, TroopBuilding::_getTroopBuildingTroopsStatic($this->user['race'], 19));
        }
        if (sizeof($this->training_buildings['stable'])) {
            $available = array_merge($available, TroopBuilding::_getTroopBuildingTroopsStatic($this->user['race'], 20));
        }
        if (sizeof($this->training_buildings['workshop'])) {
            $available = array_merge($available, TroopBuilding::_getTroopBuildingTroopsStatic($this->user['race'], 21));
        }
        $this->training_buildings['available'] = array_map("unitIdToNr", $available);
    }

    public function trainUnits()
    {
        $unit = $this->chooseUnit();
        if ($unit === FALSE) return false; //no unit can be trained
        (new TrainingModel())->addTraining($this->village['kid'],
            $unit['building']['item_id'],
            $unit['nr'],
            $unit['count'],
            $unit['training_time']);
        //remove resources
        $this->takeResources($unit['costs']);
        return true;
    }

    private function chooseUnit()
    {
        $race = $this->user['race'];
        $barracks = $this->training_buildings['barracks'];
        $stable = $this->training_buildings['stable'];
        $workshop = $this->training_buildings['workshop'];
        $arr = [];
        $barracksUnits = array_map("unitIdToNr", TroopBuilding::_getTroopBuildingTroopsStatic($race, 19));
        $stableUnits = array_map("unitIdToNr", TroopBuilding::_getTroopBuildingTroopsStatic($race, 20));
        $onlyGreatBarracks = sizeof($this->training_buildings['barracks']) == 1 && $this->training_buildings['barracks'][0]['item_id'] == 29;
        $onlyGreatStable = sizeof($stable) == 1 && $stable[0]['item_id'] == 30;
        foreach ($this->training_buildings['available'] as $i) {
            if ($i > 1 && !$this->researches['u' . $i] && !self::SKIP_RESEARCH) continue;
            $isGreat = false;
            $isBarracks = in_array($i, $barracksUnits);
            $isStable = in_array($i, $stableUnits);
            if ($isBarracks) {
                $isGreat = $onlyGreatBarracks;
            } else if ($isStable) {
                $isGreat = $onlyGreatStable;
            }
            $neededResources = Formulas::uTrainingCost(nrToUnitId($i, $race), $isGreat);
            if (!$this->isResourcesAvailable($neededResources)) {
                continue;
            }
            $arr[] = [
                'nr'         => $i,
                'costs'      => $neededResources,
                'isBarracks' => $isBarracks,
                'isStable'   => $isStable,
                'isGreat'    => $isGreat
            ];
        }
        if (!sizeof($arr)) return false;
        // Instead of picking at random, choose the unit that fits the role the
        // bot is playing right now: guards while it is being attacked, otherwise
        // the strongest attacker it can field. Ties go to the higher tier (later
        // slot), which is the better unit once it is researched.
        $defending = $this->isDefending();
        $best = null;
        $bestScore = -1;
        foreach ($arr as $candidate) {
            $stats = BattleModel::unitCombatStats($race, $candidate['nr']);
            $score = $defending
                ? max($stats['def_i'], $stats['def_c'])
                : $stats['off'];
            if ($score > $bestScore || ($score === $bestScore && $best !== null && $candidate['nr'] > $best['nr'])) {
                $bestScore = $score;
                $best = $candidate;
            }
        }
        if ($best === null || $bestScore <= 0) {
            return false;
        }
        $selected = $best;
        if ($selected['isBarracks']) {
            $building = $barracks[0];
        } else if ($selected['isStable']) {
            $building = $stable[0];
        } else {
            $building = $workshop[0];
        }
        $percent = $this->user['fasterTraining'] > time() ? Config::getInstance()->extraSettings->generalOptions->fasterTraining->percent : 0;
        $training_time = Formulas::uTrainingTime(nrToUnitId($selected['nr'], $race),
            $building['level'],
            $this->training_buildings['horseDrinking'],
            $this->hero_percents,
            $this->art_eff,
            $percent);
        $costs = [0, 0, 0, 0];
        $count = $this->maxUnits($selected['nr'], $selected['isGreat']);
        for ($i = 0; $i < 4; ++$i) {
            $costs[$i] = $selected['costs'][$i] * $count;
        }
        return [
            'nr'            => $selected['nr'],
            'costs'         => $costs,
            'count'         => $count,
            'building'      => $building,
            'training_time' => $training_time
        ];
    }

    /**
     * True while this bot has been marked as under attack
     * (BotWarModel::defendThreatenedVillages()). Cached per request: the AI step
     * runs in a loop and would otherwise repeat this query for every action.
     */
    private static $defendingCache = [];

    private function isDefending()
    {
        if (!isset($this->village['owner'])) {
            return false;
        }
        $uid = (int)$this->village['owner'];
        if (!array_key_exists($uid, self::$defendingCache)) {
            $db = DB::getInstance();
            // The column only exists once the bot war feature has run its
            // migration; until then every bot simply is not defending.
            $hasColumn = $db->fetchScalar("SHOW COLUMNS FROM users LIKE 'botDefendUntil'");
            self::$defendingCache[$uid] = $hasColumn
                ? ((int)$db->fetchScalar("SELECT botDefendUntil FROM users WHERE id=$uid") > time())
                : false;
        }
        return self::$defendingCache[$uid];
    }

    private function isResourcesAvailable($costs)
    {
        for ($i = 0; $i < 4; ++$i) {
            if ($this->resources[$i] < $costs[$i]) {
                return FALSE;
            }
        }
        return TRUE;
    }

    private function maxUnits($nr, $great = false)
    {
        $cost = Formulas::uTrainingCost(nrToUnitId($nr, $this->user['race']), $great);
        $can = [];
        foreach ($this->resources as $r => $v) {
            if ($cost[$r] == 0) {
                logError('Division by zero (maxUnits) AI for race ' . $this->user['race']);
                return 0;
            }
            $can[$r] = floor($v / $cost[$r]);
        }
        return min($can);
    }

    private function takeResources($resources)
    {
        for ($i = 0; $i < 4; ++$i) {
            $this->resources[$i] = max($this->resources[$i] - $resources[$i], 0);
        }
        DB::getInstance()->query("UPDATE vdata SET wood=IF(wood-{$resources[0]} > 0, wood-{$resources[0]}, 0), clay=IF(clay-{$resources[1]} > 0, clay-{$resources[1]}, 0), iron=IF(iron-{$resources[2]} > 0, iron-{$resources[2]}, 0), crop=IF(crop-{$resources[3]} > 0, crop-{$resources[3]}, 0) WHERE kid={$this->village['kid']}");
    }

    public function upgradeBuilding($count = 1)
    {
        $effects = 0;
        for ($i = 1; $i <= $count; ++$i) {
            if (method_exists($this->aiBuilder, 'upgrade')) {
                $effects += $this->aiBuilder->upgrade();
            }
        }
        return $effects;
    }

    public function researchUnit($kid)
    {
        if (!$this->training_buildings['academyLevel']) return false;
        // One research at a time per village: without this guard every AI step
        // queued another row for a unit that was already being researched (the
        // tdata flag only flips when it completes), burning resources on
        // duplicates.
        $db = DB::getInstance();
        if ($db->fetchScalar("SELECT COUNT(*) FROM research WHERE kid=$kid") > 0) {
            return false;
        }
        $arr = [];
        for ($i = 2; $i <= 8; ++$i) {
            if ($this->researches['u' . $i]) continue;
            $unitId = nrToUnitId($i, $this->user['race']);
            $neededResources = Formulas::uResearchCost($unitId);
            if (!$this->isResourcesAvailable($neededResources)) continue;
            // The bot's own tribe - this used to read the session race, which is
            // empty in the automation engine.
            if (!$this->_canDoResearch(Formulas::uResearchPreRequests($this->user['race'],
                $unitId))) continue;
            $arr[] = ['nr' => $i, 'costs' => $neededResources, 'duration' => Formulas::uResearchTime($unitId)];
        }
        if (!sizeof($arr)) {
            return false;
        }
        // Research in slot order: the tribe's units get better as the slot goes
        // up, so this walks the tree instead of picking a random branch.
        usort($arr, function ($a, $b) {
            return $a['nr'] <=> $b['nr'];
        });
        $selected = $arr[0];
        $this->takeResources($selected['costs']);
        $db->query("INSERT INTO research (`kid`, `mode`, `nr`, `end_time`) VALUES ($kid, 1, " . $selected['nr'] . ", " . (time() + $selected['duration']) . ")");
        return true;
    }

    private function _canDoResearch($breq)
    {
        foreach ($breq as $bid => $level) {
            if (max(self::getTypeLevel($bid)) < $level) {
                return FALSE;
            }
        }
        return TRUE;
    }

    private function getTypeLevel($gid)
    {
        $buildingsAssoc = $this->buildings;
        if ($gid == 16) {
            return [$buildingsAssoc[39]['level']];
        }
        $lvl = [];
        if ($gid <= 4) {
            for ($i = 1; $i <= 18; ++$i) {
                if ($buildingsAssoc[$i]['item_id'] == $gid) {
                    $lvl[] = $buildingsAssoc[$i]['level'];
                }
            }
            if (!sizeof($lvl)) {
                $lvl[] = 0;
            }
            return $lvl;
        }
        $multi = FALSE;
        if (isset(Formulas::$data['buildings'][$gid - 1]['req']) && isset(Formulas::$data['buildings'][$gid - 1]['req']['multi'])) {
            $multi = Formulas::$data['buildings'][$gid - 1]['req']['multi'] == 'true';
        }
        for ($i = 19; $i <= 40; ++$i) {
            if ($buildingsAssoc[$i]['item_id'] == $gid) {
                $lvl[] = $buildingsAssoc[$i]['level'];
                if (!$multi) {
                    break;
                }
            }
        }
        if (!sizeof($lvl)) {
            $lvl[] = 0;
        }
        return $lvl;
    }

    public function upgradeUnit($kid)
    {
        if ($this->training_buildings['smithyLevel'] <= 0) return false;
        $maxResearchCount = $this->user['plus'] > time() ? 2 : 1;
        if ($this->smithyUpgradesCount >= $maxResearchCount) return false;
        $researchUP = -1;
        $commence = time();
        $db = DB::getInstance();
        if ($this->smithyUpgradesCount == 1) {
            $lastUpgrade = $db->query("SELECT nr, end_time FROM research WHERE mode=0 AND kid=$kid")->fetch_assoc();
            $researchUP = $lastUpgrade['nr'];
            $commence = $lastUpgrade['end_time'];
        }
        $researches = $db->query("SELECT * FROM tdata WHERE kid=$kid")->fetch_assoc();
        $upgrades = $db->query("SELECT * FROM smithy WHERE kid=$kid")->fetch_assoc();
        $arr = [];
        for ($i = 1; $i <= 8; ++$i) {
            if ($i > 1 && !$researches['u' . $i] && !self::SKIP_RESEARCH) continue;
            $level = $upgrades['u' . $i] + ($researchUP == $i ? 1 : 0);
            if ($level >= 20) continue;
            $unitId = nrToUnitId($i, $this->user['race']);
            $neededResources = Formulas::uUpgradeCost($unitId, $level + 1);
            if (!$this->isResourcesAvailable($neededResources)) continue;
            $arr[] = [
                'nr'       => $i,
                'costs'    => $neededResources,
                'duration' => Formulas::uUpgradeTime($unitId,
                    $level + 1,
                    $this->training_buildings['smithyLevel'])
            ];
        }
        if (!sizeof($arr)) {
            return false;
        }
        shuffle($arr);
        $selected = $arr[mt_rand(0, sizeof($arr) - 1)];
        $this->takeResources($selected['costs']);
        $this->smithyUpgradesCount++;
        $db->query("INSERT INTO research (`kid`, `mode`, `nr`, `end_time`) VALUES ($kid, 0, " . $selected['nr'] . ", " . ($commence + $selected['duration']) . ")");
        return true;
    }
}

class AI
{
    /**
     * One "thinking" step for a fake player: research, build, train.
     *
     * The previous version trained units only when there was nothing left to
     * build, and on a slow world (speed <= 10, which includes 1x) it spent the
     * first 36 hours building only. The result measured on a live 1x world was
     * 147 bots, 7 barracks and zero troops ever trained - so no bot could ever
     * attack anything. Training now happens on a configurable share of the
     * steps (custom->botTrainChance, default 45%) and research runs first,
     * because better troops are what makes an army dangerous.
     */
    public static function doSomethingRandom($kid, $count = 1)
    {
        $ai = new AI_MAIN($kid);
        $trainChance = (int)Config::getProperty("custom", "botTrainChance");
        if ($trainChance <= 0 || $trainChance > 100) {
            $trainChance = 45;
        }
        for ($i = 1; $i <= $count; ++$i) {
            if ($ai->researchUnit($kid)) {
                continue;
            }
            if (mt_rand(1, 100) <= $trainChance) {
                if (!$ai->trainUnits()) {
                    $ai->upgradeBuilding();
                }
            } else {
                if (!$ai->upgradeBuilding()) {
                    $ai->trainUnits();
                }
            }
        }
    }
}