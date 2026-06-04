<?php

namespace App\Http\Controllers\Api;

use App\Http\Controllers\Controller;
use App\Models\ApiAccessToken;
use App\Models\Role;
use App\Models\User;
use Illuminate\Http\Client\ConnectionException;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Hash;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;
use RuntimeException;

class AuthController extends Controller
{
    private const SSO_STATE_TTL_SECONDS = 300;
    private const SSO_LOGIN_CODE_TTL_SECONDS = 120;

    public function register(Request $request): JsonResponse
    {
        $validated = $request->validate([
            'name' => ['required', 'string', 'max:255'],
            'email' => ['required', 'string', 'email', 'max:255', 'unique:users,email'],
            'password' => ['required', 'string', 'min:6'],
        ]);

        $roleName = 'user';
        $payload = [
            'name' => trim((string) $validated['name']),
            'email' => strtolower((string) $validated['email']),
            'password' => Hash::make((string) $validated['password']),
            'is_active' => true,
        ];

        if (Schema::hasColumn('users', 'role_id') && Schema::hasTable('roles')) {
            $payload['role_id'] = Role::query()->firstOrCreate(['name' => $roleName])->id;
        }
        if (Schema::hasColumn('users', 'role')) {
            $payload['role'] = $roleName;
        }
        if (Schema::hasColumn('users', 'auth_provider')) {
            $payload['auth_provider'] = 'local';
        }

        User::query()->create($payload);

        return response()->json([
            'message' => 'Registrasi berhasil. Silakan login.',
        ], 201);
    }

    public function login(Request $request): JsonResponse
    {
        $validated = $request->validate([
            'email' => ['required', 'email'],
            'password' => ['required', 'string'],
        ]);

        $user = User::query()
            ->where('email', strtolower($validated['email']))
            ->first();

        if ($user === null || ! Hash::check($validated['password'], (string) $user->password)) {
            return response()->json([
                'message' => 'Email atau password salah.',
            ], 401);
        }

        if (! (bool) ($user->is_active ?? true)) {
            return response()->json([
                'message' => 'Akun Anda dinonaktifkan. Hubungi admin.',
            ], 403);
        }

        [$plainToken, $tokenRow] = $this->createApiToken($user, 'mobile_local_login');
        $this->logAuthActivity($request, $user, 'auth.login', "Login lokal berhasil oleh {$user->email}", $tokenRow);

        return response()->json([
            'message' => 'Login berhasil.',
            'token' => $plainToken,
            'token_type' => 'Bearer',
            'user' => $this->userPayload($user),
        ]);
    }

    public function me(Request $request): JsonResponse
    {
        /** @var User $user */
        $user = $request->user();

        return response()->json([
            'user' => $this->userPayload($user),
        ]);
    }

    public function roles(Request $request): JsonResponse
    {
        $user = $request->user();
        if (! $user instanceof User) {
            return response()->json([
                'message' => 'User tidak valid.',
            ], 401);
        }

        return response()->json([
            'data' => ['super_admin', 'admin', 'user'],
        ]);
    }

    public function users(Request $request): JsonResponse
    {
        $user = $request->user();
        if (! $user instanceof User) {
            return response()->json([
                'message' => 'User tidak valid.',
            ], 401);
        }
        if (! $this->canViewUserDirectory($user)) {
            return response()->json([
                'message' => 'Anda tidak memiliki izin melihat daftar user.',
            ], 403);
        }

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

        $limit = (int) min(max((int) $request->query('limit', 200), 1), 500);
        $users = $query
            ->limit($limit)
            ->get()
            ->map(fn (User $row): array => $this->userPayload($row));

        return response()->json([
            'data' => $users,
        ]);
    }

