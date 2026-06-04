<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('activity_logs', function (Blueprint $table): void {
            $table->string('auth_provider', 30)->nullable()->after('actor_role');
            $table->string('session_id', 120)->nullable()->after('auth_provider');
            $table->string('token_jti', 120)->nullable()->after('session_id');

            $table->index('auth_provider');
            $table->index('session_id');
            $table->index('token_jti');
        });
    }

    public function down(): void
    {
        Schema::table('activity_logs', function (Blueprint $table): void {
            $table->dropIndex(['auth_provider']);
            $table->dropIndex(['session_id']);
            $table->dropIndex(['token_jti']);
            $table->dropColumn(['auth_provider', 'session_id', 'token_jti']);
        });
    }
};