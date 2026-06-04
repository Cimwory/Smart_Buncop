<?php

namespace App\Http\Controllers\Auth;

use App\Http\Controllers\Controller;
use App\Models\Role;
use App\Models\User;
use App\Http\Requests\Auth\LoginRequest;
use App\Models\ActivityLog;
use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;
use Illuminate\View\View;

class AuthenticatedSessionController extends Controller
{
    /**
     * Display the login view.
     */
    public function create(): View
    {
        return view('auth.login');
    }

    /**
     * Handle an incoming authentication request.
     */
    public function store(LoginRequest $request): RedirectResponse
    {
        $request->authenticate();

        $request->session()->regenerate();

        $user = $request->user();
        if ($user) {
            ActivityLog::createSafe([
                'user_id' => $user->id,
                'event' => 'login',
                'module' => 'auth',
                'action' => 'auth.login',
                'description' => "Login via web (email/password) - {$user->email}",
                'guard' => 'web',
                'login_identifier' => $user->email,
                'ip_address' => $request->ip(),
                'user_agent' => $request->userAgent(),
            ]);
        }

        return redirect()->intended(route('home', absolute: false));
    }

    /**
     * Destroy an authenticated session.
     */
    public function destroy(Request $request): RedirectResponse
    {
        $user = $request->user();
        if ($user) {
            ActivityLog::createSafe([
                'user_id' => $user->id,
                'event' => 'logout',
                'module' => 'auth',
                'action' => 'auth.logout',
                'description' => "Logout dari web - {$user->email}",
                'guard' => 'web',
                'login_identifier' => $user->email,
                'ip_address' => $request->ip(),
                'user_agent' => $request->userAgent(),
            ]);
        }

        $idToken = $request->session()->get('sso_id_token');
        $isSsoLogin = (bool) $request->session()->get('sso_login', false);

        Auth::guard('web')->logout();

        $request->session()->invalidate();

        $request->session()->regenerateToken();

        $logoutUrl = (string) config('services.keycloak.logout_url');
        $postLogoutRedirect = route('login', absolute: true);
        if ($isSsoLogin && $logoutUrl !== '') {
            $showConfirmPage = filter_var(config('services.keycloak.logout_confirm', true), FILTER_VALIDATE_BOOL);
            $queryParams = [
                'client_id' => config('services.keycloak.client_id'),
                'post_logout_redirect_uri' => $postLogoutRedirect,
                // Compatibility for some Keycloak deployments.
                'redirect_uri' => $postLogoutRedirect,
            ];

            // If confirmation page is disabled, use id_token_hint for direct logout.
            if (! $showConfirmPage && $idToken) {
                $queryParams['id_token_hint'] = $idToken;
            }

            $query = http_build_query($queryParams);

            return redirect()->away(rtrim($logoutUrl, '?').'?'.$query);
        }

        return redirect('/');
    }

    /**
     * Log in using a guest account.
     */
    public function guest(Request $request): RedirectResponse
    {
        $payload = [
            'name' => 'Guest User',
            'email' => 'guest@vitaroot.local',
            'password' => Str::random(40),
        ];

        if (Schema::hasColumn('users', 'is_active')) {
            $payload['is_active'] = true;
        }
        if (Schema::hasColumn('users', 'auth_provider')) {
            $payload['auth_provider'] = 'local';
        }
        if (Schema::hasColumn('users', 'role_id') && Schema::hasTable('roles')) {
            $payload['role_id'] = Role::query()->firstOrCreate(['name' => 'user'])->id;
        }

        $guest = User::query()->firstOrCreate(
            ['email' => 'guest@vitaroot.local'],
            $payload
        );

        if (Schema::hasColumn('users', 'is_active') && ! (bool) ($guest->is_active ?? true)) {
            $guest->forceFill(['is_active' => true])->save();
        }

        Auth::login($guest, false);
        $request->session()->regenerate();

        return redirect()->intended(route('home', absolute: false));
    }
}
