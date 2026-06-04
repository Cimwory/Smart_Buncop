<?php

namespace App\Services;

use PhpMqtt\Client\MqttClient;
use PhpMqtt\Client\ConnectionSettings;
use Illuminate\Support\Facades\Log;

/**
 * MQTT service for publishing commands and subscribing to device topics.
 * Uses php-mqtt/client to connect to the EMQX broker.
 */
class MqttService
{
    private ?MqttClient $client = null;

    public function topic(string $area, string $deviceId, string $suffix): string
    {
        return config('mqtt.topic_prefix', 'buncop') . "/{$area}/{$deviceId}/{$suffix}";
    }

    /**
     * Publish a JSON command to a device topic.
     */
    public function publishCommand(string $area, string $deviceId, array $payload): bool
    {
        $topic = $this->topic($area, $deviceId, 'command');
        return $this->publish($topic, $payload);
    }

    /**
     * Publish a JSON message to any topic.
     */
    public function publish(string $topic, array $payload, bool $retain = false, int $qos = 1): bool
    {
        try {
            $client = $this->connect();
            $client->publish($topic, json_encode($payload), $qos, $retain);
            return true;
        } catch (\Throwable $e) {
            Log::warning("[MQTT] Publish failed [{$topic}]: {$e->getMessage()}");
            return false;
        }
    }

    /**
     * Get or open a connected MQTT client.
     */
    public function client(): MqttClient
    {
        return $this->connect();
    }

    /**
     * Subscribe to a topic using the shared client connection.
     *
     * @param callable(string, string, bool, array<int, string>): void $handler
     */
    public function subscribe(string $topic, callable $handler, int $qos = 0): void
    {
        $this->connect()->subscribe($topic, $handler, $qos);
    }

    /**
     * Run the MQTT event loop.
     */
    public function loop(bool $allowSleep = true, bool $exitWhenQueuesEmpty = false): void
    {
        $this->connect()->loop($allowSleep, $exitWhenQueuesEmpty);
    }

    /**
     * Interrupt the MQTT loop gracefully.
     */
    public function interrupt(): void
    {
        if ($this->client !== null) {
            $this->client->interrupt();
        }
    }

    /**
     * Get an MQTT client connection (reuses existing connection).
     */
    private function connect(): MqttClient
    {
        if ($this->client !== null && $this->client->isConnected()) {
            return $this->client;
        }

        $host = config('mqtt.host', 'localhost');
        $port = (int) config('mqtt.port', 1883);
        $clientId = config('mqtt.client_id_prefix', 'buncop_laravel') . '_' . substr(md5(uniqid('', true)), 0, 8);

        $settings = (new ConnectionSettings())
            ->setUsername(config('mqtt.username', ''))
            ->setPassword(config('mqtt.password', ''))
            ->setKeepAliveInterval(30)
            ->setConnectTimeout(5);

        if (config('mqtt.use_tls', false)) {
            $settings->setUseTls(true);
        }

        $this->client = new MqttClient($host, $port, $clientId);
        $this->client->connect($settings);

        return $this->client;
    }

    /**
     * Disconnect gracefully.
     */
    public function disconnect(): void
    {
        try {
            if ($this->client !== null && $this->client->isConnected()) {
                $this->client->disconnect();
            }
        } catch (\Throwable) {
            // Ignore disconnect errors.
        }
        $this->client = null;
    }

    public function __destruct()
    {
        $this->disconnect();
    }
}
