<?php

return [

    /*
    |--------------------------------------------------------------------------
    | InfluxDB 2.x Configuration
    |--------------------------------------------------------------------------
    */

    'url' => env('INFLUXDB_URL', 'http://pulsedb.petrokimia-gresik.com'),
    'token' => env('INFLUXDB_TOKEN', ''),
    'org' => env('INFLUXDB_ORG', 'b1fe2ae4fcdf2e9f'),
    'bucket' => env('INFLUXDB_BUCKET', 'buncop_iot_raw'),

    // Default measurement names per device type
    'measurements' => [
        'incubator' => 'incubator_sensor',
        'nutrimix' => 'nutrimix_sensor',
        'monitoring' => 'monitoring_sensor',
    ],

];
