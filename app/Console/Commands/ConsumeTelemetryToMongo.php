<?php

namespace App\Console\Commands;

use App\Services\MongoDbService;
use App\Services\MqttService;
use Illuminate\Console\Command;
use Illuminate\Support\Facades\Log;

class ConsumeTelemetryToMongo extends Command
{
    protected $signature = 'mqtt:consume-telemetry-mongo
        {--topic= : Override full MQTT topic}
        {--area= : MQTT area segment}
        {--device= : Device ID segment}
        {--suffix=telemetry : Topic suffix}
        {--measurement= : Mongo measurement name}
        {--qos=0 : MQTT QoS level}
        {--source=mqtt_worker : Source label stored in MongoDB}
        {--once : Stop after the first successfully processed message}';

    protected $description = 'Consume telemetry from MQTT and store it into MongoDB using measurement-based collection routing.';

    private bool $shouldStop = false;

    public function __construct(
        private readonly MqttService $mqtt,
        private readonly MongoDbService $mongo,
    ) {
        parent::__construct();
    }

    public function handle(): int
    {
        if (! $this->mongo->isConfigured()) {
            $this->error('[mqtt:consume-telemetry-mongo] MongoDB belum terkonfigurasi atau extension mongodb belum aktif.');

            return self::FAILURE;
        }

        $topic = $this->resolveTopic();
        $measurement = trim((string) $this->option('measurement'));
        $deviceId = trim((string) $this->option('device'));
        $source = trim((string) $this->option('source'));
        $qos = max(0, min(2, (int) $this->option('qos')));
        $stopAfterFirst = (bool) $this->option('once');

        if ($topic === '' || ($measurement === '' && $deviceId === '')) {
            $this->error('[mqtt:consume-telemetry-mongo] topik wajib terisi, dan minimal salah satu dari --device atau --measurement harus tersedia agar worker bisa menurunkan metadata telemetry.');

            return self::FAILURE;
        }

        $this->registerSignalHandlers();

        $this->info("[mqtt:consume-telemetry-mongo] subscribe topic={$topic} measurement={$measurement} qos={$qos}");
        Log::info('[MQTT Worker] Starting generic Mongo telemetry consumer', [
            'topic' => $topic,
            'device_id' => $deviceId !== '' ? $deviceId : '(topic-derived)',
            'measurement' => $measurement,
            'qos' => $qos,
        ]);

        try {
            $this->mqtt->subscribe(
                $topic,
                function (string $receivedTopic, string $message, bool $retained) use ($measurement, $deviceId, $source, $stopAfterFirst): void {
                    $payload = json_decode($message, true);

                    if (! is_array($payload)) {
                        Log::warning('[MQTT Worker] Ignoring non-JSON telemetry payload', [
                            'topic' => $receivedTopic,
                            'payload_preview' => mb_substr($message, 0, 500),
                        ]);

                        return;
                    }

                    $resolvedDeviceId = $this->resolveDeviceId($receivedTopic, $deviceId, $payload);
                    $resolvedMeasurement = $this->resolveMeasurement($receivedTopic, $resolvedDeviceId, $measurement, $payload);

                    if ($resolvedDeviceId === '' || $resolvedMeasurement === '') {
                        $this->warn("[mqtt:consume-telemetry-mongo] metadata topic={$receivedTopic} tidak bisa diturunkan (device/measurement kosong).");

                        return;
                    }

                    $document = $this->buildDocument($receivedTopic, $resolvedDeviceId, $resolvedMeasurement, $source, $payload, $retained);
                    $ok = $this->mongo->upsertTelemetryDocument($document);

                    if (! $ok) {
                        $reason = $this->mongo->lastErrorMessage();
                        $suffix = $reason ? " | alasan={$reason}" : '';
                        $this->warn("[mqtt:consume-telemetry-mongo] gagal simpan telemetry topic={$receivedTopic}{$suffix}");

                        return;
                    }

                    $this->line(sprintf(
                        '[mqtt:consume-telemetry-mongo] saved topic=%s measurement=%s temp=%s hum=%s ph=%s',
                        $receivedTopic,
                        $resolvedMeasurement,
                        $document['temperature'] ?? '-',
                        $document['humidity'] ?? '-',
                        $document['ph'] ?? '-',
                    ));

                    if ($stopAfterFirst) {
                        $this->shouldStop = true;
                        $this->mqtt->interrupt();
                    }
                },
                $qos
            );

            $this->mqtt->loop(true);
        } catch (\Throwable $e) {
            Log::error('[MQTT Worker] Generic Mongo telemetry consumer crashed', [
                'message' => $e->getMessage(),
                'topic' => $topic,
                'measurement' => $measurement,
            ]);

            $this->error('[mqtt:consume-telemetry-mongo] '.$e->getMessage());

            return self::FAILURE;
        } finally {
            $this->mqtt->disconnect();
        }

        $this->info('[mqtt:consume-telemetry-mongo] stopped');

        return self::SUCCESS;
    }

