<?php

namespace App\Services;

use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Log;

class InfluxDbService
{
    private string $baseUrl;
    private string $token;
    private string $org;
    private string $bucket;
    private string $measurement;
    private bool $verifyTls;
    private int $timeoutSeconds;

    public function __construct()
    {
        $this->baseUrl = rtrim((string) config('services.influxdb.url', ''), '/');
        $this->token = (string) config('services.influxdb.token', '');
        $this->org = (string) config('services.influxdb.org', '');
        $this->bucket = (string) config('services.influxdb.bucket', '');
        $this->measurement = (string) config('services.influxdb.measurement', 'mqtt_consumer');
        $this->verifyTls = filter_var(config('services.influxdb.verify_tls', true), FILTER_VALIDATE_BOOL, FILTER_NULL_ON_FAILURE) ?? true;
        $this->timeoutSeconds = max(3, (int) config('services.influxdb.timeout_seconds', 10));
    }

    public function isConfigured(): bool
    {
        return $this->baseUrl !== ''
            && $this->token !== ''
            && $this->org !== ''
            && $this->bucket !== '';
    }

    public function latestByTopic(string $topic, int $lookbackHours = 48): array
    {
        if (! $this->isConfigured() || trim($topic) === '') {
            return [];
        }

        $lookback = max(1, $lookbackHours);
        $topicEscaped = $this->escapeFluxString($topic);
        $measurementFilter = trim($this->measurement) !== ''
            ? sprintf('|> filter(fn: (r) => r["_measurement"] == "%s")', $this->escapeFluxString($this->measurement))
            : '';

        $query = <<<FLUX
from(bucket: "{$this->escapeFluxString($this->bucket)}")
  |> range(start: -{$lookback}h)
  {$measurementFilter}
  |> filter(fn: (r) => r["topic"] == "{$topicEscaped}")
  |> last()
  |> pivot(rowKey:["_time"], columnKey: ["_field"], valueColumn: "_value")
FLUX;

        $rows = $this->queryRows($query);

        return $rows[0] ?? [];
    }

    public function getLatestSensor(string $deviceId, string $measurement = 'incubator_sensor'): array
    {
        if (! $this->isConfigured()) {
            return [
                'temperature' => null,
                'humidity' => null,
                'soil_moisture' => null,
                'timestamp' => null,
            ];
        }

        $measurementEscaped = $this->escapeFluxString(trim($measurement) !== '' ? $measurement : 'incubator_sensor');
        $deviceFilter = $this->buildDeviceFilterExpression($deviceId);

        $query = <<<FLUX
import "strings"

from(bucket: "{$this->escapeFluxString($this->bucket)}")
  |> range(start: -72h)
  |> filter(fn: (r) => r["_measurement"] == "{$measurementEscaped}")
  |> filter(fn: (r) => {$deviceFilter})
  |> filter(fn: (r) => r["_field"] == "temperature" or r["_field"] == "humidity" or r["_field"] == "soil_moisture")
  |> group(columns: ["_field"])
  |> last()
  |> pivot(rowKey:["_time"], columnKey: ["_field"], valueColumn: "_value")
  |> sort(columns: ["_time"], desc: true)
  |> limit(n: 1)
FLUX;

        $rows = $this->queryRows($query);
        $row = $rows[0] ?? [];

        $temperature = $this->toNullableFloat($row['temperature'] ?? null);
        $humidity = $this->toNullableFloat($row['humidity'] ?? null);
        $soilMoisture = $this->toNullableFloat($row['soil_moisture'] ?? null);
        $timestamp = $this->toEpochSeconds($row['_time'] ?? null);

        if ($temperature === null && $humidity === null && $soilMoisture === null) {
            $topicBase = $this->topicBaseForDevice($deviceId);
            $telemetryRow = $this->latestByTopic("{$topicBase}/telemetry", 72);
            $decoded = $this->extractPayload($telemetryRow);

            $temperature = $this->toNullableFloat($decoded['temperature'] ?? null);
            $humidity = $this->toNullableFloat($decoded['humidity'] ?? null);
            $soilMoisture = $this->toNullableFloat($decoded['soil_moisture'] ?? null);
            $timestamp = $this->toEpochSeconds($decoded['timestamp'] ?? $decoded['last_seen'] ?? $telemetryRow['_time'] ?? null);
        }

        return [
            'temperature' => $temperature,
            'humidity' => $humidity,
            'soil_moisture' => $soilMoisture,
            'timestamp' => $timestamp,
        ];
    }

