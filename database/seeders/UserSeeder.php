<?php

namespace Database\Seeders;

use Illuminate\Database\Seeder;
use App\Models\User;
use App\Models\Role;
use Illuminate\Support\Facades\Hash;

class UserSeeder extends Seeder
{
    public function run()
    {
        $superadminRole = Role::query()->where('name', 'super_admin')->firstOrFail();

        // Keep seed minimal: only bootstrap super admin account.
        User::query()
            ->whereIn('email', ['admin@vitaroot.local', 'user@vitaroot.local'])
            ->delete();

        User::query()->updateOrCreate(['email' => 'superadmin@vitaroot.local'], [
            'name' => 'Super Admin',
            'email' => 'superadmin@vitaroot.local',
            'password' => Hash::make('password123'),
            'is_active' => true,
            'role_id' => $superadminRole->id,
            'auth_provider' => 'local',
        ]);
    }
}
