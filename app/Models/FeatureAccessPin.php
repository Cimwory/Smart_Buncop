<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

class FeatureAccessPin extends Model
{
    public const FEATURE_INDOOR_FARMING_CONTROL = 'indoor_farming_control';

    protected $fillable = [
        'feature_key',
        'pin_hash',
        'is_enabled',
        'unlock_duration_minutes',
        'updated_by',
    ];

    protected function casts(): array
    {
        return [
            'is_enabled' => 'boolean',
            'unlock_duration_minutes' => 'integer',
            'updated_by' => 'integer',
        ];
    }

    public function updatedBy(): BelongsTo
    {
        return $this->belongsTo(User::class, 'updated_by');
    }
}
