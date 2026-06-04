<?php
namespace App\Http\Controllers;

use App\Models\ActivityLog;
use App\Models\InkubatorDeviceConfig;
use App\Models\PlantProfile;
use App\Services\InfluxDbService;
use App\Services\MqttService;
use App\Services\SensorHistoryService;
use Carbon\Carbon;
use Illuminate\Http\Request;
use Illuminate\Support\Str;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Facades\Schema;

class IncubatorController extends Controller
{
    public function index(Request $request)
    {
        $deviceId = $this->resolveDeviceId((string) $request->query('device_id', ''));

        return view('incubator.index', [
            'initialState' => $this->buildStatePayload($deviceId),
        ]);
    }

    public function state(Request $request)
    {
        $deviceId = $this->resolveDeviceId((string) $request->query('device_id', ''));
        return response()->json($this->buildStatePayload($deviceId));
    }

    public function runtimeSnapshot(Request $request)
    {
        $deviceId = $this->resolveDeviceId((string) $request->query('device_id', ''));
        $state = $this->buildStatePayload($deviceId);

        $runtime = is_array($state['runtime'] ?? null) ? $state['runtime'] : [];
        $config = is_array($state['config'] ?? null) ? $state['config'] : [];
        $sensor = is_array($runtime['sensor'] ?? null) ? $runtime['sensor'] : [];
        $relay = is_array($runtime['relay'] ?? null) ? $runtime['relay'] : [];

        $lastSeen = $this->toNullableInt($runtime['last_seen'] ?? null) ?? 0;

        return response()->json([
            'runtime' => [
                'temperature' => $this->toNullableFloat($sensor['temperature'] ?? null),
                'humidity' => $this->toNullableFloat($sensor['humidity'] ?? null),
                'soil_moisture' => $this->toNullableFloat($sensor['soil_moisture'] ?? null),
                'mode' => (string) ($runtime['mode'] ?? 'manual'),
                'relay' => [
                    'lamp' => (bool) ($relay['lamp'] ?? false),
                    'fan' => (bool) ($relay['fan'] ?? false),
                    'sprayer' => (bool) ($relay['sprayer'] ?? false),
                ],
                'lamp_pwm' => $this->toNullableInt($runtime['lamp_pwm'] ?? ($config['lamp_pwm'] ?? 60)) ?? 60,
                'sprayer_duration' => $this->toNullableInt($config['sprayer_duration'] ?? 10) ?? 10,
                'sprayer_times' => array_values(is_array($config['sprayer_times'] ?? null) ? $config['sprayer_times'] : []),
                'light_schedule' => is_array($config['light_schedule'] ?? null) ? $config['light_schedule'] : [],
                'active_plant' => (string) ($runtime['active_plant'] ?? ($config['active_plant_id'] ?? '')),
                'last_seen' => $lastSeen,
                'online' => $lastSeen > 0 ? (time() - $lastSeen <= 30) : false,
            ],
            'influx_configured' => (new InfluxDbService())->isConfigured(),
        ]);
    }

    private function buildStatePayload(string $deviceId): array
    {
        $plants = PlantProfile::query()
            ->where('device_id', $deviceId)
            ->orderByDesc('created_at')
            ->get();

        $plantsPayload = [];
        foreach ($plants as $plant) {
            $plantsPayload[$plant->id] = [
                'id' => $plant->id,
                'name' => $plant->name,
                'auto' => (bool) $plant->auto,
                'light_pwm' => (int) $plant->light_pwm,
                'light_kelvin' => $plant->light_kelvin,
                'par_target' => $plant->par_target,
                'temp_optimal' => [
                    'min' => $plant->temp_min,
                    'max' => $plant->temp_max,
                ],
                'watering' => [
                    'duration' => (int) $plant->watering_duration,
                    'times' => $plant->watering_times ?? [],
                    'end_times' => $plant->watering_end_times ?? [],
                ],
                'lighting' => $plant->lighting ?? [],
                'light_cycle' => $plant->light_cycle ?? [],
            ];
        }

        $config = InkubatorDeviceConfig::query()
            ->where('device_id', $deviceId)
            ->first();

        $deviceState = $this->fetchDeviceState($deviceId);

        $manual = [];
        $lightSchedule = $config?->light_schedule ?? [];
        $sprayerTimes = $config?->sprayer_times ?? [];
        $sprayerEndTimes = $config?->sprayer_end_times ?? [];
        $sprayerDuration = (int) ($config?->sprayer_duration ?? 10);

        $resolvedActivePlantId = $config?->active_plant_id ?? null;

        $runtime = [
            'mode' => $config?->mode ?? null,
            'sensor' => is_array($deviceState['sensor'] ?? null) ? $deviceState['sensor'] : [],
            'relay' => $config?->relay ?? [],
            'lamp_pwm' => (int) ($config?->lamp_pwm ?? 60),
            'active_plant' => $resolvedActivePlantId,
            'last_seen' => $deviceState['last_seen'] ?? null,
            'status' => $config?->status ?? null,
        ];

        return [
            'plants' => $plantsPayload,
            'config' => [
                'device_id' => $deviceId,
                'lamp_pwm' => (int) ($config?->lamp_pwm ?? ($runtime['lamp_pwm'] ?? 60)),
                'sprayer_duration' => $sprayerDuration,
                'sprayer_times' => $sprayerTimes,
                'sprayer_end_times' => $sprayerEndTimes,
                'light_schedule' => $lightSchedule,
                'active_plant_id' => $resolvedActivePlantId,
            ],
            'runtime' => $runtime,
        ];
    }

