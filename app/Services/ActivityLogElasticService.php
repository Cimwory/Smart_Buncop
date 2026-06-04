<?php

namespace App\Services;

use App\Models\ActivityLog;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Log;

class ActivityLogElasticService
{
    /**
     * Keep warning noise low: one warning per invalid driver value per process.
     *
     * @var array<string, bool>
     */
    private static array $invalidDriverWarnings = [];

    public function send(ActivityLog $log, array $source = []): void
    {
        if (! $this->boolConfig('services.activity_log_elastic.enabled', false)) {
            return;
        }

        try {
            $payload = $this->buildPayload($log, $source);
            $driver = $this->resolveDriver();

            if ($driver === 'logstash_tcp') {
                $this->sendTcp($payload, $log);
                return;
            }

            $endpoint = rtrim((string) config('services.activity_log_elastic.endpoint', ''), '/');
            if ($endpoint === '') {
                return;
            }

            $response = $this->httpClient()->post($endpoint, $payload);

            if ($response->failed()) {
                Log::warning('Activity log Elastic sink failed.', [
                    'status' => $response->status(),
                    'body' => $response->body(),
                    'activity_log_id' => $log->id,
                ]);
            }
        } catch (\Throwable $e) {
            Log::warning('Activity log Elastic sink error.', [
                'message' => $e->getMessage(),
                'activity_log_id' => $log->id,
            ]);
        }
    }

    private function buildPayload(ActivityLog $log, array $source): array
    {
        $timestamp = $this->resolveTimestamp($log);
        $metadata = is_array($log->metadata ?? null) ? $log->metadata : ($source['metadata'] ?? []);
        $description = (string) ($log->description ?? $source['description'] ?? '');
        $action = (string) ($log->action ?? $source['action'] ?? 'activity');
        $module = (string) ($log->module ?? $source['module'] ?? 'activity');

        $level = $this->resolveLevel($action, $metadata);
        $message = $description !== '' ? $description : $action;
        $account = (string) (
            $log->login_identifier
            ?? $source['login_identifier']
            ?? $log->user?->name
            ?? 'system'
        );

        return [
            '@timestamp' => $timestamp->toIso8601String(),
            'app' => (string) config('services.activity_log_elastic.app', config('app.name', 'incubator')),
            'project' => (string) config('services.activity_log_elastic.project', 'incubator'),
            'environment' => (string) config('services.activity_log_elastic.environment', config('app.env')),
            'space' => (string) config('services.activity_log_elastic.space', 'operasi_produksi'),
            'account' => $account,
            'activity' => $action,
            'level' => $level,
            'message' => $message,
            'timestamp' => $timestamp->toIso8601String(),
            'data' => [
                'activity_log_id' => $log->id,
                'module' => $module,
                'device_id' => $log->device_id ?? $source['device_id'] ?? null,
                'metadata' => $metadata,
            ],
            'event' => [
                'id' => $log->id,
                'kind' => 'event',
                'category' => $this->resolveCategory($module),
                'action' => $action,
                'module' => $module,
                'type' => $this->resolveEventType($action),
            ],
            'user' => [
                'id' => $log->user_id,
                'email' => $log->login_identifier ?? $source['login_identifier'] ?? null,
                'role' => $log->role_name ?? $log->actor_role ?? $source['role_name'] ?? null,
            ],
            'device' => [
                'id' => $log->device_id ?? $source['device_id'] ?? null,
            ],
            'http' => [
                'method' => $log->http_method ?? $source['http_method'] ?? null,
                'status_code' => $log->status_code ?? $source['status_code'] ?? null,
                'url' => $log->url ?? $source['url'] ?? null,
            ],
            'source' => [
                'ip' => $log->ip_address ?? $source['ip_address'] ?? null,
                'user_agent' => $log->user_agent ?? $source['user_agent'] ?? null,
                'guard' => $log->guard ?? $source['guard'] ?? null,
                'route_name' => $log->route_name ?? $source['route_name'] ?? null,
            ],
            'labels' => [
                'activity_log_id' => $log->id,
            ],
            'metadata' => $metadata,
        ];
    }

    private function resolveTimestamp(ActivityLog $log): Carbon
    {
        $candidate = $log->occurred_at ?? $log->performed_at ?? $log->created_at;

        if ($candidate instanceof Carbon) {
            return $candidate->copy();
        }

        if ($candidate !== null) {
            return Carbon::parse($candidate);
        }

        return now();
    }

