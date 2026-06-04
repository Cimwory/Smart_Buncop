<?php

namespace App\Console\Commands;

use App\Models\IndoorFarmingDeviceConfig;
use App\Services\FirebaseMessagingService;
use App\Services\MqttService;
use Illuminate\Console\Command;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Log;

class ConsumeIndoorFarmingAlerts extends Command
{
    protected $signature = 'mqtt:consume-indoor-farming-alerts
        {--device=indoor_farming_sensor : Specific indoor farming device id}
        {--qos=0 : MQTT QoS level}
        {--prefix= : Override MQTT topic prefix}
        {--once : Stop after first processed alert transition}';

    protected $description = 'Consume indoor farming telemetry/status and generate selected backend-side notifications.';

    private const CACHE_STATE_PREFIX = 'indoor_farming:alerts:state:';

    public function __construct(
        private readonly MqttService $mqtt,
        private readonly FirebaseMessagingService $fcm,
    ) {
        parent::__construct();
    }

    public function handle(): int
    {
        $deviceId = trim((string) $this->option('device'));
        $qos = max(0, min(2, (int) $this->option('qos')));
        $prefix = trim((string) $this->option('prefix'));
        if ($prefix === '') {
            $prefix = trim((string) config('mqtt.topic_prefix', 'buncop'));
        }

        $telemetryTopic = sprintf('%s/indoor_farming/%s/telemetry', $prefix, $deviceId);
        $statusTopic = sprintf('%s/indoor_farming/%s/status', $prefix, $deviceId);
        $stopAfterFirst = (bool) $this->option('once');

        $this->info("[mqtt:consume-indoor-farming-alerts] subscribe telemetry={$telemetryTopic} status={$statusTopic} qos={$qos}");

        try {
            $handler = function (string $receivedTopic, string $message, bool $retained, array $matchedWildcards = []) use ($deviceId, $stopAfterFirst): void {
                $payload = json_decode($message, true);
                if (! is_array($payload)) {
                    Log::warning('[Indoor Alert Worker] Ignore non-JSON payload', [
                        'topic' => $receivedTopic,
                        'retained' => $retained,
                        'wildcards' => $matchedWildcards,
                    ]);

                    return;
                }

                $config = $this->resolveConfig($deviceId);
                $transitions = str_ends_with($receivedTopic, '/status')
                    ? $this->evaluateStatusPayload($deviceId, $payload)
                    : $this->evaluateTelemetryPayload($config, $payload);

                foreach ($transitions as $transition) {
                    $this->dispatchTransition($deviceId, $receivedTopic, $transition);

                    if ($stopAfterFirst) {
                        $this->mqtt->interrupt();
                        return;
                    }
                }
            };

            $this->mqtt->subscribe($telemetryTopic, $handler, $qos);
            $this->mqtt->subscribe($statusTopic, $handler, $qos);
            $this->mqtt->loop(true);
        } catch (\Throwable $e) {
            Log::error('[Indoor Alert Worker] Crashed.', [
                'message' => $e->getMessage(),
                'device_id' => $deviceId,
            ]);
            $this->error('[mqtt:consume-indoor-farming-alerts] '.$e->getMessage());

            return self::FAILURE;
        } finally {
            $this->mqtt->disconnect();
        }

        return self::SUCCESS;
    }

    /**
     * @param array<string, mixed> $payload
     * @return array<int, array<string, mixed>>
     */
    private function evaluateTelemetryPayload(IndoorFarmingDeviceConfig $config, array $payload): array
    {
        $roTargetLevel = (int) ($config->ro_target_level ?: 2);
        $waterLevelCurrent = (int) ($payload['water_level_current'] ?? $payload['water_level']['current'] ?? 0);
        $waterLevelLabel = trim((string) ($payload['water_level_label'] ?? $payload['water_level']['current_label'] ?? 'UNKNOWN'));
        $relayDo6 = filter_var($payload['relay']['do6'] ?? null, FILTER_VALIDATE_BOOL, FILTER_NULL_ON_FAILURE);

        $transitions = [];
        $transitions[] = $this->transition(
            'ro_target_reached',
            $waterLevelCurrent >= $roTargetLevel,
            'Tandon RO Mencapai Target',
            'Level air RO sudah mencapai batas '.$this->roTargetLabel($roTargetLevel).' dengan status '.$waterLevelLabel.'.',
            'Level RO Turun dari Target',
            'Level air RO turun dari batas target dan sekarang berada di '.$waterLevelLabel.'.',
            'info'
        );
        $transitions[] = $this->transition(
            'irrigation_running',
            $relayDo6 === true,
            'Jadwal Irigasi Berjalan',
            'Pompa irigasi indoor farming sedang berjalan sesuai jadwal.',
            'Jadwal Irigasi Selesai',
            'Pompa irigasi indoor farming telah berhenti.',
            'info',
            false
        );

        return array_values(array_filter($transitions));
    }