    public function upsertPlant(Request $request)
    {
        $validated = $request->validate([
            'id' => ['nullable', 'string', 'max:26'],
            'device_id' => ['nullable', 'string', 'max:100'],
            'name' => ['required', 'string', 'max:150'],
            'auto' => ['nullable', 'boolean'],
            'light_pwm' => ['nullable', 'integer', 'min:0', 'max:100'],
            'light_kelvin' => ['nullable', 'integer', 'min:1000', 'max:20000'],
            'par_target' => ['nullable', 'integer', 'min:0', 'max:100000'],
            'temp_optimal' => ['nullable', 'array'],
            'temp_optimal.min' => ['nullable', 'numeric'],
            'temp_optimal.max' => ['nullable', 'numeric'],
            'watering' => ['nullable', 'array'],
            'watering.duration' => ['nullable', 'integer', 'min:1', 'max:600'],
            'watering.times' => ['nullable', 'array'],
            'watering.times.*' => ['string', 'regex:/^([01]?[0-9]|2[0-3]):[0-5][0-9]$/'],
            'watering.end_times' => ['nullable', 'array'],
            'watering.end_times.*' => ['string', 'regex:/^([01]?[0-9]|2[0-3]):[0-5][0-9](:[0-5][0-9])?$/'],
            'lighting' => ['nullable', 'array'],
            'light_cycle' => ['nullable', 'array'],
        ]);

        $plantId = (string) ($validated['id'] ?? Str::ulid());
        $deviceId = (string) ($validated['device_id'] ?? $this->defaultDeviceId());
        $watering = $validated['watering'] ?? [];
        $tempOptimal = $validated['temp_optimal'] ?? [];
        $wateringTimes = array_values($watering['times'] ?? []);
        $wateringDuration = (int) ($watering['duration'] ?? 10);
        $wateringEndTimes = array_values($watering['end_times'] ?? $this->computeEndTimes($wateringTimes, $wateringDuration));

        $plant = PlantProfile::query()->updateOrCreate(
            ['id' => $plantId],
            [
                'device_id' => $deviceId,
                'name' => $validated['name'],
                'auto' => (bool) ($validated['auto'] ?? true),
                'light_pwm' => (int) ($validated['light_pwm'] ?? 60),
                'light_kelvin' => $validated['light_kelvin'] ?? 6500,
                'par_target' => $validated['par_target'] ?? 200,
                'watering_times' => $wateringTimes,
                'watering_end_times' => $wateringEndTimes,
                'watering_duration' => $wateringDuration,
                'temp_min' => $tempOptimal['min'] ?? null,
                'temp_max' => $tempOptimal['max'] ?? null,
                'lighting' => $validated['lighting'] ?? [],
                'light_cycle' => $validated['light_cycle'] ?? [],
                'created_by' => $request->user()?->id,
            ]
        );

        $this->storeActivity($request, [
            'action' => 'inkubator.plant.upsert',
            'module' => 'inkubator',
            'device_id' => $deviceId,
            'description' => "Simpan tanaman {$plant->name}",
            'metadata' => [
                'plant_id' => $plant->id,
                'plant_name' => $plant->name,
                'auto' => (bool) $plant->auto,
                'light_cycle' => $plant->light_cycle,
            ],
        ]);

        return response()->json([
            'message' => 'Plant profile tersimpan.',
            'id' => $plant->id,
        ]);
    }

    public function deletePlant(Request $request, string $id)
    {
        $plant = PlantProfile::query()->where('id', $id)->first();

        if (! $plant) {
            return response()->json(['message' => 'Plant profile tidak ditemukan.'], 404);
        }

        $user = $request->user();
        $userRole = strtolower((string) ($user?->role?->name ?? $user?->role ?? ''));
        $isAdminOrAbove = in_array($userRole, ['super_admin', 'admin'], true);

        if (! $isAdminOrAbove && $plant->created_by !== $user?->id) {
            return response()->json(['message' => 'Anda tidak memiliki akses untuk menghapus tanaman ini.'], 403);
        }

        $deviceId = $plant->device_id ?? $this->defaultDeviceId();

        PlantProfile::query()->where('id', $id)->delete();
        InkubatorDeviceConfig::query()
            ->where('active_plant_id', $id)
            ->update(['active_plant_id' => null]);

        $this->storeActivity($request, [
            'action' => 'inkubator.plant.delete',
            'module' => 'inkubator',
            'device_id' => $deviceId,
            'description' => "Hapus tanaman {$id}",
            'metadata' => [
                'plant_id' => $id,
                'plant_name' => $plant?->name,
            ],
        ]);

        return response()->json([
            'message' => 'Plant profile dihapus.',
        ]);
    }

