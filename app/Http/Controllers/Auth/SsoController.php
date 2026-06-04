<?php

namespace App\Http\Controllers\Auth;

use App\Http\Controllers\Controller;
use App\Models\ActivityLog;
use App\Models\Role;
use App\Models\User;
use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Request;
use Illuminate\Http\Client\ConnectionException;
use Illuminate\Http\Client\PendingRequest;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;

class SsoController extends Controller
{
    public function redirect(Request $request): RedirectResponse
    {
        $state = Str::random(40);
        $redirectUri = $this->resolveRedirectUri($request);

        $states = $request->session()->get('sso_states', []);
        $states = is_array($states) ? $states : [];

        // Keep only recent states (10 minutes) to avoid stale growth.
        $now = time();
        $states = array_filter($states, function ($item) use ($now) {
            if (! is_array($item)) {
                return false;
            }

            $createdAt = (int) ($item['created_at'] ?? 0);

            return $createdAt > 0 && ($now - $createdAt) <= 600;
        });

        $states[$state] = [
            'created_at' => $now,
            'redirect_uri' => $redirectUri,
        ];
        $request->session()->put('sso_states', $states);
        Cache::put($this->stateCacheKey($state), $states[$state], now()->addMinutes(10));

        $url = $this->oidcBaseUrl().'/auth?'.http_build_query([
            'client_id' => config('services.keycloak.client_id'),
            'redirect_uri' => $redirectUri,
            'response_type' => 'code',
            'scope' => 'openid profile email',
            'state' => $state,
        ]);

        return redirect()->away($url);
    }

