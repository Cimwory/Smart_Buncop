<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('feature_access_pins', function (Blueprint $table): void {
            if (! Schema::hasColumn('feature_access_pins', 'unlock_duration_minutes')) {
                $table->unsignedInteger('unlock_duration_minutes')->default(30)->after('is_enabled');
            }
        });
    }

    public function down(): void
    {
        Schema::table('feature_access_pins', function (Blueprint $table): void {
            if (Schema::hasColumn('feature_access_pins', 'unlock_duration_minutes')) {
                $table->dropColumn('unlock_duration_minutes');
            }
        });
    }
};
