<?php

namespace App\Http\Middleware;

use App\Models\ApiAccessToken;
use Closure;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;

class AuthenticateApiToken
{
    public function handle(Request $request, Closure $next): mixed
    {
        $plainToken = trim((string) $request->bearerToken());
        if ($plainToken === '') {
            return $this->unauthorized('Token autentikasi tidak ditemukan.');
        }

        $token = ApiAccessToken::query()
            ->with('user.role')
            ->where('token_hash', hash('sha256', $plainToken))
            ->first();

        if ($token === null) {
            return $this->unauthorized('Token autentikasi tidak valid.');
        }

        if ($token->user === null) {
            $token->delete();
            return $this->unauthorized('Token tidak terhubung ke user aktif. Silakan login ulang.');
        }

        if (! (bool) ($token->user?->is_active ?? true)) {
            $token->delete();
            return response()->json([
                'message' => 'Akun Anda dinonaktifkan. Hubungi admin.',
            ], 403);
        }

        if ($token->expires_at !== null && $token->expires_at->isPast()) {
            $token->delete();
            return $this->unauthorized('Sesi token sudah kedaluwarsa.');
        }

        $token->forceFill([
            'last_used_at' => now(),
        ])->save();

        $request->attributes->set('api_access_token', $token);
        $request->setUserResolver(fn () => $token->user);

        return $next($request);
    }

    private function unauthorized(string $message): JsonResponse
    {
        return response()->json([
            'message' => $message,
        ], 401);
    }
}
