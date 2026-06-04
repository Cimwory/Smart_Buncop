<?php

namespace App\Http\Controllers;

use App\Models\ActivityLog;
use App\Models\ApiAccessToken;
use App\Models\FeatureAccessGrant;
use App\Models\FeatureAccessPin;
use App\Models\Role;
use App\Models\User;
use Illuminate\Support\Carbon;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Hash;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Facades\Route;
use Illuminate\Support\Facades\Schema;
use Illuminate\View\View;
use App\Services\SensorHistoryService;

class RolePortalController extends Controller
{
    public function portal(Request $request): View
    {
        $user = $request->user();
        $this->abortIfRoleNotIn($user, ['super_admin', 'admin', 'user']);

        $modules = [
            [
                'route' => 'incubator',
                'class' => 'card-incubator',
                'icon' => 'fa-seedling',
                'title' => 'Inkubator Tanaman',
                'description' => 'Kontrol suhu, kelembaban, penyinaran, dan jadwal penyiraman tanaman.',
                'cta' => 'Masuk Modul',
            ],
            [
                'route' => 'nutrimix',
                'class' => 'card-nutrimix',
                'icon' => 'fa-flask-vial',
                'title' => 'Nutrimix Controller',
                'description' => 'Atur proses pencampuran nutrisi otomatis berdasarkan target berat.',
                'cta' => 'Masuk Modul',
            ],
            [
                'route' => 'tools.monitoring_area',
                'class' => 'card-tools',
                'icon' => 'fa-chart-line',
                'title' => 'Monitoring Kebun Percobaan',
                'description' => 'Kontrolling dan monitoring multi area kebun PT Petrokimia Gresik.',
                'cta' => 'Masuk Modul',
            ],
            [
                'route' => 'indoor_farming',
                'class' => 'card-indoor',
                'icon' => 'fa-leaf',
                'title' => 'Indoor Farming',
                'description' => 'Monitoring dan kontrol indoor farming (fitur bertahap).',
                'cta' => 'Masuk Modul',
            ],
        ];

        $modules = array_values(array_filter($modules, static fn (array $m) => Route::has((string) ($m['route'] ?? ''))));

        return view('vitaroot', [
            'modules' => $modules,
            'moduleCount' => count($modules),
        ]);
    }

    public function dashboard(Request $request): RedirectResponse
    {
        $user = $request->user();
        $this->abortIfRoleNotIn($user, ['super_admin', 'admin', 'user']);

        return redirect()->route($this->resolveDashboardRouteName($this->resolveRoleName($user)));
    }

    public function superAdminDashboard(Request $request): View
    {
        $user = $request->user();
        $this->abortIfRoleNotIn($user, ['super_admin']);
        $role = $this->resolveRoleName($user);

        return view('role.super_admin_dashboard', [
            'role' => $role,
            'user' => $user,
        ]);
    }

    public function adminDashboard(Request $request): View
    {
        $user = $request->user();
        $this->abortIfRoleNotIn($user, ['super_admin', 'admin']);
        $role = $this->resolveRoleName($user);

        return view('role.admin_dashboard', [
            'role' => $role,
            'user' => $user,
            'canBackToSuperAdmin' => $role === 'super_admin',
        ]);
    }

    public function userDashboard(Request $request): View
    {
        $user = $request->user();
        $this->abortIfRoleNotIn($user, ['super_admin', 'admin', 'user']);
        $role = $this->resolveRoleName($user);

        return view('role.user_dashboard', [
            'role' => $role,
            'user' => $user,
            'canBackToSuperAdmin' => $role === 'super_admin',
            'canBackToAdmin' => in_array($role, ['super_admin', 'admin'], true),
        ]);
    }

