<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('inkubator_device_configs', function (Blueprint $table): void {
            $table->id();
            $table->string('device_id', 100)->unique();
            $table->unsignedTinyInteger('lamp_pwm')->default(60);
            $table->unsignedInteger('sprayer_duration')->default(10);
            $table->json('sprayer_times')->nullable();
            $table->unsignedBigInteger('updated_by')->nullable();
            $table->timestamps();

            $table->index('device_id');
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('inkubator_device_configs');
    }
};

