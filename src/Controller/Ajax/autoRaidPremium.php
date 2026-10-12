<?php

namespace Controller\Ajax;

use Core\Session;
use Model\AutoRaidModel;

/**
 * Buy the paid auto raid, or change its interval. Called from the farm list page:
 *   Travian.ajax({data: {cmd: "autoRaidPremium", action: "buy", minutes: 15}})
 */
class autoRaidPremium extends AjaxBase
{
    public function dispatch()
    {
        $model = new AutoRaidModel();
        if (!$model->isEnabled()) {
            $this->error('Auto raid is disabled on this server.');
            return;
        }
        $uid = Session::getInstance()->getPlayerId();
        if (Session::getInstance()->isInVacationMode()) {
            $this->error('You cannot use auto raid while on vacation.');
            return;
        }
        $action = isset($_POST['action']) ? $_POST['action'] : 'status';
        $minutes = isset($_POST['minutes']) ? (int)$_POST['minutes'] : AutoRaidModel::DEFAULT_MINUTES;

        if ($action == 'buy') {
            $result = $model->buy($uid, $minutes);
            if (!$result['ok']) {
                $this->error($result['error']);
                return;
            }
            $this->response['data'] = [
                'active'  => true,
                'minutes' => $result['minutes'],
                'price'   => $result['price'],
                'gold'    => $result['gold'],
                'msg'     => sprintf('Auto raid unlocked for the rest of this round. Raiding every %d minutes.',
                    $result['minutes']),
            ];
            return;
        }

        if ($action == 'minutes') {
            $result = $model->updateMinutes($uid, $minutes);
            if (!$result['ok']) {
                $this->error($result['error']);
                return;
            }
            $this->response['data'] = [
                'active'  => true,
                'minutes' => $result['minutes'],
                'gold'    => $model->getGold($uid),
                'msg'     => sprintf('Auto raid interval set to %d minutes.', $result['minutes']),
            ];
            return;
        }

        $this->response['data'] = [
            'active'  => $model->isActive($uid),
            'minutes' => $model->getMinutes($uid),
            'price'   => $model->getPrice(),
            'gold'    => $model->getGold($uid),
        ];
    }
}
