<?php

namespace App\Http\Controllers;

use App\Models\ActivityLog;
use App\Models\FeatureAccessPin;
use App\Models\FeatureAccessGrant;
use App\Models\IndoorFarmingDeviceConfig;
use App\Services\FirebaseMessagingService;
use Illuminate\Support\Carbon;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Hash;
use Illuminate\Support\Facades\Schema;
use Illuminate\Validation\ValidationException;

class IndoorFarmingController extends Controller
{
    private const DEFAULT_DEVICE_ID = 'indoor_farming_sensor';
    private const CONTROL_UNLOCK_SESSION_KEY = 'indoor_farming.control_unlock_until';
    private const CONTROL_UNLOCK_CACHE_PREFIX = 'indoor_farming:control_unlock:';
    private const CONTROL_UNLOCK_DURATION_MINUTES = 30;

    public function index(Request $request)
    {
        $config = $this->resolveConfig(
            (string) $request->query('device_id', self::DEFAULT_DEVICE_ID)
        );

        return view('indoor_farming', [
            'initialAutoConfig' => $this->serializeConfig($config),
            'indoorFarmingDeviceId' => $config->device_id,
            'controlAccess' => $this->serializeControlAccess($request),
        ]);
    }

    public function research(Request $request)
    {
        $config = $this->resolveConfig(
            (string) $request->query('device_id', self::DEFAULT_DEVICE_ID)
        );

        return view('indoor_farming_research', [
            'initialAutoConfig' => $this->serializeConfig($config),
            'indoorFarmingDeviceId' => $config->device_id,
            'controlAccess' => $this->serializeControlAccess($request),
        ]);
    }

    public function activityLogsPage(Request $request)
    {
        $deviceId = trim((string) $request->query('device_id', self::DEFAULT_DEVICE_ID));
        if ($deviceId === '') {
            $deviceId = self::DEFAULT_DEVICE_ID;
        }

        $actions = [
            'indoor_farming.auto_mode.enable',
            'indoor_farming.auto_mode.disable',
            'indoor_farming.auto.sensor_air.start',
            'indoor_farming.auto.sensor_air.stop',
            'indoor_farming.auto.sensor_air_warmup.start',
            'indoor_farming.auto.sensor_air_warmup.stop',
            'indoor_farming.auto.irrigation.start',
            'indoor_farming.auto.irrigation.stop',
            'indoor_farming.auto.irrigation_continuous.start',
            'indoor_farming.auto.irrigation_continuous.stop',
            'indoor_farming.auto.dosing_nutrition.start',
            'indoor_farming.auto.dosing_nutrition.stop',
            'indoor_farming.auto.dosing_ph_up.start',
            'indoor_farming.auto.dosing_ph_up.stop',
            'indoor_farming.auto.dosing_ph_down.start',
            'indoor_farming.auto.dosing_ph_down.stop',
            'indoor_farming.auto.ro_fill.start',
            'indoor_farming.auto.ro_fill.stop',
        ];

        $logs = ActivityLog::query()
            ->where('device_id', $deviceId)
            ->whereIn('action', $actions)
            ->orderByDesc('performed_at')
            ->orderByDesc('created_at')
            ->paginate(30);

        return view('indoor_farming_activity_logs', [
            'logs' => $logs,
            'deviceId' => $deviceId,
        ]);
    }

    public function showConfig(Request $request): JsonResponse
    {
        $config = $this->resolveConfig(
            (string) $request->query('device_id', self::DEFAULT_DEVICE_ID)
        );

        return response()->json([
            'config' => $this->serializeConfig($config),
        ]);
    }

