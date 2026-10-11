<?php
global $connection;
$connection = [
    'speed' => '1',
    'round_length' => '60',
    'worldId' => '1',
    'secure_hash_code' => 'devhash',
    'title' => 'Travium Local',
    'gameWorldUrl' => 'http://127.0.0.1:8123/',
    'serverName' => 'local',
    'auto_reinstall' => '0',
    'auto_reinstall_start_after' => '0',
    'engine_filename' => 'engine.php',
    'database' => [
        'hostname' => '127.0.0.1',
        'username' => 'root',
        'password' => 'root',
        'database' => 'travium',
        'charset' => 'utf8mb4',
    ],
];
