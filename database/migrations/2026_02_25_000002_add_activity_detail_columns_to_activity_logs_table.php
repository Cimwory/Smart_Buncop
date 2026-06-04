<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * Run the migrations.
     */
    public function up(): void
    {
        Schema::table('activity_logs', function (Blueprint $table) {
            if (! Schema::hasColumn('activity_logs', 'action')) {
                $table->string('action', 100)->nullable()->after('event');
            }

            if (! Schema::hasColumn('activity_logs', 'role_name')) {
                $table->string('role_name', 100)->nullable()->after('guard');
            }

            if (! Schema::hasColumn('activity_logs', 'route_name')) {
                $table->string('route_name')->nullable()->after('role_name');
            }

            if (! Schema::hasColumn('activity_logs', 'url')) {
                $table->text('url')->nullable()->after('route_name');
            }

            if (! Schema::hasColumn('activity_logs', 'http_method')) {
                $table->string('http_method', 10)->nullable()->after('url');
            }

            if (! Schema::hasColumn('activity_logs', 'status_code')) {
                $table->unsignedSmallInteger('status_code')->nullable()->after('http_method');
            }
        });
    }

    /**
     * Reverse the migrations.
     */
    public function down(): void
    {
        Schema::table('activity_logs', function (Blueprint $table) {
            foreach (['action', 'role_name', 'route_name', 'url', 'http_method', 'status_code'] as $column) {
                if (Schema::hasColumn('activity_logs', $column)) {
                    $table->dropColumn($column);
                }
            }
        });
    }
};
