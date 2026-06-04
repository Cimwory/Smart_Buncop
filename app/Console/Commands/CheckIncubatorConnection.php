<?php

namespace App\Console\Commands;

use App\Services\FirebaseMessagingService;
use App\Services\InfluxDbService;
use Illuminate\Console\Command;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Log;

class CheckIncubatorConnection extends Command
{
    protected $signature = 'inkubator:check-connection
        {--device= : Override device id (default from INCUBATOR_DEFAULT_DEVICE_ID)}
        {--threshold=120 : Seconds since last_seen to consider device offline}';

    protected $description = 'Check if incubator ESP is offline and send FCM alert.';

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
            $this->error('[inkubator:check-connection] device id kosong.');
            return self::FAILURE;
        }

        $threshold = max(60, (int) $this->option('threshold'));

        $sensor = $this->influx->getLatestSensor($deviceId, 'incubator_sensor');
        $lastSeen = (int) ($sensor['timestamp'] ?? 0);
        $isOffline = $lastSeen === 0 || (time() - $lastSeen > $threshold);
        
        $cacheKey = 'incubator_offline_status_' . $deviceId;
        $wasOffline = Cache::get($cacheKey, false);

        if ($isOffline && !$wasOffline) {
            // Device just went offline
            Cache::put($cacheKey, true, now()->addDays(7));
            $this->sendAlert($deviceId, false, $lastSeen);
            $this->info("Alert sent: ESP $deviceId is OFFLINE.");
        } elseif (!$isOffline && $wasOffline) {
            // Device came back online
            Cache::put($cacheKey, false, now()->addDays(7));
            $this->sendAlert($deviceId, true, $lastSeen);
            $this->info("Alert sent: ESP $deviceId is back ONLINE.");
        } else {
            $this->info("ESP $deviceId status unchanged (Offline: " . ($isOffline ? 'Yes' : 'No') . ").");
        }

        return self::SUCCESS;
    }

    private function sendAlert(string $deviceId, bool $isOnline, int $lastSeen)
    {
        $topics = [
            $this->fcm->defaultTopic(),
            'incubator_alerts',
            'device_'.$this->sanitizeTopic($deviceId).'_alerts',
        ];

        $title = $isOnline ? 'Koneksi Inkubator Pulih' : 'Peringatan: Inkubator Terputus!';
        $body = $isOnline 
            ? "Perangkat ESP inkubator telah kembali terhubung."
            : "Koneksi ke ESP inkubator terputus. Mohon periksa daya atau WiFi perangkat.";

        $this->fcm->sendToTopics($topics, $title, $body, [
            'source' => 'inkubator_connection_monitor',
            'area' => 'incubator',
            'device_id' => $deviceId,
            'online' => $isOnline ? 'true' : 'false',
            'last_seen' => (string) $lastSeen,
        ]);
        
        Log::info('[Inkubator Connection Monitor] Alert dispatched.', [
            'device_id' => $deviceId,
            'online' => $isOnline,
            'topics' => $topics
        ]);
    }

    private function sanitizeTopic(string $value): string
    {
        $value = strtolower(trim($value));
        $value = preg_replace('/[^a-z0-9_]+/', '_', $value) ?? '';

        return trim($value, '_');
    }
}
