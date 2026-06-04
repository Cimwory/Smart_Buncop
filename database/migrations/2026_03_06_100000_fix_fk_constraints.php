<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        // Fix 1: Change role_id cascade from CASCADE to RESTRICT to prevent
        // accidental mass-deletion of users when a role is removed.
        Schema::table('users', function (Blueprint $table) {
            $table->dropForeign(['role_id']);
            $table->foreignId('role_id')->change()->constrained()->onDelete('restrict');
        });

        // Fix 2: Convert updated_by from plain integer to proper foreign key
        // with nullOnDelete so records aren't orphaned when a user is removed.
        Schema::table('inkubator_device_configs', function (Blueprint $table) {
            $table->foreignId('updated_by')->nullable()->change();
            $table->foreign('updated_by')->references('id')->on('users')->nullOnDelete();
        });
    }

    public function down(): void
    {
        Schema::table('inkubator_device_configs', function (Blueprint $table) {
            $table->dropForeign(['updated_by']);
        });

        Schema::table('users', function (Blueprint $table) {
            $table->dropForeign(['role_id']);
            $table->foreignId('role_id')->change()->constrained()->onDelete('cascade');
        });
    }
};
