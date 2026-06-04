# EMQX Rules & InfluxDB Integration Guide
## BunCOP IoT — MQTT Migration

### Existing Rule (already deployed)
- **Rule ID**: `rule_iuhy`
- **SQL**: `SELECT payload.temperature, payload.humidity, topic FROM "buncop/+/+/telemetry"`
- **Action**: Write to InfluxDB via connector `Influx_buncop`
- **Write Syntax**: `incubator_sensor,device ${topic} temperature ${temperature},humidity ${humidity}`

> This rule only writes **incubator** sensor data as measurement `incubator_sensor`.
> After migration, nutrimix and monitoring devices also publish to telemetry topics.
> We need to either expand the existing rule or add new rules per area.

---

## Recommended Approach: Per-Area Rules

### Rule 1 — Incubator Telemetry (update existing `rule_iuhy`)

**SQL:**
```sql
SELECT
  payload.temperature,
  payload.humidity,
  topic as device
FROM "buncop/incubator/+/telemetry"
```

**InfluxDB Write Syntax (Line Protocol):**
```
incubator_sensor,device=${device} temperature=${temperature},humidity=${humidity}
```

---

### Rule 2 — Monitoring Telemetry (new)

**Rule Name**: `rule_monitoring_telemetry`

**SQL:**
```sql
SELECT
  payload.temperature,
  payload.humidity,
  topic as device
FROM "buncop/monitoring/+/telemetry"
```

**InfluxDB Write Syntax:**
```
monitoring_sensor,device=${device} temperature=${temperature},humidity=${humidity}
```

> Untuk node monitoring yang tidak mengirim `temperature/humidity` (contoh: `atc_enviro`, `atc_smart_hidroponik`) sebaiknya gunakan rule khusus agar field tidak kosong.

---

### Rule 2B — ATC Enviro Gas Telemetry (recreate, NH3 + CH4 only)

**Rule Name**: `rule_monitoring_atc_enviro_telemetry`

**SQL:**
```sql
SELECT
  payload.nh3,
  payload.ch4,
  topic as device
FROM "buncop/monitoring/atc_enviro/telemetry"
```

**InfluxDB Write Syntax:**
```
monitoring_atc_enviro,device=${device} nh3=${payload.nh3},ch4=${payload.ch4}
```

**Catatan (penting):** Hapus / disable rule lama `Monitoring_ATC_Enviro_Status` jika masih ada.

**Catatan mapping penting:** jika SQL masih memakai bentuk `payload.nh3` / `payload.ch4` tanpa alias `as nh3`, maka di write syntax juga harus memakai `${payload.nh3}` / `${payload.ch4}`.  
Kalau ingin write syntax lebih sederhana (`${nh3}`), ubah SQL menjadi:

```sql
SELECT
  payload.nh3 as nh3,
  payload.ch4 as ch4,
  topic as device
FROM "buncop/monitoring/atc_enviro/telemetry"
```

---

### Rule 2C — ATC Smart Hidroponik Telemetry (new)

**Rule Name**: `rule_monitoring_atc_hidroponik_telemetry`

**SQL:**
```sql
SELECT
  payload.pH,
  payload.tds,
  topic as device
FROM "buncop/monitoring/atc_smart_hidroponik/telemetry"
```

**InfluxDB Write Syntax:**
```
monitoring_atc_hidroponik,device=${device} pH=${pH},tds=${tds}
```

---
 
### Rule 2D — ATC Irigasi Telemetry (RKK)

**Rule Name**: `rule_monitoring_atc_irigasi_rkk_telemetry`

**SQL:**
```sql
SELECT
  payload.temperature,
  payload.humidity,
  payload.soil_moisture,
  topic as device
FROM "buncop/monitoring/atc_irigasi_rkk/telemetry"
```

**InfluxDB Write Syntax:**
```
monitoring_atc_irigasi_rkk,device=${device} temperature=${payload.temperature},humidity=${payload.humidity},soil_moisture=${payload.soil_moisture}
```

**Format Pengisian Tabel (Jika pakai Data Format JSON):**

- **Measurement**: `monitoring_atc_irigasi_rkk`
- **Timestamp**: kosongkan
- **Fields**:
  - Key: `temperature` | Value: `${payload.temperature}`
  - Key: `humidity` | Value: `${payload.humidity}`
  - Key: `soil_moisture` | Value: `${payload.soil_moisture}`