    public function saveManualSchedule(Request $request)
    {
        $validated = $request->validate([
            'device_id' => ['nullable', 'string', 'max:100'],
            'sprayer_duration' => ['required', 'integer', 'min:1', 'max:600'],
            'sprayer_times' => ['required', 'array', 'min:1'],
            'sprayer_times.*' => ['string', 'regex:/^([01]?[0-9]|2[0-3]):[0-5][0-9]$/'],
            'sprayer_end_times' => ['nullable', 'array'],
            'sprayer_end_times.*' => ['string', 'regex:/^([01]?[0-9]|2[0-3]):[0-5][0-9](:[0-5][0-9])?$/'],
            'light_schedule' => ['required', 'array'],
        ]);

        $deviceId = (string) ($validated['device_id'] ?? $this->defaultDeviceId());
        $sprayerTimes = array_values($validated['sprayer_times']);
        $sprayerDuration = (int) $validated['sprayer_duration'];
        $sprayerEndTimes = array_values($validated['sprayer_end_times'] ?? $this->computeEndTimes($sprayerTimes, $sprayerDuration));

        InkubatorDeviceConfig::query()->updateOrCreate(
            ['device_id' => $deviceId],
            [
                'sprayer_duration' => $sprayerDuration,
                'sprayer_times' => $sprayerTimes,
                'sprayer_end_times' => $sprayerEndTimes,
                'light_schedule' => $validated['light_schedule'],
                'updated_by' => $request->user()?->id,
            ]
        );

        $this->storeActivity($request, [
            'action' => 'inkubator.schedule.manual.save',
            'module' => 'inkubator',
            'device_id' => $deviceId,
            'description' => 'Simpan jadwal manual inkubator',
            'metadata' => [
                'sprayer_duration' => (int) $validated['sprayer_duration'],
                'sprayer_times' => $sprayerTimes,
                'sprayer_end_times' => $sprayerEndTimes,
                'light_schedule' => $validated['light_schedule'],
            ],
        ]);

        return response()->json(['message' => 'Jadwal manual tersimpan.']);
    }

    public function applyPlant(Request $request)
    {
        $validated = $request->validate([
            'device_id' => ['nullable', 'string', 'max:100'],
            'active_plant_id' => ['required', 'string', 'max:26'],
            'sprayer_duration' => ['required', 'integer', 'min:1', 'max:600'],
            'sprayer_times' => ['required', 'array', 'min:1'],
            'sprayer_times.*' => ['string'],
            'sprayer_end_times' => ['nullable', 'array'],
            'sprayer_end_times.*' => ['string'],
            'light_schedule' => ['required', 'array'],
            'lamp_pwm' => ['required', 'integer', 'min:0', 'max:100'],
        ]);

        $deviceId = (string) ($validated['device_id'] ?? $this->defaultDeviceId());
        $sprayerTimes = array_values($validated['sprayer_times']);
        $sprayerDuration = (int) $validated['sprayer_duration'];
        $sprayerEndTimes = array_values($validated['sprayer_end_times'] ?? $this->computeEndTimes($sprayerTimes, $sprayerDuration));

        InkubatorDeviceConfig::query()->updateOrCreate(
            ['device_id' => $deviceId],
            [
                'active_plant_id' => $validated['active_plant_id'],
                'sprayer_duration' => $sprayerDuration,
                'sprayer_times' => $sprayerTimes,
                'sprayer_end_times' => $sprayerEndTimes,
                'light_schedule' => $validated['light_schedule'],
                'lamp_pwm' => (int) $validated['lamp_pwm'],
                'updated_by' => $request->user()?->id,
            ]
        );

        $this->storeActivity($request, [
            'action' => 'inkubator.plant.apply',
            'module' => 'inkubator',
            'device_id' => $deviceId,
            'description' => "Terapkan tanaman aktif {$validated['active_plant_id']}",
            'metadata' => [
                'active_plant_id' => $validated['active_plant_id'],
                'sprayer_duration' => $sprayerDuration,
                'sprayer_times' => $sprayerTimes,
                'sprayer_end_times' => $sprayerEndTimes,
                'light_schedule' => $validated['light_schedule'],
                'lamp_pwm' => (int) $validated['lamp_pwm'],
            ],
        ]);

        return response()->json(['message' => 'Pengaturan tanaman aktif tersimpan.']);
    }

