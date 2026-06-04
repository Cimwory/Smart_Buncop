<?php

namespace App\Console\Commands;

use App\Services\FirebaseMessagingService;
use App\Services\InfluxDbService;
use Illuminate\Console\Command;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Log;

/**
 * Pantau koneksi real-time semua perangkat monitoring kebun percobaan.
 * Berjalan setiap 1 menit. Mengirim notifikasi FCM hanya saat:
 *  1. Status berubah dari ONLINE → OFFLINE (ESP baru saja mati/WiFi putus)
 *  2. Status berubah dari OFFLINE → ONLINE (ESP kembali terhubung)
 *
 * Catatan: mode change (perubahan auto/manual) dipantau setiap 1 menit
 * dan notifikasi dikirim jika mode berubah sejak pemeriksaan terakhir.
 */
class CheckMonitoringConnection extends Command
{
    protected $signature = 'monitoring:check-connection
        {--threshold=120 : Seconds since last_seen to consider device offline}';

    protected $description = 'Check real-time connection status for all monitoring area devices and alert via FCM on change.';

    private const DEVICES = [
        ['id' => 'bc1_screenhouse',     'name' => 'Screen House (BC-1)', 'area' => 'bc1'],
        ['id' => 'bc2_hydroponic',      'name' => 'Hidroponik (BC-2)',   'area' => 'bc2'],
        ['id' => 'atc_enviro',           'name' => 'Enviro Control (ATC)',      'area' => 'atc'],
        ['id' => 'atc_smart_hidroponik', 'name' => 'Smart Hidroponik (ATC)',    'area' => 'atc'],
        ['id' => 'atc_irigasi_rkk',      'name' => 'Irigasi RKK (ATC)',        'area' => 'atc'],
        ['id' => 'atc_irigasi_rkb',      'name' => 'Irigasi RKB (ATC)',        'area' => 'atc'],
    ];

    public function __construct(
        private readonly FirebaseMessagingService $fcm,
        private readonly InfluxDbService $influx,
    ) {
        parent::__construct();
    }

    public function handle(): int
    {
        $threshold = max(60, (int) $this->option('threshold'));

        foreach (self::DEVICES as $device) {
            $this->checkDevice($device, $threshold);
        }

        return self::SUCCESS;
    }

    private function checkDevice(array $device, int $threshold): void
    {
        $deviceId = $device['id'];
        $name     = $device['name'];
        $area     = $device['area'];

        $sensor   = $this->influx->getLatestSensor($deviceId, 'monitoring_sensor');
        $lastSeen = (int) ($sensor['timestamp'] ?? 0);
        $isOffline = $lastSeen === 0 || (time() - $lastSeen > $threshold);

        $currentMode = strtolower(trim((string) ($sensor['mode'] ?? 'manual')));
        if (! in_array($currentMode, ['auto', 'manual'], true)) {
            $currentMode = 'manual';
        }

        $topics = $this->buildTopics($deviceId, $area);

        // ── Cek perubahan status online/offline ──
        $onlineCacheKey = "monitoring_offline_status_{$deviceId}";
        $wasOffline = Cache::get($onlineCacheKey, false);

        if ($isOffline && ! $wasOffline) {
            Cache::put($onlineCacheKey, true, now()->addDays(7));
            $this->sendConnectionAlert($deviceId, $name, false, $lastSeen, $topics);
            $this->info("[{$deviceId}] OFFLINE alert sent.");
        } elseif (! $isOffline && $wasOffline) {
            Cache::put($onlineCacheKey, false, now()->addDays(7));
            $this->sendConnectionAlert($deviceId, $name, true, $lastSeen, $topics);
            $this->info("[{$deviceId}] ONLINE (recovered) alert sent.");
        } else {
            $this->line("[{$deviceId}] status unchanged (offline=" . ($isOffline ? 'yes' : 'no') . ').');
        }

        // ── Cek perubahan mode ──
        $modeCacheKey = "monitoring_mode_{$deviceId}";
        $prevMode = Cache::get($modeCacheKey, null);

        if ($prevMode !== null && $prevMode !== $currentMode) {
            $this->sendModeChangeAlert($deviceId, $name, $prevMode, $currentMode, $topics);
            $this->info("[{$deviceId}] Mode changed: {$prevMode} → {$currentMode}.");
        }

        // Simpan mode saat ini untuk perbandingan berikutnya
        Cache::put($modeCacheKey, $currentMode, now()->addDays(7));
    }

    private function sendConnectionAlert(
        string $deviceId,
        string $name,
        bool $isOnline,
        int $lastSeen,
        array $topics
    ): void {
        $title = $isOnline
            ? "Koneksi Pulih – {$name}"
            : "⚠️ ESP Terputus – {$name}";

        $body = $isOnline
            ? "Perangkat ESP {$name} telah kembali terhubung."
            : "Koneksi ke ESP {$name} terputus. Periksa daya atau WiFi perangkat.";

        $this->fcm->sendToTopics($topics, $title, $body, [
            'source'    => 'monitoring_connection_alert',
            'device_id' => $deviceId,
            'online'    => $isOnline ? 'true' : 'false',
            'last_seen' => (string) $lastSeen,
        ]);

        Log::info('[Monitoring Connection Alert] Dispatched.', [
            'device_id' => $deviceId,
            'online'    => $isOnline,
            'topics'    => $topics,
        ]);
    }

    private function sendModeChangeAlert(
        string $deviceId,
        string $name,
        string $prevMode,
        string $currentMode,
        array $topics
    ): void {
        $title = "🔄 Mode Berubah – {$name}";
        $body  = sprintf(
            'Mode pada perangkat %s berubah dari %s ke %s.',
            $name,
            strtoupper($prevMode),
            strtoupper($currentMode)
        );

        $this->fcm->sendToTopics($topics, $title, $body, [
            'source'     => 'monitoring_mode_change',
            'device_id'  => $deviceId,
            'prev_mode'  => $prevMode,
            'mode'       => $currentMode,
        ]);

        Log::info('[Monitoring Mode Change Alert] Dispatched.', [
            'device_id'  => $deviceId,
            'prev_mode'  => $prevMode,
            'mode'       => $currentMode,
            'topics'     => $topics,
        ]);
    }

    private function buildTopics(string $deviceId, string $area): array
    {
        return [
            $this->fcm->defaultTopic(),
            'monitoring_alerts',
            "{$area}_alerts",
            'device_' . $this->sanitizeTopic($deviceId) . '_alerts',
        ];
    }

    private function sanitizeTopic(string $value): string
    {
        $value = strtolower(trim($value));
        $value = preg_replace('/[^a-z0-9_]+/', '_', $value) ?? '';

        return trim($value, '_');
    }
}