    public function saveConfig(Request $request): JsonResponse
    {
        if (! $this->canManageControls($request)) {
            return response()->json([
                'message' => 'Akses kontrol indoor farming terkunci. Masukkan PIN terlebih dahulu.',
            ], 403);
        }

        $validated = $request->validate([
            'device_id' => ['nullable', 'string', 'max:100'],
            'auto_enabled' => ['nullable', 'boolean'],
            'nft_interval_min' => ['nullable', 'integer', 'min:1', 'max:240'],
            'nft_duration_min' => ['nullable', 'integer', 'min:1', 'max:60'],
            'irrigation_duration_sec' => ['nullable', 'integer', 'min:5', 'max:1800'],
            'irrigation_mode' => ['nullable', 'in:schedule,nft'],
            'irrigation_times' => ['nullable', 'array'],
            'irrigation_times.*' => ['string', 'regex:/^([01][0-9]|2[0-3]):[0-5][0-9]$/'],
            'target_ppm' => ['nullable', 'numeric', 'min:100', 'max:3000'],
            'ppm_deadband' => ['nullable', 'numeric', 'min:1', 'max:500'],
            'target_ph' => ['nullable', 'numeric', 'min:3', 'max:9'],
            'ph_deadband' => ['nullable', 'numeric', 'min:0.01', 'max:1'],
            'nutrition_dose_pulse_sec' => ['nullable', 'integer', 'min:1', 'max:30'],
            'ph_dose_pulse_sec' => ['nullable', 'integer', 'min:1', 'max:30'],
            'nutrition_dosing_cooldown_sec' => ['nullable', 'integer', 'min:5', 'max:600'],
            'ph_dosing_cooldown_sec' => ['nullable', 'integer', 'min:5', 'max:600'],
            'nft_sensor_warmup_sec' => ['nullable', 'integer', 'in:30,60'],
            'ro_target_level' => ['nullable', 'integer', 'in:2,3'],
        ]);

        $deviceId = (string) ($validated['device_id'] ?? self::DEFAULT_DEVICE_ID);
        $config = $this->resolveConfig($deviceId);

        if (array_key_exists('irrigation_times', $validated)) {
            $validated['irrigation_times'] = $this->normalizeTimes($validated['irrigation_times'] ?? []);
        }

        $validated['updated_by'] = $request->user()?->id;

        $config->fill($validated);
        $config->save();

        $this->notifyIndoorConfigChanged($request, $config->fresh());

        return response()->json([
            'message' => 'Konfigurasi indoor farming tersimpan.',
            'config' => $this->serializeConfig($config->fresh()),
        ]);
    }

    public function storeWebActivity(Request $request): JsonResponse
    {
        $validated = $request->validate([
            'action' => ['required', 'string', 'max:120'],
            'module' => ['nullable', 'string', 'max:60'],
            'device_id' => ['nullable', 'string', 'max:120'],
            'description' => ['nullable', 'string'],
            'metadata' => ['nullable', 'array'],
            'performed_at' => ['nullable', 'date'],
        ]);

        $log = $this->storeActivity($request, [
            'action' => $validated['action'],
            'module' => $validated['module'] ?? 'indoor_farming',
            'device_id' => $validated['device_id'] ?? self::DEFAULT_DEVICE_ID,
            'description' => $validated['description'] ?? null,
            'metadata' => $validated['metadata'] ?? null,
            'performed_at' => $validated['performed_at'] ?? now(),
        ]);

        return response()->json([
            'message' => 'Aktivitas indoor farming tersimpan.',
            'id' => $log?->id,
        ], 201);
    }

    public function unlockControls(Request $request): JsonResponse
    {
        if (! $this->requiresControlPin($request)) {
            return response()->json([
                'message' => 'Akses kontrol tidak memerlukan PIN untuk akun ini.',
                'access' => $this->serializeControlAccess($request),
            ]);
        }

        $validated = $request->validate([
            'pin' => ['required', 'regex:/^\d{4,8}$/'],
            'target' => ['nullable', 'in:config,control,config_control'],
        ]);

        $pinSetting = $this->resolveControlPin();
        if (! $pinSetting || ! $pinSetting->is_enabled || ! is_string($pinSetting->pin_hash) || $pinSetting->pin_hash === '') {
            return response()->json([
                'message' => 'PIN kontrol indoor farming belum diatur.',
            ], 422);
        }

        $target = $this->resolveUnlockTarget($validated['target'] ?? null);

        if (! Hash::check((string) $validated['pin'], $pinSetting->pin_hash)) {
            $this->notifyIndoorPinAccessAttempt($request, $target, false, false);
            throw ValidationException::withMessages([
                'pin' => 'PIN indoor farming tidak valid.',
            ]);
        }

        $expiresAt = Carbon::now()->addMinutes($this->resolveControlUnlockDurationMinutes());
        $request->session()->put(self::CONTROL_UNLOCK_SESSION_KEY, $expiresAt->timestamp);
        $this->notifyIndoorPinAccessAttempt($request, $target, true, false);

        return response()->json([
            'message' => 'Akses kontrol indoor farming berhasil dibuka.',
            'access' => $this->serializeControlAccess($request),
        ]);
    }