    public function toolsIndex(Request $request): View
    {
        $user = $request->user();
        $this->abortIfRoleNotIn($user, ['super_admin', 'admin', 'user']);
        $role = $this->resolveRoleName($user);

        $indoorPin = FeatureAccessPin::query()
            ->with('updatedBy:id,name,email')
            ->where('feature_key', FeatureAccessPin::FEATURE_INDOOR_FARMING_CONTROL)
            ->first();
        $indoorAccessGrantCandidates = User::query()
            ->with('role:id,name')
            ->where('is_active', true)
            ->whereHas('role', fn ($q) => $q->where('name', 'user'))
            ->orderBy('name')
            ->get(['id', 'name', 'email', 'role_id', 'is_active']);
        $indoorAccessGrants = FeatureAccessGrant::query()
            ->with(['user:id,name,email,is_active,role_id', 'user.role:id,name', 'grantedBy:id,name,email'])
            ->where('feature_key', FeatureAccessGrant::FEATURE_INDOOR_FARMING_CONTROL)
            ->orderByDesc('created_at')
            ->get();

        return view('tools.index', [
            'dashboardRoute' => $this->resolveDashboardRouteName($role),
            'canBackToSuperAdmin' => $role === 'super_admin',
            'canBackToAdmin' => in_array($role, ['super_admin', 'admin'], true),
            'roleName' => $role,
            'indoorFarmingPinSetting' => $indoorPin,
            'indoorAccessGrantCandidates' => $indoorAccessGrantCandidates,
            'indoorAccessGrants' => $indoorAccessGrants,
        ]);
    }

    public function saveIndoorFarmingPin(Request $request): RedirectResponse
    {
        $actor = $request->user();
        $this->abortIfRoleNotIn($actor, ['super_admin']);

        $validated = $request->validate([
            'pin' => ['nullable', 'regex:/^\d{4,8}$/', 'confirmed'],
            'unlock_duration_minutes' => ['required', 'integer', 'min:1', 'max:1440'],
            'disable_pin' => ['nullable', 'boolean'],
        ]);

        $pinSetting = FeatureAccessPin::query()->firstOrNew([
            'feature_key' => FeatureAccessPin::FEATURE_INDOOR_FARMING_CONTROL,
        ]);

        $disablePin = (bool) ($validated['disable_pin'] ?? false);
        if ($disablePin) {
            $pinSetting->fill([
                'pin_hash' => null,
                'is_enabled' => false,
                'unlock_duration_minutes' => (int) $validated['unlock_duration_minutes'],
                'updated_by' => $actor?->id,
            ])->save();

            ActivityLog::createSafe([
                'user_id' => $actor?->id,
                'module' => 'admin',
                'action' => 'indoor_farming.pin.disable',
                'description' => 'Menonaktifkan PIN akses kontrol indoor farming (web)',
                'guard' => 'web',
                'role_name' => $this->resolveRoleName($actor),
                'login_identifier' => $actor?->email,
                'ip_address' => $request->ip(),
                'user_agent' => $request->userAgent(),
            ]);

            return back()->with('status', 'PIN indoor farming dinonaktifkan.');
        }

        $pinValue = trim((string) ($validated['pin'] ?? ''));
        $currentPinHash = is_string($pinSetting->pin_hash) ? trim($pinSetting->pin_hash) : '';
        if ($pinValue === '' && $currentPinHash === '') {
            return back()
                ->withErrors(['pin' => 'PIN wajib diisi saat pertama kali mengaktifkan kontrol indoor farming.'])
                ->withInput();
        }

        $pinSetting->fill([
            'pin_hash' => $pinValue !== '' ? Hash::make($pinValue) : $pinSetting->pin_hash,
            'is_enabled' => true,
            'unlock_duration_minutes' => (int) $validated['unlock_duration_minutes'],
            'updated_by' => $actor?->id,
        ])->save();

        ActivityLog::createSafe([
            'user_id' => $actor?->id,
            'module' => 'admin',
            'action' => 'indoor_farming.pin.update',
            'description' => 'Memperbarui PIN akses kontrol indoor farming (web)',
            'guard' => 'web',
            'role_name' => $this->resolveRoleName($actor),
            'login_identifier' => $actor?->email,
            'ip_address' => $request->ip(),
            'user_agent' => $request->userAgent(),
            'metadata' => [
                'unlock_duration_minutes' => (int) $validated['unlock_duration_minutes'],
                'pin_rotated' => $pinValue !== '',
            ],
        ]);

        return back()->with('status', 'Pengaturan PIN indoor farming berhasil diperbarui.');
    }

