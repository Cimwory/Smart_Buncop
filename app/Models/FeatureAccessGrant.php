<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

class FeatureAccessGrant extends Model
{
    public const FEATURE_INDOOR_FARMING_CONTROL = 'indoor_farming_control';

    protected $fillable = [
        'feature_key',
        'user_id',
        'granted_by',
    ];

    protected function casts(): array
    {
        return [
            'user_id' => 'integer',
            'granted_by' => 'integer',
        ];
    }

    public function user(): BelongsTo
    {
        return $this->belongsTo(User::class);
    }

    public function grantedBy(): BelongsTo
    {
        return $this->belongsTo(User::class, 'granted_by');
    }
}