    public function apiControlAccess(Request $request): JsonResponse
    {
        $config = $this->resolveConfig(
            (string) $request->query('device_id', self::DEFAULT_DEVICE_ID)
        );

        return response()->json([
            'access' => $this->serializeControlAccess($request, true),
            'config' => $this->serializeConfig($config),
        ]);
    }

    public function apiUnlockControls(Request $request): JsonResponse
    {
        $config = $this->resolveConfig(
            (string) $request->input('device_id', self::DEFAULT_DEVICE_ID)
        );

        if (! $this->requiresControlPin($request)) {
            return response()->json([
                'message' => 'Akses kontrol tidak memerlukan PIN untuk akun ini.',
                'access' => $this->serializeControlAccess($request, true),
                'config' => $this->serializeConfig($config),
            ]);
        }

        $validated = $request->validate([
            'pin' => ['required', 'regex:/^\d{4,8}$/'],
            'target' => ['nullable', 'in:config,control,config_control'],
        ]);

        $pinSetting = $this->resolveControlPin();
        if (! $pinSetting || ! $pinSetting->is_enabled || ! is_string($pinSetting->pin_hash) || $pinSetting->pin_hash === '') {
            return response()->json([
                'message' => 'PIN kontrol indoor farming belum diatur.',
            ], 422);
        }

        $target = $this->resolveUnlockTarget($validated['target'] ?? null);

        if (! Hash::check((string) $validated['pin'], $pinSetting->pin_hash)) {
            $this->notifyIndoorPinAccessAttempt($request, $target, false, true);
            throw ValidationException::withMessages([
                'pin' => 'PIN indoor farming tidak valid.',
            ]);
        }

        $expiresAt = Carbon::now()->addMinutes($this->resolveControlUnlockDurationMinutes());
        Cache::put(
            $this->mobileUnlockCacheKey($request),
            $expiresAt->timestamp,
            $expiresAt
        );
        $this->notifyIndoorPinAccessAttempt($request, $target, true, true);

        return response()->json([
            'message' => 'Akses kontrol indoor farming berhasil dibuka.',
            'access' => $this->serializeControlAccess($request, true),
            'config' => $this->serializeConfig($config),
        ]);
    }

