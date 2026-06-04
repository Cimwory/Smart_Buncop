<?php

namespace App\Console\Commands;

use App\Services\InfluxDbService;
use App\Services\MongoDbService;
use Illuminate\Console\Command;
use Illuminate\Support\Facades\Http;

class DiagnoseIntegrations extends Command
{
    protected $signature = 'diagnose:integrations
        {target : influx or mongodb or elk}
        {--device=indoor_farming_sensor : Device ID for Influx test}
        {--measurement=indoor_farming_sensor : Influx measurement}
        {--field=temperature : Influx field}
        {--range=-1d : Influx relative range}
        {--window=15m : Influx aggregate window}
        {--raw : Show raw Influx rows without device filter and aggregateWindow}
        {--url= : Override Logstash HTTP/HTTPS URL}
        {--username= : Override Logstash HTTP username}
        {--password= : Override Logstash HTTP password}
        {--host= : Override Logstash host}
        {--port= : Override Logstash port}';

    protected $description = 'Diagnose InfluxDB / MongoDB sensor history reads or Logstash activity-log delivery.';

    public function handle(): int
    {
        return match (strtolower((string) $this->argument('target'))) {
            'influx' => $this->diagnoseInflux(),
            'mongodb', 'mongo' => $this->diagnoseMongoDb(),
            'elk', 'elastic', 'logstash' => $this->diagnoseElk(),
            default => $this->invalidTarget(),
        };
    }

    private function diagnoseInflux(): int
    {
        $deviceId = (string) $this->option('device');
        $measurement = (string) $this->option('measurement');
        $field = (string) $this->option('field');
        $range = (string) $this->option('range');
        $window = (string) $this->option('window');

        $this->line('[diagnose:influx] config');
        $this->line('url='.(string) config('services.influxdb.url'));
        $this->line('org='.(string) config('services.influxdb.org'));
        $this->line('bucket='.(string) config('services.influxdb.bucket'));
        $this->line('token='.(((string) config('services.influxdb.token')) !== '' ? 'set' : 'empty'));

        if ((bool) $this->option('raw')) {
            $rows = app(InfluxDbService::class)->rawFieldRows($measurement, $field, $range, 10);
            $this->line("[diagnose:influx] raw measurement={$measurement} field={$field} range={$range}");
            $this->line('[diagnose:influx] raw_count='.count($rows));
            foreach ($rows as $idx => $row) {
                $this->line('[diagnose:influx] raw_'.$idx.'='.json_encode($row, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE));
            }

            return $rows === [] ? self::FAILURE : self::SUCCESS;
        }

        $series = app(InfluxDbService::class)->getFieldHistory(
            $deviceId,
            $measurement,
            [$field],
            $range,
            $window,
        );

        $points = is_array($series[0]['points'] ?? null) ? $series[0]['points'] : [];
        $this->line("[diagnose:influx] device={$deviceId} measurement={$measurement} field={$field}");
        $this->line('[diagnose:influx] series_count='.count($series).' point_count='.count($points));

        if ($points === []) {
            $this->warn('[diagnose:influx] no data returned');
            return self::FAILURE;
        }

        $this->line('[diagnose:influx] first_point='.json_encode($points[0], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE));
        $this->line('[diagnose:influx] last_point='.json_encode($points[count($points) - 1], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE));

        return self::SUCCESS;
    }

    private function diagnoseMongoDb(): int
    {
        $deviceId = (string) $this->option('device');
        $measurement = (string) $this->option('measurement');
        $field = (string) $this->option('field');
        $range = (string) $this->option('range');
        $window = (string) $this->option('window');

        $this->line('[diagnose:mongodb] config');
        $this->line('uri='.(((string) config('services.mongodb.uri')) !== '' ? 'set' : 'empty'));
        $this->line('database='.(string) config('services.mongodb.database'));
        $this->line('collection='.(string) config('services.mongodb.collection'));
        $this->line('extension='.(extension_loaded('mongodb') ? 'loaded' : 'missing'));

        if ((bool) $this->option('raw')) {
            $rows = app(MongoDbService::class)->rawFieldRows($measurement, $field, $range, 10);
            $this->line("[diagnose:mongodb] raw measurement={$measurement} field={$field} range={$range}");
            $this->line('[diagnose:mongodb] raw_count='.count($rows));
            foreach ($rows as $idx => $row) {
                $this->line('[diagnose:mongodb] raw_'.$idx.'='.json_encode($row, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE));
            }

            return $rows === [] ? self::FAILURE : self::SUCCESS;
        }

        $series = app(MongoDbService::class)->getFieldHistory(
            $deviceId,
            $measurement,
            [$field],
            $range,
            $window,
        );

        $points = is_array($series[0]['points'] ?? null) ? $series[0]['points'] : [];
        $this->line("[diagnose:mongodb] device={$deviceId} measurement={$measurement} field={$field}");
        $this->line('[diagnose:mongodb] series_count='.count($series).' point_count='.count($points));

        if ($points === []) {
            $this->warn('[diagnose:mongodb] no data returned');
            return self::FAILURE;
        }

        $this->line('[diagnose:mongodb] first_point='.json_encode($points[0], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE));
        $this->line('[diagnose:mongodb] last_point='.json_encode($points[count($points) - 1], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE));

        return self::SUCCESS;
    }

