<?php

use Illuminate\Foundation\Inspiring;
use Illuminate\Support\Facades\Artisan;
use Illuminate\Support\Facades\Schedule;

Artisan::command('inspire', function () {
    $this->comment(Inspiring::quote());
})->purpose('Display an inspiring quote');

Schedule::command('sensor:log')->everyTenSeconds()->withoutOverlapping();
Schedule::command('inkubator:send-daily-status')->timezone('Asia/Jakarta')->dailyAt('07:00')->withoutOverlapping();
Schedule::command('inkubator:send-daily-status')->timezone('Asia/Jakarta')->dailyAt('16:00')->withoutOverlapping();

Schedule::command('inkubator:check-connection')->everyMinute()->withoutOverlapping();

// ── Monitoring Kebun Percobaan ──
Schedule::command('monitoring:send-daily-status')->timezone('Asia/Jakarta')->dailyAt('07:00')->withoutOverlapping();
Schedule::command('monitoring:send-daily-status')->timezone('Asia/Jakarta')->dailyAt('16:00')->withoutOverlapping();
Schedule::command('monitoring:check-connection')->everyMinute()->withoutOverlapping();
