<?php

namespace App\Http\Controllers\Api;

use App\Http\Controllers\Controller;
use App\Models\ActivityLog;
use App\Services\FirebaseMessagingService;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\Schema;

class ActivityLogController extends Controller
{
    public function index(Request $request): JsonResponse
    {
        $limit = (int) min(max((int) $request->query('limit', 50), 1), 5000);
        $dateColumn = $this->resolveDateColumn();

        $query = ActivityLog::query()
            ->with(['user:id,name,email'])
            ->when($request->filled('module'), fn ($q) => $q->where('module', $request->query('module')))
            ->when($request->filled('device_id'), fn ($q) => $q->where('device_id', $request->query('device_id')))
            ->when($request->filled('action'), fn ($q) => $q->where('action', $request->query('action')))
            ->when($request->filled('q'), function ($q) use ($request): void {
                $keyword = trim((string) $request->query('q'));
                if ($keyword === '') {
                    return;
                }
                $q->where(function ($sub) use ($keyword): void {
                    $sub->where('module', 'like', '%'.$keyword.'%')
                        ->orWhere('action', 'like', '%'.$keyword.'%')
                        ->orWhere('description', 'like', '%'.$keyword.'%')
                        ->orWhere('login_identifier', 'like', '%'.$keyword.'%');
                });
            });

        if ($request->filled('date_from')) {
            $query->whereDate($dateColumn, '>=', (string) $request->query('date_from'));
        }
        if ($request->filled('date_to')) {
            $query->whereDate($dateColumn, '<=', (string) $request->query('date_to'));
        }
        if ($request->filled('datetime_from')) {
            $query->where($dateColumn, '>=', (string) $request->query('datetime_from'));
        }
        if ($request->filled('datetime_to')) {
            $query->where($dateColumn, '<=', (string) $request->query('datetime_to'));
        }
        if (Schema::hasColumn('activity_logs', 'occurred_at') && $request->filled('datetime_from')) {
            $query->where('occurred_at', '>=', (string) $request->query('datetime_from'));
        }
        if (Schema::hasColumn('activity_logs', 'occurred_at') && $request->filled('datetime_to')) {
            $query->where('occurred_at', '<=', (string) $request->query('datetime_to'));
        }
        if (
            ! $request->filled('date_from') &&
            ! $request->filled('date_to') &&
            ! $request->filled('datetime_from') &&
            ! $request->filled('datetime_to')
        ) {
            $todayStart = Carbon::now(config('app.timezone'))->startOfDay()->format('Y-m-d H:i:s');
            $todayEnd = Carbon::now(config('app.timezone'))->endOfDay()->format('Y-m-d H:i:s');
            $query->whereBetween($dateColumn, [$todayStart, $todayEnd]);
            if (Schema::hasColumn('activity_logs', 'occurred_at')) {
                $query->whereBetween('occurred_at', [$todayStart, $todayEnd]);
            }
        }

        if (Schema::hasColumn('activity_logs', 'performed_at')) {
            $query->orderByDesc('performed_at');
        } elseif (Schema::hasColumn('activity_logs', 'created_at')) {
            $query->orderByDesc('created_at');
        }

        $logs = $query
            ->limit($limit)
            ->get()
            ->map(function (ActivityLog $log): array {
                $performedAt = $log->performed_at ?? $log->created_at;
                $performedAtLocal = $performedAt?->copy()->timezone(config('app.timezone'));

                return [
                    'id' => $log->id,
                    'module' => $log->module ?? 'system',
                    'action' => $log->friendly_action ?? 'event',
                    'description' => $log->friendly_description ?? '-',
                    'device_id' => $log->friendly_device_id ?? '',
                    'performed_at' => $performedAtLocal?->toIso8601String(),
                    'performed_at_local' => $performedAtLocal?->format('Y-m-d H:i:s'),
                    'performed_at_ts' => $performedAtLocal?->getTimestampMs(),
                    'metadata' => $log->metadata ?? [],
                    'user_name' => $log->user?->name ?? $log->login_identifier ?? 'system',
                    'login_identifier' => $log->login_identifier ?? '',
                ];
            });

        return response()->json([
            'data' => $logs,
        ]);
    }

    public function store(Request $request): JsonResponse
    {
        $validated = $request->validate([
            'action' => ['required', 'string', 'max:100'],
            'module' => ['nullable', 'string', 'max:60'],
            'device_id' => ['nullable', 'string', 'max:120'],
            'description' => ['nullable', 'string'],
            'metadata' => ['nullable', 'array'],
            'performed_at' => ['nullable', 'date'],
        ]);

        $user = $request->user();
        if ($user === null) {
            return response()->json([
                'message' => 'Unauthorized.',
            ], 401);
        }
        $roleName = null;
        $roleAttr = $user->role ?? null;
        if (is_string($roleAttr)) {
            $roleName = $roleAttr;
        } elseif (is_object($roleAttr) && isset($roleAttr->name) && is_string($roleAttr->name)) {
            $roleName = $roleAttr->name;
        }

        if (! $this->shouldPersistUserActivity(
            strtolower((string) ($roleName ?? 'user')),
            (string) $validated['action'],
            (string) ($validated['module'] ?? 'app')
        )) {
            return response()->json([
                'message' => 'Activity log diabaikan oleh filter.',
            ], 202);
        }

        $log = ActivityLog::createSafe([
            'user_id' => $user?->id,
            'event' => 'activity',
            'action' => $validated['action'],
            'module' => $validated['module'] ?? 'app',
            'device_id' => $validated['device_id'] ?? null,
            'description' => $validated['description'] ?? null,
            'metadata' => $validated['metadata'] ?? null,
            'performed_at' => $validated['performed_at'] ?? now(),
            'guard' => 'api',
            'role_name' => $roleName,
            'route_name' => $request->route()?->getName(),
            'url' => $request->fullUrl(),
            'http_method' => $request->method(),
            'status_code' => 201,
            'login_identifier' => $user?->email,
            'ip_address' => $request->ip(),
            'user_agent' => (string) $request->userAgent(),
            'occurred_at' => now(),
        ]);

        $this->notifyIndoorFarmingControlChange($request, $validated);

        return response()->json([
            'message' => 'Activity log tersimpan.',
            'data' => $log,
        ], 201);
    }

