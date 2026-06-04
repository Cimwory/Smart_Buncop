<?php

use App\Models\Role;
use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
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
            DB::table('users')
                ->whereNull('role_id')
                ->update(['role_id' => $defaultRoleId]);
        }

        if (Schema::hasColumn('users', 'sso_subject') && Schema::hasColumn('users', 'keycloak_sub')) {
            DB::table('users')
                ->whereNull('sso_subject')
                ->whereNotNull('keycloak_sub')
                ->update(['sso_subject' => DB::raw('keycloak_sub')]);
        }

        if (DB::getDriverName() === 'sqlite') {
            foreach ([
                'users_role_index',
                'users_keycloak_sub_unique',
                'users_sso_provider_index',
            ] as $indexName) {
                try {
                    DB::statement("DROP INDEX IF EXISTS {$indexName}");
                } catch (\Throwable) {
                    // Ignore schema differences across drivers.
                }
            }
        }

        $dropColumns = [];
        foreach (['role', 'keycloak_sub', 'sso_provider'] as $column) {
            if (Schema::hasColumn('users', $column)) {
                $dropColumns[] = $column;
            }
        }

        if ($dropColumns !== []) {
            Schema::table('users', function (Blueprint $table) use ($dropColumns): void {
                $table->dropColumn($dropColumns);
            });
        }
    }

    public function down(): void
    {
        if (! Schema::hasTable('users')) {
            return;
        }

        Schema::table('users', function (Blueprint $table): void {
            if (! Schema::hasColumn('users', 'role')) {
                $table->string('role', 20)->default('user')->after('password');
                $table->index('role');
            }
            if (! Schema::hasColumn('users', 'keycloak_sub')) {
                $table->string('keycloak_sub')->nullable()->after('email')->unique();
            }
            if (! Schema::hasColumn('users', 'sso_provider')) {
                $table->string('sso_provider')->nullable()->after('keycloak_sub');
            }
        });
    }
};