    private function resolveConfig(string $deviceId): IndoorFarmingDeviceConfig
    {
        $resolvedDeviceId = trim($deviceId) !== '' ? trim($deviceId) : self::DEFAULT_DEVICE_ID;

        return IndoorFarmingDeviceConfig::query()->firstOrCreate(
            ['device_id' => $resolvedDeviceId],
            [
                'auto_enabled' => true,
                'nft_interval_min' => 30,
                'nft_duration_min' => 5,
                'irrigation_duration_sec' => 120,
                'irrigation_mode' => 'schedule',
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

    private function resolveControlPin(): ?FeatureAccessPin
    {
        return FeatureAccessPin::query()
            ->where('feature_key', FeatureAccessPin::FEATURE_INDOOR_FARMING_CONTROL)
            ->first();
    }

    private function resolveControlUnlockDurationMinutes(): int
    {
        $pinSetting = $this->resolveControlPin();
        $minutes = (int) ($pinSetting?->unlock_duration_minutes ?? self::CONTROL_UNLOCK_DURATION_MINUTES);

        return max(1, $minutes);
    }

    private function serializeControlAccess(Request $request, bool $api = false): array
    {
        $unlockUntil = $this->resolveUnlockUntil($request, $api);
        $role = $this->resolveRoleName($request);

        return [
            'role' => $role,
            'requiresPin' => $this->requiresControlPin($request),
            'canManageControls' => $this->canManageControls($request, $api),
            'bypassGranted' => $this->hasBypassGrant($request),
            'unlockExpiresAt' => $unlockUntil?->toIso8601String(),
            'unlockDurationMinutes' => $this->resolveControlUnlockDurationMinutes(),
        ];
    }

    private function canManageControls(Request $request, bool $api = false): bool
    {
        $role = $this->resolveRoleName($request);
        if (in_array($role, ['super_admin', 'admin'], true)) {
            return true;
        }

        if ($this->hasBypassGrant($request)) {
            return true;
        }

        if (! $this->requiresControlPin($request)) {
            return true;
        }

        return $this->resolveUnlockUntil($request, $api) !== null;
    }

    private function requiresControlPin(Request $request): bool
    {
        $role = $this->resolveRoleName($request);
        if ($role !== 'user') {
            return false;
        }

        $pinSetting = $this->resolveControlPin();
        return $pinSetting !== null
            && $pinSetting->is_enabled === true
            && is_string($pinSetting->pin_hash)
            && $pinSetting->pin_hash !== '';
    }

    private function resolveUnlockUntil(Request $request, bool $api = false): ?Carbon
    {
        $timestamp = $api
            ? (int) Cache::get($this->mobileUnlockCacheKey($request), 0)
            : (int) $request->session()->get(self::CONTROL_UNLOCK_SESSION_KEY, 0);
        if ($timestamp <= 0) {
            return null;
        }

        $expiresAt = Carbon::createFromTimestamp($timestamp);
        if ($expiresAt->isPast()) {
            if ($api) {
                Cache::forget($this->mobileUnlockCacheKey($request));
            } else {
                $request->session()->forget(self::CONTROL_UNLOCK_SESSION_KEY);
            }
            return null;
        }

        return $expiresAt;
    }

    private function mobileUnlockCacheKey(Request $request): string
    {
        $userId = (int) ($request->user()?->id ?? 0);
        return self::CONTROL_UNLOCK_CACHE_PREFIX.$userId;
    }

    private function hasBypassGrant(Request $request): bool
    {
        $user = $request->user();
        if (! $user || ! $user->id) {
            return false;
        }

        return FeatureAccessGrant::query()
            ->where('feature_key', FeatureAccessGrant::FEATURE_INDOOR_FARMING_CONTROL)
            ->where('user_id', $user->id)
            ->exists();
    }

    private function resolveRoleName(Request $request): string
    {
        $user = $request->user();
        $roleName = strtolower(trim((string) ($user?->role?->name ?? $user?->role ?? 'user')));
        return $roleName !== '' ? $roleName : 'user';
    }

    private function serializeConfig(IndoorFarmingDeviceConfig $config): array
    {
        return [
            'device_id' => $config->device_id,
            'enabled' => (bool) $config->auto_enabled,
            'auto_enabled' => (bool) $config->auto_enabled,
            'nft_interval_min' => (int) $config->nft_interval_min,
            'nft_duration_min' => (int) $config->nft_duration_min,
            'irrigation_duration_sec' => (int) $config->irrigation_duration_sec,
            'irrigation_mode' => in_array((string) $config->irrigation_mode, ['schedule', 'nft'], true)
                ? (string) $config->irrigation_mode
                : 'schedule',
            'irrigation_times' => $this->normalizeTimes($config->irrigation_times ?? []),
            'target_ppm' => (float) $config->target_ppm,
            'ppm_deadband' => (float) $config->ppm_deadband,
            'target_ph' => (float) $config->target_ph,
            'ph_deadband' => (float) $config->ph_deadband,
            'nutrition_dose_pulse_sec' => (int) $config->nutrition_dose_pulse_sec,
            'ph_dose_pulse_sec' => (int) $config->ph_dose_pulse_sec,
            'nutrition_dosing_cooldown_sec' => (int) $config->nutrition_dosing_cooldown_sec,
            'ph_dosing_cooldown_sec' => (int) $config->ph_dosing_cooldown_sec,
            'nft_sensor_warmup_sec' => (int) ($config->nft_sensor_warmup_sec ?: 60),
            'ro_target_level' => (int) ($config->ro_target_level ?: 2),
            'ro_target_label' => ((int) ($config->ro_target_level ?: 2)) >= 3 ? 'HIGH' : 'MID',
            'updated_by' => $config->updated_by,
            'updated_at' => optional($config->updated_at)?->toIso8601String(),
        ];
    }

    /**
     * @param  array<int, mixed>  $times
     * @return array<int, string>
     */
    private function normalizeTimes(array $times): array
    {
        $normalized = [];

        foreach ($times as $time) {
            $value = trim((string) $time);
            if (! preg_match('/^([01][0-9]|2[0-3]):[0-5][0-9]$/', $value)) {
                continue;
            }
            $normalized[] = $value;
        }

        $normalized = array_values(array_unique($normalized));
        sort($normalized);

        return $normalized;
    }

    private function resolveUnlockTarget(mixed $value): string
    {
        $target = strtolower(trim((string) $value));

        return in_array($target, ['config', 'control', 'config_control'], true)
            ? $target
            : 'config_control';
    }

    private function describeUnlockTarget(string $target): string
    {
        return match ($target) {
            'config' => 'konfigurasi',
            'control' => 'kontrol',
            default => 'konfigurasi dan kontrol',
        };
    }

    private function notifyIndoorPinAccessAttempt(Request $request, string $target, bool $success, bool $api): void
    {
        try {
            $actor = trim((string) ($request->user()?->name ?? $request->user()?->email ?? 'User'));
            $deviceId = trim((string) $request->input('device_id', self::DEFAULT_DEVICE_ID));
            if ($deviceId === '') {
                $deviceId = self::DEFAULT_DEVICE_ID;
            }

            $targetLabel = $this->describeUnlockTarget($target);
            $channel = $api ? 'mobile' : 'web';
            $title = $success
                ? 'PIN Indoor Farming Berhasil Digunakan'
                : 'Percobaan PIN Indoor Farming Gagal';
            $body = $success
                ? sprintf('%s membuka akses %s indoor farming via %s.', $actor, $targetLabel, $channel)
                : sprintf('%s mencoba membuka akses %s indoor farming via %s, tetapi PIN tidak valid.', $actor, $targetLabel, $channel);

            app(FirebaseMessagingService::class)->sendToTopics([
                'indoor_farming_alerts',
                'device_'.$deviceId.'_alerts',
            ], $title, $body, [
                'source' => 'indoor_farming_pin_access',
                'area' => 'indoor_farming',
                'device_id' => $deviceId,
                'actor' => $actor,
                'action' => $success ? 'pin_unlock_success' : 'pin_unlock_failed',
                'target' => $target,
                'channel' => $channel,
            ]);
        } catch (\Throwable) {
            // Notification must not block unlock flow.
        }
    }

    private function notifyIndoorConfigChanged(Request $request, IndoorFarmingDeviceConfig $config): void
    {
        try {
            $actor = trim((string) ($request->user()?->name ?? $request->user()?->email ?? 'User'));
            app(FirebaseMessagingService::class)->sendToTopics([
                'indoor_farming_alerts',
                'device_'.$config->device_id.'_alerts',
            ], 'Konfigurasi Indoor Farming Diubah', $actor.' mengubah konfigurasi indoor farming untuk '.$config->device_id.'.', [
                'source' => 'indoor_farming_config_save',
                'area' => 'indoor_farming',
                'device_id' => $config->device_id,
                'actor' => $actor,
                'action' => 'config_changed',
            ]);
        } catch (\Throwable) {
            // Notification must not block config save.
        }
    }

    private function storeActivity(Request $request, array $payload): ?ActivityLog
    {
        if (! Schema::hasTable('activity_logs')) {
            return null;
        }

        $user = $request->user();
        $module = (string) ($payload['module'] ?? 'indoor_farming');
        $action = (string) ($payload['action'] ?? 'activity');
        $deviceId = $payload['device_id'] ?? self::DEFAULT_DEVICE_ID;
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
}
