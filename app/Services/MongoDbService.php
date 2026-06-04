<?php

namespace App\Services;

use DateInterval;
use DateTimeImmutable;
use DateTimeInterface;
use Illuminate\Support\Facades\Log;
use MongoDB\BSON\UTCDateTime;
use MongoDB\Driver\BulkWrite;
use MongoDB\Driver\Manager;
use MongoDB\Driver\Query;

class MongoDbService
{
    private const HISTORY_QUERY_LIMIT = 200000;
    private const BETWEEN_CHUNK_SECONDS = 43200;

    private string $uri;
    private string $database;
    private string $collection;
    /** @var array<string, string> */
    private array $collectionMap;
    private int $timeoutMs;
    private ?string $lastErrorMessage = null;

    public function __construct()
    {
        $this->uri = trim((string) config('services.mongodb.uri', ''));
        $this->database = trim((string) config('services.mongodb.database', ''));
        $this->collection = trim((string) config('services.mongodb.collection', 'sensor_histories'));
        $this->collectionMap = [
            'indoor' => trim((string) config('services.mongodb.collection_indoor', $this->collection ?: 'sensor_histories')),
            'incubator' => trim((string) config('services.mongodb.collection_incubator', 'sensor_histories_incubator')),
            'monitoring' => trim((string) config('services.mongodb.collection_monitoring', 'sensor_histories_monitoring')),
        ];
        $this->timeoutMs = max(1000, (int) config('services.mongodb.timeout_ms', 5000));
    }

    public function isConfigured(): bool
    {
        return $this->uri !== ''
            && $this->database !== ''
            && $this->collection !== ''
            && extension_loaded('mongodb');
    }

    public function lastErrorMessage(): ?string
    {
        return $this->lastErrorMessage;
    }

    /**
     * Upsert a telemetry document into MongoDB.
     *
     * Documents with the same device_id, measurement, and recorded_at
     * are updated in place to avoid duplicate time-series points.
     */
    public function upsertTelemetryDocument(array $document): bool
    {
        $this->lastErrorMessage = null;

        if (! $this->isConfigured()) {
            $this->lastErrorMessage = 'MongoDB belum terkonfigurasi atau extension mongodb belum aktif.';

            return false;
        }

        $normalized = $this->normalizeTelemetryDocument($document);
        if ($normalized === null) {
            $this->lastErrorMessage = 'Dokumen telemetry tidak valid setelah dinormalisasi.';

            return false;
        }

        try {
            $bulk = new BulkWrite();
            $filter = [
                'device_id' => $normalized['device_id'],
                'measurement' => $normalized['measurement'],
                'recorded_at' => $normalized['recorded_at'],
            ];

            $bulk->update(
                $filter,
                [
                    '$set' => $normalized,
                    '$setOnInsert' => [
                        'created_at' => $normalized['ingested_at'],
                    ],
                ],
                ['multi' => false, 'upsert' => true]
            );

            $this->manager()->executeBulkWrite($this->namespace($this->resolveCollectionForMeasurement($normalized['measurement'])), $bulk);

            return true;
        } catch (\Throwable $e) {
            $this->lastErrorMessage = $e->getMessage();

            Log::warning('MongoDB telemetry upsert failed', [
                'message' => $e->getMessage(),
                'database' => $this->database,
                'collection' => $this->collection,
                'device_id' => $normalized['device_id'] ?? null,
                'measurement' => $normalized['measurement'] ?? null,
            ]);

            return false;
        }
    }

    public function getSensorHistory(
        string $deviceId,
        string $measurement = 'incubator_sensor',
        string $range = '-1h',
        string $window = '30s'
    ): array {
        if (! $this->isConfigured()) {
            return [];
        }

        $documents = $this->findDocuments($deviceId, $measurement, $range, $this->estimateDocumentLimitFromRange($range), [
            'temperature',
            'humidity',
            'soil_moisture',
        ]);
        if ($documents === []) {
            return [];
        }

        $grouped = $this->aggregateDocuments($documents, ['temperature', 'humidity', 'soil_moisture'], $window);
        $rows = [];

        foreach ($grouped as $bucket) {
            $rows[] = [
                'timestamp' => $bucket['timestamp'],
                'temperature' => $bucket['fields']['temperature'] ?? null,
                'humidity' => $bucket['fields']['humidity'] ?? null,
                'soil_moisture' => $bucket['fields']['soil_moisture'] ?? null,
            ];
        }

        return $rows;
    }

    public function getSensorHistoryBetween(
        string $deviceId,
        string $measurement,
        DateTimeInterface $start,
        DateTimeInterface $end,
        string $window = '30s'
    ): array {
        if (! $this->isConfigured()) {
            return [];
        }

        $documents = $this->findDocumentsBetween($deviceId, $measurement, $start, $end, $this->estimateDocumentLimitFromSpan($start, $end), [
            'temperature',
            'humidity',
            'soil_moisture',
        ]);
        if ($documents === []) {
            return [];
        }

        $grouped = $this->aggregateDocuments($documents, ['temperature', 'humidity', 'soil_moisture'], $window);
        $rows = [];

        foreach ($grouped as $bucket) {
            $rows[] = [
                'timestamp' => $bucket['timestamp'],
                'temperature' => $bucket['fields']['temperature'] ?? null,
                'humidity' => $bucket['fields']['humidity'] ?? null,
                'soil_moisture' => $bucket['fields']['soil_moisture'] ?? null,
            ];
        }

        return $rows;
    }

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