    public function updateUserRole(Request $request, int $userId): JsonResponse
    {
        $actor = $request->user();
        if (! $actor instanceof User) {
            return response()->json([
                'message' => 'User tidak valid.',
            ], 401);
        }

        if (! $this->isSuperAdmin($actor)) {
            return response()->json([
                'message' => 'Hanya super_admin yang dapat mengubah role user.',
            ], 403);
        }

        $validated = $request->validate([
            'role' => ['required', 'string', 'in:super_admin,admin,user'],
        ]);
        $roleName = strtolower((string) $validated['role']);

        $targetUser = User::query()->with('role')->find($userId);
        if (! $targetUser instanceof User) {
            return response()->json([
                'message' => 'User target tidak ditemukan.',
            ], 404);
        }

        if ($targetUser->id === $actor->id && $roleName !== 'super_admin') {
            return response()->json([
                'message' => 'Super admin tidak boleh menurunkan role akun sendiri.',
            ], 422);
        }

        $roleId = Role::query()->firstOrCreate(['name' => $roleName])->id;
        $targetUser->forceFill(['role_id' => $roleId])->save();
        $targetUser->refresh()->load('role');

        $this->logAuthActivity(
            request: $request,
            user: $actor,
            action: 'auth.role_update',
            description: "Role {$targetUser->email} diubah menjadi {$roleName}",
            token: $request->attributes->get('api_access_token')
        );

        return response()->json([
            'message' => 'Role user berhasil diperbarui.',
            'user' => $this->userPayload($targetUser),
        ]);
    }

    public function updateUserActive(Request $request, int $userId): JsonResponse
    {
        $actor = $request->user();
        if (! $actor instanceof User) {
            return response()->json([
                'message' => 'User tidak valid.',
            ], 401);
        }

        if (! $this->canManageUserActive($actor)) {
            return response()->json([
                'message' => 'Anda tidak memiliki izin mengubah status aktif user.',
            ], 403);
        }

        $validated = $request->validate([
            'is_active' => ['required', 'boolean'],
        ]);
        $isActive = (bool) $validated['is_active'];

        $targetUser = User::query()->with('role')->find($userId);
        if (! $targetUser instanceof User) {
            return response()->json([
                'message' => 'User target tidak ditemukan.',
            ], 404);
        }

        if ($targetUser->id === $actor->id && ! $isActive) {
            return response()->json([
                'message' => 'Anda tidak dapat menonaktifkan akun sendiri.',
            ], 422);
        }

        if (! $this->isSuperAdmin($actor) && $this->isSuperAdmin($targetUser)) {
            return response()->json([
                'message' => 'Admin tidak dapat mengubah status super_admin.',
            ], 403);
        }

        $targetUser->forceFill(['is_active' => $isActive])->save();
        if (! $isActive) {
            ApiAccessToken::query()->where('user_id', $targetUser->id)->delete();
        }

        $this->logAuthActivity(
            request: $request,
            user: $actor,
            action: 'auth.user_active_update',
            description: 'Status aktif '.$targetUser->email.' diubah menjadi '.($isActive ? 'aktif' : 'nonaktif'),
            token: $request->attributes->get('api_access_token')
        );

        return response()->json([
            'message' => 'Status aktif user berhasil diperbarui.',
            'user' => $this->userPayload($targetUser->refresh()),
        ]);
    }

    public function logout(Request $request): JsonResponse
    {
        /** @var User|null $user */
        $user = $request->user();
        /** @var ApiAccessToken|null $token */
        $token = $request->attributes->get('api_access_token');

        if ($token !== null) {
            $this->logAuthActivity($request, $user, 'auth.logout', 'Logout berhasil', $token);
            $token->delete();
        }

        return response()->json([
            'message' => 'Logout berhasil.',
        ]);
    }

    public function ssoStart(Request $request): JsonResponse
    {
        if ($configError = $this->ssoConfigError()) {
            return $configError;
        }

        $config = $this->keycloakConfig();
        $redirectUri = $this->resolveApiRedirectUri($request);
        $state = Str::random(64);
        $channel = $request->input('channel', 'mobile');
        $channel = in_array($channel, ['mobile', 'json'], true) ? $channel : 'mobile';

        Cache::put(
            $this->ssoStateKey($state),
            [
                'channel' => $channel,
                'redirect_uri' => $redirectUri,
            ],
            now()->addSeconds(self::SSO_STATE_TTL_SECONDS)
        );

        $query = http_build_query([
            'client_id' => $config['client_id'],
            'redirect_uri' => $redirectUri,
            'response_type' => 'code',
            'scope' => 'openid email profile',
            'state' => $state,
            'prompt' => 'login',
        ]);

        return response()->json([
            'auth_url' => $config['authorize_url'].'?'.$query,
            'expires_in' => self::SSO_STATE_TTL_SECONDS,
        ]);
    }

