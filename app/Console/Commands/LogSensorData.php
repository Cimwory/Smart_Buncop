<?php

namespace App\Console\Commands;

use App\Models\ActivityLog;
use App\Services\InfluxDbService;
use Illuminate\Console\Command;
use Illuminate\Support\Facades\Log;

class LogSensorData extends Command
{
    protected $signature = 'sensor:log {--device= : Device ID to read}';

    protected $description = 'Read latest sensor data from InfluxDB and store as activity log';

    public function handle(): int
    {
        $deviceId = (string) ($this->option('device') ?: config('services.incubator.default_device_id', 'inkubator_1'));

        if ($deviceId === '') {
            $this->warn('[sensor:log] device_id kosong. Set INCUBATOR_DEFAULT_DEVICE_ID atau pakai --device=');
            return self::SUCCESS;
        }

        try {
            $influx = new InfluxDbService();
            $sensor = $influx->getLatestSensor($deviceId, 'incubator_sensor');

            $temperature = $sensor['temperature'];
            $humidity = $sensor['humidity'];

            if ($temperature === null && $humidity === null) {
                $this->line("[sensor:log] {$deviceId} — no recent data in InfluxDB");
                return self::SUCCESS;
            }

            $parts = [];
            if ($temperature !== null) {
                $parts[] = "suhu: {$temperature}°C";
            }
            if ($humidity !== null) {
                $parts[] = "kelembapan: {$humidity}%";
            }

            ActivityLog::createSafe([
                'user_id' => null,
                'event' => 'activity',
                'action' => 'inkubator.sensor.snapshot',
                'module' => 'inkubator',
                'device_id' => $deviceId,
                'description' => 'System snapshot sensor — '.implode(', ', $parts),
                'metadata' => array_filter([
                    'temperature' => $temperature,
                    'humidity' => $humidity,
                    'source' => 'influxdb',
                ]),
                'performed_at' => now(),
                'guard' => 'system',
                'role_name' => 'system',
                'login_identifier' => 'system:'.$deviceId,
                'ip_address' => '127.0.0.1',
                'user_agent' => 'artisan/sensor:log',
            ]);

            $this->line("[sensor:log] {$deviceId} temp={$temperature} hum={$humidity}");

        } catch (\Throwable $e) {
            Log::warning("[sensor:log] Error: {$e->getMessage()}");
            $this->error($e->getMessage());

            return self::FAILURE;
        }

        return self::SUCCESS;
    }
}