        $documents = $this->findDocuments($deviceId, $measurement, $range, $this->estimateDocumentLimitFromRange($range), $normalizedFields);
        if ($documents === []) {
            return [];
        }

        $grouped = $this->aggregateDocuments($documents, $normalizedFields, $window);
        $seriesMap = [];

        foreach ($normalizedFields as $field) {
            $seriesMap[$field] = [
                'field' => $field,
                'points' => [],
            ];
        }

        foreach ($grouped as $bucket) {
            foreach ($normalizedFields as $field) {
                $value = $bucket['fields'][$field] ?? null;
                if ($value === null) {
                    continue;
                }

                $seriesMap[$field]['points'][] = [
                    'timestamp' => $bucket['timestamp'],
                    'value' => $value,
                ];
            }
        }

        return array_values(array_filter($seriesMap, static fn (array $series) => $series['points'] !== []));
    }

    public function getFieldHistoryBetween(
        string $deviceId,
        string $measurement,
        array $fields,
        DateTimeInterface $start,
        DateTimeInterface $end,
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

        $documents = $this->findDocumentsBetween($deviceId, $measurement, $start, $end, $this->estimateDocumentLimitFromSpan($start, $end), $normalizedFields);
        if ($documents === []) {
            return [];
        }

        $grouped = $this->aggregateDocuments($documents, $normalizedFields, $window);
        $seriesMap = [];

        foreach ($normalizedFields as $field) {
            $seriesMap[$field] = [
                'field' => $field,
                'points' => [],
            ];
        }

        foreach ($grouped as $bucket) {
            foreach ($normalizedFields as $field) {
                $value = $bucket['fields'][$field] ?? null;
                if ($value === null) {
                    continue;
                }

                $seriesMap[$field]['points'][] = [
                    'timestamp' => $bucket['timestamp'],
                    'value' => $value,
                ];
            }
        }

        return array_values(array_filter($seriesMap, static fn (array $series) => $series['points'] !== []));
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

        $field = preg_match('/^[A-Za-z0-9_]+$/', $field) === 1 ? $field : 'temperature';
        $documents = $this->findDocuments('', $measurement, $range, max(1, min(100, $limit)));
        $rows = [];

        foreach ($documents as $document) {
            $value = $this->extractNumericField($document, $field);
            if ($value === null) {
                continue;
            }

            $rows[] = [
                '_time' => $this->extractTimeIso8601($document),
                '_measurement' => $this->extractMeasurement($document),
                '_field' => $field,
                '_value' => $value,
                'device' => $this->extractStringField($document, ['device', 'topic']),
                'device_id' => $this->extractStringField($document, ['device_id']),
                'topic' => $this->extractStringField($document, ['topic']),
            ];
        }

        return $rows;
    }

    /**
     * @return array<int, array<string, mixed>>
     */
    public function getTelemetryDocuments(
        string $deviceId,
        string $measurement,
        string $range = '-1d',
        int $limit = 5000
    ): array {
        if (! $this->isConfigured()) {
            return [];
        }

        $documents = $this->findDocuments($deviceId, $measurement, $range, $limit);
        $rows = [];

        foreach ($documents as $document) {
            $timestamp = $this->extractEpochSeconds($document);
            if ($timestamp === null) {
                continue;
            }

            $rows[] = [
                'timestamp' => $timestamp,
                'time' => $this->extractTimeIso8601($document),
                'measurement' => $this->extractMeasurement($document),
                'device_id' => $this->extractStringField($document, ['device_id']) ?? $deviceId,
                'device' => $this->extractStringField($document, ['device', 'topic']),
                'topic' => $this->extractStringField($document, ['topic']),
                'source' => $this->extractStringField($document, ['source']) ?? 'mongodb',
                'temperature' => $this->extractNumericField($document, 'temperature'),
                'humidity' => $this->extractNumericField($document, 'humidity'),
                'soil_moisture' => $this->extractNumericField($document, 'soil_moisture'),
                'do' => $this->extractNumericField($document, 'do'),
                'ec_us' => $this->extractNumericField($document, 'ec_us'),
                'ec_ms' => $this->extractNumericField($document, 'ec_ms'),
                'ppm' => $this->extractNumericField($document, 'ppm'),
                'tds' => $this->extractNumericField($document, 'tds'),
                'ph' => $this->extractNumericField($document, 'ph'),
                'payload' => is_array($document['payload'] ?? null) ? $document['payload'] : null,
            ];
        }

        return $rows;
    }

    /**
     * @return array<int, array<string, mixed>>
     */
    public function getTelemetryDocumentsBetween(
        string $deviceId,
        string $measurement,
        DateTimeInterface $start,
        DateTimeInterface $end,
        int $limit = 10000
    ): array {
        if (! $this->isConfigured()) {
            return [];
        }

        $documents = $this->findDocumentsBetween($deviceId, $measurement, $start, $end, min($limit, $this->estimateDocumentLimitFromSpan($start, $end)));
        $rows = [];

        foreach ($documents as $document) {
            $timestamp = $this->extractEpochSeconds($document);
            if ($timestamp === null) {
                continue;
            }

            $rows[] = [
                'timestamp' => $timestamp,
                'time' => $this->extractTimeIso8601($document),
                'measurement' => $this->extractMeasurement($document),
                'device_id' => $this->extractStringField($document, ['device_id']) ?? $deviceId,
                'device' => $this->extractStringField($document, ['device', 'topic']),
                'topic' => $this->extractStringField($document, ['topic']),
                'source' => $this->extractStringField($document, ['source']) ?? 'mongodb',
                'temperature' => $this->extractNumericField($document, 'temperature'),
                'humidity' => $this->extractNumericField($document, 'humidity'),
                'soil_moisture' => $this->extractNumericField($document, 'soil_moisture'),
                'do' => $this->extractNumericField($document, 'do'),
                'ec_us' => $this->extractNumericField($document, 'ec_us'),
                'ec_ms' => $this->extractNumericField($document, 'ec_ms'),
                'ppm' => $this->extractNumericField($document, 'ppm'),
                'tds' => $this->extractNumericField($document, 'tds'),
                'ph' => $this->extractNumericField($document, 'ph'),
                'payload' => is_array($document['payload'] ?? null) ? $document['payload'] : null,
            ];
        }

        return $rows;
    }

    /**
     * @return array<int, array<string, mixed>>
     */
    private function findDocuments(
        string $deviceId,
        string $measurement,
        string $range,
        int $limit = self::HISTORY_QUERY_LIMIT,
        array $fields = []
    ): array
    {
        try {
            $manager = $this->manager();
            $collection = $this->resolveCollectionForMeasurement($measurement);

            $filter = $this->buildIndexedFindFilter($deviceId, $measurement, $range);
            $options = [
                // Read newest rows first so capped queries keep the latest telemetry.
                'sort' => ['recorded_at' => -1, 'timestamp' => -1, 'time' => -1, '_id' => -1],
                'limit' => max(1, min(self::HISTORY_QUERY_LIMIT, $limit)),
            ];
            $projection = $this->buildFieldProjection($fields);
            if ($projection !== []) {
                $options['projection'] = $projection;
            }
            $query = new Query($filter, $options);

            $cursor = $manager->executeQuery($this->namespace($collection), $query);
            $cursor->setTypeMap(['root' => 'array', 'document' => 'array', 'array' => 'array']);
            $documents = iterator_to_array($cursor, false);

            $threshold = $this->rangeStartDate($range);
            if ($documents === [] || $this->shouldBackfillLegacyDocuments($documents, $threshold)) {
                $fallbackQuery = new Query($this->buildFindFilter($deviceId, $measurement, $range), $options);
                $fallbackCursor = $manager->executeQuery($this->namespace($collection), $fallbackQuery);
                $fallbackCursor->setTypeMap(['root' => 'array', 'document' => 'array', 'array' => 'array']);
                $fallbackDocuments = iterator_to_array($fallbackCursor, false);
                $documents = $this->mergeDocumentsDescending($documents, $fallbackDocuments, $limit);
            }

            return array_reverse($documents);
        } catch (\Throwable $e) {
            Log::warning('MongoDB query exception', [
                'message' => $e->getMessage(),
                'database' => $this->database,
                'collection' => $this->collection,
                'device_id' => $deviceId,
                'measurement' => $measurement,
                'range' => $range,
                'limit' => $limit,
            ]);

            return [];
        }
    }

    /**
     * @return array<int, array<string, mixed>>
     */
    private function findDocumentsBetween(
        string $deviceId,
        string $measurement,
        DateTimeInterface $start,
        DateTimeInterface $end,
        int $limit = self::HISTORY_QUERY_LIMIT,
        array $fields = []
    ): array {
        $startTs = $start->getTimestamp();
        $endTs = $end->getTimestamp();

        if (($endTs - $startTs) > self::BETWEEN_CHUNK_SECONDS) {
            $merged = [];
            $cursorStart = $startTs;

            while ($cursorStart < $endTs) {
                $cursorEnd = min($cursorStart + self::BETWEEN_CHUNK_SECONDS, $endTs);
                $chunkStart = (new DateTimeImmutable('@' . $cursorStart))->setTimezone(new \DateTimeZone('UTC'));
                $chunkEnd = (new DateTimeImmutable('@' . $cursorEnd))->setTimezone(new \DateTimeZone('UTC'));
                $chunkDocuments = $this->findDocumentsBetweenWindow(
                    $deviceId,
                    $measurement,
                    $chunkStart,
                    $chunkEnd,
                    $limit,
                    $fields
                );
                $merged = $this->mergeDocumentsDescending($merged, $chunkDocuments, $limit);
                $cursorStart = $cursorEnd;
            }

            return $this->filterDocumentsByTimestampRange($merged, $start, $end, $limit);
        }

        return $this->findDocumentsBetweenWindow($deviceId, $measurement, $start, $end, $limit, $fields);
    }

    /**
     * @return array<int, array<string, mixed>>
     */
    private function findDocumentsBetweenWindow(
        string $deviceId,
        string $measurement,
        DateTimeInterface $start,
        DateTimeInterface $end,
        int $limit = self::HISTORY_QUERY_LIMIT,
        array $fields = []
    ): array {
        try {
            $manager = $this->manager();
            $collection = $this->resolveCollectionForMeasurement($measurement);

            $filter = $this->buildIndexedFindFilterBetween($deviceId, $measurement, $start, $end);
            $options = [
                'sort' => ['recorded_at' => -1, 'timestamp' => -1, 'time' => -1, '_id' => -1],
                'limit' => max(1, min(self::HISTORY_QUERY_LIMIT, $limit)),
            ];
            $projection = $this->buildFieldProjection($fields);
            if ($projection !== []) {
                $options['projection'] = $projection;
            }
            $query = new Query($filter, $options);

            $cursor = $manager->executeQuery($this->namespace($collection), $query);
            $cursor->setTypeMap(['root' => 'array', 'document' => 'array', 'array' => 'array']);
            $documents = iterator_to_array($cursor, false);

            if ($documents === [] || $this->shouldBackfillLegacyDocuments($documents, $start)) {
                $fallbackQuery = new Query($this->buildFindFilterBetween($deviceId, $measurement, $start, $end), $options);
                $fallbackCursor = $manager->executeQuery($this->namespace($collection), $fallbackQuery);
                $fallbackCursor->setTypeMap(['root' => 'array', 'document' => 'array', 'array' => 'array']);
                $fallbackDocuments = iterator_to_array($fallbackCursor, false);
                $documents = $this->mergeDocumentsDescending($documents, $fallbackDocuments, $limit);
            }

            if ($documents !== []) {
                return $this->filterDocumentsByTimestampRange($documents, $start, $end, $limit);
            }

            $fallbackRange = $this->relativeRangeFromDate($start);
            $fallbackFilter = $this->buildFindFilter($deviceId, $measurement, $fallbackRange);
            $fallbackOptions = [
                'sort' => ['recorded_at' => -1, 'timestamp' => -1, 'time' => -1, '_id' => -1],
                'limit' => max(1, min(self::HISTORY_QUERY_LIMIT, max($limit * 5, 20000))),
            ];
            if ($projection !== []) {
                $fallbackOptions['projection'] = $projection;
            }
            $fallbackQuery = new Query($fallbackFilter, $fallbackOptions);
            $fallbackCursor = $manager->executeQuery($this->namespace($collection), $fallbackQuery);
            $fallbackCursor->setTypeMap(['root' => 'array', 'document' => 'array', 'array' => 'array']);
            $fallbackDocuments = iterator_to_array($fallbackCursor, false);

            return $this->filterDocumentsByTimestampRange($fallbackDocuments, $start, $end, $limit);
        } catch (\Throwable $e) {
            Log::warning('MongoDB query exception', [
                'message' => $e->getMessage(),
                'database' => $this->database,
                'collection' => $this->collection,
                'device_id' => $deviceId,
                'measurement' => $measurement,
                'start' => $start->format(DATE_ATOM),
                'end' => $end->format(DATE_ATOM),
                'limit' => $limit,
            ]);

            return [];
        }
    }

    /**
     * @param array<int, array<string, mixed>> $documents
     * @param array<int, string> $fields
     * @return array<int, array{timestamp:int, fields:array<string, float|null>}>
     */
    private function aggregateDocuments(array $documents, array $fields, string $window): array
    {
        $windowSeconds = $this->windowToSeconds($window);
        $buckets = [];

        foreach ($documents as $document) {
            $timestamp = $this->extractEpochSeconds($document);
            if ($timestamp === null) {
                continue;
            }

            $bucketTs = (int) floor($timestamp / $windowSeconds) * $windowSeconds;
            $bucketKey = (string) $bucketTs;

            if (! isset($buckets[$bucketKey])) {
                $buckets[$bucketKey] = [
                    'timestamp' => $bucketTs,
                    'sums' => [],
                    'counts' => [],
                ];
            }

            foreach ($fields as $field) {
                $value = $this->extractNumericField($document, $field);
                if ($value === null) {
                    continue;
                }

                $buckets[$bucketKey]['sums'][$field] = ($buckets[$bucketKey]['sums'][$field] ?? 0.0) + $value;
                $buckets[$bucketKey]['counts'][$field] = ($buckets[$bucketKey]['counts'][$field] ?? 0) + 1;
            }
        }

        ksort($buckets, SORT_NUMERIC);

        $rows = [];
        foreach ($buckets as $bucket) {
            $fieldAverages = [];
            foreach ($fields as $field) {
                $count = (int) ($bucket['counts'][$field] ?? 0);
                $fieldAverages[$field] = $count > 0
                    ? round(((float) ($bucket['sums'][$field] ?? 0.0)) / $count, 6)
                    : null;
            }

            $rows[] = [
                'timestamp' => $bucket['timestamp'],
                'fields' => $fieldAverages,
            ];
        }

        return $rows;
    }

    /**
     * @return array<string, mixed>
     */
    private function buildFindFilter(string $deviceId, string $measurement, string $range): array
    {
        $filter = [];

        $timeThreshold = $this->rangeStartDate($range);
        if ($timeThreshold !== null) {
            $epochSeconds = $timeThreshold->getTimestamp();
            $epochMs = $epochSeconds * 1000;
            $utcDateTime = new UTCDateTime($epochMs);
            $isoThreshold = gmdate(DATE_ATOM, $epochSeconds);
            $filter['$or'] = [
                ['recorded_at' => ['$gte' => $utcDateTime]],
                ['timestamp' => ['$gte' => $utcDateTime]],
                ['time' => ['$gte' => $utcDateTime]],
                ['payload.recorded_at' => ['$gte' => $utcDateTime]],
                ['payload.time' => ['$gte' => $utcDateTime]],
                ['timestamp' => ['$gte' => $epochSeconds]],
                ['timestamp' => ['$gte' => $epochMs]],
                ['payload.timestamp' => ['$gte' => $epochSeconds]],
                ['payload.timestamp' => ['$gte' => $epochMs]],
                ['recorded_at' => ['$gte' => $isoThreshold]],
                ['time' => ['$gte' => $isoThreshold]],
                ['payload.recorded_at' => ['$gte' => $isoThreshold]],
                ['payload.time' => ['$gte' => $isoThreshold]],
            ];
        }

        $measurement = trim($measurement);
        if ($measurement !== '') {
            $filter['$and'][] = [
                '$or' => [
                    ['measurement' => $measurement],
                    ['payload.measurement' => $measurement],
                    ['_measurement' => $measurement],
                ],
            ];
        }

        $deviceId = trim($deviceId);
        if ($deviceId !== '') {
            $deviceRegex = new \MongoDB\BSON\Regex(preg_quote($deviceId, '/'), 'i');
            $filter['$and'][] = [
                '$or' => [
                    ['device_id' => $deviceId],
                    ['device' => $deviceId],
                    ['topic' => $deviceRegex],
                    ['device_id' => $deviceRegex],
                    ['device' => $deviceRegex],
                    ['payload.device_id' => $deviceId],
                    ['payload.device' => $deviceId],
                ],
            ];
        }

        if (! isset($filter['$and'])) {
            return $filter;
        }

        return $filter;
    }

    /**
     * Fast path for the normalized telemetry schema stored by this app.
     *
     * This keeps long-range history queries on the most selective keys first
     * so MongoDB can avoid scanning fallback timestamp/topic variants unless
     * the dataset is actually in an older shape.
     *
     * @return array<string, mixed>
     */
    private function buildIndexedFindFilter(string $deviceId, string $measurement, string $range): array
    {
        $filter = [];

        $measurement = trim($measurement);
        if ($measurement !== '') {
            $filter['measurement'] = $measurement;
        }

        $deviceId = trim($deviceId);
        if ($deviceId !== '') {
            $filter['device_id'] = $deviceId;
        }

        $timeThreshold = $this->rangeStartDate($range);
        if ($timeThreshold !== null) {
            $filter['recorded_at'] = ['$gte' => new UTCDateTime($timeThreshold->getTimestamp() * 1000)];
        }

        return $filter;
    }

    /**
     * @param array<int, array<string, mixed>> $documents
     * @return array<int, array<string, mixed>>
     */
    private function filterDocumentsByTimestampRange(
        array $documents,
        DateTimeInterface $start,
        DateTimeInterface $end,
        int $limit
    ): array {
        $startTs = $start->getTimestamp();
        $endTs = $end->getTimestamp();
        $rows = [];

        foreach ($documents as $document) {
            $timestamp = $this->extractEpochSeconds($document);
            if ($timestamp === null) {
                continue;
            }

            if ($timestamp < $startTs || $timestamp > $endTs) {
                continue;
            }

            $rows[] = $document;
            if (count($rows) >= max(1, min(self::HISTORY_QUERY_LIMIT, $limit))) {
                break;
            }
        }

        return array_reverse($rows);
    }

    /**
     * @param array<int, array<string, mixed>> $documents
     */
    private function shouldBackfillLegacyDocuments(array $documents, ?DateTimeInterface $expectedStart): bool
    {
        if ($documents === [] || $expectedStart === null) {
            return $documents === [];
        }

        $oldestTimestamp = null;
        foreach ($documents as $document) {
            $timestamp = $this->extractEpochSeconds($document);
            if ($timestamp === null) {
                continue;
            }

            $oldestTimestamp = $oldestTimestamp === null
                ? $timestamp
                : min($oldestTimestamp, $timestamp);
        }

        if ($oldestTimestamp === null) {
            return true;
        }

        return $oldestTimestamp > ($expectedStart->getTimestamp() + 300);
    }

    /**
     * @param array<int, array<string, mixed>> $primary
     * @param array<int, array<string, mixed>> $fallback
     * @return array<int, array<string, mixed>>
     */
    private function mergeDocumentsDescending(array $primary, array $fallback, int $limit): array
    {
        $merged = [];
        $seen = [];

        foreach (array_merge($primary, $fallback) as $document) {
            $signature = md5(json_encode($document, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES) ?: serialize($document));
            if (isset($seen[$signature])) {
                continue;
            }

            $seen[$signature] = true;
            $merged[] = $document;
        }

        usort($merged, function (array $left, array $right): int {
            $leftTs = $this->extractEpochSeconds($left) ?? 0;
            $rightTs = $this->extractEpochSeconds($right) ?? 0;

            return $rightTs <=> $leftTs;
        });

        return array_slice($merged, 0, max(1, min(self::HISTORY_QUERY_LIMIT, $limit)));
    }

    /**
     * @return array<string, mixed>
     */
    private function buildFindFilterBetween(
        string $deviceId,
        string $measurement,
        DateTimeInterface $start,
        DateTimeInterface $end
    ): array {
        $filter = [];
        $startSeconds = $start->getTimestamp();
        $endSeconds = $end->getTimestamp();
        $startMs = $startSeconds * 1000;
        $endMs = $endSeconds * 1000;
        $startUtc = new UTCDateTime($startMs);
        $endUtc = new UTCDateTime($endMs);
        $startIso = gmdate(DATE_ATOM, $startSeconds);
        $endIso = gmdate(DATE_ATOM, $endSeconds);

        $filter['$or'] = [
            ['recorded_at' => ['$gte' => $startUtc, '$lte' => $endUtc]],
            ['timestamp' => ['$gte' => $startUtc, '$lte' => $endUtc]],
            ['time' => ['$gte' => $startUtc, '$lte' => $endUtc]],
            ['payload.recorded_at' => ['$gte' => $startUtc, '$lte' => $endUtc]],
            ['payload.time' => ['$gte' => $startUtc, '$lte' => $endUtc]],
            ['timestamp' => ['$gte' => $startSeconds, '$lte' => $endSeconds]],
            ['timestamp' => ['$gte' => $startMs, '$lte' => $endMs]],
            ['payload.timestamp' => ['$gte' => $startSeconds, '$lte' => $endSeconds]],
            ['payload.timestamp' => ['$gte' => $startMs, '$lte' => $endMs]],
            ['recorded_at' => ['$gte' => $startIso, '$lte' => $endIso]],
            ['time' => ['$gte' => $startIso, '$lte' => $endIso]],
            ['payload.recorded_at' => ['$gte' => $startIso, '$lte' => $endIso]],
            ['payload.time' => ['$gte' => $startIso, '$lte' => $endIso]],
        ];

        $measurement = trim($measurement);
        if ($measurement !== '') {
            $filter['$and'][] = [
                '$or' => [
                    ['measurement' => $measurement],
                    ['payload.measurement' => $measurement],
                    ['_measurement' => $measurement],
                ],
            ];
        }

        $deviceId = trim($deviceId);
        if ($deviceId !== '') {
            $deviceRegex = new \MongoDB\BSON\Regex(preg_quote($deviceId, '/'), 'i');
            $filter['$and'][] = [
                '$or' => [
                    ['device_id' => $deviceId],
                    ['device' => $deviceId],
                    ['topic' => $deviceRegex],
                    ['device_id' => $deviceRegex],
                    ['device' => $deviceRegex],
                    ['payload.device_id' => $deviceId],
                    ['payload.device' => $deviceId],
                ],
            ];
        }

        if (! isset($filter['$and'])) {
            return $filter;
        }

        return $filter;
    }

    /**
     * @return array<string, mixed>
     */
    private function buildIndexedFindFilterBetween(
        string $deviceId,
        string $measurement,
        DateTimeInterface $start,
        DateTimeInterface $end
    ): array {
        $filter = [
            'recorded_at' => [
                '$gte' => new UTCDateTime($start->getTimestamp() * 1000),
                '$lte' => new UTCDateTime($end->getTimestamp() * 1000),
            ],
        ];

        $measurement = trim($measurement);
        if ($measurement !== '') {
            $filter['measurement'] = $measurement;
        }

        $deviceId = trim($deviceId);
        if ($deviceId !== '') {
            $filter['device_id'] = $deviceId;
        }

        return $filter;
    }

    private function extractMeasurement(array $document): string
    {
        foreach (['measurement', '_measurement'] as $field) {
            $value = $document[$field] ?? null;
            if (is_string($value) && trim($value) !== '') {
                return trim($value);
            }
        }

        $payloadMeasurement = data_get($document, 'payload.measurement');
        return is_string($payloadMeasurement) ? trim($payloadMeasurement) : '';
    }

    private function extractNumericField(array $document, string $field): ?float
    {
        $candidates = [
            $document[$field] ?? null,
            data_get($document, "payload.{$field}"),
        ];

        if ($field === 'do') {
            $candidates[] = $document['do_value'] ?? null;
            $candidates[] = data_get($document, 'payload.do_value');
            $candidates[] = $document['dissolved_oxygen'] ?? null;
            $candidates[] = data_get($document, 'payload.dissolved_oxygen');
        }

        if ($field === 'ph') {
            $candidates[] = $document['pH'] ?? null;
            $candidates[] = data_get($document, 'payload.pH');
        }

        foreach ($candidates as $candidate) {
            if (is_numeric($candidate)) {
                $numeric = (float) $candidate;
                if (is_finite($numeric)) {
                    return $numeric;
                }
            }
        }

        return null;
    }

    private function extractStringField(array $document, array $fields): ?string
    {
        foreach ($fields as $field) {
            $value = $document[$field] ?? null;
            if (is_string($value) && trim($value) !== '') {
                return trim($value);
            }
        }

        return null;
    }

    private function extractEpochSeconds(array $document): ?int
    {
        $candidates = [
            $document['recorded_at'] ?? null,
            $document['timestamp'] ?? null,
            $document['time'] ?? null,
            data_get($document, 'payload.recorded_at'),
            data_get($document, 'payload.timestamp'),
            data_get($document, 'payload.time'),
        ];

        foreach ($candidates as $candidate) {
            if ($candidate instanceof UTCDateTime) {
                return (int) floor($candidate->toDateTime()->getTimestamp());
            }

            if ($candidate instanceof DateTimeInterface) {
                return (int) floor($candidate->getTimestamp());
            }

            if (is_numeric($candidate)) {
                $numeric = (float) $candidate;
                if ($numeric > 1000000000000) {
                    return (int) floor($numeric / 1000);
                }

                if ($numeric > 1000000000) {
                    return (int) floor($numeric);
                }
            }

            if (is_string($candidate) && trim($candidate) !== '') {
                try {
                    return (new DateTimeImmutable($candidate))->getTimestamp();
                } catch (\Throwable) {
                    continue;
                }
            }

            if (is_array($candidate)) {
                $normalized = $this->extractEpochSecondsFromExtendedJson($candidate);
                if ($normalized !== null) {
                    return $normalized;
                }
            }
        }

        return null;
    }

    /**
     * Normalize Mongo Extended JSON date payloads produced by json_encode().
     *
     * @param array<string, mixed> $candidate
     */
    private function extractEpochSecondsFromExtendedJson(array $candidate): ?int
    {
        $dateValue = $candidate['$date'] ?? null;

        if (is_string($dateValue) && trim($dateValue) !== '') {
            try {
                return (new DateTimeImmutable($dateValue))->getTimestamp();
            } catch (\Throwable) {
                return null;
            }
        }

        if (is_array($dateValue)) {
            $numberLong = $dateValue['$numberLong'] ?? null;
            if (is_numeric($numberLong)) {
                return (int) floor(((float) $numberLong) / 1000);
            }
        }

        return null;
    }

    private function extractTimeIso8601(array $document): ?string
    {
        $timestamp = $this->extractEpochSeconds($document);
        if ($timestamp === null) {
            return null;
        }

        return gmdate(DATE_ATOM, $timestamp);
    }

    private function rangeStartDate(string $range): ?DateTimeImmutable
    {
        $range = trim($range);
        if (preg_match('/^-([0-9]+)([smhdw])$/', $range, $matches) !== 1) {
            return null;
        }

        $amount = max(1, (int) $matches[1]);
        $unit = $matches[2];
        $intervalMap = [
            's' => "PT{$amount}S",
            'm' => "PT{$amount}M",
            'h' => "PT{$amount}H",
            'd' => "P{$amount}D",
            'w' => "P{$amount}W",
        ];

        try {
            return (new DateTimeImmutable('now'))->sub(new DateInterval($intervalMap[$unit]));
        } catch (\Throwable) {
            return null;
        }
    }

    private function relativeRangeFromDate(DateTimeInterface $start): string
    {
        $seconds = max(60, time() - $start->getTimestamp());

        if ($seconds <= 3600) {
            return '-' . (string) max(1, (int) ceil($seconds / 60)) . 'm';
        }

        if ($seconds <= 86400) {
            return '-' . (string) max(1, (int) ceil($seconds / 60)) . 'm';
        }

        if ($seconds <= 604800) {
            return '-' . (string) max(1, (int) ceil($seconds / 3600)) . 'h';
        }

        if ($seconds <= 2592000) {
            return '-' . (string) max(1, (int) ceil($seconds / 86400)) . 'd';
        }

        return '-' . (string) max(1, (int) ceil($seconds / 604800)) . 'w';
    }

    private function windowToSeconds(string $window): int
    {
        if (preg_match('/^([0-9]+)([smhd])$/', trim($window), $matches) !== 1) {
            return 30;
        }

        $amount = max(1, (int) $matches[1]);
        return match ($matches[2]) {
            's' => $amount,
            'm' => $amount * 60,
            'h' => $amount * 3600,
            'd' => $amount * 86400,
            default => 30,
        };
    }

    private function estimateDocumentLimitFromRange(string $range): int
    {
        $start = $this->rangeStartDate($range);
        if ($start === null) {
            return min(self::HISTORY_QUERY_LIMIT, 25000);
        }

        return $this->estimateDocumentLimitFromSpan($start, new DateTimeImmutable('now'));
    }

    private function estimateDocumentLimitFromSpan(DateTimeInterface $start, DateTimeInterface $end): int
    {
        $spanSeconds = max(60, $end->getTimestamp() - $start->getTimestamp());

        // Assume high-frequency telemetry up to one point every 5 seconds,
        // then add a modest safety buffer for duplicate/legacy rows.
        $estimated = (int) ceil($spanSeconds / 5) + 2000;

        return max(5000, min(self::HISTORY_QUERY_LIMIT, $estimated));
    }

    private function manager(): Manager
    {
        return new Manager($this->uri, [], [
            'serverSelectionTimeoutMS' => $this->timeoutMs,
            'connectTimeoutMS' => $this->timeoutMs,
            'socketTimeoutMS' => $this->timeoutMs,
        ]);
    }

    private function namespace(?string $collection = null): string
    {
        $selectedCollection = trim((string) ($collection ?: $this->collection));
        if ($selectedCollection === '') {
            $selectedCollection = 'sensor_histories';
        }

        return "{$this->database}.{$selectedCollection}";
    }

    private function resolveCollectionForMeasurement(string $measurement): string
    {
        $measurement = strtolower(trim($measurement));
        if ($measurement === '') {
            return $this->collection;
        }

        if ($measurement === 'indoor_farming_sensor' || str_contains($measurement, 'indoor_farming')) {
            return $this->collectionMap['indoor'] ?: $this->collection;
        }

        if ($measurement === 'incubator_sensor' || str_contains($measurement, 'incubator') || str_contains($measurement, 'inkubator')) {
            return $this->collectionMap['incubator'] ?: $this->collection;
        }

        if ($measurement === 'monitoring_sensor' || str_starts_with($measurement, 'monitoring_')) {
            return $this->collectionMap['monitoring'] ?: $this->collection;
        }

        return $this->collection;
    }

    /**
     * @param array<int, string> $fields
     * @return array<string, int>
     */
    private function buildFieldProjection(array $fields): array
    {
        $projection = [
            '_id' => 1,
            'measurement' => 1,
            '_measurement' => 1,
            'recorded_at' => 1,
            'timestamp' => 1,
            'time' => 1,
            'payload.recorded_at' => 1,
            'payload.timestamp' => 1,
            'payload.time' => 1,
        ];

        foreach ($fields as $field) {
            $normalized = preg_match('/^[A-Za-z0-9_]+$/', (string) $field) === 1 ? (string) $field : '';
            if ($normalized === '') {
                continue;
            }

            $projection[$normalized] = 1;
            $projection["payload.{$normalized}"] = 1;

            if ($normalized === 'do') {
                $projection['do_value'] = 1;
                $projection['dissolved_oxygen'] = 1;
                $projection['payload.do_value'] = 1;
                $projection['payload.dissolved_oxygen'] = 1;
            }

            if ($normalized === 'ph') {
                $projection['pH'] = 1;
                $projection['payload.pH'] = 1;
            }
        }

        return $projection;
    }

    /**
     * @param array<string, mixed> $document
     * @return array<string, mixed>|null
     */
    private function normalizeTelemetryDocument(array $document): ?array
    {
        $deviceId = trim((string) ($document['device_id'] ?? ''));
        $measurement = trim((string) ($document['measurement'] ?? ''));
        if ($deviceId === '' || $measurement === '') {
            return null;
        }

        $rawPayload = is_array($document['raw_payload'] ?? null)
            ? $document['raw_payload']
            : (is_array($document['payload'] ?? null) ? $document['payload'] : []);

        $recordedAt = $this->normalizeDate($document['recorded_at'] ?? null)
            ?? $this->normalizeDate($rawPayload['recorded_at'] ?? null)
            ?? $this->normalizeDate($rawPayload['timestamp'] ?? null)
            ?? $this->normalizeDate($rawPayload['time'] ?? null)
            ?? $this->normalizeDate('now');

        if ($recordedAt === null) {
            return null;
        }

        $ingestedAt = $this->normalizeDate($document['ingested_at'] ?? null) ?? new UTCDateTime();

        $normalized = [
            'device_id' => $deviceId,
            'measurement' => $measurement,
            'topic' => $this->normalizeNullableString($document['topic'] ?? null),
            'source' => $this->normalizeNullableString($document['source'] ?? 'mqtt_worker'),
            'device' => $this->normalizeNullableString($document['device'] ?? null),
            'client_id' => $this->normalizeNullableString($document['client_id'] ?? null),
            'retained' => (bool) ($document['retained'] ?? false),
            'recorded_at' => $recordedAt,
            'ingested_at' => $ingestedAt,
            'payload' => $rawPayload,
            'raw_payload' => $rawPayload,
        ];

        foreach (['temperature', 'humidity', 'soil_moisture', 'do', 'ec_us', 'ec_ms', 'ppm', 'tds', 'ph', 'nh3', 'ch4', 'weight_g', 'target_weight_g'] as $field) {
            $value = $document[$field] ?? $rawPayload[$field] ?? null;

            if ($field === 'do' && $value === null) {
                $value = $document['do_value'] ?? $document['dissolved_oxygen'] ?? $rawPayload['do_value'] ?? $rawPayload['dissolved_oxygen'] ?? null;
            }

            if (is_numeric($value)) {
                $normalized[$field] = (float) $value;
            }
        }

        return array_filter(
            $normalized,
            static fn ($value, $key) => $value !== null || in_array($key, ['topic', 'source', 'device', 'client_id'], true),
            ARRAY_FILTER_USE_BOTH
        );
    }

    private function normalizeNullableString(mixed $value): ?string
    {
        if (! is_string($value)) {
            return null;
        }

        $trimmed = trim($value);
        return $trimmed !== '' ? $trimmed : null;
    }

    private function normalizeDate(mixed $value): ?UTCDateTime
    {
        if ($value instanceof UTCDateTime) {
            return $value;
        }

        if ($value instanceof DateTimeInterface) {
            return new UTCDateTime($value->getTimestamp() * 1000);
        }

        if (is_numeric($value)) {
            $numeric = (float) $value;
            $millis = $numeric > 1000000000000
                ? (int) round($numeric)
                : (int) round($numeric * 1000);

            return new UTCDateTime($millis);
        }

        if (is_string($value) && trim($value) !== '') {
            try {
                return new UTCDateTime((new DateTimeImmutable($value))->getTimestamp() * 1000);
            } catch (\Throwable) {
                return null;
            }
        }

        return null;
    }
}