    /**
     * @return array<int, array{timestamp:int|null, temperature:float|null, humidity:float|null, soil_moisture:float|null}>
     */
    public function getSensorHistory(
        string $deviceId,
        string $measurement = 'incubator_sensor',
        string $range = '-1h',
        string $window = '30s'
    ): array {
        if (! $this->isConfigured()) {
            return [];
        }

        $measurementEscaped = $this->escapeFluxString(trim($measurement) !== '' ? $measurement : 'incubator_sensor');
        $range = $this->sanitizeRange($range, '-1h');
        $window = $this->sanitizeWindow($window, '30s');
        $deviceFilter = $this->buildDeviceFilterExpression($deviceId);

        $query = <<<FLUX
import "strings"

from(bucket: "{$this->escapeFluxString($this->bucket)}")
  |> range(start: {$range})
  |> filter(fn: (r) => r["_measurement"] == "{$measurementEscaped}")
  |> filter(fn: (r) => {$deviceFilter})
  |> filter(fn: (r) => r["_field"] == "temperature" or r["_field"] == "humidity" or r["_field"] == "soil_moisture")
  |> aggregateWindow(every: {$window}, fn: mean, createEmpty: false)
  |> pivot(rowKey:["_time"], columnKey: ["_field"], valueColumn: "_value")
  |> sort(columns: ["_time"])
FLUX;

        $rows = $this->queryRows($query);
        if ($rows === [] && trim($deviceId) !== '') {
            $query = <<<FLUX
from(bucket: "{$this->escapeFluxString($this->bucket)}")
  |> range(start: {$range})
  |> filter(fn: (r) => r["_measurement"] == "{$measurementEscaped}")
  |> filter(fn: (r) => r["_field"] == "temperature" or r["_field"] == "humidity" or r["_field"] == "soil_moisture")
  |> aggregateWindow(every: {$window}, fn: mean, createEmpty: false)
  |> pivot(rowKey:["_time"], columnKey: ["_field"], valueColumn: "_value")
  |> sort(columns: ["_time"])
FLUX;
            $rows = $this->queryRows($query);
        }
        if ($rows === []) {
            $query = <<<FLUX
from(bucket: "{$this->escapeFluxString($this->bucket)}")
  |> range(start: {$range})
  |> filter(fn: (r) => r["_measurement"] == "{$measurementEscaped}")
  |> filter(fn: (r) => r["_field"] == "temperature" or r["_field"] == "humidity" or r["_field"] == "soil_moisture")
  |> pivot(rowKey:["_time"], columnKey: ["_field"], valueColumn: "_value")
  |> sort(columns: ["_time"])
FLUX;
            $rows = $this->queryRows($query);
        }

        $points = [];
        foreach ($rows as $row) {
            $points[] = [
                'timestamp' => $this->toEpochSeconds($row['_time'] ?? null),
                'temperature' => $this->toNullableFloat($row['temperature'] ?? null),
                'humidity' => $this->toNullableFloat($row['humidity'] ?? null),
                'soil_moisture' => $this->toNullableFloat($row['soil_moisture'] ?? null),
            ];
        }

        return $points;
    }

