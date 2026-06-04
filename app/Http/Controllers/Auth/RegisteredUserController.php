<?php

namespace App\Http\Controllers\Auth;

use App\Http\Controllers\Controller;
use App\Models\Role;
use App\Models\User;
use Illuminate\Auth\Events\Registered;
use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Hash;
use Illuminate\Support\Facades\Schema;
use Illuminate\View\View;

class RegisteredUserController extends Controller
{
    /**
     * Display the registration view.
     */
    public function create(): View
    {
        return view('auth.register');
    }

    /**
     * Handle an incoming registration request.
     *
     * @throws \Illuminate\Validation\ValidationException
     */
    public function store(Request $request): RedirectResponse
    {
        $request->validate([
            'name' => ['required', 'string', 'max:255'],
            'email' => ['required', 'string', 'lowercase', 'email', 'max:255', 'unique:'.User::class],
            'password' => ['required', 'string', 'min:6'],
        ]);

        $roleName = 'user';

        $payload = [
            'name' => $request->name,
            'email' => $request->email,
            'password' => Hash::make($request->password),
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

        $user = User::create($payload);

        event(new Registered($user));

        return redirect()
            ->route('login')
            ->with('status', 'Registrasi berhasil. Silakan login.');
    }
}