- **Tags**:
  - Key: `device` | Value: `${device}`

**Catatan mapping penting:** jika SQL masih memakai `payload.temperature`, `payload.humidity`, dan `payload.soil_moisture` tanpa alias, maka write syntax / field value juga harus memakai `${payload.temperature}`, `${payload.humidity}`, dan `${payload.soil_moisture}`.

---

### Rule 2E — ATC Irigasi Telemetry (RKB)

**Rule Name**: `rule_monitoring_atc_irigasi_rkb_telemetry`

**SQL:**
```sql
SELECT
  payload.temperature,
  payload.humidity,
  payload.soil_moisture,
  topic as device
FROM "buncop/monitoring/atc_irigasi_rkb/telemetry"
```

**InfluxDB Write Syntax:**
```
monitoring_atc_irigasi_rkb,device=${device} temperature=${payload.temperature},humidity=${payload.humidity},soil_moisture=${payload.soil_moisture}
```

**Format Pengisian Tabel (Jika pakai Data Format JSON):**

- **Measurement**: `monitoring_atc_irigasi_rkb`
- **Timestamp**: kosongkan
- **Fields**:
  - Key: `temperature` | Value: `${payload.temperature}`
  - Key: `humidity` | Value: `${payload.humidity}`
  - Key: `soil_moisture` | Value: `${payload.soil_moisture}`
- **Tags**:
  - Key: `device` | Value: `${device}`

**Catatan mapping penting:** jika SQL masih memakai `payload.temperature`, `payload.humidity`, dan `payload.soil_moisture` tanpa alias, maka write syntax / field value juga harus memakai `${payload.temperature}`, `${payload.humidity}`, dan `${payload.soil_moisture}`.

---

### Rule 3 — Nutrimix Telemetry (new)

**Rule Name**: `rule_nutrimix_telemetry`

**SQL:**
```sql
SELECT
  payload.weight_g,
  payload.target_weight_g,
  topic as device
FROM "buncop/nutrimix/+/telemetry"
```

**InfluxDB Write Syntax:**
```
nutrimix_sensor,device=${device} weight_g=${weight_g},target_weight_g=${target_weight_g}
```

---

### Rule 4 - Indoor Farming Telemetry (new)

**Rule Name**: `rule_indoor_farming_telemetry`

**SQL:**
```sql
SELECT
  payload.ec_us,
  payload.ec_ms,
  payload.ppm,
  payload.temperature,
  payload.do,
  payload.tds,
  payload.ph,
  topic as device
FROM "buncop/indoor_farming/indoor_farming_sensor/telemetry"
```

**InfluxDB Write Syntax:**
```
indoor_farming_sensor,device=${device} ec_us=${payload.ec_us},ec_ms=${payload.ec_ms},ppm=${payload.ppm},temperature=${payload.temperature},do=${payload.do},tds=${payload.tds},ph=${payload.ph}
```

**Format Pengisian Tabel (Jika pakai Data Format JSON):**

- **Measurement**: `indoor_farming_sensor`
- **Timestamp**: kosongkan
- **Fields**:
  - Key: `ec_us` | Value: `${payload.ec_us}`
  - Key: `ec_ms` | Value: `${payload.ec_ms}`
  - Key: `ppm` | Value: `${payload.ppm}`
  - Key: `temperature` | Value: `${payload.temperature}`
  - Key: `do` | Value: `${payload.do}`
  - Key: `tds` | Value: `${payload.tds}`
  - Key: `ph` | Value: `${payload.ph}`
- **Tags**:
  - Key: `device` | Value: `${device}`

**Catatan:** indoor farming tidak perlu user MQTT baru selama firmware tetap memakai `buncop_esp`, dan app/web tetap memakai `buncop_app_ctrl`.

---

## Alternative: Single Unified Rule

If you prefer one rule for all areas:

**SQL:**
```sql
SELECT
  payload,
  topic,
  nth(2, topic_tokens) AS area,
  nth(3, topic_tokens) AS device_id
FROM "buncop/+/+/telemetry"
```

This requires the InfluxDB action to handle variable fields. EMQX's InfluxDB action with line protocol can be templated:

