<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('users', function (Blueprint $table): void {
            $table->string('auth_provider', 30)->default('local')->after('role');
            $table->string('sso_subject', 191)->nullable()->after('auth_provider');
            $table->string('employee_id', 100)->nullable()->after('sso_subject');

            $table->unique('sso_subject');
            $table->index('auth_provider');
        });
    }

    public function down(): void
    {
        Schema::table('users', function (Blueprint $table): void {
            $table->dropUnique(['sso_subject']);
            $table->dropIndex(['auth_provider']);
            $table->dropColumn(['auth_provider', 'sso_subject', 'employee_id']);
        });
    }
};