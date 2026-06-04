<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

class PlantProfile extends Model
{
    public $incrementing = false;
    protected $keyType = 'string';

    protected $fillable = [
        'id',
        'device_id',
        'name',
        'auto',
        'light_pwm',
        'light_kelvin',
        'par_target',
        'watering_times',
        'watering_end_times',
        'watering_duration',
        'temp_min',
        'temp_max',
        'lighting',
        'light_cycle',
        'created_by',
    ];

    protected function casts(): array
    {
        return [
            'auto' => 'boolean',
            'light_pwm' => 'integer',
            'light_kelvin' => 'integer',
            'par_target' => 'integer',
            'watering_times' => 'array',
            'watering_end_times' => 'array',
            'watering_duration' => 'integer',
            'temp_min' => 'float',
            'temp_max' => 'float',
            'lighting' => 'array',
            'light_cycle' => 'array',
        ];
    }

    public function creator(): BelongsTo
    {
        return $this->belongsTo(User::class, 'created_by');
    }
}