    public function storeIndoorFarmingAccessGrant(Request $request): RedirectResponse
    {
        $actor = $request->user();
        $this->abortIfRoleNotIn($actor, ['super_admin']);

        $validated = $request->validate([
            'user_id' => ['required', 'integer', 'exists:users,id'],
        ]);

        $targetUser = User::query()->with('role')->findOrFail((int) $validated['user_id']);
        $targetRole = $this->resolveRoleName($targetUser);
        if ($targetRole !== 'user') {
            return back()->withErrors([
                'user_id' => 'Hanya akun dengan role user yang dapat diberi akses penuh tanpa PIN.',
            ]);
        }

        $grant = FeatureAccessGrant::query()->firstOrCreate(
            [
                'feature_key' => FeatureAccessGrant::FEATURE_INDOOR_FARMING_CONTROL,
                'user_id' => $targetUser->id,
            ],
            [
                'granted_by' => $actor?->id,
            ]
        );

        if (! $grant->wasRecentlyCreated) {
            return back()->with('status', "Akses penuh indoor farming untuk {$targetUser->email} sudah aktif.");
        }

        ActivityLog::createSafe([
            'user_id' => $actor?->id,
            'module' => 'admin',
            'action' => 'indoor_farming.access_grant.create',
            'description' => "Memberi akses penuh indoor farming tanpa PIN ke '{$targetUser->email}' (web)",
            'guard' => 'web',
            'role_name' => $this->resolveRoleName($actor),
            'login_identifier' => $actor?->email,
            'ip_address' => $request->ip(),
            'user_agent' => $request->userAgent(),
            'metadata' => [
                'target_user_id' => $targetUser->id,
                'target_email' => $targetUser->email,
            ],
        ]);

        return back()->with('status', "Akses penuh indoor farming diberikan ke {$targetUser->email}.");
    }

    public function destroyIndoorFarmingAccessGrant(Request $request, FeatureAccessGrant $grant): RedirectResponse
    {
        $actor = $request->user();
        $this->abortIfRoleNotIn($actor, ['super_admin']);

        if ($grant->feature_key !== FeatureAccessGrant::FEATURE_INDOOR_FARMING_CONTROL) {
            abort(404);
        }

        $targetUser = $grant->user()->first();
        $targetEmail = $targetUser?->email ?? 'unknown';
        $targetUserId = $targetUser?->id;
        $grant->delete();

        ActivityLog::createSafe([
            'user_id' => $actor?->id,
            'module' => 'admin',
            'action' => 'indoor_farming.access_grant.delete',
            'description' => "Mencabut akses penuh indoor farming tanpa PIN dari '{$targetEmail}' (web)",
            'guard' => 'web',
            'role_name' => $this->resolveRoleName($actor),
            'login_identifier' => $actor?->email,
            'ip_address' => $request->ip(),
            'user_agent' => $request->userAgent(),
            'metadata' => [
                'target_user_id' => $targetUserId,
                'target_email' => $targetEmail,
            ],
        ]);

        return back()->with('status', "Akses penuh indoor farming untuk {$targetEmail} dicabut.");
    }

    public function monitoringArea(Request $request): View
    {
        $user = $request->user();
        $this->abortIfRoleNotIn($user, ['super_admin', 'admin', 'user']);
        $role = $this->resolveRoleName($user);

        ActivityLog::createSafe([
            'user_id' => $user?->id,
            'module' => 'monitoring',
            'action' => 'screen.open',
            'description' => 'Membuka halaman monitoring area (web)',
            'guard' => 'web',
            'role_name' => $role,
            'login_identifier' => $user?->email,
            'ip_address' => $request->ip(),
            'user_agent' => $request->userAgent(),
            'metadata' => ['page' => 'monitoring_area'],
        ]);

        return view('tools.monitoring_area_index', [
            'dashboardRoute' => $this->resolveDashboardRouteName($role),
            'backRoute' => $this->resolveDashboardRouteName($role),
        ]);
    }

