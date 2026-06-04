<?php

namespace App\Services;

use Firebase\JWT\JWT;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Log;

class FirebaseMessagingService
{
    private const ACCESS_TOKEN_CACHE_KEY = 'firebase:fcm:access-token';

    public function isEnabled(): bool
    {
        return (bool) config('services.firebase.enabled', false);
    }

    public function isConfigured(): bool
    {
        return $this->projectId() !== ''
            && $this->serviceAccountEmail() !== ''
            && $this->privateKey() !== '';
    }

    public function defaultTopic(): string
    {
        return trim((string) config('services.firebase.default_topic', 'esp_status'));
    }

    /**
     * @param array<string, string> $data
     */
    public function sendToTopic(string $topic, string $title, string $body, array $data = []): bool
    {
        $topic = trim($topic);
        if ($topic === '') {
            return false;
        }

        return $this->sendMessage([
            'topic' => $topic,
            'notification' => [
                'title' => $title,
                'body' => $body,
            ],
            'data' => $this->stringifyData($data),
            'android' => [
                'priority' => 'high',
                'notification' => [
                    'channel_id' => 'esp_channel',
                    'sound' => 'default',
                ],
            ],
        ]);
    }

    /**
     * @param array<int, string> $topics
     * @param array<string, string> $data
     */
    public function sendToTopics(array $topics, string $title, string $body, array $data = []): array
    {
        $results = [];

        foreach (array_values(array_unique(array_filter(array_map('trim', $topics)))) as $topic) {
            $results[$topic] = $this->sendToTopic($topic, $title, $body, $data);
        }

        return $results;
    }

    /**
     * @param array<string, mixed> $payload
     */
    private function sendMessage(array $payload): bool
    {
        if (! $this->isEnabled()) {
            Log::info('[FCM] Skip send because feature flag is disabled.', [
                'payload' => $payload,
            ]);

            return false;
        }

        if (! $this->isConfigured()) {
            Log::warning('[FCM] Skip send because Firebase service account config is incomplete.');

            return false;
        }

        try {
            $response = Http::withToken($this->accessToken())
                ->timeout(15)
                ->post($this->sendEndpoint(), [
                    'message' => $payload,
                ]);

            if ($response->successful()) {
                Log::info('[FCM] Notification sent.', [
                    'target' => $payload['topic'] ?? $payload['token'] ?? 'unknown',
                ]);

                return true;
            }

            Log::warning('[FCM] Notification send failed.', [
                'status' => $response->status(),
                'body' => $response->body(),
            ]);
        } catch (\Throwable $e) {
            Log::warning('[FCM] Notification send exception.', [
                'message' => $e->getMessage(),
            ]);
        }

        return false;
    }

    private function accessToken(): string
    {
        return Cache::remember(self::ACCESS_TOKEN_CACHE_KEY, now()->addMinutes(50), function (): string {
            $response = Http::asForm()
                ->timeout(15)
                ->post('https://oauth2.googleapis.com/token', [
                    'grant_type' => 'urn:ietf:params:oauth:grant-type:jwt-bearer',
                    'assertion' => $this->buildJwtAssertion(),
                ]);

            if (! $response->successful()) {
                throw new \RuntimeException('Gagal mengambil access token Firebase: '.$response->body());
            }

            $json = $response->json();
            $token = is_array($json) ? (string) ($json['access_token'] ?? '') : '';

            if ($token === '') {
                throw new \RuntimeException('Access token Firebase kosong.');
            }

            return $token;
        });
    }

    private function buildJwtAssertion(): string
    {
        $now = time();

        return JWT::encode([
            'iss' => $this->serviceAccountEmail(),
            'scope' => 'https://www.googleapis.com/auth/firebase.messaging',
            'aud' => 'https://oauth2.googleapis.com/token',
            'iat' => $now,
            'exp' => $now + 3600,
        ], $this->privateKey(), 'RS256');
    }

    private function sendEndpoint(): string
    {
        return sprintf(
            'https://fcm.googleapis.com/v1/projects/%s/messages:send',
            $this->projectId()
        );
    }

    private function projectId(): string
    {
        return trim((string) config('services.firebase.project_id', ''));
    }

    private function serviceAccountEmail(): string
    {
        return trim((string) config('services.firebase.service_account_email', ''));
    }

    private function privateKey(): string
    {
        $raw = (string) config('services.firebase.private_key', '');

        return str_replace('\n', "\n", trim($raw));
    }

    /**
     * @param array<string, mixed> $data
     * @return array<string, string>
     */
    private function stringifyData(array $data): array
    {
        $normalized = [];

        foreach ($data as $key => $value) {
            if (! is_string($key) || trim($key) === '' || $value === null) {
                continue;
            }

            if (is_scalar($value)) {
                $normalized[$key] = (string) $value;
                continue;
            }

            $normalized[$key] = (string) json_encode($value);
        }

        return $normalized;
    }
}
