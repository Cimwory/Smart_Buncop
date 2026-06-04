<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('indoor_farming_device_configs', function (Blueprint $table): void {
            $table->unsignedTinyInteger('ro_target_level')->default(2)->after('ph_dosing_cooldown_sec');
        });
    }

    public function down(): void
    {
        Schema::table('indoor_farming_device_configs', function (Blueprint $table): void {
            $table->dropColumn('ro_target_level');
        });
    }
};