    public function monitoringAreaDetail(Request $request, string $areaId): View
    {
        $user = $request->user();
        $this->abortIfRoleNotIn($user, ['super_admin', 'admin', 'user']);
        $role = $this->resolveRoleName($user);

        ActivityLog::createSafe([
            'user_id' => $user?->id,
            'module' => 'monitoring',
            'action' => 'screen.open',
            'description' => "Membuka detail area monitoring '{$areaId}' (web)",
            'guard' => 'web',
            'role_name' => $role,
            'login_identifier' => $user?->email,
            'ip_address' => $request->ip(),
            'user_agent' => $request->userAgent(),
            'metadata' => ['page' => 'monitoring_area_detail', 'area_id' => $areaId],
        ]);

        return view('tools.monitoring_area', [
            'dashboardRoute' => $this->resolveDashboardRouteName($role),
            'backRoute' => $this->resolveDashboardRouteName($role),
            'areaId' => strtolower($areaId),
        ]);
    }

    public function superAdminUsers(Request $request): View
    {
        $user = $request->user();
        $this->abortIfRoleNotIn($user, ['super_admin']);

        $query = User::query()
            ->with('role')
            ->orderBy('name');

        if ($request->filled('q')) {
            $keyword = trim((string) $request->query('q'));
            if ($keyword !== '') {
                $query->where(function ($q) use ($keyword): void {
                    $q->where('name', 'like', '%'.$keyword.'%')
                        ->orWhere('email', 'like', '%'.$keyword.'%');
                });
            }
        }
        if ($request->filled('role')) {
            $roleFilter = strtolower(trim((string) $request->query('role')));
            if ($roleFilter !== '') {
                $query->whereHas('role', fn ($q) => $q->where('name', $roleFilter));
            }
        }
        if ($request->filled('active')) {
            $active = filter_var($request->query('active'), FILTER_VALIDATE_BOOL, FILTER_NULL_ON_FAILURE);
            if ($active !== null) {
                $query->where('is_active', $active);
            }
        }

        $users = $query->get();

        $totals = [
            'all' => User::query()->count(),
            'super_admin' => User::query()->whereHas('role', fn ($q) => $q->where('name', 'super_admin'))->count(),
            'admin' => User::query()->whereHas('role', fn ($q) => $q->where('name', 'admin'))->count(),
            'user' => User::query()->whereHas('role', fn ($q) => $q->where('name', 'user'))->count(),
            'active' => User::query()->where('is_active', true)->count(),
            'inactive' => User::query()->where('is_active', false)->count(),
        ];

        return view('role.super_admin_users', [
            'users' => $users,
            'availableRoles' => ['super_admin', 'admin', 'user'],
            'currentUserId' => $user?->id,
            'totals' => $totals,
            'dashboardRoute' => 'super_admin.dashboard',
        ]);
    }

    public function updateUserRole(Request $request, User $user): RedirectResponse
    {
        $actor = $request->user();
        $this->abortIfRoleNotIn($actor, ['super_admin']);

        $validated = $request->validate([
            'role' => ['required', 'string', 'in:super_admin,admin,user'],
        ]);

        $roleName = strtolower((string) $validated['role']);
        if ($actor !== null && $actor->id === $user->id && $roleName !== 'super_admin') {
            return back()->withErrors([
                'role' => 'Super admin tidak boleh menurunkan role akun sendiri.',
            ]);
        }

        $oldRole = $this->resolveRoleName($user);
        $roleId = Role::query()->firstOrCreate(['name' => $roleName])->id;
        $user->forceFill(['role_id' => $roleId])->save();

        ActivityLog::createSafe([
            'user_id' => $actor->id,
            'module' => 'admin',
            'action' => 'admin.user.role.change',
            'description' => "Mengubah role user '{$user->email}' dari '{$oldRole}' menjadi '{$roleName}' (web)",
            'guard' => 'web',
            'role_name' => $this->resolveRoleName($actor),
            'login_identifier' => $actor->email,
            'ip_address' => $request->ip(),
            'user_agent' => $request->userAgent(),
            'metadata' => [
                'target_user_id' => $user->id,
                'target_email' => $user->email,
                'old_role' => $oldRole,
                'new_role' => $roleName,
            ],
        ]);

        return back()->with('status', "Role {$user->email} diubah menjadi {$roleName}.");
    }

