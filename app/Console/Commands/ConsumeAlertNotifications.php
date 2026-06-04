<?php

namespace App\Console\Commands;

use App\Services\FirebaseMessagingService;
use App\Services\MqttService;
use Illuminate\Console\Command;
use Illuminate\Support\Facades\Log;

class ConsumeAlertNotifications extends Command
{
    /**
     * @var array<string, array<int, string>>
     */
    private const DISABLED_ALERT_TYPES_BY_AREA = [
        'indoor_farming' => [
            'ph_low',
            'ph_high',
            'ph_normal',
            'ppm_low',
            'ppm_high',
            'ppm_normal',
            'ro_tank_low',
            'ro_tank_normal',
            'solution_temp_high',
            'solution_temp_normal',
            'do_low',
            'do_normal',
        ],
    ];

    protected $signature = 'mqtt:consume-alert-notifications
        {--topic= : Override full MQTT topic}
        {--qos=0 : MQTT QoS level}
        {--once : Stop after first successfully processed alert}';

    protected $description = 'Consume MQTT alert messages and forward them to Firebase Cloud Messaging topics.';

    /**
     * @var array<string, array{lamp:bool,fan:bool,sprayer:bool,initialized:bool}>
     */
    private array $relayStateByDevice = [];

    public function __construct(
        private readonly MqttService $mqtt,
        private readonly FirebaseMessagingService $fcm,
    ) {
        parent::__construct();
    }

    public function handle(): int
    {
        $topic = trim((string) $this->option('topic'));
        if ($topic === '') {
            $topic = config('mqtt.topic_prefix', 'buncop').'/+/+/alert';
        }

        $incubatorStatusTopic = config('mqtt.topic_prefix', 'buncop').'/incubator/+/status';

        $qos = max(0, min(2, (int) $this->option('qos')));
        $stopAfterFirst = (bool) $this->option('once');

        $this->info("[mqtt:consume-alert-notifications] subscribe alert={$topic} incubator_status={$incubatorStatusTopic} qos={$qos}");

        try {
            $this->mqtt->subscribe(
                $topic,
                function (string $receivedTopic, string $message, bool $retained, array $matchedWildcards = []) use ($stopAfterFirst): void {
                    $payload = json_decode($message, true);
                    if (! is_array($payload)) {
                        Log::warning('[FCM Alert Worker] Ignore non-JSON alert payload', [
                            'topic' => $receivedTopic,
                            'retained' => $retained,
                            'wildcards' => $matchedWildcards,
                        ]);

                        return;
                    }

                    $segments = array_values(array_filter(explode('/', trim($receivedTopic, '/'))));
                    $area = strtolower(trim((string) ($segments[1] ?? 'unknown')));
                    $deviceId = trim((string) ($segments[2] ?? 'unknown_device'));
                    $alertType = strtolower(trim((string) ($payload['type'] ?? 'alert')));

                    if ($this->shouldSkipAlert($area, $alertType)) {
                        Log::info('[FCM Alert Worker] Alert skipped by backend filter.', [
                            'mqtt_topic' => $receivedTopic,
                            'area' => $area,
                            'device_id' => $deviceId,
                            'alert_type' => $alertType,
                        ]);

                        $this->line(sprintf(
                            '[mqtt:consume-alert-notifications] skipped area=%s device=%s type=%s',
                            $area,
                            $deviceId,
                            $alertType
                        ));

                        return;
                    }

                    [$title, $body] = $this->resolveNotificationText($payload, $area, $deviceId);
                    $topics = $this->buildTopics($area, $deviceId);

                    $results = $this->fcm->sendToTopics($topics, $title, $body, [
                        'source' => 'mqtt_alert_worker',
                        'area' => $area,
                        'device_id' => $deviceId,
                        'mqtt_topic' => $receivedTopic,
                        'alert_type' => (string) ($payload['type'] ?? 'alert'),
                    ]);

                    Log::info('[FCM Alert Worker] Alert forwarded.', [
                        'mqtt_topic' => $receivedTopic,
                        'fcm_topics' => $topics,
                        'results' => $results,
                    ]);

                    $this->line(sprintf(
                        '[mqtt:consume-alert-notifications] sent area=%s device=%s topics=%s',
                        $area,
                        $deviceId,
                        implode(',', $topics)
                    ));

                    if ($stopAfterFirst) {
                        $this->mqtt->interrupt();
                    }
                },
                $qos
            );

            $this->mqtt->subscribe(
                $incubatorStatusTopic,
                function (string $receivedTopic, string $message, bool $retained, array $matchedWildcards = []) use ($stopAfterFirst): void {
                    $payload = json_decode($message, true);
                    if (! is_array($payload)) {
                        Log::warning('[FCM Incubator Status Worker] Ignore non-JSON payload', [
                            'topic' => $receivedTopic,
                            'retained' => $retained,
                            'wildcards' => $matchedWildcards,
                        ]);

                        return;
                    }

                    $segments = array_values(array_filter(explode('/', trim($receivedTopic, '/'))));
                    $deviceId = trim((string) ($segments[2] ?? 'unknown_device'));
                    if ($deviceId === '') {
                        return;
                    }

                    $relay = $payload['relay'] ?? null;
                    if (! is_array($relay)) {
                        return;
                    }

                    $next = [
                        'lamp' => filter_var($relay['lamp'] ?? false, FILTER_VALIDATE_BOOL),
                        'fan' => filter_var($relay['fan'] ?? false, FILTER_VALIDATE_BOOL),
                        'sprayer' => filter_var($relay['sprayer'] ?? false, FILTER_VALIDATE_BOOL),
                    ];

                    $current = $this->relayStateByDevice[$deviceId] ?? [
                        'lamp' => false,
                        'fan' => false,
                        'sprayer' => false,
                        'initialized' => false,
                    ];

                    // Always store the latest snapshot. Avoid sending notifications
                    // for retained messages or the first snapshot after boot.
                    $shouldNotify = $current['initialized'] && ! $retained;
                    $this->relayStateByDevice[$deviceId] = [
                        'lamp' => $next['lamp'],
                        'fan' => $next['fan'],
                        'sprayer' => $next['sprayer'],
                        'initialized' => true,
                    ];

                    if (! $shouldNotify) {
                        return;
                    }

                    $topics = $this->buildTopics('incubator', $deviceId);

                    foreach (['sprayer' => 'Sprayer', 'lamp' => 'Lampu', 'fan' => 'Kipas'] as $key => $label) {
                        $prevValue = (bool) ($current[$key] ?? false);
                        $nextValue = (bool) ($next[$key] ?? false);
                        if ($prevValue === $nextValue) {
                            continue;
                        }

                        $title = $label.' Inkubator';
                        $body = $nextValue
                            ? $label.' menyala'
                            : $label.' mati';

                        $results = $this->fcm->sendToTopics($topics, $title, $body, [
                            'source' => 'mqtt_status_worker',
                            'area' => 'incubator',
                            'device_id' => $deviceId,
                            'mqtt_topic' => $receivedTopic,
                            'event' => 'relay_change',
                            'relay' => $key,
                            'state' => $nextValue ? 'on' : 'off',
                        ]);

                        Log::info('[FCM Incubator Status Worker] Relay notification forwarded.', [
                            'mqtt_topic' => $receivedTopic,
                            'device_id' => $deviceId,
                            'relay' => $key,
                            'state' => $nextValue ? 'on' : 'off',
                            'fcm_topics' => $topics,
                            'results' => $results,
                        ]);

                        $this->line(sprintf(
                            '[mqtt:consume-alert-notifications] incubator relay %s %s -> %s',
                            $deviceId,
                            $key,
                            $nextValue ? 'on' : 'off'
                        ));

                        if ($stopAfterFirst) {
                            $this->mqtt->interrupt();
                            return;
                        }
                    }
                },
                $qos
            );

            $this->mqtt->loop(true);
        } catch (\Throwable $e) {
            Log::error('[FCM Alert Worker] Crashed.', [
                'message' => $e->getMessage(),
                'topic' => $topic,
            ]);
            $this->error('[mqtt:consume-alert-notifications] '.$e->getMessage());

            return self::FAILURE;
        } finally {
            $this->mqtt->disconnect();
        }

        return self::SUCCESS;
    }

