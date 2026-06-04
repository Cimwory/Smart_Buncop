<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        if (! Schema::hasTable('indoor_farming_device_configs')) {
            return;
        }

        if (! Schema::hasColumn('indoor_farming_device_configs', 'ro_target_level')) {
            Schema::table('indoor_farming_device_configs', function (Blueprint $table): void {
                $table->unsignedTinyInteger('ro_target_level')->default(2)->after('ph_dosing_cooldown_sec');
            });
        }
    }

    public function down(): void
    {
        if (! Schema::hasTable('indoor_farming_device_configs')) {
            return;
        }

        if (Schema::hasColumn('indoor_farming_device_configs', 'ro_target_level')) {
            Schema::table('indoor_farming_device_configs', function (Blueprint $table): void {
                $table->dropColumn('ro_target_level');
            });
        }
    }
};