    public function ssoLogoutUrl(): JsonResponse
    {
        if ($configError = $this->ssoConfigError()) {
            return $configError;
        }

        $config = $this->keycloakConfig();
        $logoutBase = trim((string) env('KEYCLOAK_LOGOUT_URL', ''));
        if ($logoutBase === '') {
            $logoutBase = $config['base_url'].'/realms/'.$config['realm'].'/protocol/openid-connect/logout';
        }

        $postLogoutRedirectUri = $this->mobileLogoutCallbackUri();
        $query = http_build_query([
            'client_id' => $config['client_id'],
            'post_logout_redirect_uri' => $postLogoutRedirectUri,
            'redirect_uri' => $postLogoutRedirectUri,
        ]);

        return response()->json([
            'logout_url' => $logoutBase.'?'.$query,
        ]);
    }

    public function ssoCallback(Request $request): JsonResponse|RedirectResponse
    {
        if ($configError = $this->ssoConfigError()) {
            return $configError;
        }

        $validated = $request->validate([
            'code' => ['required', 'string'],
            'state' => ['required', 'string'],
        ]);

        $stateData = Cache::pull($this->ssoStateKey($validated['state']));
        if (! is_array($stateData)) {
            return response()->json([
                'message' => 'State SSO tidak valid atau sudah kedaluwarsa.',
            ], 422);
        }

        $config = $this->keycloakConfig();
        $redirectUri = (string) ($stateData['redirect_uri'] ?? $this->resolveApiRedirectUri($request));

        try {
            $tokenPayload = $this->exchangeAuthorizationCode($validated['code'], $config, $redirectUri);
            $profile = $this->fetchUserInfo((string) ($tokenPayload['access_token'] ?? ''), $config);
            $user = $this->upsertSsoUser($profile);
            if (! (bool) ($user->is_active ?? true)) {
                return response()->json([
                    'message' => 'Akun Anda dinonaktifkan. Hubungi admin.',
                ], 403);
            }

            [$plainToken, $tokenRow] = $this->createApiToken($user, 'mobile_sso_login');
            $this->logAuthActivity($request, $user, 'auth.login', "SSO login berhasil oleh {$user->email}", $tokenRow);

            $loginCode = Str::random(64);
            $exchangePayload = [
                'message' => 'Login SSO berhasil.',
                'token' => $plainToken,
                'token_type' => 'Bearer',
                'user' => $this->userPayload($user),
                'sso' => [
                    'expires_in' => (int) ($tokenPayload['expires_in'] ?? 0),
                    'refresh_expires_in' => (int) ($tokenPayload['refresh_expires_in'] ?? 0),
                    'token_type' => (string) ($tokenPayload['token_type'] ?? 'Bearer'),
                    'session_state' => (string) ($tokenPayload['session_state'] ?? ''),
                    'scope' => (string) ($tokenPayload['scope'] ?? ''),
                    'base_url' => $config['base_url'],
                ],
            ];

            Cache::put(
                $this->ssoLoginCodeKey($loginCode),
                $exchangePayload,
                now()->addSeconds(self::SSO_LOGIN_CODE_TTL_SECONDS)
            );

            if (($stateData['channel'] ?? 'mobile') === 'json') {
                return response()->json([
                    'login_code' => $loginCode,
                    'expires_in' => self::SSO_LOGIN_CODE_TTL_SECONDS,
                ]);
            }

            return redirect()->away($this->mobileCallbackUri().'?code='.urlencode($loginCode));
        } catch (RuntimeException $e) {
            return response()->json([
                'message' => $e->getMessage(),
            ], 422);
        }
    }

    public function ssoExchange(Request $request): JsonResponse
    {
        $validated = $request->validate([
            'code' => ['required', 'string'],
        ]);

        $payload = Cache::pull($this->ssoLoginCodeKey($validated['code']));
        if (! is_array($payload)) {
            return response()->json([
                'message' => 'Kode login SSO tidak valid atau sudah kedaluwarsa.',
            ], 422);
        }

        return response()->json($payload);
    }

