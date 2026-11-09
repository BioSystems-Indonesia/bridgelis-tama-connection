<?php
namespace App\Controllers;

use BridgeLisTamaConnection\Client;

require_once ROOTPATH . '_shared/handlers.php';

class Lis extends BaseController
{
    private function lis(): Client
    {
        static $lis = null;
        if ($lis === null) { $lis = new Client(); sbx_register($lis); }
        return $lis;
    }

    public function webhook()
    {
        $r = $this->lis()->handleWebhook($this->request);   // README: CodeIgniter 4 ($this->request)
        return $this->response->setStatusCode($r['status'])->setContentType('application/json')->setBody($r['body']);
    }

    public function rest(string ...$parts)
    {
        $res = sbx_route($this->lis(), strtoupper($this->request->getMethod()), '/' . implode('/', $parts), json_decode((string) $this->request->getBody(), true))
            ?? [404, ['error' => 'ROUTE']];
        return $this->response->setStatusCode($res[0])->setJSON($res[1]);
    }
}
