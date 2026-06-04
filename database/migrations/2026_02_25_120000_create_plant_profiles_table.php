<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration {
    public function up(): void
    {
        Schema::create('plant_profiles', function (Blueprint $table): void {
            $table->string('id', 26)->primary();
            $table->string('device_id', 100)->index();
            $table->string('name', 150);
            $table->boolean('auto')->default(true);
            $table->unsignedTinyInteger('light_pwm')->default(60);
            $table->unsignedInteger('light_kelvin')->nullable();
            $table->unsignedInteger('par_target')->nullable();
            $table->json('watering_times')->nullable();
            $table->unsignedInteger('watering_duration')->default(10);
            $table->decimal('temp_min', 5, 2)->nullable();
            $table->decimal('temp_max', 5, 2)->nullable();
            $table->foreignId('created_by')->nullable()->constrained('users')->nullOnDelete();
            $table->timestamps();
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('plant_profiles');
    }
};

