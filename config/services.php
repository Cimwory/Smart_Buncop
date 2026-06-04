<?php

return [

    /*
    |--------------------------------------------------------------------------
    | Third Party Services
    |--------------------------------------------------------------------------
    |
    | This file is for storing the credentials for third party services such
    | as Mailgun, Postmark, AWS and more. This file provides the de facto
    | location for this type of information, allowing packages to have
    | a conventional file to locate the various service credentials.
    |
    */

    'postmark' => [
        'key' => env('POSTMARK_API_KEY'),
    ],

    'resend' => [
        'key' => env('RESEND_API_KEY'),
    ],

    'ses' => [
        'key' => env('AWS_ACCESS_KEY_ID'),
        'secret' => env('AWS_SECRET_ACCESS_KEY'),
        'region' => env('AWS_DEFAULT_REGION', 'us-east-1'),
    ],

    'slack' => [
        'notifications' => [
            'bot_user_oauth_token' => env('SLACK_BOT_USER_OAUTH_TOKEN'),
            'channel' => env('SLACK_BOT_USER_DEFAULT_CHANNEL'),
        ],
    ],

    'keycloak' => [
        'client_id' => env('KEYCLOAK_CLIENT_ID'),
        'client_secret' => env('KEYCLOAK_CLIENT_SECRET'),
        'redirect' => env('KEYCLOAK_REDIRECT_URI'),
        'base_url' => env('KEYCLOAK_BASE_URL'),
        'realm' => env('KEYCLOAK_REALM'),
        'client_uuid' => env('KEYCLOAK_CLIENT_UUID'),
        'public_key' => env('KEYCLOAK_PUBLIC_KEY'),
        'logout_url' => env('KEYCLOAK_LOGOUT_URL'),
        'logout_confirm' => env('KEYCLOAK_LOGOUT_CONFIRM', true),
        'verify_ssl' => env('KEYCLOAK_VERIFY_SSL', true),
        'ca_bundle' => env('KEYCLOAK_CA_BUNDLE'),
    ],

    'firebase' => [
        'enabled' => env('FIREBASE_FCM_ENABLED', false),
        'web_api_key' => env('FIREBASE_WEB_API_KEY'),
        'db_url' => env('FIREBASE_DB_URL'),
        'project_id' => env('FIREBASE_PROJECT_ID'),
        'service_account_email' => env('FIREBASE_SERVICE_ACCOUNT_EMAIL'),
        'private_key' => env('FIREBASE_PRIVATE_KEY'),
        'default_topic' => env('FIREBASE_FCM_DEFAULT_TOPIC', 'esp_status'),
    ],

    'mqtt' => [
        'broker_url' => env('MQTT_BROKER_URL'),
        'username' => env('MQTT_USERNAME'),
        'password' => env('MQTT_PASSWORD'),
        'ws_url' => env('MQTT_WS_URL'),
        'ws_username' => env('MQTT_WS_USERNAME', env('MQTT_USERNAME')),
        'ws_password' => env('MQTT_WS_PASSWORD', env('MQTT_PASSWORD')),
        'ws_port' => (int) env('MQTT_WS_PORT', 8083),
        'ws_path' => env('MQTT_WS_PATH', '/mqtt'),
    ],

    'influxdb' => [
        // Support both env naming styles used across deployments.
        'url' => env('INFLUX_URL', env('INFLUXDB_URL')),
        'token' => env('INFLUX_TOKEN', env('INFLUXDB_TOKEN')),
        'org' => env('INFLUX_ORG', env('INFLUXDB_ORG')),
        'bucket' => env('INFLUX_BUCKET', env('INFLUXDB_BUCKET')),
        'measurement' => env('INFLUX_MEASUREMENT', env('INFLUXDB_MEASUREMENT', 'mqtt_consumer')),
        'verify_tls' => env('INFLUX_VERIFY_TLS', env('INFLUXDB_VERIFY_TLS', true)),
        'timeout_seconds' => (int) env('INFLUX_TIMEOUT_SECONDS', env('INFLUXDB_TIMEOUT_SECONDS', 10)),
    ],

    'mongodb' => [
        'uri' => env('MONGODB_URI'),
        'database' => env('MONGODB_DATABASE'),
        'collection' => env('MONGODB_COLLECTION', 'sensor_histories'),
        'collection_indoor' => env('MONGODB_COLLECTION_INDOOR', env('MONGODB_COLLECTION', 'sensor_histories')),
        'collection_incubator' => env('MONGODB_COLLECTION_INCUBATOR', 'sensor_histories_incubator'),
        'collection_monitoring' => env('MONGODB_COLLECTION_MONITORING', 'sensor_histories_monitoring'),
        'timeout_ms' => (int) env('MONGODB_TIMEOUT_MS', 5000),
    ],

    'sensor_history' => [
        // auto = try Influx first then MongoDB, mongodb = Mongo first then Influx.
        'driver' => env('SENSOR_HISTORY_DRIVER', 'auto'),
    ],

    'activity_log_elastic' => [
        'enabled' => env('ACTIVITY_LOG_ELASTIC_ENABLED', false),
        // Logstash-only policy: logstash_tcp = JSON lines to TCP input, logstash = HTTP input.
        'driver' => env('ACTIVITY_LOG_ELASTIC_DRIVER', 'logstash_tcp'),
        'endpoint' => env('ACTIVITY_LOG_ELASTIC_ENDPOINT') ?: env('LOGSTASH_URL'),
        'host' => env('ACTIVITY_LOG_ELASTIC_HOST') ?: env('LOGSTASH_HOST'),
        'port' => (int) (env('ACTIVITY_LOG_ELASTIC_PORT') ?: env('LOGSTASH_PORT', 5000)),
        'username' => env('ACTIVITY_LOG_ELASTIC_USERNAME') ?: env('LOGSTASH_USERNAME'),
        'password' => env('ACTIVITY_LOG_ELASTIC_PASSWORD') ?: env('LOGSTASH_PASSWORD'),
        'bearer_token' => env('ACTIVITY_LOG_ELASTIC_BEARER_TOKEN'),
        'api_key' => env('ACTIVITY_LOG_ELASTIC_API_KEY'),
        'index_prefix' => env('ACTIVITY_LOG_ELASTIC_INDEX_PREFIX', 'app-logs-dev-incubator'),
        'index_date_format' => env('ACTIVITY_LOG_ELASTIC_INDEX_DATE_FORMAT', 'Y.m.d'),
        'app' => env('ACTIVITY_LOG_ELASTIC_APP', env('APP_NAME', 'incubator')),
        'project' => env('ACTIVITY_LOG_ELASTIC_PROJECT', 'incubator'),
        'environment' => env('ACTIVITY_LOG_ELASTIC_ENVIRONMENT', env('APP_ENV', 'local')),
        'space' => env('ACTIVITY_LOG_ELASTIC_SPACE', 'operasi_produksi'),
        'verify_tls' => env('ACTIVITY_LOG_ELASTIC_VERIFY_TLS', true),
        'timeout_seconds' => (int) env('ACTIVITY_LOG_ELASTIC_TIMEOUT_SECONDS', 3),
    ],

    'incubator' => [
        'default_device_id' => env('INCUBATOR_DEFAULT_DEVICE_ID', 'inkubator_1'),
        'mqtt_area' => env('INCUBATOR_MQTT_AREA', 'incubator'),
        'mqtt_topic_base' => env('INCUBATOR_MQTT_TOPIC_BASE'),
    ],

    'nutrimix' => [
        'default_device_id' => env('NUTRIMIX_DEFAULT_DEVICE_ID'),
    ],

];