    public function storeWebActivity(Request $request)
    {
        $validated = $request->validate([
            'action' => ['required', 'string', 'max:100'],
            'module' => ['nullable', 'string', 'max:60'],
            'device_id' => ['nullable', 'string', 'max:120'],
            'description' => ['nullable', 'string'],
            'metadata' => ['nullable', 'array'],
            'performed_at' => ['nullable', 'date'],
        ]);

        $log = $this->storeActivity($request, [
            'action' => $validated['action'],
            'module' => $validated['module'] ?? 'inkubator',
            'device_id' => $validated['device_id'] ?? $this->defaultDeviceId(),
            'description' => $validated['description'] ?? null,
            'metadata' => $validated['metadata'] ?? null,
            'performed_at' => $validated['performed_at'] ?? now(),
        ]);

        return response()->json([
            'message' => 'Aktivitas tersimpan.',
            'id' => $log?->id,
        ], 201);
    }

    public function activityLogsPage(Request $request)
    {
        $deviceId = (string) $request->query('device_id', $this->defaultDeviceId());

        $logs = \App\Models\ActivityLog::query()
            ->where('device_id', $deviceId)
            ->whereIn('action', [
                'web.auto_relay_activity',
                'auto_relay_activity',
                'web.relay_control',
                'relay_control',
                'web.auto_sprayer_triggered',
                'auto_sprayer_triggered',
                'web.auto_lamp_schedule',
                'auto_lamp_schedule',
                'web.auto_repair_active_plant_sync',
                'auto_repair_active_plant_sync',
                'inkubator.command.relay_fan',
                'inkubator.command.relay_lamp',
                'inkubator.command.relay_sprayer'
            ])
            ->orderByDesc('performed_at')
            ->orderByDesc('created_at')
            ->paginate(25);

        return view('incubator.activity_logs', [
            'logs' => $logs,
            'deviceId' => $deviceId,
        ]);
    }

