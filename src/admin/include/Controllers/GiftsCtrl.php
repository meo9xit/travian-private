<?php

use Core\Database\DB;
use Core\Helper\Notification;
use Core\Helper\WebService;
use Core\Session;
use Game\Formulas;
use Model\MessageModel;

class GiftsCtrl
{
    public function __construct()
    {
        $dispatcher = Dispatcher::getInstance();
        if(!getCustom('allowInterruptionInGame')){
            $dispatcher->appendContent("<hr><p class='error center'>Disabled by admin.</p><hr>");
            return;
        }
        $section = isset($_REQUEST['section']) ? $_REQUEST['section'] : null;
        $params['error'] = '&nbsp;';
        $params['giftUidGold'] = isset($_REQUEST['giftUidGold']) ? (int)$_REQUEST['giftUidGold'] : 0;
        $params['giftUid'] = isset($_REQUEST['giftUid']) ? (int)$_REQUEST['giftUid'] : 0;
        if (isset($_REQUEST['fullResources']) && !isServerFinished() && Session::validateChecker()) {
            $db = DB::getInstance();
            $max = Formulas::storeCAP(20) * 2;
            $db->query("UPDATE vdata SET wood=wood+$max, clay=clay+$max, iron=iron+$max, crop=crop+$max");
        } else if ($section == 'giftUidGold' && $params['giftUid'] > 0 && $params['giftUidGold'] > 0 && !isServerFinished() && Session::validateChecker()) {
            $db = DB::getInstance();
            // users.gift_gold is INT(11). Check the target player and the
            // resulting balance first, so an oversized gift (the input used to
            // be capped at 4 digits, it no longer is) reports an error instead
            // of being refused by MySQL without any feedback.
            $maxGold = 2147483647;
            $user = $db->query("SELECT id, name, gift_gold FROM users WHERE id={$params['giftUid']}")->fetch_assoc();
            $giftedName = $user ? htmlspecialchars($user['name'], ENT_QUOTES) : '';
            if (!$user) {
                $params['error'] = '<font color="Red"><b>There is no player with id ' . $params['giftUid'] . ' - nothing was gifted.</font></b>';
            } else if (((int)$user['gift_gold'] + $params['giftUidGold']) > $maxGold) {
                $params['error'] = '<font color="Red"><b>' . number_format($params['giftUidGold']) . ' gold would take "' . $giftedName
                    . '" above the maximum balance of ' . number_format($maxGold) . ' - nothing was gifted.</font></b>';
            } else {
                $db->query("UPDATE users SET gift_gold=gift_gold+{$params['giftUidGold']} WHERE id={$params['giftUid']}");
                if ($db->affectedRows()) {
                    $m = new MessageModel();
                    $m->sendMessage(0, $params['giftUid'], NULL, $params['giftUidGold'], 4);
                    $params['error'] = '<font color="Red"><b>Gold Added To player "' . $giftedName . '" and message sent!</font></b>';
                    Notification::RealTimeNotify("Manual Gold",
                        sprintf("%s golds has been gifted to %s.", $params['giftUidGold'], $user['name']));
                }
            }
        } else if (!isServerFinished() && WebService::isPost() && $section == 'giftResources' && Session::validateChecker()) {
            $params['error'] = 'Resources were gifted to all players.';
            $db = DB::getInstance();
            $wood = max(0, $_POST['wood']);
            $clay = max(0, $_POST['clay']);
            $iron = max(0, $_POST['iron']);
            $crop = max(0, $_POST['crop']);
            $db->query("UPDATE vdata SET wood=wood+$wood, clay=clay+$clay, iron=iron+$iron, crop=crop+$crop");
            //TODO: this will cause a problem in MasterBuilder!
            AdminLog::getInstance()->addLog("Gifted resources to players.[" . implode(",", [$wood, $clay, $iron, $crop]) . "]");
        } else if (!isServerFinished() && WebService::isPost() && $section == 'giftGold' && Session::validateChecker()) {
            $give_gold = (int)$_POST['give_gold'];
            if ($give_gold > 0) {
                $params['error'] = $give_gold . ' Gold gifted to all players.';
                $db = DB::getInstance();
                $db->query("UPDATE users SET gift_gold=gift_gold+$give_gold");
                $m = new MessageModel();
                $users = $db->query("SELECT id FROM users WHERE id > 2 AND access<>2");
                while ($row = $users->fetch_assoc()) {
                    $m->sendMessage(0, $row['id'], NULL, $give_gold, 4);
                }
                AdminLog::getInstance()->addLog($params['error']);
                Notification::RealTimeNotify("Gift Gold",
                    sprintf("%s golds has been gifted to all players.", $give_gold));
            }
        }
        $dispatcher->appendContent(\resources\View\PHPBatchView::render('admin/gifts', $params));
    }
}