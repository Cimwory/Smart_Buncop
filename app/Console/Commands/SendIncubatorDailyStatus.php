<?php

namespace App\Console\Commands;

use App\Models\InkubatorDeviceConfig;
use App\Services\FirebaseMessagingService;
use App\Services\InfluxDbService;
use Illuminate\Console\Command;
use Illuminate\Support\Facades\Log;

class SendIncubatorDailyStatus extends Command
{
    protected $signature = 'inkubator:send-daily-status
        {--device= : Override device id (default from INCUBATOR_DEFAULT_DEVICE_ID)}
        {--online-threshold=30 : Seconds since last_seen to consider device online}';

    protected $description = 'Send scheduled daily incubator status (mode + online) to FCM topics.';

    public function __construct(
        private readonly FirebaseMessagingService $fcm,
        private readonly InfluxDbService $influx,
    ) {
        parent::__construct();
    }

    public function handle(): int
    {
        $deviceId = trim((string) $this->option('device'));
        if ($deviceId === '') {
            $deviceId = trim((string) config('services.incubator.default_device_id', 'inkubator_1'));
        }

        if ($deviceId === '') {
            $this->error('[inkubator:send-daily-status] device id kosong.');

            return self::FAILURE;
        }

        $threshold = max(5, (int) $this->option('online-threshold'));

        $config = InkubatorDeviceConfig::query()->where('device_id', $deviceId)->first();
        $mode = strtolower(trim((string) ($config?->mode ?? 'manual')));
        if (! in_array($mode, ['auto', 'manual'], true)) {
            $mode = 'manual';
        }

        $sensor = $this->influx->getLatestSensor($deviceId, 'incubator_sensor');
        $lastSeen = (int) ($sensor['timestamp'] ?? 0);
        $online = $lastSeen > 0 ? (time() - $lastSeen <= $threshold) : false;

        $topics = [
            $this->fcm->defaultTopic(),
            'incubator_alerts',
            'device_'.$this->sanitizeTopic($deviceId).'_alerts',
        ];

        $title = 'Status Inkubator';
        $body = sprintf('Mode: %s • ESP: %s', strtoupper($mode), $online ? 'ONLINE' : 'OFFLINE');

        $results = $this->fcm->sendToTopics($topics, $title, $body, [
            'source' => 'inkubator_daily_status',
            'area' => 'incubator',
            'device_id' => $deviceId,
            'mode' => $mode,
            'online' => $online ? 'true' : 'false',
            'last_seen' => (string) $lastSeen,
        ]);

        Log::info('[Inkubator Daily Status] Dispatched.', [
            'device_id' => $deviceId,
            'mode' => $mode,
            'online' => $online,
            'last_seen' => $lastSeen,
            'topics' => $topics,
            'results' => $results,
        ]);

        $this->line(sprintf(
            '[inkubator:send-daily-status] sent device=%s mode=%s online=%s',
            $deviceId,
            $mode,
            $online ? 'true' : 'false'
        ));

        return self::SUCCESS;
    }

    private function sanitizeTopic(string $value): string
    {
        $value = strtolower(trim($value));
        $value = preg_replace('/[^a-z0-9_]+/', '_', $value) ?? '';

        return trim($value, '_');
    }
}