    public function sensorHistory(Request $request)
    {
        $deviceId = (string) $request->query('device_id', $this->defaultDeviceId());
        $measurement = trim((string) $request->query('measurement', 'incubator_sensor'));
        $range = (string) $request->query('range', '-1h');
        $window = (string) $request->query('window', '30s');
        $driver = strtolower(trim((string) $request->query('driver', 'auto')));

        try {
            $customDateRange = $driver === 'mongodb' ? $this->resolveMongoCustomDateRange($request) : null;
            $allowedMeasurements = [
                'incubator_sensor',
                'monitoring_sensor',
                'monitoring_bc1_screenhouse',
                'monitoring_atc_irigasi_rkk',
                'monitoring_atc_irigasi_rkb',
                'monitoring_atc_enviro',
                'monitoring_atc_hidroponik',
                'monitoring_atc_smart_hidroponik',
                'indoor_farming_sensor',
            ];
            $allowedFields = [
                'temperature',
                'humidity',
                'soil_moisture',
                'weight_g',
                'target_weight_g',
                'nh3',
                'ch4',
                'do',
                'ph',
                'pH',
                'tds',
                'ec_us',
                'ec_ms',
                'ppm',
            ];

            // Whitelist allowed range/window values to prevent Flux injection
            $allowedRanges = ['-5m', '-10m', '-15m', '-20m', '-30m', '-1h', '-3h', '-6h', '-12h', '-1d', '-2d', '-3d', '-7d', '-14d', '-30d', '-90d'];
            $allowedWindows = ['10s', '30s', '1m', '5m', '15m', '30m', '1h', '2h', '3h', '6h'];

            if (! in_array($range, $allowedRanges, true)) {
                $range = '-1h';
            }
            if (! in_array($window, $allowedWindows, true)) {
                $window = '30s';
            }
            if (! in_array($measurement, $allowedMeasurements, true)) {
                $measurement = 'incubator_sensor';
            }

            $queriesRaw = $request->query('queries');
            if (is_string($queriesRaw) && trim($queriesRaw) !== '') {
                $decodedQueries = json_decode($queriesRaw, true);
                $queries = is_array($decodedQueries) ? $decodedQueries : [];

                $normalizedQueries = [];
                foreach ($queries as $query) {
                    if (! is_array($query)) {
                        continue;
                    }

                    $queryDeviceId = trim((string) ($query['device_id'] ?? ''));
                    $queryMeasurement = trim((string) ($query['measurement'] ?? ''));
                    $fields = array_values(array_filter(array_map(
                        static fn ($field) => is_string($field) ? trim($field) : '',
                        is_array($query['fields'] ?? null) ? $query['fields'] : []
                    )));

                    if ($queryDeviceId === '' || ! in_array($queryMeasurement, $allowedMeasurements, true)) {
                        continue;
                    }

                    $fields = array_values(array_filter(
                        $fields,
                        static fn ($field) => in_array($field, $allowedFields, true)
                    ));

                    if ($fields === []) {
                        continue;
                    }

                    $normalizedQueries[] = [
                        'device_id' => $queryDeviceId,
                        'measurement' => $queryMeasurement,
                        'fields' => $fields,
                        'label' => is_string($query['label'] ?? null) ? trim((string) $query['label']) : null,
                    ];
                }

                if ($normalizedQueries === []) {
                    return response()->json([
                        'message' => 'Parameter queries tidak valid.',
                    ], 422);
                }

                $historyService = app(SensorHistoryService::class);
                $cards = [];

                foreach ($normalizedQueries as $query) {
                    if ($driver === 'mongodb') {
                        $mongo = app(\App\Services\MongoDbService::class);
                        $seriesList = $mongo->getFieldHistory(
                            $query['device_id'],
                            $query['measurement'],
                            $query['fields'],
                            $range,
                            $window,
                        );
                    } else {
                        $seriesList = $historyService->getFieldHistory(
                            $query['device_id'],
                            $query['measurement'],
                            $query['fields'],
                            $range,
                            $window,
                        );
                    }

                    foreach ($seriesList as $series) {
                        $cards[] = [
                            'label' => $query['label'] ?: $query['device_id'],
                            'device_id' => $query['device_id'],
                            'measurement' => $query['measurement'],
                            'field' => $series['field'],
                            'points' => $series['points'],
                        ];
                    }
                }

                return response()->json([
                    'data' => $cards,
                    'range' => $range,
                    'window' => $window,
                    'driver' => $driver === 'mongodb' ? 'mongodb' : 'auto',
                ]);
            }

            $requestedFields = $this->normalizeHistoryFields($request->query('fields'), $allowedFields);

            $historyService = app(SensorHistoryService::class);
            if ($requestedFields !== []) {
                if ($driver === 'mongodb') {
                    $mongo = app(\App\Services\MongoDbService::class);
                    $seriesList = $customDateRange !== null
                        ? $mongo->getFieldHistoryBetween($deviceId, $measurement, $requestedFields, $customDateRange['start'], $customDateRange['end'], $window)
                        : $mongo->getFieldHistory($deviceId, $measurement, $requestedFields, $range, $window);
                } else {
                    $seriesList = $historyService->getFieldHistory($deviceId, $measurement, $requestedFields, $range, $window);
                }

                $rows = $this->pivotFieldHistorySeries($seriesList);
                if ($driver === 'mongodb' && $customDateRange !== null) {
                    $rows = $this->filterHistoryRowsByDateRange($rows, $customDateRange['start'], $customDateRange['end']);
                }

                return response()->json([
                    'data' => $rows,
                    'device_id' => $deviceId,
                    'measurement' => $measurement,
                    'fields' => $requestedFields,
                    'driver' => $driver === 'mongodb' ? 'mongodb' : 'auto',
                ]);
            }

            if ($driver === 'mongodb') {
                $mongo = app(\App\Services\MongoDbService::class);
                $history = $customDateRange !== null
                    ? $mongo->getSensorHistoryBetween($deviceId, $measurement, $customDateRange['start'], $customDateRange['end'], $window)
                    : $mongo->getSensorHistory($deviceId, $measurement, $range, $window);
            } else {
                $history = $historyService->getSensorHistory($deviceId, $measurement, $range, $window);
            }
            $history = array_map(fn (array $row) => [
                'timestamp' => $row['timestamp'] ?? null,
                'time' => $this->epochToIso8601($row['timestamp'] ?? null),
                'temperature' => $row['temperature'] ?? null,
                'humidity' => $row['humidity'] ?? null,
                'soil_moisture' => $row['soil_moisture'] ?? null,
            ], $history);
            if ($driver === 'mongodb' && $customDateRange !== null) {
                $history = $this->filterHistoryRowsByDateRange($history, $customDateRange['start'], $customDateRange['end']);
            }

            return response()->json([
                'data' => $history,
                'device_id' => $deviceId,
                'measurement' => $measurement,
                'driver' => $driver === 'mongodb' ? 'mongodb' : 'auto',
            ]);
        } catch (\Throwable $e) {
            Log::error('sensorHistory failed', [
                'message' => $e->getMessage(),
                'file' => $e->getFile(),
                'line' => $e->getLine(),
                'device_id' => $deviceId,
                'measurement' => $measurement,
                'range' => $range,
                'window' => $window,
                'driver' => $driver,
                'fields' => $requestedFields ?? [],
                'datetime_from' => $request->query('datetime_from'),
                'datetime_to' => $request->query('datetime_to'),
            ]);

            return response()->json([
                'data' => [],
                'device_id' => $deviceId,
                'measurement' => $measurement,
                'driver' => $driver === 'mongodb' ? 'mongodb' : 'auto',
                'error' => app()->hasDebugModeEnabled() || config('app.debug')
                    ? $e->getMessage()
                    : 'Sensor history sementara gagal dimuat.',
            ], 500);
        }
    }