    public function ssoMobileExchange(Request $request): JsonResponse
    {
        $validated = $request->validate([
            'id_token' => ['required', 'string'],
            'expires_in' => ['nullable', 'integer', 'min:0'],
            'refresh_expires_in' => ['nullable', 'integer', 'min:0'],
            'token_type' => ['nullable', 'string'],
            'scope' => ['nullable', 'string'],
            'session_state' => ['nullable', 'string'],
        ]);

        if ($configError = $this->ssoConfigError()) {
            return $configError;
        }

        $config = $this->keycloakConfig();

        try {
            $claims = $this->decodeJwtPayload($validated['id_token']);
            $user = $this->upsertSsoUser($claims);
            if (! (bool) ($user->is_active ?? true)) {
                return response()->json([
                    'message' => 'Akun Anda dinonaktifkan. Hubungi admin.',
                ], 403);
            }
            [$plainToken, $tokenRow] = $this->createApiToken($user, 'mobile_sso_token_exchange');

            $this->logAuthActivity($request, $user, 'auth.login', "SSO AppAuth login berhasil oleh {$user->email}", $tokenRow);

            return response()->json([
                'message' => 'Login SSO berhasil.',
                'token' => $plainToken,
                'token_type' => 'Bearer',
                'user' => $this->userPayload($user),
                'sso' => [
                    'expires_in' => (int) ($validated['expires_in'] ?? 0),
                    'refresh_expires_in' => (int) ($validated['refresh_expires_in'] ?? 0),
                    'token_type' => (string) ($validated['token_type'] ?? 'Bearer'),
                    'session_state' => (string) ($validated['session_state'] ?? ''),
                    'scope' => (string) ($validated['scope'] ?? ''),
                    'base_url' => $config['base_url'],
                ],
            ]);
        } catch (RuntimeException $e) {
            return response()->json([
                'message' => $e->getMessage(),
            ], 422);
        }
    }

    private function createApiToken(User $user, string $name = 'mobile'): array
    {
        $plainToken = Str::random(64);

        $token = ApiAccessToken::query()->create([
            'user_id' => $user->id,
            'name' => $name,
            'token_hash' => hash('sha256', $plainToken),
            'expires_at' => now()->addDays(30),
        ]);

        return [$plainToken, $token];
    }

    private function userPayload(User $user): array
    {
        $roleValue = null;
        if (Schema::hasColumn('users', 'role') && is_string($user->role ?? null)) {
            $roleValue = $user->role;
        } elseif (Schema::hasColumn('users', 'role_id') && Schema::hasTable('roles')) {
            $roleValue = $user->role?->name;
        }

        $authProvider = null;
        if (Schema::hasColumn('users', 'auth_provider')) {
            $authProvider = $user->auth_provider;
        } elseif (Schema::hasColumn('users', 'sso_provider')) {
            $authProvider = $user->sso_provider;
        }

        $ssoSubject = null;
        if (Schema::hasColumn('users', 'sso_subject')) {
            $ssoSubject = $user->sso_subject;
        } elseif (Schema::hasColumn('users', 'keycloak_sub')) {
            $ssoSubject = $user->keycloak_sub;
        }

        return [
            'id' => $user->id,
            'name' => $user->name,
            'email' => $user->email,
            'role' => $roleValue ?? 'user',
            'is_active' => (bool) ($user->is_active ?? true),
            'auth_provider' => $authProvider ?: 'local',
            'sso_subject' => $ssoSubject,
            'employee_id' => null,
        ];
    }

    private function logAuthActivity(
        Request $request,
        ?User $user,
        string $action,
        string $description,
        ?ApiAccessToken $token = null
    ): void {
        try {
            \App\Models\ActivityLog::createSafe([
                'user_id' => $user?->id,
                'event' => str_contains($action, 'logout') ? 'logout' : 'login',
                'action' => $action,
                'module' => 'auth',
                'description' => $description,
                'performed_at' => now(),
                'guard' => 'api',
                'role_name' => $this->resolveUserRoleName($user),
                'ip_address' => $request->ip(),
                'user_agent' => (string) $request->userAgent(),
                'login_identifier' => $user?->email,
                'occurred_at' => now(),
                'metadata' => [
                    'token_id' => $token?->id,
                ],
            ]);
        } catch (\Throwable) {
            // Do not block auth flow if activity log insert fails.
        }
    }

    private function exchangeAuthorizationCode(string $code, array $config, string $redirectUri): array
    {
        try {
            $response = Http::asForm()
                ->timeout(15)
                ->post($config['token_url'], [
                    'grant_type' => 'authorization_code',
                    'client_id' => $config['client_id'],
                    'client_secret' => $config['client_secret'],
                    'redirect_uri' => $redirectUri,
                    'code' => $code,
                ]);
        } catch (ConnectionException) {
            throw new RuntimeException('Tidak dapat terhubung ke server SSO.');
        }

        if (! $response->successful()) {
            throw new RuntimeException('Pertukaran authorization code ke provider SSO gagal.');
        }

        $json = $response->json();
        if (! is_array($json)) {
            throw new RuntimeException('Respons token SSO tidak valid.');
        }

        return $json;
    }

