<?php

namespace App\Services;

class SensorHistoryService
{
    public function __construct(
        private readonly InfluxDbService $influx,
        private readonly MongoDbService $mongodb,
    ) {
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
        foreach ($this->preferredDrivers() as $driver) {
            $rows = match ($driver) {
                'mongodb' => $this->mongodb->getFieldHistory($deviceId, $measurement, $fields, $range, $window),
                default => $this->influx->getFieldHistory($deviceId, $measurement, $fields, $range, $window),
            };

            if ($rows !== []) {
                return $rows;
            }
        }

        return [];
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
        foreach ($this->preferredDrivers() as $driver) {
            $rows = match ($driver) {
                'mongodb' => $this->mongodb->getSensorHistory($deviceId, $measurement, $range, $window),
                default => $this->influx->getSensorHistory($deviceId, $measurement, $range, $window),
            };

            if ($rows !== []) {
                return $rows;
            }
        }

        return [];
    }

    public function rawFieldRows(
        string $measurement,
        string $field,
        string $range = '-1d',
        int $limit = 10
    ): array {
        foreach ($this->preferredDrivers() as $driver) {
            $rows = match ($driver) {
                'mongodb' => $this->mongodb->rawFieldRows($measurement, $field, $range, $limit),
                default => $this->influx->rawFieldRows($measurement, $field, $range, $limit),
            };

            if ($rows !== []) {
                return $rows;
            }
        }

        return [];
    }

    /**
     * @return array<int, string>
     */
    private function preferredDrivers(): array
    {
        $driver = strtolower(trim((string) config('services.sensor_history.driver', 'auto')));

        return match ($driver) {
            'mongodb', 'mongo' => ['mongodb', 'influx'],
            'influx', 'influxdb' => ['influx', 'mongodb'],
            default => ['influx', 'mongodb'],
        };
    }
}
