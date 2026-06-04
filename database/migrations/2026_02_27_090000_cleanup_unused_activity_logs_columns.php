<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        if (! Schema::hasTable('activity_logs')) {
            return;
        }

        // Some drivers (notably SQLite in tests) require dropping indexes first.
        foreach ([
            'activity_logs_auth_provider_index',
            'activity_logs_session_id_index',
            'activity_logs_token_jti_index',
        ] as $indexName) {
            try {
                DB::statement("DROP INDEX IF EXISTS {$indexName}");
            } catch (\Throwable) {
                // Ignore if index does not exist for current schema variant.
            }
        }

        Schema::table('activity_logs', function (Blueprint $table): void {
            $dropColumns = [];
            foreach (['actor_role', 'auth_provider', 'session_id', 'token_jti'] as $column) {
                if (Schema::hasColumn('activity_logs', $column)) {
                    $dropColumns[] = $column;
                }
            }

            if ($dropColumns !== []) {
                $table->dropColumn($dropColumns);
            }
        });
    }

    public function down(): void
    {
        if (! Schema::hasTable('activity_logs')) {
            return;
        }

        Schema::table('activity_logs', function (Blueprint $table): void {
            if (! Schema::hasColumn('activity_logs', 'actor_role')) {
                $table->string('actor_role', 20)->nullable()->after('user_id');
            }
            if (! Schema::hasColumn('activity_logs', 'auth_provider')) {
                $table->string('auth_provider', 50)->nullable()->after('updated_at');
            }
            if (! Schema::hasColumn('activity_logs', 'session_id')) {
                $table->string('session_id', 128)->nullable()->after('auth_provider');
            }
            if (! Schema::hasColumn('activity_logs', 'token_jti')) {
                $table->string('token_jti', 128)->nullable()->after('session_id');
            }
        });
    }
};