    private function fetchUserInfo(string $accessToken, array $config): array
    {
        if ($accessToken === '') {
            throw new RuntimeException('Access token dari provider SSO kosong.');
        }

        try {
            $response = Http::withToken($accessToken)
                ->timeout(15)
                ->get($config['userinfo_url']);
        } catch (ConnectionException) {
            throw new RuntimeException('Tidak dapat mengambil profil user dari provider SSO.');
        }

        if (! $response->successful()) {
            throw new RuntimeException('Gagal mengambil profil user dari provider SSO.');
        }

        $profile = $response->json();
        if (! is_array($profile)) {
            throw new RuntimeException('Respons profil user SSO tidak valid.');
        }

        return $profile;
    }

    private function upsertSsoUser(array $claims): User
    {
        $subject = trim((string) ($claims['sub'] ?? ''));
        if ($subject === '') {
            throw new RuntimeException('Subject (sub) pada token SSO tidak valid.');
        }

        $email = strtolower(trim((string) ($claims['email'] ?? '')));
        if ($email === '') {
            $username = trim((string) ($claims['preferred_username'] ?? ''));
            $email = $username !== '' ? strtolower($username).'@sso.local' : strtolower($subject).'@sso.local';
        }

        $name = trim((string) ($claims['name'] ?? ''));
        if ($name === '') {
            $name = trim((string) ($claims['preferred_username'] ?? $email));
        }
        if ($name === '') {
            $name = 'SSO User';
        }

        $roleName = 'user';
        $roleId = null;
        if (Schema::hasColumn('users', 'role_id') && Schema::hasTable('roles')) {
            $roleId = Role::query()->firstOrCreate(['name' => $roleName])->id;
        }

        $user = User::query()
            ->when(
                Schema::hasColumn('users', 'keycloak_sub'),
                fn ($q) => $q->where('keycloak_sub', $subject),
                fn ($q) => $q->where('sso_subject', $subject)
            )
            ->orWhere('email', $email)
            ->first();

        if ($user === null) {
            $payload = [
                'name' => $name,
                'email' => $email,
                'password' => Str::random(48),
                'is_active' => true,
            ];

            if (Schema::hasColumn('users', 'role')) {
                $payload['role'] = $roleName;
            }
            if ($roleId !== null) {
                $payload['role_id'] = $roleId;
            }

            if (Schema::hasColumn('users', 'sso_subject')) {
                $payload['sso_subject'] = $subject;
            } elseif (Schema::hasColumn('users', 'keycloak_sub')) {
                $payload['keycloak_sub'] = $subject;
            }

            if (Schema::hasColumn('users', 'auth_provider')) {
                $payload['auth_provider'] = 'keycloak';
            } elseif (Schema::hasColumn('users', 'sso_provider')) {
                $payload['sso_provider'] = 'keycloak';
            }

            return User::query()->create($payload);
        }

        $payload = [
            'name' => $name,
            'email' => $email,
        ];

        if (Schema::hasColumn('users', 'sso_subject')) {
            $payload['sso_subject'] = $subject;
        } elseif (Schema::hasColumn('users', 'keycloak_sub')) {
            $payload['keycloak_sub'] = $subject;
        }

        if (Schema::hasColumn('users', 'auth_provider')) {
            $payload['auth_provider'] = 'keycloak';
        } elseif (Schema::hasColumn('users', 'sso_provider')) {
            $payload['sso_provider'] = 'keycloak';
        }

        $user->forceFill($payload)->save();

        return $user;
    }

    private function resolveUserRoleName(?User $user): ?string
    {
        if ($user === null) {
            return null;
        }

        if (Schema::hasColumn('users', 'role') && is_string($user->role ?? null)) {
            return $user->role;
        }

        if (Schema::hasColumn('users', 'role_id') && Schema::hasTable('roles')) {
            return $user->role?->name;
        }

        return null;
    }

    private function isSuperAdmin(User $user): bool
    {
        return strtolower((string) ($this->resolveUserRoleName($user) ?? '')) === 'super_admin';
    }