    public function adminUsers(Request $request): View
    {
        $user = $request->user();
        $this->abortIfRoleNotIn($user, ['super_admin', 'admin']);

        $query = User::query()
            ->with('role')
            ->orderBy('name');

        if ($request->filled('q')) {
            $keyword = trim((string) $request->query('q'));
            if ($keyword !== '') {
                $query->where(function ($q) use ($keyword): void {
                    $q->where('name', 'like', '%'.$keyword.'%')
                        ->orWhere('email', 'like', '%'.$keyword.'%');
                });
            }
        }

        if ($request->filled('role')) {
            $roleFilter = strtolower(trim((string) $request->query('role')));
            if ($roleFilter !== '') {
                $query->whereHas('role', fn ($q) => $q->where('name', $roleFilter));
            }
        }

        if ($request->filled('active')) {
            $active = filter_var($request->query('active'), FILTER_VALIDATE_BOOL, FILTER_NULL_ON_FAILURE);
            if ($active !== null) {
                $query->where('is_active', $active);
            }
        }

        $users = $query->get();

        return view('role.admin_users', [
            'users' => $users,
            'currentUserId' => $user?->id,
            'canBackToSuperAdmin' => $this->resolveRoleName($user) === 'super_admin',
            'dashboardRoute' => $this->resolveDashboardRouteName($this->resolveRoleName($user)),
        ]);
    }

    public function adminActivityLogs(Request $request): View|JsonResponse
    {
        $user = $request->user();
        $this->abortIfRoleNotIn($user, ['super_admin', 'admin']);
        $dateColumn = $this->resolveActivityLogDateColumn();

        $query = ActivityLog::query()->with(['user:id,name,email']);
        if ($request->filled('q')) {
            $keyword = trim((string) $request->query('q'));
            if ($keyword !== '') {
                $query->where(function ($q) use ($keyword): void {
                    $q->where('action', 'like', '%'.$keyword.'%')
                        ->orWhere('module', 'like', '%'.$keyword.'%')
                        ->orWhere('description', 'like', '%'.$keyword.'%')
                        ->orWhere('login_identifier', 'like', '%'.$keyword.'%');
                });
            }
        }
        if ($request->filled('module')) {
            $query->where('module', trim((string) $request->query('module')));
        }
        if ($request->filled('action')) {
            $query->where('action', trim((string) $request->query('action')));
        }
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
        if (
            ! $request->filled('date_from') &&
            ! $request->filled('date_to') &&
            ! $request->filled('datetime_from') &&
            ! $request->filled('datetime_to')
        ) {
            $todayStart = Carbon::now(config('app.timezone'))->startOfDay()->format('Y-m-d H:i:s');
            $todayEnd = Carbon::now(config('app.timezone'))->endOfDay()->format('Y-m-d H:i:s');
            $query->whereBetween($dateColumn, [$todayStart, $todayEnd]);
        }
        if (Schema::hasColumn('activity_logs', 'performed_at')) {
            $query->orderByDesc('performed_at');
        } elseif (Schema::hasColumn('activity_logs', 'created_at')) {
            $query->orderByDesc('created_at');
        }

        $limit = (int) min(max((int) $request->query('limit', 200), 1), 5000);
        $logs = $query->limit($limit)->get();

        if ($request->boolean('json') || $request->expectsJson() || $request->ajax()) {
            $activityRows = $logs
                ->reject(fn (ActivityLog $log) => $this->isSensorSnapshotActivity($log))
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
                })
                ->values();