    public function systemSensorHistory(Request $request)
    {
        $allowedMeasurements = [
            'incubator_sensor',
            'monitoring_sensor',
            'monitoring_bc1_screenhouse',
            'monitoring_atc_irigasi_rkk',
            'monitoring_atc_irigasi_rkb',
            'monitoring_atc_enviro',
            'monitoring_atc_hidroponik',
            'monitoring_atc_smart_hidroponik',
            'indoor_farming_sensor',
        ];
        $allowedFields = [
            'temperature',
            'humidity',
            'soil_moisture',
            'weight_g',
            'target_weight_g',
            'nh3',
            'ch4',
            'do',
            'ph',
            'pH',
            'tds',
            'ec_us',
            'ec_ms',
            'ppm',
        ];
        $allowedRanges = ['-5m', '-10m', '-15m', '-20m', '-30m', '-1h', '-3h', '-6h', '-12h', '-1d', '-2d', '-3d', '-7d', '-14d', '-30d', '-90d'];
        $allowedWindows = ['10s', '30s', '1m', '5m', '15m', '30m', '1h', '2h', '3h', '6h'];

        $range = (string) $request->query('range', '-1h');
        $window = (string) $request->query('window', '30s');
        if (! in_array($range, $allowedRanges, true)) {
            $range = '-1h';
        }
        if (! in_array($window, $allowedWindows, true)) {
            $window = '30s';
        }

        $queriesRaw = $request->query('queries');
        if (is_string($queriesRaw) && trim($queriesRaw) !== '') {
            $decodedQueries = json_decode($queriesRaw, true);
            $queries = is_array($decodedQueries) ? $decodedQueries : [];

            $normalizedQueries = [];
            foreach ($queries as $query) {
                if (! is_array($query)) {
                    continue;
                }

                $deviceId = trim((string) ($query['device_id'] ?? ''));
                $measurement = trim((string) ($query['measurement'] ?? ''));
                $fields = array_values(array_filter(array_map(
                    static fn ($field) => is_string($field) ? trim($field) : '',
                    is_array($query['fields'] ?? null) ? $query['fields'] : []
                )));

                if ($deviceId === '' || ! in_array($measurement, $allowedMeasurements, true)) {
                    continue;
                }

                $fields = array_values(array_filter(
                    $fields,
                    static fn ($field) => in_array($field, $allowedFields, true)
                ));

                if (empty($fields)) {
                    continue;
                }

                $normalizedQueries[] = [
                    'device_id' => $deviceId,
                    'measurement' => $measurement,
                    'fields' => $fields,
                    'label' => is_string($query['label'] ?? null) ? trim((string) $query['label']) : null,
                ];
            }

            if (empty($normalizedQueries)) {
                return response()->json([
                    'message' => 'Parameter queries tidak valid.',
                ], 422);
            }

            $historyService = app(SensorHistoryService::class);
            $cards = [];

            foreach ($normalizedQueries as $query) {
                $seriesList = $historyService->getFieldHistory(
                    $query['device_id'],
                    $query['measurement'],
                    $query['fields'],
                    $range,
                    $window,
                );

                foreach ($seriesList as $series) {
                    $cards[] = [
                        'label' => $query['label'] ?: $query['device_id'],
                        'device_id' => $query['device_id'],
                        'measurement' => $query['measurement'],
                        'field' => $series['field'],
                        'points' => $series['points'],
                    ];
                }
            }

            return response()->json([
                'data' => $cards,
                'range' => $range,
                'window' => $window,
            ]);
        }

        $deviceId = trim((string) $request->query('device_id', ''));
        if ($deviceId === '') {
            return response()->json([
                'message' => 'Parameter device_id wajib diisi.',
            ], 422);
        }

        $measurement = trim((string) $request->query('measurement', 'incubator_sensor'));
        if (! in_array($measurement, $allowedMeasurements, true)) {
            $measurement = 'incubator_sensor';
        }

        $historyService = app(SensorHistoryService::class);
        $history = $historyService->getSensorHistory($deviceId, $measurement, $range, $window);

        return response()->json([
            'data' => $history,
            'device_id' => $deviceId,
            'measurement' => $measurement,
        ]);
    }

    public function systemSensorHistoryDebug(Request $request)
    {
        $deviceId = trim((string) $request->query('device_id', $this->defaultDeviceId()));
        $measurement = trim((string) $request->query('measurement', 'incubator_sensor'));
        $field = trim((string) $request->query('field', 'temperature'));
        $range = (string) $request->query('range', '-1d');
        $window = (string) $request->query('window', '30m');

        $influx = new InfluxDbService();
        $historyService = app(SensorHistoryService::class);
        $latest = $influx->getLatestSensor($deviceId, $measurement);
        $history = $historyService->getSensorHistory($deviceId, $measurement, $range, $window);
        $series = $historyService->getFieldHistory($deviceId, $measurement, [$field], $range, $window);

        return response()->json([
            'config' => [
                'url' => (string) config('services.influxdb.url'),
                'org' => (string) config('services.influxdb.org'),
                'bucket' => (string) config('services.influxdb.bucket'),
            ],
            'query' => [
                'device_id' => $deviceId,
                'measurement' => $measurement,
                'field' => $field,
                'range' => $range,
                'window' => $window,
            ],
            'latest' => $latest,
            'history_count' => count($history),
            'history_preview' => array_slice($history, 0, 5),
            'series_count' => count($series),
            'series_preview' => array_slice($series, 0, 2),
        ]);
    }

