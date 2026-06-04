<?php

namespace App\Http\Middleware;

use Closure;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;

class AuthenticateSystemActivityKey
{
    public function handle(Request $request, Closure $next): mixed
    {
        $configuredKey = trim((string) config('services.system_activity.key', ''));
        if ($configuredKey === '') {
            return response()->json([
                'message' => 'SYSTEM_ACTIVITY_KEY belum dikonfigurasi di server.',
            ], 503);
        }

        $providedKey = trim((string) $request->header('X-System-Key', ''));
        if ($providedKey === '') {
            return $this->unauthorized('Header X-System-Key tidak ditemukan.');
        }

        if (! hash_equals($configuredKey, $providedKey)) {
            return $this->unauthorized('System key tidak valid.');
        }

        return $next($request);
    }

    private function unauthorized(string $message): JsonResponse
    {
        return response()->json([
            'message' => $message,
        ], 401);
    }
}
