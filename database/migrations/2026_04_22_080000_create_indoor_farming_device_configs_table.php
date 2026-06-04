<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('indoor_farming_device_configs', function (Blueprint $table): void {
            $table->id();
            $table->string('device_id', 100)->unique();
            $table->boolean('auto_enabled')->default(true);
            $table->unsignedInteger('nft_interval_min')->default(30);
            $table->unsignedInteger('nft_duration_min')->default(5);
            $table->unsignedInteger('irrigation_duration_sec')->default(120);
            $table->json('irrigation_times')->nullable();
            $table->decimal('target_ppm', 8, 2)->default(900.00);
            $table->decimal('ppm_deadband', 8, 2)->default(30.00);
            $table->decimal('target_ph', 5, 2)->default(6.00);
            $table->decimal('ph_deadband', 5, 2)->default(0.15);
            $table->unsignedInteger('nutrition_dose_pulse_sec')->default(2);
            $table->unsignedInteger('ph_dose_pulse_sec')->default(2);
            $table->unsignedInteger('nutrition_dosing_cooldown_sec')->default(30);
            $table->unsignedInteger('ph_dosing_cooldown_sec')->default(30);
            $table->unsignedBigInteger('updated_by')->nullable();
            $table->timestamps();

            $table->index('device_id');
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('indoor_farming_device_configs');
    }
};
