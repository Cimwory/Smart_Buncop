<?php

use App\Models\Role;
use Illuminate\Database\Migrations\Migration;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        if (! Schema::hasTable('users')) {
            return;
        }

        if (Schema::hasColumn('users', 'role') && Schema::hasColumn('users', 'role_id') && Schema::hasTable('roles')) {
            $roleNames = DB::table('users')
                ->whereNotNull('role')
                ->select('role')
                ->distinct()
                ->pluck('role')
                ->filter(fn ($name) => is_string($name) && trim($name) !== '');

            foreach ($roleNames as $roleName) {
                $normalized = strtolower(trim((string) $roleName));
                if ($normalized === '') {
                    continue;
                }
                $roleId = Role::query()->firstOrCreate(['name' => $normalized])->id;
                DB::table('users')
                    ->whereNull('role_id')
                    ->where('role', $roleName)
                    ->update(['role_id' => $roleId]);
            }

            $defaultRoleId = Role::query()->firstOrCreate(['name' => 'user'])->id;
            DB::table('users')->whereNull('role_id')->update(['role_id' => $defaultRoleId]);
        }

        if (Schema::hasColumn('users', 'sso_subject') && Schema::hasColumn('users', 'keycloak_sub')) {
            DB::table('users')
                ->whereNull('sso_subject')
                ->whereNotNull('keycloak_sub')
                ->update(['sso_subject' => DB::raw('keycloak_sub')]);
        }

        if (DB::getDriverName() === 'sqlite') {
            foreach (['users_role_index', 'users_keycloak_sub_unique', 'users_sso_provider_index'] as $indexName) {
                try {
                    DB::statement("DROP INDEX IF EXISTS {$indexName}");
                } catch (\Throwable) {
                    // ignore
                }
            }
        }

        foreach (['role', 'keycloak_sub', 'sso_provider'] as $column) {
            if (! Schema::hasColumn('users', $column)) {
                continue;
            }
            try {
                DB::statement("ALTER TABLE users DROP COLUMN {$column}");
            } catch (\Throwable) {
                // ignore to keep migration idempotent across schema variants
            }
        }
    }

    public function down(): void
    {
        // No-op. This is a hard normalization migration.
    }
};