    public function callback(Request $request): RedirectResponse
    {
        $incomingState = (string) $request->query('state', '');
        $states = $request->session()->get('sso_states', []);
        $states = is_array($states) ? $states : [];
        $stateData = $incomingState !== '' ? ($states[$incomingState] ?? null) : null;
        if (! is_array($stateData) && $incomingState !== '') {
            $cached = Cache::pull($this->stateCacheKey($incomingState));
            $stateData = is_array($cached) ? $cached : null;
        }

        if ($incomingState === '' || ! is_array($stateData)) {
            return redirect()->route('login')->withErrors(['email' => 'SSO gagal: state tidak valid.']);
        }

        unset($states[$incomingState]);
        $request->session()->put('sso_states', $states);
        Cache::forget($this->stateCacheKey($incomingState));

        $redirectUri = (string) ($stateData['redirect_uri'] ?? $this->resolveRedirectUri($request));

        if ($request->filled('error')) {
            return redirect()->route('login')->withErrors([
                'email' => 'SSO ditolak: '.$request->query('error_description', $request->query('error')),
            ]);
        }

        $code = (string) $request->query('code', '');
        if ($code === '') {
            return redirect()->route('login')->withErrors(['email' => 'SSO gagal: authorization code tidak ditemukan.']);
        }

        try {
            $tokenResponse = $this->keycloakHttp()->asForm()->post($this->oidcBaseUrl().'/token', [
                'grant_type' => 'authorization_code',
                'client_id' => config('services.keycloak.client_id'),
                'client_secret' => config('services.keycloak.client_secret'),
                'code' => $code,
                'redirect_uri' => $redirectUri,
            ]);
        } catch (ConnectionException) {
            return redirect()->route('login')->withErrors([
                'email' => 'SSO gagal: tidak bisa terhubung ke server Keycloak (cek SSL/sertifikat intranet).',
            ]);
        }

        if (! $tokenResponse->successful()) {
            return redirect()->route('login')->withErrors(['email' => 'SSO gagal: token endpoint tidak merespons dengan benar.']);
        }

        $tokenData = $tokenResponse->json();
        $accessToken = (string) ($tokenData['access_token'] ?? '');
        $idToken = (string) ($tokenData['id_token'] ?? '');

        if ($accessToken === '') {
            return redirect()->route('login')->withErrors(['email' => 'SSO gagal: access token kosong.']);
        }

        try {
            $userInfoResponse = $this->keycloakHttp()->withToken($accessToken)->get($this->oidcBaseUrl().'/userinfo');
        } catch (ConnectionException) {
            return redirect()->route('login')->withErrors([
                'email' => 'SSO gagal: koneksi ke userinfo Keycloak terputus (cek SSL/sertifikat intranet).',
            ]);
        }

        if (! $userInfoResponse->successful()) {
            return redirect()->route('login')->withErrors(['email' => 'SSO gagal: tidak bisa mengambil data user.']);
        }

        $profile = $userInfoResponse->json();
        $email = strtolower((string) ($profile['email'] ?? ''));
        $sub = (string) ($profile['sub'] ?? '');
        $name = (string) ($profile['name'] ?? $profile['preferred_username'] ?? 'User SSO');

        if ($email === '') {
            $username = (string) ($profile['preferred_username'] ?? '');
            $email = $username !== '' ? strtolower($username).'@sso.local' : '';
        }

        if ($email === '' || $sub === '') {
            return redirect()->route('login')->withErrors(['email' => 'SSO gagal: profile email/sub tidak valid.']);
        }

        $user = User::query();
        if (Schema::hasColumn('users', 'keycloak_sub')) {
            $user->where('keycloak_sub', $sub);
        } elseif (Schema::hasColumn('users', 'sso_subject')) {
            $user->where('sso_subject', $sub);
        }
        $user = $user->orWhere('email', $email)->first();

        if (! $user) {
            $payload = [
                'name' => $name,
                'email' => $email,
                'password' => Str::random(40),
                'is_active' => true,
                'email_verified_at' => now(),
            ];

            if (Schema::hasColumn('users', 'role_id') && Schema::hasTable('roles')) {
                $payload['role_id'] = Role::query()->firstOrCreate(['name' => 'user'])->id;
            }
            if (Schema::hasColumn('users', 'role')) {
                $payload['role'] = 'user';
            }

            if (Schema::hasColumn('users', 'keycloak_sub')) {
                $payload['keycloak_sub'] = $sub;
            }
            if (Schema::hasColumn('users', 'sso_subject')) {
                $payload['sso_subject'] = $sub;
            }

            if (Schema::hasColumn('users', 'sso_provider')) {
                $payload['sso_provider'] = 'keycloak';
            }
            if (Schema::hasColumn('users', 'auth_provider')) {
                $payload['auth_provider'] = 'keycloak';
            }

            $user = User::create($payload);
        } else {
            $payload = [
                'name' => $name ?: $user->name,
                'email' => $email ?: $user->email,
            ];

            if (Schema::hasColumn('users', 'keycloak_sub')) {
                $payload['keycloak_sub'] = $sub;
            }
            if (Schema::hasColumn('users', 'sso_subject')) {
                $payload['sso_subject'] = $sub;
            }
            if (Schema::hasColumn('users', 'sso_provider')) {
                $payload['sso_provider'] = 'keycloak';
            }
            if (Schema::hasColumn('users', 'auth_provider')) {
                $payload['auth_provider'] = 'keycloak';
            }

            $user->forceFill($payload)->save();
        }

        if (! (bool) ($user->is_active ?? true)) {
            return redirect()->route('login')->withErrors([
                'email' => 'Akun Anda dinonaktifkan. Hubungi admin.',
            ]);
        }

        Auth::login($user, true);
        $request->session()->regenerate();
        $request->session()->put('sso_id_token', $idToken);
        $request->session()->put('sso_login', true);
        $request->session()->put('sso_provider', 'keycloak');

        ActivityLog::createSafe([
            'user_id' => $user->id,
            'module' => 'auth',
            'action' => 'auth.login',
            'description' => "Login via web (SSO Keycloak) - {$user->email}",
            'guard' => 'web',
            'login_identifier' => $user->email,
            'ip_address' => $request->ip(),
            'user_agent' => $request->userAgent(),
        ]);

        return redirect()->intended(route('home', absolute: false));
    }

    private function oidcBaseUrl(): string
    {
        $baseUrl = rtrim((string) config('services.keycloak.base_url'), '/');
        $realm = trim((string) config('services.keycloak.realm'), '/');

        return $baseUrl.'/realms/'.$realm.'/protocol/openid-connect';
    }

    private function resolveRedirectUri(Request $request): string
    {
        $configured = trim((string) config('services.keycloak.redirect'));
        $current = route('sso.callback', absolute: true);

        if ($configured === '') {
            return $current;
        }

        $configuredHost = parse_url($configured, PHP_URL_HOST);
        $requestHost = $request->getHost();
        $isConfiguredLocal = in_array($configuredHost, ['localhost', '127.0.0.1', '10.0.2.2'], true);
        $isRequestLocal = in_array($requestHost, ['localhost', '127.0.0.1', '10.0.2.2'], true);

        if ($isConfiguredLocal && ! $isRequestLocal) {
            return $current;
        }

        return $configured;
    }

    private function keycloakHttp(): PendingRequest
    {
        $verify = filter_var(config('services.keycloak.verify_ssl', true), FILTER_VALIDATE_BOOL);
        $caBundle = trim((string) config('services.keycloak.ca_bundle', ''));

        if ($caBundle !== '') {
            return Http::withOptions(['verify' => $caBundle])->timeout(20);
        }

        return Http::withOptions(['verify' => $verify])->timeout(20);
    }

    private function stateCacheKey(string $state): string
    {
        return 'sso_state:'.$state;
    }
}