    private function canManageUserActive(User $user): bool
    {
        $role = strtolower((string) ($this->resolveUserRoleName($user) ?? ''));
        return in_array($role, ['super_admin', 'admin'], true);
    }

    private function canViewUserDirectory(User $user): bool
    {
        return $this->canManageUserActive($user);
    }

    private function extractRoles(array $claims): array
    {
        $roles = [];

        if (isset($claims['roles']) && is_array($claims['roles'])) {
            $roles = array_merge($roles, $claims['roles']);
        }

        $realmRoles = $claims['realm_access']['roles'] ?? null;
        if (is_array($realmRoles)) {
            $roles = array_merge($roles, $realmRoles);
        }

        $clientId = (string) env('KEYCLOAK_CLIENT_ID', '');
        $resourceRoles = $claims['resource_access'][$clientId]['roles'] ?? null;
        if (is_array($resourceRoles)) {
            $roles = array_merge($roles, $resourceRoles);
        }

        return array_values(array_unique(array_filter(array_map(
            static fn ($role) => is_string($role) ? strtolower(trim($role)) : '',
            $roles
        ))));
    }

    private function mapRole(array $roles): string
    {
        if (
            in_array('super_admin', $roles, true)
            || in_array('super-admin', $roles, true)
            || in_array('superadmin', $roles, true)
        ) {
            return 'super_admin';
        }

        if (in_array('admin', $roles, true)) {
            return 'admin';
        }

        return 'user';
    }

    private function decodeJwtPayload(string $jwt): array
    {
        $parts = explode('.', $jwt);
        if (count($parts) !== 3) {
            throw new RuntimeException('Format ID token tidak valid.');
        }

        // Attempt cryptographic verification using Keycloak public key.
        $publicKey = trim((string) config('services.keycloak.public_key', env('KEYCLOAK_PUBLIC_KEY', '')));

        if ($publicKey !== '') {
            // Wrap raw key in PEM format if not already wrapped.
            if (! str_contains($publicKey, '-----BEGIN')) {
                $publicKey = "-----BEGIN PUBLIC KEY-----\n"
                    . wordwrap($publicKey, 64, "\n", true)
                    . "\n-----END PUBLIC KEY-----";
            }

            try {
                $decoded = \Firebase\JWT\JWT::decode(
                    $jwt,
                    new \Firebase\JWT\Key($publicKey, 'RS256')
                );

                return (array) $decoded;
            } catch (\Throwable $e) {
                throw new RuntimeException('Verifikasi signature ID token gagal: ' . $e->getMessage());
            }
        }

        // Fallback: decode without verification only in development.
        if (! app()->environment('production')) {
            $payloadJson = $this->base64UrlDecode($parts[1]);
            if ($payloadJson === '') {
                throw new RuntimeException('Payload ID token tidak dapat didekode.');
            }

            $payload = json_decode($payloadJson, true);
            if (! is_array($payload)) {
                throw new RuntimeException('Payload ID token tidak valid.');
            }

            return $payload;
        }

        throw new RuntimeException('KEYCLOAK_PUBLIC_KEY belum dikonfigurasi. Verifikasi JWT tidak dapat dilakukan.');
    }

    private function ssoConfigError(): ?JsonResponse
    {
        $required = [
            'KEYCLOAK_BASE_URL' => env('KEYCLOAK_BASE_URL'),
            'KEYCLOAK_REALM' => env('KEYCLOAK_REALM'),
            'KEYCLOAK_CLIENT_ID' => env('KEYCLOAK_CLIENT_ID'),
            'KEYCLOAK_CLIENT_SECRET' => env('KEYCLOAK_CLIENT_SECRET'),
        ];

        $missing = [];
        foreach ($required as $key => $value) {
            if (! is_string($value) || trim($value) === '') {
                $missing[] = $key;
            }
        }

        if ($missing === []) {
            return null;
        }

        return response()->json([
            'message' => 'Konfigurasi SSO belum lengkap.',
            'missing' => $missing,
        ], 500);
    }

