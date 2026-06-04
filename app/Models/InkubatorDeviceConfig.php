<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

class InkubatorDeviceConfig extends Model
{
    protected $fillable = [
        'device_id',
        'lamp_pwm',
        'sprayer_duration',
        'sprayer_times',
        'sprayer_end_times',
        'light_schedule',
        'active_plant_id',
        'updated_by',
    ];

    protected function casts(): array
    {
        return [
            'lamp_pwm' => 'integer',
            'sprayer_duration' => 'integer',
            'sprayer_times' => 'array',
            'sprayer_end_times' => 'array',
            'light_schedule' => 'array',
        ];
    }
}
