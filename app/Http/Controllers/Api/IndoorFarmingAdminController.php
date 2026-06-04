<?php

namespace App\Http\Controllers\Api;

use App\Http\Controllers\Controller;
use App\Models\ActivityLog;
use App\Models\FeatureAccessGrant;
use App\Models\FeatureAccessPin;
use App\Models\User;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Hash;

class IndoorFarmingAdminController extends Controller
{
    public function config(Request $request): JsonResponse
    {
        $actor = $request->user();
        if ($this->resolveRoleName($actor) !== 'super_admin') {
            return response()->json([
                'message' => 'Hanya super admin yang dapat mengakses pengaturan ini.',
            ], 403);
        }

        $pinSetting = FeatureAccessPin::query()
            ->with('updatedBy:id,name,email')
            ->where('feature_key', FeatureAccessPin::FEATURE_INDOOR_FARMING_CONTROL)
            ->first();

        $candidates = User::query()
            ->with('role:id,name')
            ->where('is_active', true)
            ->whereHas('role', fn ($q) => $q->where('name', 'user'))
            ->orderBy('name')
            ->get(['id', 'name', 'email', 'role_id', 'is_active']);

        $grants = FeatureAccessGrant::query()
            ->with(['user:id,name,email,is_active,role_id', 'user.role:id,name', 'grantedBy:id,name,email'])
            ->where('feature_key', FeatureAccessGrant::FEATURE_INDOOR_FARMING_CONTROL)
            ->orderByDesc('created_at')
            ->get();

        return response()->json([
            'data' => [
                'pin_setting' => $this->serializePinSetting($pinSetting),
                'grant_candidates' => $candidates->map(fn (User $user) => [
                    'id' => $user->id,
                    'name' => $user->name,
                    'email' => $user->email,
                    'role' => strtolower(trim((string) ($user->role->name ?? 'user'))),
                    'is_active' => (bool) $user->is_active,
                ])->values(),
                'access_grants' => $grants->map(fn (FeatureAccessGrant $grant) => [
                    'id' => $grant->id,
                    'user_id' => $grant->user_id,
                    'user_name' => $grant->user?->name ?? '-',
                    'user_email' => $grant->user?->email ?? '-',
                    'user_role' => strtolower(trim((string) ($grant->user?->role?->name ?? 'user'))),
                    'user_is_active' => (bool) ($grant->user?->is_active ?? false),
                    'granted_by_name' => $grant->grantedBy?->name ?? $grant->grantedBy?->email ?? '-',
                    'created_at' => optional($grant->created_at)?->toIso8601String(),
                ])->values(),
            ],
        ]);
    }

    public function savePin(Request $request): JsonResponse
    {
        $actor = $request->user();
        if ($this->resolveRoleName($actor) !== 'super_admin') {
            return response()->json([
                'message' => 'Hanya super admin yang dapat mengubah PIN indoor farming.',
            ], 403);
        }

        $validated = $request->validate([
            'pin' => ['nullable', 'regex:/^\d{4,8}$/', 'confirmed'],
            'pin_confirmation' => ['nullable', 'regex:/^\d{4,8}$/'],
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
                'description' => 'Menonaktifkan PIN akses kontrol indoor farming (mobile)',
                'guard' => 'api',
                'role_name' => $this->resolveRoleName($actor),
                'login_identifier' => $actor?->email,
                'ip_address' => $request->ip(),
                'user_agent' => $request->userAgent(),
            ]);

            return response()->json([
                'message' => 'PIN indoor farming dinonaktifkan.',
                'data' => $this->serializePinSetting($pinSetting->fresh(['updatedBy:id,name,email'])),
            ]);
        }