    /**
     * @return array<int, array{field:string, points:array<int, array{timestamp:int|null, value:float|null}>}>
     */
    public function getFieldHistory(
        string $deviceId,
        string $measurement,
        array $fields,
        string $range = '-1h',
        string $window = '30s'
    ): array {
        if (! $this->isConfigured()) {
            return [];
        }

        $normalizedFields = array_values(array_unique(array_filter(array_map(
            static fn ($field) => preg_match('/^[A-Za-z0-9_]+$/', (string) $field) ? (string) $field : '',
            $fields
        ))));

        if ($normalizedFields === []) {
            return [];
        }

        $measurementEscaped = $this->escapeFluxString(trim($measurement) !== '' ? $measurement : 'incubator_sensor');
        $range = $this->sanitizeRange($range, '-1h');
        $window = $this->sanitizeWindow($window, '30s');
        $deviceFilter = $this->buildDeviceFilterExpression($deviceId);

        $fieldClauses = array_map(
            fn ($field) => 'r["_field"] == "' . $this->escapeFluxString($field) . '"',
            $normalizedFields
        );
        $fieldFilter = implode(' or ', $fieldClauses);

        $query = <<<FLUX
import "strings"

from(bucket: "{$this->escapeFluxString($this->bucket)}")
  |> range(start: {$range})
  |> filter(fn: (r) => r["_measurement"] == "{$measurementEscaped}")
  |> filter(fn: (r) => {$deviceFilter})
  |> filter(fn: (r) => {$fieldFilter})
  |> aggregateWindow(every: {$window}, fn: mean, createEmpty: false)
  |> keep(columns: ["_time", "_field", "_value"])
  |> sort(columns: ["_time"])
FLUX;

        $rows = $this->queryRows($query);
        if ($rows === [] && trim($deviceId) !== '') {
            $query = <<<FLUX
from(bucket: "{$this->escapeFluxString($this->bucket)}")
  |> range(start: {$range})
  |> filter(fn: (r) => r["_measurement"] == "{$measurementEscaped}")
  |> filter(fn: (r) => {$fieldFilter})
  |> aggregateWindow(every: {$window}, fn: mean, createEmpty: false)
  |> keep(columns: ["_time", "_field", "_value"])
  |> sort(columns: ["_time"])
FLUX;
            $rows = $this->queryRows($query);
        }
        if ($rows === []) {
            $query = <<<FLUX
from(bucket: "{$this->escapeFluxString($this->bucket)}")
  |> range(start: {$range})
  |> filter(fn: (r) => r["_measurement"] == "{$measurementEscaped}")
  |> filter(fn: (r) => {$fieldFilter})
  |> keep(columns: ["_time", "_field", "_value"])
  |> sort(columns: ["_time"])
FLUX;
            $rows = $this->queryRows($query);
        }

        $seriesMap = [];

        foreach ($rows as $row) {
            $field = isset($row['_field']) ? (string) $row['_field'] : '';
            if ($field === '') {
                continue;
            }

            if (! isset($seriesMap[$field])) {
                $seriesMap[$field] = [
                    'field' => $field,
                    'points' => [],
                ];
            }

            $seriesMap[$field]['points'][] = [
                'timestamp' => $this->toEpochSeconds($row['_time'] ?? null),
                'value' => $this->toNullableFloat($row['_value'] ?? null),
            ];
        }

        return array_values($seriesMap);
    }

    public function queryRows(string $fluxQuery): array
    {
        if (! $this->isConfigured()) {
            return [];
        }

        try {
            $response = Http::withToken($this->token)
                ->withHeaders([
                    'Accept' => 'application/csv',
                    'Content-Type' => 'application/json',
                ])
                ->withOptions([
                    'verify' => $this->verifyTls,
                ])
                ->timeout($this->timeoutSeconds)
                ->post($this->baseUrl . '/api/v2/query?org=' . rawurlencode($this->org), [
                    'query' => $fluxQuery,
                    'type' => 'flux',
                ]);

            if (! $response->successful()) {
                Log::warning('Influx query failed', [
                    'status' => $response->status(),
                    'body' => mb_substr((string) $response->body(), 0, 500),
                ]);

                return [];
            }

            return $this->parseAnnotatedCsv((string) $response->body());
        } catch (\Throwable $e) {
            Log::warning('Influx query exception', [
                'message' => $e->getMessage(),
            ]);

            return [];
        }
    }

    public function rawFieldRows(
        string $measurement,
        string $field,
        string $range = '-1d',
        int $limit = 10
    ): array {
        if (! $this->isConfigured()) {
            return [];
        }

        $measurementEscaped = $this->escapeFluxString(trim($measurement) !== '' ? $measurement : 'incubator_sensor');
        $fieldEscaped = $this->escapeFluxString(trim($field) !== '' ? $field : 'temperature');
        $range = $this->sanitizeRange($range, '-1d');
        $limit = max(1, min(100, $limit));

        $query = <<<FLUX
from(bucket: "{$this->escapeFluxString($this->bucket)}")
  |> range(start: {$range})
  |> filter(fn: (r) => r["_measurement"] == "{$measurementEscaped}")
  |> filter(fn: (r) => r["_field"] == "{$fieldEscaped}")
  |> keep(columns: ["_time", "_measurement", "_field", "_value", "device", "device_id", "topic"])
  |> sort(columns: ["_time"], desc: true)
  |> limit(n: {$limit})
FLUX;

        return $this->queryRows($query);
    }

