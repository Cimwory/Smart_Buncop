<?php

namespace App\Providers;

use App\Models\ActivityLog;
use App\Models\User;
use Illuminate\Auth\Events\Failed;
use Illuminate\Auth\Events\Login;
use Illuminate\Auth\Events\Logout;
use Illuminate\Contracts\Auth\Authenticatable;
use Illuminate\Support\Arr;
use Illuminate\Support\Facades\Event;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\ServiceProvider;

class AppServiceProvider extends ServiceProvider
{
    /**
     * Register any application services.
     */
    public function register(): void
    {
        //
    }

    /**
     * Bootstrap any application services.
     */
    public function boot(): void
    {
        Event::listen(Login::class, function (Login $event): void {
            $this->logAuthEvent(
                event: 'login',
                user: $event->user,
                guard: $event->guard,
                action: 'auth_login_success'
            );
        });

        Event::listen(Logout::class, function (Logout $event): void {
            $this->logAuthEvent(
                event: 'logout',
                user: $event->user,
                guard: $event->guard,
                action: 'auth_logout'
            );
        });

        Event::listen(Failed::class, function (Failed $event): void {
            $identifier = Arr::get($event->credentials, 'email')
                ?? Arr::get($event->credentials, 'username')
                ?? Arr::get($event->credentials, 'login');

            $this->logAuthEvent(
                event: 'login_failed',
                user: $event->user,
                guard: $event->guard,
                action: 'auth_login_failed',
                identifier: is_string($identifier) ? $identifier : null
            );
        });
    }

    private function logAuthEvent(
        string $event,
        ?Authenticatable $user,
        ?string $guard = null,
        ?string $action = null,
        ?string $identifier = null
    ): void {
        if (! Schema::hasTable('activity_logs')) {
            return;
        }

        $request = app()->bound('request') ? app('request') : null;
        $userId = $user?->getAuthIdentifier();
        $roleName = null;

        if ($userId) {
            $userModel = User::query()->find($userId);
            if ($userModel !== null) {
                if (Schema::hasColumn('users', 'role') && is_string($userModel->role)) {
                    $roleName = $userModel->role;
                } elseif (Schema::hasColumn('users', 'role_id') && Schema::hasTable('roles')) {
                    $roleName = $userModel->role?->name;
                }
            }
        }

        try {
            ActivityLog::createSafe([
                'user_id' => $userId,
                'event' => $event,
                'action' => $action,
                'guard' => $guard,
                'role_name' => $roleName,
                'route_name' => $request?->route()?->getName(),
                'url' => $request?->fullUrl(),
                'http_method' => $request?->method(),
                'status_code' => null,
                'login_identifier' => $identifier ?? (is_string($user?->email ?? null) ? $user->email : null),
                'ip_address' => $request?->ip(),
                'user_agent' => $request?->userAgent(),
                'occurred_at' => now(),
            ]);
        } catch (\Throwable) {
            // Do not block auth flow if logging fails.
        }
    }
}