    public function storeSystem(Request $request): JsonResponse
    {
        $validated = $request->validate([
            'action' => ['required', 'string', 'max:100'],
            'module' => ['nullable', 'string', 'max:60'],
            'device_id' => ['nullable', 'string', 'max:120'],
            'description' => ['nullable', 'string'],
            'metadata' => ['nullable', 'array'],
            'performed_at' => ['nullable', 'date'],
        ]);

        $deviceId = trim((string) ($validated['device_id'] ?? $request->header('X-Device-Id', '')));
        if ($deviceId === '') {
            $deviceId = 'unknown_device';
        }

        $metadata = is_array($validated['metadata'] ?? null) ? $validated['metadata'] : [];
        $metadata['source'] = 'system_key';

        $log = ActivityLog::createSafe([
            'user_id' => null,
            'event' => 'activity',
            'action' => $validated['action'],
            'module' => $validated['module'] ?? 'system',
            'device_id' => $deviceId,
            'description' => $validated['description'] ?? null,
            'metadata' => $metadata,
            'performed_at' => $validated['performed_at'] ?? now(),
            'guard' => 'system',
            'role_name' => 'system',
            'route_name' => $request->route()?->getName(),
            'url' => $request->fullUrl(),
            'http_method' => $request->method(),
            'status_code' => 201,
            'login_identifier' => 'system:'.$deviceId,
            'ip_address' => $request->ip(),
            'user_agent' => (string) $request->userAgent(),
            'occurred_at' => now(),
        ]);

        return response()->json([
            'message' => 'System activity log tersimpan.',
            'data' => $log,
        ], 201);
    }

    private function resolveDateColumn(): string
    {
        if (Schema::hasColumn('activity_logs', 'performed_at')) {
            return 'performed_at';
        }

        return 'created_at';
    }

    private function shouldPersistUserActivity(string $roleName, string $action, string $module): bool
    {
        $action = strtolower(trim($action));
        $module = strtolower(trim($module));

        if ($action === '' || str_starts_with($action, 'screen.open') || in_array($action, [
            'page_visit',
            'navigation',
            'monitoring.node.inspect',
        ], true)) {
            return false;
        }

        if (in_array($roleName, ['super_admin', 'admin'], true)) {
            return in_array($action, [
                'auth.login',
                'auth.logout',
                'admin.user.status.change',
                'admin.user.suspend',
                'admin.user.unsuspend',
                'admin.user.role.change',
                'admin.user.create',
                'admin.user.delete',
            ], true);
        }

        return ! in_array($module, ['admin', 'super_admin', 'navigation'], true);
    }

    /**
     * @param array<string, mixed> $validated
     */
    private function notifyIndoorFarmingControlChange(Request $request, array $validated): void
    {
        $module = strtolower(trim((string) ($validated['module'] ?? '')));
        $action = strtolower(trim((string) ($validated['action'] ?? '')));
        if ($module !== 'indoor_farming') {
            return;
        }

        if (! in_array($action, ['auto_mode.enable', 'auto_mode.disable', 'relay.manual'], true)) {
            return;
        }

        $deviceId = trim((string) ($validated['device_id'] ?? 'indoor_farming_sensor'));
        $actor = trim((string) ($request->user()?->name ?? $request->user()?->email ?? 'User'));
        $description = trim((string) ($validated['description'] ?? 'Perubahan kontrol indoor farming.'));
        $title = match ($action) {
            'auto_mode.enable' => 'Mode Auto Indoor Farming Aktif',
            'auto_mode.disable' => 'Mode Auto Indoor Farming Nonaktif',
            'relay.manual' => 'Kontrol Manual Indoor Farming Diubah',
            default => 'Kontrol Indoor Farming Diubah',
        };

        try {
            app(FirebaseMessagingService::class)->sendToTopics([
                'indoor_farming_alerts',
                'device_'.$deviceId.'_alerts',
            ], $title, $actor.' melakukan perubahan kontrol: '.$description, [
                'source' => 'indoor_farming_activity_log',
                'area' => 'indoor_farming',
                'device_id' => $deviceId,
                'actor' => $actor,
                'action' => $action,
            ]);
        } catch (\Throwable) {
            // Notification must not block activity logging.
        }
    }
}
