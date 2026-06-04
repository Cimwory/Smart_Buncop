<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

class IndoorFarmingDeviceConfig extends Model
{
    protected $fillable = [
        'device_id',
        'auto_enabled',
        'nft_interval_min',
        'nft_duration_min',
        'irrigation_duration_sec',
        'irrigation_mode',
        'irrigation_times',
        'target_ppm',
        'ppm_deadband',
        'target_ph',
        'ph_deadband',
        'nutrition_dose_pulse_sec',
        'ph_dose_pulse_sec',
        'nutrition_dosing_cooldown_sec',
        'ph_dosing_cooldown_sec',
        'nft_sensor_warmup_sec',
        'ro_target_level',
        'updated_by',
    ];

    protected function casts(): array
    {
        return [
            'auto_enabled' => 'boolean',
            'nft_interval_min' => 'integer',
            'nft_duration_min' => 'integer',
            'irrigation_duration_sec' => 'integer',
            'irrigation_mode' => 'string',
            'irrigation_times' => 'array',
            'target_ppm' => 'float',
            'ppm_deadband' => 'float',
            'target_ph' => 'float',
            'ph_deadband' => 'float',
            'nutrition_dose_pulse_sec' => 'integer',
            'ph_dose_pulse_sec' => 'integer',
            'nutrition_dosing_cooldown_sec' => 'integer',
            'ph_dosing_cooldown_sec' => 'integer',
            'nft_sensor_warmup_sec' => 'integer',
            'ro_target_level' => 'integer',
            'updated_by' => 'integer',
        ];
    }
}