```
buncop_telemetry,area=${area},device_id=${device_id} ${payload}
```

However, since each area has **different fields** (temp/humidity vs weight_g), separate rules with explicit field mappings are cleaner and safer.

---

## InfluxDB Details

| Setting | Value |
|---------|-------|
| **Host** | `pulsedb.petrokimia-gresik.com` |
| **Port** | `8086` |
| **Org** | `TI PKG` |
| **Bucket** | `buncop_iot_raw` |
| **Connector** | `Influx_buncop` (already exists) |

---

## EMQX ACL Summary

| User | Pub | Sub |
|------|-----|-----|
| `buncop_esp` | `+/telemetry`, `+/status`, `+/alert` | `+/command` |
| `buncop_app_ctrl` | `+/command` | `+/ack`, `+/status`, `+/alert` |
| `buncop_app_ro` | — | `+/status`, `+/alert` |
| `buncop_gateway` | `+/command` | `+/telemetry`, `+/status`, `+/alert` |
| `buncop_bridge` | — | `buncop/#` (all) |

All passwords: `Kinds123`

---

## Steps to Deploy

1. **Log into EMQX Dashboard**: `https://pulsehub.petrokimia-gresik.com:18083`
2. **Go to Rules** → Edit existing `rule_iuhy` dan samakan SQL jadi `topic as device`
3. **Create rule baru** untuk monitoring/ATC/nutrimix sesuai template SQL di atas
4. **Add Action**
  - **Type of Action**: InfluxDB
  - Jika mau pakai action yang sudah ada, pilih action existing (contoh: `write_incubator`)
  - Jika mau bikin action baru, pilih **Create Action**
5. **Jika pilih Create Action**, isi form seperti ini:
  - **Name**: contoh `write_monitoring_atc`
  - **Connector**: `Influx_buncop`
  - **Data Format**: pilih **Line Protocol** (disarankan agar sama dengan rule lama)
  - **Time Precision**: millisecond (atau sesuai connector existing)
  - **Write Syntax / Line Protocol**: gunakan format di masing-masing rule di atas
6. **Jika pilih action existing**, cukup isi **Write Syntax** di level rule dengan format line protocol masing-masing
7. **Test Connectivity** lalu **Create / Update**
8. **Verifikasi data** di InfluxDB bucket `buncop_iot_raw`

---

## Action & Data Format (Praktis)

Untuk menyamakan semua rule dengan pola lama:

- SQL di Rule: selalu ada `topic as device`
- Tag line protocol: selalu pakai `device=${device}`
- Data Format Action: **Line Protocol**

Contoh paling sederhana (temperature + humidity):

```sql
SELECT
  payload.temperature as temperature,
  payload.humidity as humidity,
  topic as device
FROM "buncop/monitoring/+/telemetry"
```

Line protocol:

```
monitoring_sensor,device=${device} temperature=${temperature},humidity=${humidity}
```

### Template Pengisian Tabel Action (JSON)

Jika di EMQX kamu memilih **Data Format = JSON**, isi tabel dengan pola berikut:

- **Measurement**: nama measurement Influx
- **Timestamp**: kosongkan jika tidak perlu timestamp manual
- **Fields**: isi key sensor dan value dari hasil SQL
- **Tags**: minimal isi `device=${device}`

Contoh untuk **ATC Enviro**:

- **Measurement**: `monitoring_atc_enviro`
- **Fields**:
  - `nh3` → `${payload.nh3}`
  - `ch4` → `${payload.ch4}`
- **Tags**:
  - `device` → `${device}`

Contoh untuk **ATC Irigasi RKK**:

- **Measurement**: `monitoring_atc_irigasi_rkk`
- **Fields**:
  - `temperature` → `${payload.temperature}`
  - `humidity` → `${payload.humidity}`
  - `soil_moisture` → `${payload.soil_moisture}`
- **Tags**:
  - `device` → `${device}`

Contoh untuk **ATC Irigasi RKB**:

- **Measurement**: `monitoring_atc_irigasi_rkb`
- **Fields**:
  - `temperature` → `${payload.temperature}`
  - `humidity` → `${payload.humidity}`
  - `soil_moisture` → `${payload.soil_moisture}`
- **Tags**:
  - `device` → `${device}`