    private function resolveLevel(string $action, array $metadata): string
    {
        $action = strtolower($action);
        $statusCode = (int) ($metadata['status_code'] ?? 0);

        if (str_contains($action, 'error') || str_contains($action, 'failed') || $statusCode >= 500) {
            return 'error';
        }

        if (str_contains($action, 'suspend') || str_contains($action, 'delete') || $statusCode >= 400) {
            return 'warning';
        }

        return 'info';
    }

    private function resolveCategory(string $module): string
    {
        return match (strtolower($module)) {
            'auth' => 'authentication',
            'admin', 'super_admin' => 'iam',
            'incubator', 'indoor_farming', 'monitoring', 'nutrimix' => 'device',
            default => 'application',
        };
    }

    private function resolveEventType(string $action): string
    {
        $action = strtolower($action);

        if (str_contains($action, 'login') || str_contains($action, 'logout')) {
            return 'access';
        }

        if (str_contains($action, 'suspend') || str_contains($action, 'unsuspend') || str_contains($action, 'role')) {
            return 'change';
        }

        if (str_contains($action, 'relay') || str_contains($action, 'control') || str_contains($action, 'command')) {
            return 'control';
        }

        return 'info';
    }

    private function buildElasticsearchUrl(string $endpoint): string
    {
        $prefix = trim((string) config('services.activity_log_elastic.index_prefix', 'app-logs-dev-incubator'), " \t\n\r\0\x0B/");
        $dateFormat = (string) config('services.activity_log_elastic.index_date_format', 'Y.m.d');
        $index = $prefix.'-'.now()->format($dateFormat);

        return $endpoint.'/'.$index.'/_doc';
    }

    private function resolveDriver(): string
    {
        $rawDriver = strtolower(trim((string) config('services.activity_log_elastic.driver', 'logstash_tcp')));

        return match ($rawDriver) {
            'logstash', 'http', 'https' => 'logstash',
            '', 'logstash_tcp', 'tcp' => 'logstash_tcp',
            default => $this->warnInvalidDriver($rawDriver),
        };
    }

    private function warnInvalidDriver(string $rawDriver): string
    {
        if (! isset(self::$invalidDriverWarnings[$rawDriver])) {
            Log::warning('Invalid activity log driver. Falling back to logstash_tcp policy.', [
                'driver' => $rawDriver,
                'allowed' => ['logstash_tcp', 'logstash'],
            ]);

            self::$invalidDriverWarnings[$rawDriver] = true;
        }

        return 'logstash_tcp';
    }

    private function sendTcp(array $payload, ActivityLog $log): void
    {
        $host = trim((string) config('services.activity_log_elastic.host', ''));
        $port = (int) config('services.activity_log_elastic.port', 5000);
        $timeout = (int) config('services.activity_log_elastic.timeout_seconds', 3);

        if ($host === '' || $port <= 0) {
            return;
        }

        $errno = 0;
        $errstr = '';
        $socket = @fsockopen($host, $port, $errno, $errstr, max(1, $timeout));

        if (! $socket) {
            Log::warning('Activity log Logstash TCP sink failed.', [
                'host' => $host,
                'port' => $port,
                'error' => $errstr,
                'errno' => $errno,
                'activity_log_id' => $log->id,
            ]);
            return;
        }

        try {
            fwrite($socket, json_encode($payload, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE)."\n");
        } finally {
            fclose($socket);
        }
    }

    private function httpClient()
    {
        $client = Http::timeout((int) config('services.activity_log_elastic.timeout_seconds', 3))
            ->acceptJson()
            ->asJson()
            ->withOptions([
                'verify' => $this->boolConfig('services.activity_log_elastic.verify_tls', true),
            ]);

        $username = trim((string) config('services.activity_log_elastic.username', ''));
        $password = (string) config('services.activity_log_elastic.password', '');
        $bearerToken = trim((string) config('services.activity_log_elastic.bearer_token', ''));
        $apiKey = trim((string) config('services.activity_log_elastic.api_key', ''));

        if ($apiKey !== '') {
            return $client->withHeaders(['Authorization' => 'ApiKey '.$apiKey]);
        }

        if ($bearerToken !== '') {
            return $client->withToken($bearerToken);
        }

        if ($username !== '') {
            return $client->withBasicAuth($username, $password);
        }

        return $client;
    }

    private function boolConfig(string $key, bool $default): bool
    {
        return filter_var(config($key, $default), FILTER_VALIDATE_BOOL, FILTER_NULL_ON_FAILURE) ?? $default;
    }
}
