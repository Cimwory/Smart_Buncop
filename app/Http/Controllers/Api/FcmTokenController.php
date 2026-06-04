<?php

namespace App\Http\Controllers\Api;

use App\Http\Controllers\Controller;
use App\Models\FcmDeviceToken;
use App\Models\User;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;

class FcmTokenController extends Controller
{
    public function store(Request $request): JsonResponse
    {
        $user = $request->user();
        if (! $user instanceof User) {
            return response()->json([
                'message' => 'User tidak valid.',
            ], 401);
        }

        $validated = $request->validate([
            'token' => ['required', 'string', 'max:4096'],
            'platform' => ['nullable', 'string', 'max:32'],
            'device_name' => ['nullable', 'string', 'max:255'],
            'device_model' => ['nullable', 'string', 'max:255'],
            'app_version' => ['nullable', 'string', 'max:64'],
            'topics' => ['nullable', 'array'],
            'topics.*' => ['string', 'max:128'],
        ]);

        $topics = array_values(array_unique(array_filter(array_map(
            static fn ($topic) => trim((string) $topic),
            (array) ($validated['topics'] ?? [])
        ))));

        $row = FcmDeviceToken::query()->updateOrCreate(
            ['token' => trim((string) $validated['token'])],
            [
                'user_id' => $user->id,
                'platform' => strtolower(trim((string) ($validated['platform'] ?? 'android'))),
                'device_name' => $this->nullableTrim($validated['device_name'] ?? null),
                'device_model' => $this->nullableTrim($validated['device_model'] ?? null),
                'app_version' => $this->nullableTrim($validated['app_version'] ?? null),
                'subscribed_topics' => $topics,
                'last_seen_at' => now(),
            ]
        );

        return response()->json([
            'message' => 'FCM token berhasil disimpan.',
            'data' => [
                'id' => $row->id,
                'token' => $row->token,
                'topics' => $row->subscribed_topics ?? [],
            ],
        ]);
    }

    public function destroy(Request $request): JsonResponse
    {
        $user = $request->user();
        if (! $user instanceof User) {
            return response()->json([
                'message' => 'User tidak valid.',
            ], 401);
        }

        $validated = $request->validate([
            'token' => ['required', 'string', 'max:4096'],
        ]);

        FcmDeviceToken::query()
            ->where('user_id', $user->id)
            ->where('token', trim((string) $validated['token']))
            ->delete();

        return response()->json([
            'message' => 'FCM token berhasil dihapus.',
        ]);
    }

    private function nullableTrim(mixed $value): ?string
    {
        $trimmed = trim((string) $value);

        return $trimmed !== '' ? $trimmed : null;
    }
}
