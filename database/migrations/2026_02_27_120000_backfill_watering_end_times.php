<?php

use App\Models\InkubatorDeviceConfig;
use App\Models\PlantProfile;
use Carbon\Carbon;
use Illuminate\Database\Migrations\Migration;

return new class extends Migration
{
    public function up(): void
    {
        PlantProfile::query()->chunkById(100, function ($plants): void {
            foreach ($plants as $plant) {
                $times = is_array($plant->watering_times) ? $plant->watering_times : [];
                $duration = max(1, (int) ($plant->watering_duration ?? 10));
                $endTimes = $this->computeEndTimes($times, $duration);

                $plant->forceFill([
                    'watering_end_times' => $endTimes,
                ])->save();
            }
        });

        InkubatorDeviceConfig::query()->chunkById(100, function ($configs): void {
            foreach ($configs as $config) {
                $times = is_array($config->sprayer_times) ? $config->sprayer_times : [];
                $duration = max(1, (int) ($config->sprayer_duration ?? 10));
                $endTimes = $this->computeEndTimes($times, $duration);

                $config->forceFill([
                    'sprayer_end_times' => $endTimes,
                ])->save();
            }
        });
    }

    public function down(): void
    {
        // No rollback required for data backfill migration.
    }

    private function computeEndTimes(array $times, int $durationSeconds): array
    {
        $endTimes = [];

        foreach ($times as $time) {
            $timeString = trim((string) $time);
            if ($timeString === '') {
                continue;
            }

            try {
                $start = Carbon::createFromFormat('H:i', $timeString);
                $endTimes[] = $start->copy()->addSeconds($durationSeconds)->format('H:i:s');
            } catch (\Throwable) {
                // Ignore malformed values.
            }
        }

        return $endTimes;
    }
};