    /**
     * @param array<string, mixed> $payload
     * @return array<int, array<string, mixed>>
     */
    private function evaluateStatusPayload(string $deviceId, array $payload): array
    {
        $online = filter_var($payload['online'] ?? true, FILTER_VALIDATE_BOOL, FILTER_NULL_ON_FAILURE);
        if ($online === null) {
            return [];
        }

        $transition = $this->transition(
            'device_online_state',
            $online === false,
            'ESP Indoor Farming Nonaktif',
            'Perangkat '.$deviceId.' terputus dari sistem.',
            'ESP Indoor Farming Aktif',
            'Perangkat '.$deviceId.' kembali terhubung.',
            'critical'
        );

        return $transition ? [$transition] : [];
    }

    private function resolveConfig(string $deviceId): IndoorFarmingDeviceConfig
    {
        return IndoorFarmingDeviceConfig::query()->firstOrCreate(
            ['device_id' => $deviceId],
            [
                'auto_enabled' => true,
                'nft_interval_min' => 30,
                'nft_duration_min' => 5,
                'irrigation_duration_sec' => 120,
                'irrigation_times' => [],
                'target_ppm' => 900,
                'ppm_deadband' => 30,
                'target_ph' => 6,
                'ph_deadband' => 0.15,
                'nutrition_dose_pulse_sec' => 2,
                'ph_dose_pulse_sec' => 2,
                'nutrition_dosing_cooldown_sec' => 30,
                'ph_dosing_cooldown_sec' => 30,
                'nft_sensor_warmup_sec' => 60,
                'ro_target_level' => 2,
            ]
        );
    }

    /**
     * @return array<string, mixed>|null
     */
    private function transition(
        string $alertKey,
        bool $nextState,
        string $activeTitle,
        string $activeMessage,
        string $resolvedTitle,
        string $resolvedMessage,
        string $severity,
        bool $sendResolved = true
    ): ?array {
        $cacheKey = self::CACHE_STATE_PREFIX.$alertKey;
        $currentState = (bool) Cache::get($cacheKey, false);
        if ($currentState === $nextState) {
            return null;
        }

        Cache::forever($cacheKey, $nextState);

        if (! $nextState && ! $sendResolved) {
            return null;
        }

        return [
            'type' => $alertKey,
            'state' => $nextState ? 'active' : 'resolved',
            'title' => $nextState ? $activeTitle : $resolvedTitle,
            'message' => $nextState ? $activeMessage : $resolvedMessage,
            'severity' => $nextState ? $severity : 'info',
        ];
    }

    /**
     * @param array<string, mixed> $transition
     */
    private function dispatchTransition(string $deviceId, string $receivedTopic, array $transition): void
    {
        $topics = [
            $this->fcm->defaultTopic(),
            'indoor_farming_alerts',
            'device_'.$this->sanitizeTopic($deviceId).'_alerts',
        ];

        $results = $this->fcm->sendToTopics($topics, (string) $transition['title'], (string) $transition['message'], [
            'source' => 'indoor_farming_backend_rule',
            'area' => 'indoor_farming',
            'device_id' => $deviceId,
            'mqtt_topic' => $receivedTopic,
            'alert_type' => (string) $transition['type'],
            'alert_state' => (string) $transition['state'],
            'severity' => (string) $transition['severity'],
        ]);

        Log::info('[Indoor Alert Worker] Alert transition dispatched.', [
            'device_id' => $deviceId,
            'mqtt_topic' => $receivedTopic,
            'transition' => $transition,
            'fcm_topics' => $topics,
            'results' => $results,
        ]);

        $this->line(sprintf(
            '[mqtt:consume-indoor-farming-alerts] %s %s -> %s',
            $deviceId,
            $transition['type'],
            $transition['state']
        ));
    }

    private function sanitizeTopic(string $value): string
    {
        $value = strtolower(trim($value));
        $value = preg_replace('/[^a-z0-9_]+/', '_', $value) ?? '';

        return trim($value, '_');
    }

    private function roTargetLabel(int $level): string
    {
        return $level >= 3 ? 'HIGH' : 'MID';
    }
}
