<?php

return [
    'auth' => [
        'default_role' => env('AUTH_DEFAULT_ROLE', 'user'),
        'local_provider' => env('AUTH_LOCAL_PROVIDER', 'local'),
        'sso_provider' => env('AUTH_SSO_PROVIDER', 'keycloak'),
        'sso_fallback_email_domain' => env('AUTH_SSO_FALLBACK_EMAIL_DOMAIN', 'sso.local'),
    ],
    'network' => [
        'local_hosts' => array_values(array_filter(array_map(
            static fn ($host) => trim((string) $host),
            explode(',', (string) env('APP_LOCAL_HOSTS', 'localhost,127.0.0.1,10.0.2.2'))
        ))),
    ],
];
