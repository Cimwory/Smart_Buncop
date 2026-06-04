<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * Run the migrations.
     */
    public function up(): void
    {
        if (Schema::hasTable('activity_logs')) {
            return;
        }

        Schema::create('activity_logs', function (Blueprint $table) {
            $table->id();
            $table->foreignId('user_id')->nullable()->constrained()->nullOnDelete();
            $table->string('event', 50);
            $table->string('guard', 50)->nullable();
            $table->string('login_identifier')->nullable();
            $table->string('ip_address', 45)->nullable();
            $table->text('user_agent')->nullable();
            $table->timestamp('occurred_at')->useCurrent();
            $table->timestamps();

            $table->index(['event', 'occurred_at']);
            $table->index(['user_id', 'occurred_at']);
            $table->index('login_identifier');
        });
    }

    /**
     * Reverse the migrations.
     */
    public function down(): void
    {
        // Guarded rollback to avoid dropping table created by another migration set.
        if (Schema::hasTable('activity_logs')) {
            Schema::dropIfExists('activity_logs');
        }
    }
};