            return response()->json([
                'data' => $activityRows,
            ]);
        }

        return view('role.admin_activity_logs', [
            'logs' => $logs,
            'canBackToSuperAdmin' => $this->resolveRoleName($user) === 'super_admin',
            'dashboardRoute' => $this->resolveDashboardRouteName($this->resolveRoleName($user)),
        ]);
    }

    public function adminTemperatureLogs(Request $request): View|JsonResponse
    {
        $user = $request->user();
        $this->abortIfRoleNotIn($user, ['super_admin', 'admin']);

        if ($request->boolean('json') || $request->expectsJson() || $request->ajax()) {
            try {
                return response()->json([
                    'data' => $this->buildMongoGraphicLogRows($request),
                ]);
            } catch (\Throwable $e) {
                Log::error('Failed to build admin temperature logs payload', [
                    'message' => $e->getMessage(),
                    'file' => $e->getFile(),
                    'line' => $e->getLine(),
                    'datetime_from' => $request->query('datetime_from'),
                    'datetime_to' => $request->query('datetime_to'),
                ]);

                return response()->json([
                    'data' => [],
                    'error' => 'temperature_logs_failed',
                ]);
            }
        }

        return view('role.admin_temperature_logs', [
            'canBackToSuperAdmin' => $this->resolveRoleName($user) === 'super_admin',
            'dashboardRoute' => $this->resolveDashboardRouteName($this->resolveRoleName($user)),
        ]);
    }

    public function updateUserActive(Request $request, User $user): RedirectResponse
    {
        $actor = $request->user();
        $this->abortIfRoleNotIn($actor, ['super_admin', 'admin']);

        $validated = $request->validate([
            'is_active' => ['required', 'boolean'],
        ]);
        $isActive = (bool) $validated['is_active'];

        if ($actor !== null && $actor->id === $user->id && ! $isActive) {
            return back()->withErrors([
                'is_active' => 'Anda tidak dapat menonaktifkan akun sendiri.',
            ]);
        }

        $actorRole = $this->resolveRoleName($actor);
        $targetRole = $this->resolveRoleName($user);
        if ($actorRole === 'admin' && $targetRole === 'super_admin') {
            return back()->withErrors([
                'is_active' => 'Admin tidak dapat mengubah status super_admin.',
            ]);
        }

        $oldStatus = $user->is_active ? 'aktif' : 'nonaktif';
        $user->forceFill(['is_active' => $isActive])->save();
        if (! $isActive) {
            ApiAccessToken::query()->where('user_id', $user->id)->delete();
        }

        $newStatus = $isActive ? 'aktif' : 'nonaktif';
        ActivityLog::createSafe([
            'user_id' => $actor->id,
            'module' => 'admin',
            'action' => $isActive ? 'admin.user.unsuspend' : 'admin.user.suspend',
            'description' => $isActive
                ? "Mengaktifkan kembali user '{$user->email}' (web)"
                : "Menangguhkan user '{$user->email}' (web)",
            'guard' => 'web',
            'role_name' => $actorRole,
            'login_identifier' => $actor->email,
            'ip_address' => $request->ip(),
            'user_agent' => $request->userAgent(),
            'metadata' => [
                'target_user_id' => $user->id,
                'target_email' => $user->email,
                'old_status' => $oldStatus,
                'new_status' => $newStatus,
            ],
        ]);

        return back()->with('status', 'Status aktif '.$user->email.' diperbarui.');
    }

    public function userProfile(Request $request): RedirectResponse
    {
        $user = $request->user();
        $this->abortIfRoleNotIn($user, ['super_admin', 'admin', 'user']);

        return redirect()->route('user.dashboard');
    }

    public function storeFrontendActivity(Request $request): JsonResponse
    {
        $user = $request->user();
        $this->abortIfRoleNotIn($user, ['super_admin', 'admin', 'user']);

        $validated = $request->validate([
            'action' => ['required', 'string', 'max:120'],
            'module' => ['nullable', 'string', 'max:80'],
            'device_id' => ['nullable', 'string', 'max:120'],
            'description' => ['nullable', 'string'],
            'metadata' => ['nullable', 'array'],
            'performed_at' => ['nullable', 'date'],
        ]);

        $roleName = $this->resolveRoleName($user);
        if (! $this->shouldPersistFrontendActivity(
            $roleName,
            (string) $validated['action'],
            (string) ($validated['module'] ?? 'monitoring')
        )) {
            return response()->json(['ok' => true, 'skipped' => true], 202);
        }

        ActivityLog::createSafe([
            'user_id' => $user?->id,
            'module' => $validated['module'] ?? 'monitoring',
            'action' => $validated['action'],
            'description' => $validated['description'] ?? '-',
            'device_id' => $validated['device_id'] ?? null,
            'guard' => 'web',
            'role_name' => $roleName,
            'login_identifier' => $user?->email,
            'ip_address' => $request->ip(),
            'user_agent' => $request->userAgent(),
            'metadata' => $validated['metadata'] ?? [],
            'performed_at' => $validated['performed_at'] ?? now(),
        ]);

        return response()->json(['ok' => true]);
    }

    private function shouldPersistFrontendActivity(string $roleName, string $action, string $module): bool
    {
        $action = strtolower(trim($action));
        $module = strtolower(trim($module));
        $roleName = strtolower(trim($roleName));

        if ($action === '' || str_starts_with($action, 'screen.open') || in_array($action, [
            'page_visit',
            'navigation',
            'monitoring.node.inspect',
        ], true)) {
            return false;
        }

        if (in_array($roleName, ['super_admin', 'admin'], true)) {
            // Allow key monitoring control actions to appear in admin activity log.
            if (str_starts_with($action, 'monitoring.web.')) {
                $allowedMonitoringPrefixes = [
                    'monitoring.web.relay.',
                    'monitoring.web.enviro.relay.',
                    'monitoring.web.hydro.relay_',
                    'monitoring.web.mode.change',
                    'monitoring.web.enviro.mode.change',
                    'monitoring.web.hydro.mode.change',
                    'monitoring.web.schedule.',
                    'monitoring.web.manual.',
                ];

                foreach ($allowedMonitoringPrefixes as $prefix) {
                    if (str_starts_with($action, $prefix)) {
                        return true;
                    }
                }
            }

            if (str_starts_with($action, 'monitoring.system.')) {
                return in_array($action, [
                    'monitoring.system.relay.change',
                ], true);
            }

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

    private function abortIfRoleNotIn(?User $user, array $allowed): void
    {
        $role = $this->resolveRoleName($user);
        if (! in_array($role, $allowed, true)) {
            abort(403, 'Anda tidak memiliki akses ke halaman ini.');
        }
    }

    private function resolveRoleName(?User $user): string
    {
        if ($user === null) {
            return 'user';
        }

        if (Schema::hasColumn('users', 'role') && is_string($user->role ?? null)) {
            $role = strtolower(trim((string) $user->role));
            return $role !== '' ? $role : 'user';
        }

        if (Schema::hasColumn('users', 'role_id') && Schema::hasTable('roles')) {
            $role = strtolower(trim((string) ($user->role?->name ?? '')));
            return $role !== '' ? $role : 'user';
        }

        return 'user';
    }

    private function resolveActivityLogDateColumn(): string
    {
        if (Schema::hasColumn('activity_logs', 'performed_at')) {
            return 'performed_at';
        }

        return 'created_at';
    }

    private function resolveDashboardRouteName(string $role): string
    {
        return match ($role) {
            'super_admin' => 'super_admin.dashboard',
            'admin' => 'admin.dashboard',
            default => 'user.dashboard',
        };
    }

    private function isSensorSnapshotActivity(ActivityLog $log): bool
    {
        return in_array((string) $log->action, [
            'inkubator.sensor.snapshot',
            'sensor.snapshot',
        ], true);
    }

    /**
     * @return array<int, array<string, mixed>>
     */
    private function buildMongoGraphicLogRows(Request $request): array
    {
        $range = $this->resolveSensorDateRange($request);
        $start = $range['start'];
        $end = $range['end'];
        $mongo = app(\App\Services\MongoDbService::class);
        $rows = [];

        $documents = $mongo->getTelemetryDocumentsBetween('indoor_farming_sensor', 'indoor_farming_sensor', $start->copy()->utc(), $end->copy()->utc(), 20000);
        foreach ($documents as $row) {
            $timestampSec = isset($row['timestamp']) && is_numeric($row['timestamp']) ? (int) $row['timestamp'] : null;
            if ($timestampSec === null) {
                continue;
            }

            $performedAt = Carbon::createFromTimestampUTC($timestampSec)->timezone(config('app.timezone'));
            if ($performedAt->lt($start) || $performedAt->gt($end)) {
                continue;
            }

            $rows[] = [
                'id' => 'mongo-indoor-farming-' . $timestampSec,
                'module' => 'sensor',
                'action' => 'sensor.snapshot',
                'description' => 'Snapshot sensor dari MongoDB Indoor Farming',
                'device_id' => $row['device_id'] ?? 'indoor_farming_sensor',
                'performed_at' => $performedAt->toIso8601String(),
                'performed_at_local' => $performedAt->format('Y-m-d H:i:s'),
                'performed_at_ts' => $performedAt->getTimestampMs(),
                'metadata' => [
                    'source' => 'mongodb',
                    'measurement' => $row['measurement'] ?? 'indoor_farming_sensor',
                    'label' => 'Indoor Farming',
                    'temperature' => $row['temperature'] ?? null,
                    'do' => $row['do'] ?? null,
                    'humidity' => $row['humidity'] ?? null,
                    'soil_moisture' => $row['soil_moisture'] ?? null,
                    'ec_us' => $row['ec_us'] ?? null,
                    'ec_ms' => $row['ec_ms'] ?? null,
                    'ppm' => $row['ppm'] ?? null,
                    'tds' => $row['tds'] ?? null,
                    'ph' => $row['ph'] ?? null,
                    'topic' => $row['topic'] ?? null,
                ],
                'user_name' => 'system',
                'login_identifier' => 'mongodb',
            ];
        }

        return $rows;
    }

    /**
     * @return array{start: Carbon, end: Carbon}
     */
    private function resolveSensorDateRange(Request $request): array
    {
        $tz = config('app.timezone');
        $start = $request->filled('datetime_from')
            ? Carbon::parse((string) $request->query('datetime_from'), $tz)
            : Carbon::now($tz)->startOfDay();
        $end = $request->filled('datetime_to')
            ? Carbon::parse((string) $request->query('datetime_to'), $tz)
            : Carbon::now($tz)->endOfDay();

        if ($end->lt($start)) {
            [$start, $end] = [$end, $start];
        }

        return ['start' => $start, 'end' => $end];
    }

    private function toInfluxRelativeRange(int $spanSeconds): string
    {
        if ($spanSeconds <= 3600) {
            return '-' . max(1, (int) ceil($spanSeconds / 60)) . 'm';
        }
        if ($spanSeconds <= 86400) {
            return '-' . max(1, (int) ceil($spanSeconds / 3600)) . 'h';
        }
        return '-' . max(1, (int) ceil($spanSeconds / 86400)) . 'd';
    }

    private function toInfluxWindow(int $spanSeconds): string
    {
        if ($spanSeconds <= 3600) {
            return '1m';
        }
        if ($spanSeconds <= 21600) {
            return '5m';
        }
        if ($spanSeconds <= 86400) {
            return '15m';
        }
        return '1h';
    }

    /**
     * @param array<int, array<string, mixed>> $seriesList
     * @return array<int, array<string, mixed>>
     */
    private function pivotInfluxSeriesRows(array $seriesList): array
    {
        $rows = [];

        foreach ($seriesList as $series) {
            $field = is_string($series['field'] ?? null) ? $series['field'] : '';
            $points = is_array($series['points'] ?? null) ? $series['points'] : [];
            if ($field === '' || $points === []) {
                continue;
            }

            foreach ($points as $point) {
                if (! is_array($point) || ! isset($point['timestamp']) || ! is_numeric($point['timestamp'])) {
                    continue;
                }
                $timestamp = (int) $point['timestamp'];
                $key = (string) $timestamp;
                if (! isset($rows[$key])) {
                    $rows[$key] = ['timestamp' => $timestamp];
                }
                $rows[$key][$field] = is_numeric($point['value'] ?? null)
                    ? (float) $point['value']
                    : null;
            }
        }

        ksort($rows, SORT_NUMERIC);
        return array_values($rows);
    }
}