    public function sendCommand(Request $request)
    {
        $validated = $request->validate([
            'device_id' => ['nullable', 'string', 'max:100'],
            'type' => ['required', 'string', 'max:60'],
            'value' => ['nullable'],
            'payload' => ['nullable', 'array'],
        ]);

        $deviceId = (string) ($validated['device_id'] ?? $this->defaultDeviceId());
        $payload = is_array($validated['payload'] ?? null) ? $validated['payload'] : [];
        if (! isset($payload['type']) || ! is_string($payload['type']) || trim($payload['type']) === '') {
            $payload['type'] = $validated['type'];
        }
        if (! array_key_exists('value', $payload) && array_key_exists('value', $validated)) {
            $payload['value'] = $validated['value'];
        }
        $payload['source'] = 'web';
        $payload['ts'] = time();

        $mqtt = new MqttService();
        $published = $mqtt->publishCommand('incubator', $deviceId, $payload);
        $mqtt->disconnect();

        if (! $published) {
            return response()->json([
                'message' => 'Gagal publish command ke MQTT.',
            ], 502);
        }

        $this->storeActivity($request, [
            'action' => 'inkubator.command.' . $validated['type'],
            'module' => 'inkubator',
            'device_id' => $deviceId,
            'description' => "Kirim command {$validated['type']}",
            'metadata' => $payload,
        ]);

        return response()->json(['message' => 'Command terkirim.']);
    }

    private function storeActivity(Request $request, array $payload): ?ActivityLog
    {
        if (! Schema::hasTable('activity_logs')) {
            return null;
        }

        $user = $request->user();
        $module = (string) ($payload['module'] ?? 'inkubator');
        $action = (string) ($payload['action'] ?? 'activity');
        $deviceId = $payload['device_id'] ?? null;
        $description = $payload['description'] ?? null;
        $metadata = $payload['metadata'] ?? null;
        $performedAt = $payload['performed_at'] ?? now();
        $roleName = null;
        if ($user !== null) {
            $roleAttr = $user->role ?? null;
            if (is_string($roleAttr)) {
                $roleName = $roleAttr;
            } elseif (is_object($roleAttr) && isset($roleAttr->name) && is_string($roleAttr->name)) {
                $roleName = $roleAttr->name;
            }
        }

        try {
            return ActivityLog::createSafe([
                'user_id' => $user?->id,
                'event' => 'activity',
                'action' => $action,
                'module' => $module,
                'device_id' => $deviceId,
                'description' => $description,
                'metadata' => $metadata,
                'performed_at' => $performedAt,
                'guard' => $request->is('api/*') ? 'api' : 'web',
                'role_name' => $roleName,
                'route_name' => $request->route()?->getName(),
                'url' => $request->fullUrl(),
                'http_method' => $request->method(),
                'status_code' => 200,
                'login_identifier' => $user?->email,
                'ip_address' => $request->ip(),
                'user_agent' => (string) $request->userAgent(),
                'occurred_at' => now(),
            ]);
        } catch (\Throwable) {
            return null;
        }
    }

    private function computeEndTimes(array $times, int $durationSeconds): array
    {
        $duration = max(1, $durationSeconds);
        $endTimes = [];

        foreach ($times as $time) {
            $timeString = trim((string) $time);
            if ($timeString === '') {
                continue;
            }

            try {
                $start = Carbon::createFromFormat('H:i', $timeString);
                $endTimes[] = $start->copy()->addSeconds($duration)->format('H:i:s');
            } catch (\Throwable) {
                // Skip invalid time values silently.
            }
        }

        return $endTimes;
    }

    private function toNullableInt(mixed $value): ?int
    {
        if ($value === null || $value === '') {
            return null;
        }
        if (! is_numeric($value)) {
            return null;
        }

        return (int) floor((float) $value);
    }

    private function toNullableFloat(mixed $value): ?float
    {
        if ($value === null || $value === '') {
            return null;
        }
        if (! is_numeric($value)) {
            return null;
        }
        $numeric = (float) $value;
        if (! is_finite($numeric)) {
            return null;
        }

        return $numeric;
    }

    private function normalizeHistoryFields(mixed $rawFields, array $allowedFields): array
    {
        $fields = [];
        if (is_string($rawFields)) {
            $fields = array_map('trim', explode(',', $rawFields));
        } elseif (is_array($rawFields)) {
            $fields = array_map(
                static fn ($field) => is_string($field) ? trim($field) : '',
                $rawFields
            );
        }

        return array_values(array_unique(array_filter(
            $fields,
            static fn ($field) => $field !== '' && in_array($field, $allowedFields, true)
        )));
    }

    /**
     * @return array{start: Carbon, end: Carbon}|null
     */
    private function resolveMongoCustomDateRange(Request $request): ?array
    {
        if (! $request->filled('datetime_from') || ! $request->filled('datetime_to')) {
            return null;
        }

        try {
            $start = Carbon::parse((string) $request->query('datetime_from'));
            $end = Carbon::parse((string) $request->query('datetime_to'));
        } catch (\Throwable) {
            return null;
        }

        if ($end->lt($start)) {
            [$start, $end] = [$end, $start];
        }

        return [
            'start' => $start,
            'end' => $end,
        ];
    }

