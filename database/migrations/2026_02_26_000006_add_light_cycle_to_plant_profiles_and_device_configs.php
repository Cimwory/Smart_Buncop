<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('plant_profiles', function (Blueprint $table): void {
            if (! Schema::hasColumn('plant_profiles', 'lighting')) {
                $table->json('lighting')->nullable()->after('temp_max');
            }
            if (! Schema::hasColumn('plant_profiles', 'light_cycle')) {
                $table->json('light_cycle')->nullable()->after('lighting');
            }
        });

        Schema::table('inkubator_device_configs', function (Blueprint $table): void {
            if (! Schema::hasColumn('inkubator_device_configs', 'light_schedule')) {
                $table->json('light_schedule')->nullable()->after('sprayer_times');
            }
            if (! Schema::hasColumn('inkubator_device_configs', 'active_plant_id')) {
                $table->string('active_plant_id', 26)->nullable()->after('light_schedule');
            }
        });
    }

    public function down(): void
    {
        Schema::table('inkubator_device_configs', function (Blueprint $table): void {
            foreach (['light_schedule', 'active_plant_id'] as $column) {
                if (Schema::hasColumn('inkubator_device_configs', $column)) {
                    $table->dropColumn($column);
                }
            }
        });

        Schema::table('plant_profiles', function (Blueprint $table): void {
            foreach (['lighting', 'light_cycle'] as $column) {
                if (Schema::hasColumn('plant_profiles', $column)) {
                    $table->dropColumn($column);
                }
            }
        });
    }
};
