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

        if (! Schema::hasColumn('indoor_farming_device_configs', 'nft_sensor_warmup_sec')) {
            Schema::table('indoor_farming_device_configs', function (Blueprint $table): void {
                $table->unsignedInteger('nft_sensor_warmup_sec')->default(60)->after('ph_dosing_cooldown_sec');
            });
        }
    }

    public function down(): void
    {
        if (! Schema::hasTable('indoor_farming_device_configs')) {
            return;
        }

        if (Schema::hasColumn('indoor_farming_device_configs', 'nft_sensor_warmup_sec')) {
            Schema::table('indoor_farming_device_configs', function (Blueprint $table): void {
                $table->dropColumn('nft_sensor_warmup_sec');
            });
        }
    }
};