    /**
     * @param array<string, mixed> $payload
     * @return array{0:string,1:string}
     */
    private function resolveNotificationText(array $payload, string $area, string $deviceId): array
    {
        $title = trim((string) ($payload['title'] ?? ''));
        $body = trim((string) ($payload['message'] ?? $payload['body'] ?? ''));

        if ($title !== '' && $body !== '') {
            return [$title, $body];
        }

        $type = strtolower(trim((string) ($payload['type'] ?? 'alert')));

        return match ($type) {
            'temperature_high' => ['Suhu terlalu tinggi', 'Perangkat '.$deviceId.' mendeteksi suhu melebihi ambang batas.'],
            'temperature_low' => ['Suhu terlalu rendah', 'Perangkat '.$deviceId.' mendeteksi suhu di bawah ambang batas.'],
            'humidity_low' => ['Kelembapan rendah', 'Perangkat '.$deviceId.' mendeteksi kelembapan di bawah ambang batas.'],
            'offline' => ['Perangkat offline', 'Perangkat '.$deviceId.' pada area '.$area.' terputus dari sistem.'],
            default => [
                $title !== '' ? $title : 'Alert perangkat '.$deviceId,
                $body !== '' ? $body : 'Area '.$area.' mengirim alert baru.',
            ],
        };
    }

    /**
     * @return array<int, string>
     */
    private function buildTopics(string $area, string $deviceId): array
    {
        $topics = [];

        $defaultTopic = trim($this->fcm->defaultTopic());
        if ($defaultTopic !== '') {
            $topics[] = $defaultTopic;
        }

        $areaTopic = $this->sanitizeTopic($area);
        if ($areaTopic !== '') {
            $topics[] = $areaTopic.'_alerts';
        }

        $deviceTopic = $this->sanitizeTopic($deviceId);
        if ($deviceTopic !== '') {
            $topics[] = 'device_'.$deviceTopic.'_alerts';
        }

        return array_values(array_unique($topics));
    }

    private function sanitizeTopic(string $value): string
    {
        $value = strtolower(trim($value));
        $value = preg_replace('/[^a-z0-9_]+/', '_', $value) ?? '';

        return trim($value, '_');
    }

    private function shouldSkipAlert(string $area, string $alertType): bool
    {
        if ($area === '' || $alertType === '') {
            return false;
        }

        $disabledTypes = self::DISABLED_ALERT_TYPES_BY_AREA[$area] ?? [];

        return in_array($alertType, $disabledTypes, true);
    }
}
