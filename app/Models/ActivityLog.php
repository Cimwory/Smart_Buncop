<?php

namespace App\Models;

use App\Services\ActivityLogElasticService;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Support\Facades\Schema;

class ActivityLog extends Model
{
    private static ?array $columnCache = null;

    protected $fillable = [
        'user_id',
        'actor_role',
        'event',
        'action',
        'module',
        'device_id',
        'description',
        'metadata',
        'performed_at',
        'guard',
        'role_name',
        'route_name',
        'url',
        'http_method',
        'status_code',
        'login_identifier',
        'ip_address',
        'user_agent',
        'occurred_at',
    ];

    protected function casts(): array
    {
        return [
            'status_code' => 'integer',
            'occurred_at' => 'datetime',
            'performed_at' => 'datetime',
            'metadata' => 'array',
        ];
    }

    public function getFriendlyActionAttribute(): string
    {
        $action = $this->action;
        $map = [
            'inkubator.plant.upsert' => 'Atur Tanaman',
            'inkubator.plant.apply' => 'Terapkan Tanaman',
            'inkubator.plant.delete' => 'Hapus Tanaman',
            'inkubator.schedule.manual.save' => 'Simpan Jadwal Manual',
            'inkubator.command.relay_fan' => 'Kontrol Kipas',
            'inkubator.command.relay_lamp' => 'Kontrol Lampu',
            'inkubator.command.relay_sprayer' => 'Kontrol Sprayer',
            'inkubator.command.lamp_pwm' => 'Atur Kecerahan Lampu',
            'inkubator.command.setpoint_suhu' => 'Atur Setpoint Suhu',
            'web.auto_relay_activity' => 'Aktivitas Otomatis Alat',
            'auto_relay_activity' => 'Aktivitas Otomatis Alat',
            'auto_repair_active_plant_sync' => 'Penyelarasan Otomatis Perangkat',
            'web.auto_repair_active_plant_sync' => 'Penyelarasan Otomatis Perangkat',
            'auth.login' => 'Masuk Akun',
            'auth.logout' => 'Keluar Akun',
            'auth_login_success' => 'Masuk Akun Berhasil',
            'screen.open' => 'Membuka Halaman',
            'web.ui_button_click' => 'Klik Tombol/Elemen',
            'ui_button_click' => 'Klik Tombol/Elemen',
            'indoor_farming.auto_mode.enable' => 'Mode Otomatis Aktif',
            'indoor_farming.auto_mode.disable' => 'Mode Otomatis Nonaktif',
            'indoor_farming.auto.sensor_air.start' => 'Sensor AIR Aktif',
            'indoor_farming.auto.sensor_air.stop' => 'Sensor AIR Berhenti',
            'indoor_farming.auto.sensor_air_warmup.start' => 'Warmup Sensor AIR Aktif',
            'indoor_farming.auto.sensor_air_warmup.stop' => 'Warmup Sensor AIR Selesai',
            'indoor_farming.auto.irrigation.start' => 'Irigasi Otomatis Aktif',
            'indoor_farming.auto.irrigation.stop' => 'Irigasi Otomatis Berhenti',
            'indoor_farming.auto.irrigation_continuous.start' => 'Irigasi Sensor AIR 24 Jam Aktif',
            'indoor_farming.auto.irrigation_continuous.stop' => 'Irigasi Sensor AIR 24 Jam Nonaktif',
            'indoor_farming.auto.dosing_nutrition.start' => 'Dosing Nutrisi Aktif',
            'indoor_farming.auto.dosing_nutrition.stop' => 'Dosing Nutrisi Selesai',
            'indoor_farming.auto.dosing_ph_up.start' => 'Dosing pH Naik Aktif',
            'indoor_farming.auto.dosing_ph_up.stop' => 'Dosing pH Naik Selesai',
            'indoor_farming.auto.dosing_ph_down.start' => 'Dosing pH Turun Aktif',
            'indoor_farming.auto.dosing_ph_down.stop' => 'Dosing pH Turun Selesai',
            'indoor_farming.auto.ro_fill.start' => 'Pompa Isi RO Aktif',
            'indoor_farming.auto.ro_fill.stop' => 'Pompa Isi RO Berhenti',
        ];
        return $map[$action] ?? $action;
    }

