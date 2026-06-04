<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('activity_logs', function (Blueprint $table) {
            if (! Schema::hasColumn('activity_logs', 'module')) {
                $table->string('module', 60)->nullable()->after('action');
            }

            if (! Schema::hasColumn('activity_logs', 'device_id')) {
                $table->string('device_id', 120)->nullable()->after('module');
            }

            if (! Schema::hasColumn('activity_logs', 'description')) {
                $table->text('description')->nullable()->after('device_id');
            }

            if (! Schema::hasColumn('activity_logs', 'metadata')) {
                $table->json('metadata')->nullable()->after('description');
            }

            if (! Schema::hasColumn('activity_logs', 'performed_at')) {
                $table->timestamp('performed_at')->nullable()->after('metadata');
            }
        });
    }

    public function down(): void
    {
        Schema::table('activity_logs', function (Blueprint $table) {
            foreach (['module', 'device_id', 'description', 'metadata', 'performed_at'] as $column) {
                if (Schema::hasColumn('activity_logs', $column)) {
                    $table->dropColumn($column);
                }
            }
        });
    }
};
