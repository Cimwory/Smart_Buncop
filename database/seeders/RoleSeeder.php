<?php

namespace Database\Seeders;

use Illuminate\Database\Seeder;
use App\Models\Role;

class RoleSeeder extends Seeder
{
    public function run()
    {
        Role::query()->updateOrCreate(['name' => 'super_admin']);
        Role::query()->updateOrCreate(['name' => 'admin']);
        Role::query()->updateOrCreate(['name' => 'user']);
    }
}