        $pinValue = trim((string) ($validated['pin'] ?? ''));
        $currentPinHash = is_string($pinSetting->pin_hash) ? trim($pinSetting->pin_hash) : '';
        if ($pinValue === '' && $currentPinHash === '') {
            return response()->json([
                'message' => 'PIN wajib diisi saat pertama kali mengaktifkan kontrol indoor farming.',
                'errors' => [
                    'pin' => ['PIN wajib diisi saat pertama kali mengaktifkan kontrol indoor farming.'],
                ],
            ], 422);
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
            'description' => 'Memperbarui PIN akses kontrol indoor farming (mobile)',
            'guard' => 'api',
            'role_name' => $this->resolveRoleName($actor),
            'login_identifier' => $actor?->email,
            'ip_address' => $request->ip(),
            'user_agent' => $request->userAgent(),
            'metadata' => [
                'unlock_duration_minutes' => (int) $validated['unlock_duration_minutes'],
                'pin_rotated' => $pinValue !== '',
            ],
        ]);

        return response()->json([
            'message' => 'Pengaturan PIN indoor farming berhasil diperbarui.',
            'data' => $this->serializePinSetting($pinSetting->fresh(['updatedBy:id,name,email'])),
        ]);
    }

    public function storeAccessGrant(Request $request): JsonResponse
    {
        $actor = $request->user();
        if ($this->resolveRoleName($actor) !== 'super_admin') {
            return response()->json([
                'message' => 'Hanya super admin yang dapat memberi akses penuh indoor farming.',
            ], 403);
        }

        $validated = $request->validate([
            'user_id' => ['required', 'integer', 'exists:users,id'],
        ]);

        $targetUser = User::query()->with('role')->findOrFail((int) $validated['user_id']);
        if ($this->resolveRoleName($targetUser) !== 'user') {
            return response()->json([
                'message' => 'Hanya akun dengan role user yang dapat diberi akses penuh tanpa PIN.',
                'errors' => [
                    'user_id' => ['Hanya akun dengan role user yang dapat diberi akses penuh tanpa PIN.'],
                ],
            ], 422);
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
            return response()->json([
                'message' => "Akses penuh indoor farming untuk {$targetUser->email} sudah aktif.",
            ]);
        }

        ActivityLog::createSafe([
            'user_id' => $actor?->id,
            'module' => 'admin',
            'action' => 'indoor_farming.access_grant.create',
            'description' => "Memberi akses penuh indoor farming tanpa PIN ke '{$targetUser->email}' (mobile)",
            'guard' => 'api',
            'role_name' => $this->resolveRoleName($actor),
            'login_identifier' => $actor?->email,
            'ip_address' => $request->ip(),
            'user_agent' => $request->userAgent(),
            'metadata' => [
                'target_user_id' => $targetUser->id,
                'target_email' => $targetUser->email,
            ],
        ]);

        return response()->json([
            'message' => "Akses penuh indoor farming diberikan ke {$targetUser->email}.",
        ]);
    }

    public function destroyAccessGrant(Request $request, int $grantId): JsonResponse
    {
        $actor = $request->user();
        if ($this->resolveRoleName($actor) !== 'super_admin') {
            return response()->json([
                'message' => 'Hanya super admin yang dapat mencabut akses penuh indoor farming.',
            ], 403);
        }

        $grant = FeatureAccessGrant::query()->with('user')->findOrFail($grantId);
        if ($grant->feature_key !== FeatureAccessGrant::FEATURE_INDOOR_FARMING_CONTROL) {
            return response()->json([
                'message' => 'Data grant tidak ditemukan.',
            ], 404);
        }

        $targetUser = $grant->user;
        $targetEmail = $targetUser?->email ?? 'unknown';
        $targetUserId = $targetUser?->id;
        $grant->delete();

        ActivityLog::createSafe([
            'user_id' => $actor?->id,
            'module' => 'admin',
            'action' => 'indoor_farming.access_grant.delete',
            'description' => "Mencabut akses penuh indoor farming tanpa PIN dari '{$targetEmail}' (mobile)",
            'guard' => 'api',
            'role_name' => $this->resolveRoleName($actor),
            'login_identifier' => $actor?->email,
            'ip_address' => $request->ip(),
            'user_agent' => $request->userAgent(),
            'metadata' => [
                'target_user_id' => $targetUserId,
                'target_email' => $targetEmail,
            ],
        ]);

        return response()->json([
            'message' => "Akses penuh indoor farming untuk {$targetEmail} dicabut.",
        ]);
    }

    private function serializePinSetting(?FeatureAccessPin $pinSetting): array
    {
        return [
            'is_enabled' => (bool) ($pinSetting?->is_enabled ?? false),
            'has_pin' => is_string($pinSetting?->pin_hash) && trim((string) $pinSetting?->pin_hash) !== '',
            'unlock_duration_minutes' => (int) ($pinSetting?->unlock_duration_minutes ?? 30),
            'updated_at' => optional($pinSetting?->updated_at)?->toIso8601String(),
            'updated_by_name' => $pinSetting?->updatedBy?->name ?? $pinSetting?->updatedBy?->email,
        ];
    }

    private function resolveRoleName(?User $user): string
    {
        $roleName = strtolower(trim((string) ($user?->role?->name ?? $user?->role ?? 'user')));
        return $roleName !== '' ? $roleName : 'user';
    }
}