    private function parseAnnotatedCsv(string $csv): array
    {
        $lines = preg_split("/\r\n|\n|\r/", trim($csv));
        if (! is_array($lines) || count($lines) === 0) {
            return [];
        }

        $header = null;
        $rows = [];

        foreach ($lines as $line) {
            if ($line === '' || str_starts_with($line, '#')) {
                continue;
            }

            $columns = str_getcsv($line);
            if (! is_array($columns) || count($columns) === 0) {
                continue;
            }

            if ($header === null) {
                $header = $columns;
                continue;
            }

            if (count($columns) < count($header)) {
                $columns = array_pad($columns, count($header), null);
            }

            $row = [];
            foreach ($header as $idx => $columnName) {
                if ($columnName === '' || $columnName === null) {
                    continue;
                }
                $row[$columnName] = $this->castScalar($columns[$idx] ?? null);
            }

            $rows[] = $row;
        }

        return $rows;
    }

    private function castScalar(mixed $value): mixed
    {
        if ($value === null || $value === '') {
            return null;
        }

        if ($value === 'true') {
            return true;
        }

        if ($value === 'false') {
            return false;
        }

        if (is_numeric($value)) {
            return str_contains((string) $value, '.')
                ? (float) $value
                : (int) $value;
        }

        return $value;
    }

    private function escapeFluxString(string $value): string
    {
        return str_replace(['\\', '"'], ['\\\\', '\\"'], $value);
    }

    private function sanitizeRange(string $range, string $fallback): string
    {
        return preg_match('/^-?[0-9]+[smhdw]$/', trim($range)) === 1
            ? trim($range)
            : $fallback;
    }

    private function sanitizeWindow(string $window, string $fallback): string
    {
        return preg_match('/^[0-9]+[smhdw]$/', trim($window)) === 1
            ? trim($window)
            : $fallback;
    }

    private function buildDeviceFilterExpression(string $deviceId): string
    {
        $deviceEscaped = $this->escapeFluxString(trim($deviceId));
        if ($deviceEscaped === '') {
            return 'true';
        }

        return '(exists r["device_id"] and r["device_id"] == "' . $deviceEscaped . '")'
            . ' or (exists r["device"] and r["device"] == "' . $deviceEscaped . '")'
            . ' or (exists r["device_id"] and strings.containsStr(v: string(v: r["device_id"]), substr: "/' . $deviceEscaped . '/"))'
            . ' or (exists r["device"] and strings.containsStr(v: string(v: r["device"]), substr: "/' . $deviceEscaped . '/"))'
            . ' or (exists r["topic"] and strings.containsStr(v: string(v: r["topic"]), substr: "/' . $deviceEscaped . '/"))'
            . ' or (not exists r["device_id"] and not exists r["device"] and not exists r["topic"])';
    }

    private function topicBaseForDevice(string $deviceId): string
    {
        $configuredBase = trim((string) config('services.incubator.mqtt_topic_base', ''));
        if ($configuredBase !== '') {
            if (str_contains($configuredBase, '{device_id}')) {
                return rtrim(str_replace('{device_id}', $deviceId, $configuredBase), '/');
            }

            return rtrim($configuredBase, '/');
        }

        $area = trim((string) config('services.incubator.mqtt_area', 'incubator'));
        if ($area === '') {
            $area = 'incubator';
        }

        return "buncop/{$area}/{$deviceId}";
    }

    private function extractPayload(array $row): array
    {
        if ($row === []) {
            return [];
        }

        if (isset($row['payload']) && is_string($row['payload'])) {
            $decoded = json_decode($row['payload'], true);
            if (is_array($decoded)) {
                return $decoded;
            }
        }

        return $row;
    }

    private function toNullableFloat(mixed $value): ?float
    {
        if ($value === null || $value === '') {
            return null;
        }
        if (! is_numeric($value)) {
            return null;
        }

        return (float) $value;
    }

    private function toEpochSeconds(mixed $value): ?int
    {
        if ($value === null || $value === '') {
            return null;
        }

        if (is_numeric($value)) {
            $numeric = (float) $value;
            if ($numeric > 2000000000000) {
                return (int) floor($numeric / 1000);
            }

            return (int) floor($numeric);
        }

        try {
            return (int) (new \DateTimeImmutable((string) $value))->format('U');
        } catch (\Throwable) {
            return null;
        }
    }
}
