<?php

namespace App\Console\Commands;

use App\Services\FirebaseMessagingService;
use App\Services\InfluxDbService;
use Illuminate\Console\Command;
use Illuminate\Support\Facades\Log;

/**
 * Kirim status harian (mode + online) untuk semua perangkat monitoring kebun percobaan:
 *  - BC-1  : bc1_screenhouse   (Screen House)
 *  - BC-2  : bc2_hydroponic    (Hidroponik)
 *  - ATC   : atc_enviro, atc_smart_hidroponik, atc_irigasi_rkk, atc_irigasi_rkb
 *
 * Dijalankan 2x sehari: jam 07:00 dan 16:00 WIB.
 */
class SendMonitoringDailyStatus extends Command
{
    protected $signature = 'monitoring:send-daily-status
        {--threshold=120 : Seconds since last_seen to consider device online}';

    protected $description = 'Send scheduled daily monitoring status (mode + online) for all kebun percobaan devices to FCM.';

    /**
     * Daftar semua perangkat yang dipantau.
     * Format: ['device_id', 'area MQTT', 'Nama Tampilan', 'FCM area_key']
     */
    private const DEVICES = [
        // BC-1
        ['id' => 'bc1_screenhouse',    'mqtt_area' => 'monitoring', 'name' => 'Screen House (BC-1)', 'area' => 'bc1'],
        // BC-2
        ['id' => 'bc2_hydroponic',     'mqtt_area' => 'monitoring', 'name' => 'Hidroponik (BC-2)',   'area' => 'bc2'],
        // ATC
        ['id' => 'atc_enviro',          'mqtt_area' => 'monitoring', 'name' => 'Enviro Control (ATC)',      'area' => 'atc'],
        ['id' => 'atc_smart_hidroponik','mqtt_area' => 'monitoring', 'name' => 'Smart Hidroponik (ATC)',    'area' => 'atc'],
        ['id' => 'atc_irigasi_rkk',     'mqtt_area' => 'monitoring', 'name' => 'Irigasi RKK (ATC)',        'area' => 'atc'],
        ['id' => 'atc_irigasi_rkb',     'mqtt_area' => 'monitoring', 'name' => 'Irigasi RKB (ATC)',        'area' => 'atc'],
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
            $this->processDevice($device, $threshold);
        }

        return self::SUCCESS;
    }

    private function processDevice(array $device, int $threshold): void
    {
        $deviceId = $device['id'];
        $name     = $device['name'];
        $area     = $device['area'];

        // Ambil data sensor terakhir dari InfluxDB (measurement: monitoring_sensor)
        $sensor   = $this->influx->getLatestSensor($deviceId, 'monitoring_sensor');
        $lastSeen = (int) ($sensor['timestamp'] ?? 0);
        $online   = $lastSeen > 0 && (time() - $lastSeen <= $threshold);

        // Mode hanya tersedia jika ESP mengirim field "mode" di MQTT status.
        // Jika tidak ada, default ke 'manual'.
        $mode = strtolower(trim((string) ($sensor['mode'] ?? 'manual')));
        if (! in_array($mode, ['auto', 'manual'], true)) {
            $mode = 'manual';
        }

        $topics = $this->buildTopics($deviceId, $area);

        $title = "Status Monitoring – {$name}";
        $body  = sprintf('Mode: %s • ESP: %s', strtoupper($mode), $online ? 'ONLINE' : 'OFFLINE');

        $results = $this->fcm->sendToTopics($topics, $title, $body, [
            'source'    => 'monitoring_daily_status',
            'area'      => $area,
            'device_id' => $deviceId,
            'mode'      => $mode,
            'online'    => $online ? 'true' : 'false',
            'last_seen' => (string) $lastSeen,
        ]);

        Log::info('[Monitoring Daily Status] Dispatched.', [
            'device_id' => $deviceId,
            'name'      => $name,
            'mode'      => $mode,
            'online'    => $online,
            'topics'    => $topics,
            'results'   => $results,
        ]);

        $this->line(sprintf(
            '[monitoring:send-daily-status] device=%s name=%s mode=%s online=%s',
            $deviceId,
            $name,
            $mode,
            $online ? 'true' : 'false'
        ));
    }

    /**
     * Bangun daftar FCM topic untuk satu device.
     */
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
