<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        if (Schema::hasTable('plant_profiles')) {
            Schema::table('plant_profiles', function (Blueprint $table): void {
                if (! Schema::hasColumn('plant_profiles', 'watering_end_times')) {
                    $table->json('watering_end_times')->nullable()->after('watering_times');
                }
            });
        }

        if (Schema::hasTable('inkubator_device_configs')) {
            Schema::table('inkubator_device_configs', function (Blueprint $table): void {
                if (! Schema::hasColumn('inkubator_device_configs', 'sprayer_end_times')) {
                    $table->json('sprayer_end_times')->nullable()->after('sprayer_times');
                }
            });
        }
    }

    public function down(): void
    {
        if (Schema::hasTable('inkubator_device_configs')) {
            Schema::table('inkubator_device_configs', function (Blueprint $table): void {
                if (Schema::hasColumn('inkubator_device_configs', 'sprayer_end_times')) {
                    $table->dropColumn('sprayer_end_times');
                }
            });
        }

        if (Schema::hasTable('plant_profiles')) {
            Schema::table('plant_profiles', function (Blueprint $table): void {
                if (Schema::hasColumn('plant_profiles', 'watering_end_times')) {
                    $table->dropColumn('watering_end_times');
                }
            });
        }
    }
};