    private function keycloakConfig(): array
    {
        $baseUrl = rtrim((string) env('KEYCLOAK_BASE_URL', ''), '/');
        $realm = trim((string) env('KEYCLOAK_REALM', ''));

        return [
            'base_url' => $baseUrl,
            'realm' => $realm,
            'authorize_url' => $baseUrl.'/realms/'.$realm.'/protocol/openid-connect/auth',
            'token_url' => $baseUrl.'/realms/'.$realm.'/protocol/openid-connect/token',
            'userinfo_url' => $baseUrl.'/realms/'.$realm.'/protocol/openid-connect/userinfo',
            'client_id' => trim((string) env('KEYCLOAK_CLIENT_ID', '')),
            'client_secret' => trim((string) env('KEYCLOAK_CLIENT_SECRET', '')),
        ];
    }

    private function resolveApiRedirectUri(Request $request): string
    {
        $configured = trim((string) env('KEYCLOAK_API_REDIRECT_URI', env('KEYCLOAK_REDIRECT_URI', '')));
        $current = rtrim($request->getSchemeAndHttpHost(), '/').'/api/v1/auth/sso/callback';

        if ($configured === '') {
            return $current;
        }

        $configuredHost = parse_url($configured, PHP_URL_HOST);
        $requestHost = $request->getHost();
        $isConfiguredLocal =
            in_array($configuredHost, ['localhost', '127.0.0.1', '10.0.2.2'], true);
        $isRequestLocal =
            in_array($requestHost, ['localhost', '127.0.0.1', '10.0.2.2'], true);

        if ($isConfiguredLocal && ! $isRequestLocal) {
            return $current;
        }

        return $configured;
    }

    private function mobileCallbackUri(): string
    {
        $explicit = trim((string) env('APP_MOBILE_CALLBACK_URI', ''));
        if ($explicit !== '') {
            return $explicit;
        }

        $scheme = rtrim(trim((string) env('APP_MOBILE_CALLBACK_SCHEME', 'buncop')), ':/');
        return $scheme.'://auth/callback';
    }

    private function mobileLogoutCallbackUri(): string
    {
        $explicit = trim((string) env('APP_MOBILE_LOGOUT_CALLBACK_URI', ''));
        if ($explicit !== '') {
            return $explicit;
        }

        $scheme = rtrim(trim((string) env('APP_MOBILE_CALLBACK_SCHEME', 'buncop')), ':/');
        return $scheme.'://auth/logout-callback';
    }

    private function base64UrlDecode(string $value): string
    {
        $replaced = strtr($value, '-_', '+/');
        $padding = strlen($replaced) % 4;
        if ($padding > 0) {
            $replaced .= str_repeat('=', 4 - $padding);
        }

        $decoded = base64_decode($replaced, true);
        return is_string($decoded) ? $decoded : '';
    }

    private function ssoStateKey(string $state): string
    {
        return 'auth:sso:state:'.$state;
    }

    private function ssoLoginCodeKey(string $code): string
    {
        return 'auth:sso:code:'.$code;
    }

    private function renderMobileCallbackPage(string $callbackUri, string $loginCode): Response
    {
        $deepLink = $callbackUri.'?code='.urlencode($loginCode);
        $escapedDeepLink = htmlspecialchars($deepLink, ENT_QUOTES, 'UTF-8');

        $html = <<<HTML
<!doctype html>
<html lang="id">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Login Berhasil</title>
  <style>
    body { font-family: Arial, sans-serif; background:#0f172a; color:#e2e8f0; display:flex; min-height:100vh; align-items:center; justify-content:center; margin:0; }
    .card { max-width:420px; background:#111827; border:1px solid #374151; border-radius:12px; padding:20px; text-align:center; }
    .btn { display:inline-block; margin-top:12px; padding:10px 14px; border-radius:10px; text-decoration:none; background:#16a34a; color:white; font-weight:600; }
    p { margin:8px 0; }
    code { word-break:break-all; font-size:12px; color:#93c5fd; }
  </style>
</head>
<body>
  <div class="card">
    <h2>Login SSO Berhasil</h2>
    <p>Mencoba membuka aplikasi kembali...</p>
    <a class="btn" href="{$escapedDeepLink}">Buka Aplikasi</a>
    <p>Jika tidak otomatis, tekan tombol di atas.</p>
    <code>{$escapedDeepLink}</code>
  </div>
  <script>
    window.location.replace("{$escapedDeepLink}");
    setTimeout(function () { window.location.href = "{$escapedDeepLink}"; }, 700);
  </script>
</body>
</html>
HTML;

        return response($html, 200, ['Content-Type' => 'text/html; charset=UTF-8']);
    }
}
