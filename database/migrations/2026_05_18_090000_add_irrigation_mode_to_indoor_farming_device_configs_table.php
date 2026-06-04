<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('indoor_farming_device_configs', function (Blueprint $table): void {
            $table->string('irrigation_mode', 20)->default('schedule')->after('irrigation_duration_sec');
        });
    }

    public function down(): void
    {
        Schema::table('indoor_farming_device_configs', function (Blueprint $table): void {
            $table->dropColumn('irrigation_mode');
        });
    }
};
