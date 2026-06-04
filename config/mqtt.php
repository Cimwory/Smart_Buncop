<?php

return [

    /*
    |--------------------------------------------------------------------------
    | MQTT Broker Configuration (EMQX)
    |--------------------------------------------------------------------------
    */

    'host' => env('MQTT_HOST', '10.14.41.20'),
    'port' => (int) env('MQTT_PORT', 1773),
    'ws_port' => (int) env('MQTT_WS_PORT', 8083),
    'wss_port' => (int) env('MQTT_WSS_PORT', 8084),

    // Gateway user — can subscribe telemetry/status/alert + publish command
    'username' => env('MQTT_USERNAME', 'buncop_gateway'),
    'password' => env('MQTT_PASSWORD', ''),

    'use_tls' => (bool) env('MQTT_USE_TLS', false),
    'topic_prefix' => env('MQTT_TOPIC_PREFIX', 'buncop'),

    // Client ID prefix — a random suffix is appended at runtime
    'client_id_prefix' => env('MQTT_CLIENT_ID_PREFIX', 'buncop_laravel'),

    // WebSocket path for browser clients (served through EMQX)
    'ws_path' => env('MQTT_WS_PATH', '/mqtt'),

];