    /**
     * @param array<int, array<string, mixed>> $rows
     * @return array<int, array<string, mixed>>
     */
    private function filterHistoryRowsByDateRange(array $rows, Carbon $start, Carbon $end): array
    {
        $startTs = $start->getTimestamp();
        $endTs = $end->getTimestamp();

        return array_values(array_filter($rows, function (array $row) use ($startTs, $endTs): bool {
            $timestamp = $this->toNullableInt($row['timestamp'] ?? null);
            return $timestamp !== null && $timestamp >= $startTs && $timestamp <= $endTs;
        }));
    }

    private function pivotFieldHistorySeries(array $seriesList): array
    {
        $rows = [];

        foreach ($seriesList as $series) {
            if (! is_array($series)) {
                continue;
            }

            $field = is_string($series['field'] ?? null) ? $series['field'] : '';
            $points = is_array($series['points'] ?? null) ? $series['points'] : [];
            if ($field === '' || $points === []) {
                continue;
            }

            foreach ($points as $point) {
                if (! is_array($point)) {
                    continue;
                }

                $timestamp = $this->toNullableInt($point['timestamp'] ?? null);
                if ($timestamp === null) {
                    continue;
                }

                $key = (string) $timestamp;
                if (! isset($rows[$key])) {
                    $rows[$key] = [
                        'timestamp' => $timestamp,
                        'time' => $this->epochToIso8601($timestamp),
                    ];
                }

                $rows[$key][$field] = $this->toNullableFloat($point['value'] ?? null);
            }
        }

        ksort($rows, SORT_NUMERIC);

        return array_values($rows);
    }

    private function epochToIso8601(mixed $timestamp): ?string
    {
        $seconds = $this->toNullableInt($timestamp);
        if ($seconds === null) {
            return null;
        }

        return Carbon::createFromTimestampUTC($seconds)->toIso8601String();
    }

    private function defaultDeviceId(): string
    {
        return (string) config('services.incubator.default_device_id', 'inkubator_1');
    }

    private function fetchDeviceState(string $deviceId): array
    {
        // Get latest sensor data from InfluxDB (written by EMQX rule)
        $influx = new InfluxDbService();
        $sensor = $influx->getLatestSensor($deviceId, 'incubator_sensor');

        // Device control state (mode, relay, lamp_pwm, etc.) is stored in the
        // InkubatorDeviceConfig model (synced via MQTT retained messages / ESP status).
        // Return a structure compatible with the old Firebase shape.
        return [
            'sensor' => array_filter([
                'temperature' => $sensor['temperature'],
                'humidity' => $sensor['humidity'],
                'soil_moisture' => $sensor['soil_moisture'],
            ], fn ($v) => $v !== null),
            'last_seen' => $sensor['timestamp'],
        ];
    }

    private function resolveDeviceId(string $requestedDeviceId = ''): string
    {
        $candidates = [];

        $requestedDeviceId = trim($requestedDeviceId);
        if ($requestedDeviceId !== '') {
            $candidates[] = $requestedDeviceId;
        }

        $defaultDeviceId = trim($this->defaultDeviceId());
        if ($defaultDeviceId !== '') {
            $candidates[] = $defaultDeviceId;
        }

        $recentPlantDeviceIds = PlantProfile::query()
            ->whereNotNull('device_id')
            ->where('device_id', '<>', '')
            ->orderByDesc('created_at')
            ->pluck('device_id')
            ->all();

        $recentConfigDeviceIds = InkubatorDeviceConfig::query()
            ->whereNotNull('device_id')
            ->where('device_id', '<>', '')
            ->orderByDesc('updated_at')
            ->pluck('device_id')
            ->all();

        $candidates = array_values(array_unique(array_filter([
            ...$candidates,
            ...$recentPlantDeviceIds,
            ...$recentConfigDeviceIds,
            'inkubator_1',
        ], fn ($value) => is_string($value) && trim($value) !== '')));

        foreach ($candidates as $candidate) {
            if ($this->deviceHasState($candidate)) {
                return $candidate;
            }
        }

        return $candidates[0] ?? 'inkubator_1';
    }

    private function deviceHasState(string $deviceId): bool
    {
        if ($deviceId === '') {
            return false;
        }

        $hasPlants = PlantProfile::query()
            ->where('device_id', $deviceId)
            ->exists();

        if ($hasPlants) {
            return true;
        }

        $hasConfig = InkubatorDeviceConfig::query()
            ->where('device_id', $deviceId)
            ->exists();

        if ($hasConfig) {
            return true;
        }

        $sensor = $this->fetchDeviceState($deviceId);

        return ! empty($sensor['sensor']) || ! empty($sensor['last_seen']);
    }
}
