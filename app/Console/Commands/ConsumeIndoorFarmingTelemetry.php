<?php

namespace App\Console\Commands;

use App\Services\MongoDbService;
use App\Services\MqttService;
use Illuminate\Console\Command;
use Illuminate\Support\Facades\Log;

class ConsumeIndoorFarmingTelemetry extends Command
{
    protected $signature = 'mqtt:consume-indoor-farming
        {--topic= : Override full MQTT topic}
        {--area=indoor_farming : MQTT area segment}
        {--device=indoor_farming_sensor : Device ID segment}
        {--suffix=telemetry : Topic suffix}
        {--measurement=indoor_farming_sensor : Mongo measurement name}
        {--qos=0 : MQTT QoS level}
        {--once : Stop after the first successfully processed message}';

    protected $description = 'Consume indoor farming telemetry from MQTT and store it into MongoDB.';

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
            $this->error('[mqtt:consume-indoor-farming] MongoDB belum terkonfigurasi atau extension mongodb belum aktif.');

            return self::FAILURE;
        }

        $topic = $this->resolveTopic();
        $measurement = trim((string) $this->option('measurement'));
        $qos = max(0, min(2, (int) $this->option('qos')));
        $stopAfterFirst = (bool) $this->option('once');

        $this->registerSignalHandlers();

        $this->info("[mqtt:consume-indoor-farming] subscribe topic={$topic} qos={$qos}");
        Log::info('[MQTT Worker] Starting indoor farming consumer', [
            'topic' => $topic,
            'measurement' => $measurement,
            'qos' => $qos,
        ]);

        try {
            $this->mqtt->subscribe(
                $topic,
                function (string $receivedTopic, string $message, bool $retained, array $matchedWildcards) use ($measurement, $stopAfterFirst): void {
                    $payload = json_decode($message, true);

                    if (! is_array($payload)) {
                        Log::warning('[MQTT Worker] Ignoring non-JSON telemetry payload', [
                            'topic' => $receivedTopic,
                            'payload_preview' => mb_substr($message, 0, 500),
                        ]);

                        return;
                    }

                    $document = $this->buildDocument($receivedTopic, $measurement, $payload, $retained);
                    $ok = $this->mongo->upsertTelemetryDocument($document);

                    if (! $ok) {
                        $reason = $this->mongo->lastErrorMessage();
                        $suffix = $reason ? " | alasan={$reason}" : '';
                        $this->warn("[mqtt:consume-indoor-farming] gagal simpan telemetry topic={$receivedTopic}{$suffix}");

                        return;
                    }

                    $this->line(sprintf(
                        '[mqtt:consume-indoor-farming] saved topic=%s temp=%s ph=%s ppm=%s',
                        $receivedTopic,
                        $document['temperature'] ?? '-',
                        $document['ph'] ?? '-',
                        $document['ppm'] ?? '-',
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
            Log::error('[MQTT Worker] Indoor farming consumer crashed', [
                'message' => $e->getMessage(),
                'topic' => $topic,
            ]);

            $this->error('[mqtt:consume-indoor-farming] '.$e->getMessage());

            return self::FAILURE;
        } finally {
            $this->mqtt->disconnect();
        }

        $this->info('[mqtt:consume-indoor-farming] stopped');

        return self::SUCCESS;
    }

    private function resolveTopic(): string
    {
        $topic = trim((string) $this->option('topic'));
        if ($topic !== '') {
            return $topic;
        }

        return $this->mqtt->topic(
            trim((string) $this->option('area')),
            trim((string) $this->option('device')),
            trim((string) $this->option('suffix'))
        );
    }

    /**
     * @param array<string, mixed> $payload
     * @param array<int, string> $matchedWildcards
     * @return array<string, mixed>
     */
    private function buildDocument(string $topic, string $measurement, array $payload, bool $retained): array
    {
        $deviceId = trim((string) ($this->option('device') ?: 'indoor_farming_sensor'));

        $document = [
            'device_id' => $deviceId,
            'measurement' => $measurement !== '' ? $measurement : 'indoor_farming_sensor',
            'topic' => $topic,
            'device' => $topic,
            'source' => 'mqtt_worker',
            'retained' => $retained,
            'recorded_at' => $this->resolveRecordedAt($payload),
            'ingested_at' => now()->toIso8601String(),
            'raw_payload' => $payload,
            'payload' => $payload,
        ];

        foreach (['temperature', 'humidity', 'soil_moisture', 'ec_us', 'ec_ms', 'ppm', 'tds', 'ph'] as $field) {
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