    private function resolveTopic(): string
    {
        $topic = trim((string) $this->option('topic'));
        if ($topic !== '') {
            return $topic;
        }

        $area = trim((string) $this->option('area'));
        $device = trim((string) $this->option('device'));
        $suffix = trim((string) $this->option('suffix'));

        if ($area === '' || $device === '') {
            return '';
        }

        return $this->mqtt->topic($area, $device, $suffix);
    }

    /**
     * @param array<string, mixed> $payload
     */
    private function resolveDeviceId(string $topic, string $fallbackDeviceId, array $payload): string
    {
        $fallbackDeviceId = trim($fallbackDeviceId);
        if ($fallbackDeviceId !== '') {
            return $fallbackDeviceId;
        }

        foreach (['device_id', 'deviceId', 'device'] as $field) {
            $value = trim((string) ($payload[$field] ?? ''));
            if ($value !== '') {
                return $value;
            }
        }

        $segments = array_values(array_filter(explode('/', trim($topic, '/')), static fn ($segment) => $segment !== ''));

        return trim((string) ($segments[2] ?? ''));
    }

    /**
     * @param array<string, mixed> $payload
     */
    private function resolveMeasurement(string $topic, string $deviceId, string $configuredMeasurement, array $payload): string
    {
        $configuredMeasurement = trim($configuredMeasurement);
        if ($configuredMeasurement !== '' && strtolower($configuredMeasurement) !== 'auto') {
            return $configuredMeasurement;
        }

        foreach (['measurement', '_measurement'] as $field) {
            $value = trim((string) ($payload[$field] ?? ''));
            if ($value !== '') {
                return $value;
            }
        }

        $deviceId = strtolower(trim($deviceId));
        $topicLower = strtolower($topic);

        if ($deviceId === 'bc1_screenhouse') {
            return 'monitoring_bc1_screenhouse';
        }

        if ($deviceId === 'atc_irigasi_rkk') {
            return 'monitoring_atc_irigasi_rkk';
        }

        if ($deviceId === 'atc_irigasi_rkb') {
            return 'monitoring_atc_irigasi_rkb';
        }

        if ($deviceId === 'atc_enviro') {
            return 'monitoring_atc_enviro';
        }

        if ($deviceId === 'atc_smart_hidroponik') {
            return 'monitoring_atc_smart_hidroponik';
        }

        if (str_contains($topicLower, '/indoor_farming/')) {
            return 'indoor_farming_sensor';
        }

        if (str_contains($topicLower, '/incubator/') || str_contains($topicLower, '/inkubator/')) {
            return 'incubator_sensor';
        }

        if (str_contains($topicLower, '/monitoring/')) {
            $sanitized = preg_replace('/[^a-z0-9_]+/', '_', $deviceId);

            return $sanitized !== '' ? 'monitoring_' . trim($sanitized, '_') : 'monitoring_sensor';
        }

        return '';
    }

    /**
     * @param array<string, mixed> $payload
     * @return array<string, mixed>
     */
    private function buildDocument(
        string $topic,
        string $deviceId,
        string $measurement,
        string $source,
        array $payload,
        bool $retained
    ): array {
        $document = [
            'device_id' => $deviceId,
            'measurement' => $measurement,
            'topic' => $topic,
            'device' => $topic,
            'source' => $source !== '' ? $source : 'mqtt_worker',
            'retained' => $retained,
            'recorded_at' => $this->resolveRecordedAt($payload),
            'ingested_at' => now()->toIso8601String(),
            'raw_payload' => $payload,
            'payload' => $payload,
        ];

        foreach (['temperature', 'humidity', 'soil_moisture', 'ec_us', 'ec_ms', 'ppm', 'tds', 'ph', 'nh3', 'ch4', 'weight_g', 'target_weight_g'] as $field) {
            $value = $payload[$field] ?? null;
            if (is_numeric($value)) {
                $document[$field] = (float) $value;
            }
        }

        $doValue = $payload['do'] ?? $payload['do_value'] ?? $payload['dissolved_oxygen'] ?? null;
        if (is_numeric($doValue)) {
            $document['do'] = (float) $doValue;
        }

        return $document;
    }

    /**
     * @param array<string, mixed> $payload
     */
    private function resolveRecordedAt(array $payload): string
    {
        foreach (['recorded_at', 'time'] as $field) {
            $value = $payload[$field] ?? null;
            if (is_string($value) && trim($value) !== '') {
                return $value;
            }
        }

        foreach (['timestamp', 'last_seen'] as $field) {
            $value = $payload[$field] ?? null;
            if (! is_numeric($value)) {
                continue;
            }

            $numeric = (float) $value;
            $seconds = $numeric > 1000000000000 ? (int) floor($numeric / 1000) : (int) floor($numeric);

            return gmdate(DATE_ATOM, $seconds);
        }

        return now()->toIso8601String();
    }

    private function registerSignalHandlers(): void
    {
        if (! function_exists('pcntl_async_signals') || ! function_exists('pcntl_signal')) {
            return;
        }

        pcntl_async_signals(true);

        $stop = function (): void {
            $this->shouldStop = true;
            $this->mqtt->interrupt();
        };

        pcntl_signal(SIGTERM, $stop);
        pcntl_signal(SIGINT, $stop);
    }
}