    public function getFriendlyDeviceIdAttribute(): string
    {
        $deviceId = $this->device_id;
        if (empty($deviceId) || $deviceId === '-') {
            return '-';
        }
        if (str_contains(strtolower($deviceId), 'inkubator')) {
            return 'Inkubator';
        }
        if (str_contains(strtolower($deviceId), 'indoor_farming')) {
            return 'Indoor Farming';
        }
        if (str_contains(strtolower($deviceId), 'nutrimix')) {
            return 'Nutrimix';
        }
        return $deviceId;
    }

    public function getFriendlyDescriptionAttribute(): string
    {
        $desc = $this->description;
        if (empty($desc)) {
            return '-';
        }

        // Clean up button click log details
        if (preg_match('/label:\s*([^|]+)/i', $desc, $matches)) {
            return 'Klik tombol "' . trim($matches[1]) . '"';
        }

        // Clean up repair active plant log details
        if (str_contains($desc, 'plantId:') && str_contains($desc, 'temperature:')) {
            preg_match('/temperature:\s*([^|]+)/i', $desc, $mTemp);
            preg_match('/tempMax:\s*([^|]+)/i', $desc, $mMax);
            $temp = isset($mTemp[1]) ? trim($mTemp[1]) : '--';
            $max = isset($mMax[1]) ? trim($mMax[1]) : '--';
            return "Penyelarasan suhu otomatis: Suhu saat ini {$temp}°C (Batas maksimum optimal: {$max}°C)";
        }

        // Replace technical plant ULID with "kustom/aktif"
        $desc = preg_replace('/plant_[a-zA-Z0-9]+/i', 'tanaman kustom', $desc);
        $desc = preg_replace('/01[a-zA-Z0-9]{24}/i', 'tanaman kustom', $desc); // ULID format

        return $desc;
    }

    public function user(): BelongsTo
    {
        return $this->belongsTo(User::class);
    }

    public static function createSafe(array $attributes): self
    {
        $columns = self::$columnCache;
        if ($columns === null) {
            $columns = Schema::hasTable('activity_logs')
                ? Schema::getColumnListing('activity_logs')
                : [];
            self::$columnCache = $columns;
        }

        $payload = [];
        foreach ($attributes as $key => $value) {
            if (in_array($key, $columns, true)) {
                $payload[$key] = $value;
            }
        }

        // Backward compatibility for schemas that use actor_role.
        if (! array_key_exists('actor_role', $payload) && in_array('actor_role', $columns, true)) {
            $payload['actor_role'] = $attributes['role_name'] ?? $attributes['actor_role'] ?? null;
        }

        if (! array_key_exists('performed_at', $payload) && in_array('performed_at', $columns, true)) {
            $payload['performed_at'] = now();
        }

        if (! array_key_exists('action', $payload) && in_array('action', $columns, true)) {
            $payload['action'] = 'activity';
        }

        if (! array_key_exists('event', $payload) && in_array('event', $columns, true)) {
            $event = 'activity';
            $candidate = $payload['action'] ?? $attributes['action'] ?? null;

            if (is_string($candidate) && trim($candidate) !== '') {
                $action = trim($candidate);
                $dotPosition = strpos($action, '.');
                $event = $dotPosition === false ? $action : substr($action, 0, $dotPosition);
                if ($event === '') {
                    $event = 'activity';
                }
            }

            $payload['event'] = $event;
        }

        $log = self::query()->create($payload);

        try {
            app(ActivityLogElasticService::class)->send($log, $attributes);
        } catch (\Throwable) {
            // Activity logging must never break the main user/device flow.
        }

        return $log;
    }
}