    private function diagnoseElk(): int
    {
        $driver = $this->resolveElkDriver();

        if ($driver === 'logstash') {
            return $this->diagnoseElkHttp();
        }

        return $this->diagnoseElkTcp();
    }

    private function resolveElkDriver(): string
    {
        $rawDriver = strtolower(trim((string) config('services.activity_log_elastic.driver', 'logstash_tcp')));

        return match ($rawDriver) {
            'logstash', 'http', 'https' => 'logstash',
            '', 'logstash_tcp', 'tcp' => 'logstash_tcp',
            default => $this->warnAndFallbackDriver($rawDriver),
        };
    }

    private function warnAndFallbackDriver(string $rawDriver): string
    {
        $this->warn("[diagnose:elk] unsupported driver '{$rawDriver}', fallback to logstash_tcp");

        return 'logstash_tcp';
    }

    private function diagnoseElkTcp(): int
    {
        $host = trim((string) ($this->option('host') ?: config('services.activity_log_elastic.host')));
        $port = (int) ($this->option('port') ?: config('services.activity_log_elastic.port', 5000));
        $timeout = (int) config('services.activity_log_elastic.timeout_seconds', 3);

        $this->line('[diagnose:elk:tcp] config');
        $this->line('enabled='.(string) config('services.activity_log_elastic.enabled'));
        $this->line('driver='.(string) config('services.activity_log_elastic.driver'));
        $this->line("host={$host}");
        $this->line("port={$port}");

        if ($host === '' || $port <= 0) {
            $this->error('[diagnose:elk:tcp] host/port is empty');
            return self::FAILURE;
        }

        $errno = 0;
        $errstr = '';
        $socket = @fsockopen($host, $port, $errno, $errstr, max(1, $timeout));

        if (! $socket) {
            $this->error("[diagnose:elk:tcp] FAILED {$errno} {$errstr}");
            return self::FAILURE;
        }

        fwrite($socket, json_encode($this->buildElkPayload(), JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE).PHP_EOL);
        fclose($socket);

        $this->info('[diagnose:elk:tcp] SENT');

        return self::SUCCESS;
    }

    private function diagnoseElkHttp(): int
    {
        $url = rtrim(trim((string) ($this->option('url') ?: config('services.activity_log_elastic.endpoint'))), '/');
        $username = trim((string) ($this->option('username') ?: config('services.activity_log_elastic.username')));
        $password = (string) ($this->option('password') ?: config('services.activity_log_elastic.password'));
        $timeout = (int) config('services.activity_log_elastic.timeout_seconds', 3);
        $verifyTls = filter_var(config('services.activity_log_elastic.verify_tls', true), FILTER_VALIDATE_BOOL, FILTER_NULL_ON_FAILURE) ?? true;

        $this->line('[diagnose:elk:http] config');
        $this->line('enabled='.(string) config('services.activity_log_elastic.enabled'));
        $this->line('driver='.(string) config('services.activity_log_elastic.driver'));
        $this->line("url={$url}");
        $this->line('username='.($username !== '' ? 'set' : 'empty'));
        $this->line('password='.($password !== '' ? 'set' : 'empty'));

        if ($url === '') {
            $this->error('[diagnose:elk:http] url is empty');
            return self::FAILURE;
        }

        $client = Http::timeout(max(1, $timeout))
            ->acceptJson()
            ->asJson()
            ->withOptions(['verify' => $verifyTls]);

        if ($username !== '') {
            $client = $client->withBasicAuth($username, $password);
        }

        $response = $client->post($url, $this->buildElkPayload());

        $this->line('[diagnose:elk:http] status='.$response->status());

        if ($response->failed()) {
            $this->error('[diagnose:elk:http] FAILED '.mb_substr((string) $response->body(), 0, 500));
            return self::FAILURE;
        }

        $this->info('[diagnose:elk:http] SENT');

        return self::SUCCESS;
    }

    private function buildElkPayload(): array
    {
        return [
            '@timestamp' => now()->toIso8601String(),
            'timestamp' => now()->toIso8601String(),
            'app' => (string) config('services.activity_log_elastic.app', 'incubator'),
            'project' => (string) config('services.activity_log_elastic.project', 'incubator'),
            'environment' => (string) config('services.activity_log_elastic.environment', config('app.env')),
            'space' => (string) config('services.activity_log_elastic.space', 'operasi_produksi'),
            'level' => 'info',
            'activity' => 'manual.elastic.test',
            'account' => 'artisan',
            'message' => 'manual test incubator from artisan command',
            'data' => [
                'source' => 'diagnose:integrations',
            ],
        ];
    }

    private function invalidTarget(): int
    {
        $this->error('Invalid target. Use: influx or mongodb or elk');

        return self::FAILURE;
    }
}
