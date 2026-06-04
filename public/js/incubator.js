// ==================== MQTT + Influx Bridge CONFIG ====================
const webConfig = window.BUNCOP_WEB_CONFIG || {};
const syncBaseUrl = "/incubator/sync";
const runtimeBaseUrl = "/incubator/runtime";
const csrfToken = document.querySelector('meta[name="csrf-token"]')?.getAttribute("content") || "";
const DEVICE_ID = webConfig.incubatorDeviceId || "inkubator_1";
const DEVICE_PATH = `/device/${DEVICE_ID}`;
const MQTT_BROKER_URL = webConfig.mqttBrokerUrl || "";
const MQTT_WS_PORT = Number(webConfig.mqttWsPort || 8083);
const MQTT_WS_PATH = String(webConfig.mqttWsPath || "/mqtt");
const MQTT_WS_URL = webConfig.mqttWsUrl
    || buildMqttWsUrlFromBroker(MQTT_BROKER_URL, MQTT_WS_PORT, MQTT_WS_PATH)
    || buildMqttWsUrlFromHost(webConfig.mqttHost, MQTT_WS_PORT, MQTT_WS_PATH);
const MQTT_BASE_TOPIC = (webConfig.mqttTopicBase || `buncop/${webConfig.mqttArea || "incubator"}/${DEVICE_ID}`).replace(/\/+$/, "");
const MQTT_TOPICS = {
    telemetry: `${MQTT_BASE_TOPIC}/telemetry`,
    status: `${MQTT_BASE_TOPIC}/status`,
    command: `${MQTT_BASE_TOPIC}/command`,
    alert: `${MQTT_BASE_TOPIC}/alert`,
};
const INCUBATOR_UI_CACHE_KEY = `buncop.incubator.ui.${DEVICE_ID}.v2`;
const ENVIRONMENT_HISTORY_RANGE_OPTIONS = {
    "5m": { label: "5 Menit", range: "-5m", window: "1m", seconds: 5 * 60 },
    "10m": { label: "10 Menit", range: "-10m", window: "10s", seconds: 10 * 60 },
    "15m": { label: "15 Menit", range: "-15m", window: "30s", seconds: 15 * 60 },
    "20m": { label: "20 Menit", range: "-20m", window: "30s", seconds: 20 * 60 },
    "30m": { label: "30 Menit", range: "-30m", window: "1m", seconds: 30 * 60 },
    "1h": { label: "1 Jam", range: "-1h", window: "1m", seconds: 60 * 60 },
    "6h": { label: "6 Jam", range: "-6h", window: "5m", seconds: 6 * 60 * 60 },
    "24h": { label: "24 Jam", range: "-1d", window: "15m", seconds: 24 * 60 * 60 },
    "3d": { label: "3 Hari", range: "-3d", window: "30m", seconds: 3 * 24 * 60 * 60 },
    "7d": { label: "7 Hari", range: "-7d", window: "1h", seconds: 7 * 24 * 60 * 60 },
};
const ENVIRONMENT_METRICS = {
    temperature: {
        label: "Suhu Udara",
        legend: "Suhu Udara (°C)",
        suffix: " °C",
        color: "#f59e0b",
        digits: 1,
    },
    humidity: {
        label: "Kelembaban Udara",
        legend: "Kelembaban Udara (%)",
        suffix: " %",
        color: "#2196f3",
        digits: 1,
    },
    soil_moisture: {
        label: "Kelembaban Tanah",
        legend: "Kelembaban Tanah (%)",
        suffix: " %",
        color: "#43a047",
        digits: 0,
    },
};

const REALTIME_STORE = {};
const REALTIME_LISTENERS = new Map();
const db = createRealtimeDbAdapter();
let mqttClient = null;
let mqttCommandQueue = Promise.resolve();
let activePlantId = "";
let environmentHistoryChart = null;
let environmentHistoryPoints = [];
let latestTemperature = null;
let latestHumidity = null;
let latestSoilMoisture = null;
let selectedEnvironmentMetric = "temperature";
let selectedEnvironmentHistoryRange = "24h";
let lastAutoRepairAt = 0;
let lastAutoRepairKey = "";
const localShadow = {
    mode: "manual",
    lamp_pwm: 60,
    active_plant: "",
    relay: { lamp: false, fan: false, sprayer: false },
    manual: {
        sprayer_times: [],
        sprayer_duration: 10,
        light_schedule: {},
    },
};

// ==================== STATE ====================
let currentMode = "manual";
let currentPlant = null;
let espOffline = false;
let lastSeenTime = 0;
let lastSensorTime = Date.now();
let plantsList = {};
let editingPlantId = null;
let scheduleTimes = ["08:00", "15:00"];
let customScheduleTimes = ["08:00", "15:00"];
let countdownInterval = null;
let sprayerEndTime = null;
let sprayerUiRunning = false;
let autoSchedulerInterval = null;
let lastAutoSprayMinuteKey = null;
let lastActivePlantMetaMinuteKey = null;
const relayLogState = {
    fan: { initialized: false, last: null },
    sprayer: { initialized: false, last: null },
    lamp: { initialized: false, last: null },
};
const autoActivityLogDedup = new Map();
let deviceState = { fan: false, sprayer: false, lamp: false };
let activePlantClosed = false;

// ==================== DOM READY ====================
document.addEventListener("DOMContentLoaded", function () {
    restoreCachedUiState();
    initUI();
    initFirebaseListeners();
    loadSyncedState();
    initEventListeners();
    initButtonClickLogging();
    initMqttBridge();
    refreshRuntimeSnapshot();
    setInterval(refreshRuntimeSnapshot, 12000);
    startAutoScheduler();
    updateTime();
    setInterval(updateTime, 1000);
    setInterval(checkESPConnection, 5000);
});

function readCachedUiState() {
    try {
        const raw = window.localStorage.getItem(INCUBATOR_UI_CACHE_KEY);
        if (!raw) return null;
        const parsed = JSON.parse(raw);
        return parsed && typeof parsed === "object" ? parsed : null;
    } catch (_error) {
        return null;
    }
}

function persistUiState() {
    try {
        window.localStorage.setItem(INCUBATOR_UI_CACHE_KEY, JSON.stringify({
            mode: currentMode,
            activePlantId,
            relay: { ...deviceState },
            lampPwm: Number(localShadow.lamp_pwm || 60),
            sprayerDuration: Number(localShadow.manual?.sprayer_duration || 10),
            sprayerTimes: Array.isArray(scheduleTimes) ? [...scheduleTimes] : [],
            temperature: Number.isFinite(Number(latestTemperature)) ? Number(latestTemperature) : null,
            humidity: Number.isFinite(Number(latestHumidity)) ? Number(latestHumidity) : null,
            soilMoisture: Number.isFinite(Number(latestSoilMoisture)) ? Number(latestSoilMoisture) : null,
            lastSeenTime: Number(lastSeenTime || 0),
            environmentMetric: selectedEnvironmentMetric,
            environmentHistoryRange: selectedEnvironmentHistoryRange,
            environmentHistoryPoints: Array.isArray(environmentHistoryPoints)
                ? environmentHistoryPoints
                    .filter((point) => Number.isFinite(Number(point?.timestamp)))
                    .slice(-480)
                : [],
            cachedAt: Date.now(),
        }));
    } catch (_error) {
        // localStorage is best-effort only.
    }
}

function parseEnvironmentHistoryTimestamp(rawValue) {
    if (rawValue === null || rawValue === undefined || rawValue === "") return null;

    if (typeof rawValue === "number" && Number.isFinite(rawValue)) {
        if (rawValue > 1000000000000) return Math.floor(rawValue / 1000);
        if (rawValue > 1000000000) return Math.floor(rawValue);
    }

    const numeric = Number(rawValue);
    if (Number.isFinite(numeric)) {
        if (numeric > 1000000000000) return Math.floor(numeric / 1000);
        if (numeric > 1000000000) return Math.floor(numeric);
    }

    const parsed = new Date(String(rawValue));
    return Number.isNaN(parsed.getTime()) ? null : Math.floor(parsed.getTime() / 1000);
}

function restoreCachedUiState() {
    const cached = readCachedUiState();
    if (!cached) return;

    currentMode = cached.mode === "auto" ? "auto" : "manual";
    localShadow.mode = currentMode;
    activePlantId = typeof cached.activePlantId === "string" ? cached.activePlantId : "";
    localShadow.active_plant = activePlantId;

    if (cached.relay && typeof cached.relay === "object") {
        deviceState = {
            fan: cached.relay.fan === true,
            sprayer: cached.relay.sprayer === true,
            lamp: cached.relay.lamp === true,
        };
        localShadow.relay = { ...deviceState };
    }

    if (Number.isFinite(Number(cached.lampPwm))) {
        localShadow.lamp_pwm = Number(cached.lampPwm);
    }

    if (Number.isFinite(Number(cached.sprayerDuration))) {
        localShadow.manual.sprayer_duration = Number(cached.sprayerDuration);
    }

    if (Array.isArray(cached.sprayerTimes) && cached.sprayerTimes.length > 0) {
        scheduleTimes = normalizeTimes(cached.sprayerTimes);
        localShadow.manual.sprayer_times = [...scheduleTimes];
    }

    if (Number.isFinite(Number(cached.temperature))) {
        latestTemperature = Number(cached.temperature);
    }

    if (Number.isFinite(Number(cached.humidity))) {
        latestHumidity = Number(cached.humidity);
    }

    if (Number.isFinite(Number(cached.soilMoisture))) {
        latestSoilMoisture = Number(cached.soilMoisture);
    }

    if (Number.isFinite(Number(cached.lastSeenTime))) {
        lastSeenTime = Number(cached.lastSeenTime);
    }

    if (cached.environmentMetric && ENVIRONMENT_METRICS[cached.environmentMetric]) {
        selectedEnvironmentMetric = cached.environmentMetric;
    }

    if (cached.environmentHistoryRange && ENVIRONMENT_HISTORY_RANGE_OPTIONS[cached.environmentHistoryRange]) {
        selectedEnvironmentHistoryRange = cached.environmentHistoryRange;
    }

    if (Array.isArray(cached.environmentHistoryPoints) && cached.environmentHistoryPoints.length > 0) {
        environmentHistoryPoints = cached.environmentHistoryPoints
            .map((point) => ({
                timestamp: Number(point?.timestamp),
                temperature: Number.isFinite(Number(point?.temperature)) ? Number(point.temperature) : null,
                humidity: Number.isFinite(Number(point?.humidity)) ? Number(point.humidity) : null,
                soil_moisture: Number.isFinite(Number(point?.soil_moisture)) ? Number(point.soil_moisture) : null,
            }))
            .filter((point) => Number.isFinite(point.timestamp))
            .sort((a, b) => a.timestamp - b.timestamp);
    }
}

function applyCachedUiStateToDom() {
    updateModeUI(currentMode);
    updateRelayUI("kipas", deviceState.fan ? 1 : 0);
    updateRelayUI("sprayer", deviceState.sprayer ? 1 : 0);
    updateLampuRelayUI(deviceState.lamp ? 1 : 0);
    updateBrightnessUI(Number(localShadow.lamp_pwm || 60));

    if (Number.isFinite(Number(latestTemperature))) {
        updateTemperatureUI(Number(latestTemperature));
    }

    if (Number.isFinite(Number(latestHumidity))) {
        updateHumidityUI(Number(latestHumidity));
    }

    if (Number.isFinite(Number(latestSoilMoisture))) {
        updateSoilMoistureUI(Number(latestSoilMoisture));
    }
}

function syncSelectedPlantFromActivePlant() {
    if (!activePlantId || !plantsList || !plantsList[activePlantId]) return;
    if (currentPlant?.id === activePlantId) return;
    selectPlantById(activePlantId);
}

function maybeRepairAutoPlantSync(reason = "auto_guard") {
    if (currentMode !== "auto" || !currentPlant || !currentPlant.id) return;
    if (!Number.isFinite(Number(latestTemperature))) return;
    if (deviceState.fan === true) return;

    const temp = Number(latestTemperature);
    const tempMax = Number(currentPlant.tempMax);
    if (!Number.isFinite(tempMax) || temp <= tempMax) return;

    const now = Date.now();
    const repairKey = `${currentPlant.id}|${tempMax}|${Math.round(temp * 10)}`;
    if (repairKey === lastAutoRepairKey && (now - lastAutoRepairAt) < 30000) return;

    lastAutoRepairAt = now;
    lastAutoRepairKey = repairKey;

    publishMqttCommand({
        type: "set_active_plant",
        value: buildActivePlantCommandPayload(currentPlant),
    }).then(() => {
        pushSystemLog("auto_repair_active_plant_sync", {
            reason,
            plantId: currentPlant.id,
            temperature: temp.toFixed(1),
            tempMax: tempMax.toFixed(1),
        });
    }).catch((err) => {
        console.warn("auto repair active plant sync failed", err);
    });
}

function initUI() {
    document.getElementById("minTemp").value = 26;
    document.getElementById("maxTemp").value = 33;
    document.getElementById("sprayerDurasi").value = 5;
    document.getElementById("lampStartDate").value = todayDate();
    document.getElementById("lampStartTime").value = "06:00";
    document.getElementById("lampEndTime").value = "17:00";
    document.getElementById("customLightStartDate").value = todayDate();
    document.getElementById("customDarkDays").value = "7";
    document.getElementById("customLightCycleDays").value = "7";
    document.getElementById("customStartPhase").value = "dark";
    document.getElementById("customLightStartTime").value = "06:00";
    document.getElementById("customLightEndTime").value = "17:00";
    setSelectedDays("lampActiveDays", [0, 1, 2, 3, 4, 5, 6]);
    setSelectedDays("customLightDays", [0, 1, 2, 3, 4, 5, 6]);
    updateSprayerDurationInfo();

    const brightnessSlider = document.getElementById("brightnessSlider");
    const brightnessValue = document.getElementById("brightnessValue");
    if (brightnessSlider && brightnessValue) {
        brightnessSlider.value = 60;
        brightnessValue.textContent = "60%";
    }

    renderScheduleList(scheduleTimes);
    renderCustomScheduleList(customScheduleTimes);
    renderActivePlantOverview();
    initEnvironmentHistoryChart();
    renderEnvironmentMetricButtons();
    renderEnvironmentHistoryRangeButtons();
    renderEnvironmentHistoryChart();
    void loadEnvironmentHistory();
    applyCachedUiStateToDom();
}

async function syncRequest(path, method = "GET", payload = null) {
    const options = {
        method,
        headers: {
            "Accept": "application/json",
            "X-CSRF-TOKEN": csrfToken
        }
    };

    if (payload !== null) {
        options.headers["Content-Type"] = "application/json";
        options.body = JSON.stringify(payload);
    }

    const response = await fetch(`${syncBaseUrl}${path}`, options);
    if (!response.ok) {
        const text = await response.text();
        throw new Error(text || `Sync HTTP ${response.status}`);
    }

    return response.json();
}

async function runtimeRequest(path, method = "GET", payload = null) {
    const options = {
        method,
        headers: {
            "Accept": "application/json",
            "X-CSRF-TOKEN": csrfToken
        }
    };

    if (payload !== null) {
        options.headers["Content-Type"] = "application/json";
        options.body = JSON.stringify(payload);
    }

    const response = await fetch(`${runtimeBaseUrl}${path}`, options);
    if (!response.ok) {
        const text = await response.text();
        throw new Error(text || `Runtime HTTP ${response.status}`);
    }

    return response.json();
}

async function loadSyncedState() {
    try {
        const data = await syncRequest(`/state?device_id=${encodeURIComponent(DEVICE_ID)}`);
        plantsList = data?.plants || {};
        setRealtimeValue("/plants", plantsList, { silent: true });
        renderPlantButtons();

        const cfg = data?.config || {};
        if (Array.isArray(cfg.sprayer_times) && cfg.sprayer_times.length > 0) {
            scheduleTimes = normalizeTimes(cfg.sprayer_times);
            renderScheduleList(scheduleTimes);
        }
        if (cfg.sprayer_duration) {
            setSprayerDurationValue(cfg.sprayer_duration);
        }

        const lightSchedule = cfg.light_schedule || {};
        if (lightSchedule.start_date) document.getElementById("lampStartDate").value = lightSchedule.start_date;
        if (lightSchedule.start_time) document.getElementById("lampStartTime").value = lightSchedule.start_time;
        if (lightSchedule.end_time) document.getElementById("lampEndTime").value = lightSchedule.end_time;
        if (Array.isArray(lightSchedule.days)) setSelectedDays("lampActiveDays", lightSchedule.days);

        if (cfg.active_plant_id && plantsList[cfg.active_plant_id]) {
            activePlantId = cfg.active_plant_id;
            setRealtimeValue(DEVICE_PATH + "/active_plant", cfg.active_plant_id, { silent: true });
            selectPlantById(cfg.active_plant_id);
        } else if (activePlantId && plantsList[activePlantId]) {
            selectPlantById(activePlantId);
        }

        setRealtimeValue(DEVICE_PATH + "/manual/sprayer_times", scheduleTimes, { silent: true });
        setRealtimeValue(DEVICE_PATH + "/manual/sprayer_duration", cfg.sprayer_duration || 10, { silent: true });
        setRealtimeValue(DEVICE_PATH + "/manual/light_schedule", lightSchedule, { silent: true });
        persistUiState();
    } catch (e) {
        console.warn("sync state load failed", e);
    }
}

function initFirebaseListeners() {
    db.ref(".info/connected").on("value", (snapshot) => updateConnectionStatus(snapshot.val()));

    db.ref(DEVICE_PATH + "/mode").on("value", (snapshot) => {
        const mode = snapshot.val();
        if (!mode) return;
        currentMode = mode;
        updateModeUI(mode);
        renderActivePlantOverview();
    });

    db.ref(DEVICE_PATH + "/sensor/temperature").on("value", (snapshot) => {
        const suhu = snapshot.val();
        if (suhu === null) return;
        lastSensorTime = Date.now();
        updateTemperatureUI(suhu);
        if (currentPlant) updatePlantStatusIndicators();
    });

    db.ref(DEVICE_PATH + "/sensor/humidity").on("value", (snapshot) => {
        const hum = snapshot.val();
        if (hum === null) return;
        lastSensorTime = Date.now();
        updateHumidityUI(hum);
        if (currentPlant) updatePlantStatusIndicators();
    });

    db.ref(DEVICE_PATH + "/sensor/soil_moisture").on("value", (snapshot) => {
        const soil = snapshot.val();
        if (soil === null) return;
        lastSensorTime = Date.now();
        updateSoilMoistureUI(soil);
    });

    db.ref(DEVICE_PATH + "/relay/fan").on("value", (snapshot) => {
        deviceState.fan = snapshot.val() === true;
        logAutoRelayActivity("fan", deviceState.fan);
        updateRelayUI("kipas", deviceState.fan ? 1 : 0);
        renderActivePlantOverview();
    });

    db.ref(DEVICE_PATH + "/relay/sprayer").on("value", (snapshot) => {
        deviceState.sprayer = snapshot.val() === true;
        logAutoRelayActivity("sprayer", deviceState.sprayer);
        updateRelayUI("sprayer", deviceState.sprayer ? 1 : 0);
        renderActivePlantOverview();
    });

    db.ref(DEVICE_PATH + "/relay/lamp").on("value", (snapshot) => {
        deviceState.lamp = snapshot.val() === true;
        logAutoRelayActivity("lamp", deviceState.lamp);
        const status = deviceState.lamp ? 1 : 0;
        updateLampuRelayUI(status);
        updateLampPWMStatus();
        renderActivePlantOverview();
    });

    db.ref(DEVICE_PATH + "/lamp_pwm").on("value", (snapshot) => {
        const brightness = snapshot.val();
        if (brightness !== null) updateBrightnessUI(brightness);
    });

    db.ref(DEVICE_PATH + "/manual/sprayer_times").on("value", (snapshot) => {
        const times = snapshot.val();
        if (times && Array.isArray(times)) {
            scheduleTimes = normalizeTimes(times);
            renderScheduleList(scheduleTimes);
        }
    });

    db.ref(DEVICE_PATH + "/manual/sprayer_duration").on("value", (snapshot) => {
        const durasi = snapshot.val();
        if (durasi !== null) setSprayerDurationValue(durasi);
    });

    db.ref(DEVICE_PATH + "/manual/light_schedule").on("value", (snapshot) => {
        const schedule = snapshot.val() || {};
        if (schedule.start_date) document.getElementById("lampStartDate").value = schedule.start_date;
        if (schedule.start_time) document.getElementById("lampStartTime").value = schedule.start_time;
        if (schedule.end_time) document.getElementById("lampEndTime").value = schedule.end_time;
        if (Array.isArray(schedule.days)) setSelectedDays("lampActiveDays", schedule.days);
    });

    db.ref(DEVICE_PATH + "/last_seen").on("value", (snapshot) => {
        const ts = snapshot.val();
        if (ts === null) {
            lastSeenTime = 0;
            return;
        }
        lastSeenTime = ts;
        const now = Math.floor(Date.now() / 1000);
        updateESPStatus(now - ts <= 20);
    });

    db.ref("/plants").on("value", (snapshot) => {
        plantsList = snapshot.val() || {};
        renderPlantButtons();
        db.ref(DEVICE_PATH + "/active_plant").once("value", (plantSnap) => {
            const activeId = plantSnap.val();
            if (activeId && plantsList[activeId]) selectPlantById(activeId);
            else renderActivePlantOverview();
        });
    });
}

function buildMqttWsUrlFromBroker(brokerUrl, wsPort, wsPath) {
    const raw = String(brokerUrl || "").trim();
    if (!raw) return "";

    try {
        const source = new URL(raw);
        const protocol = source.protocol === "mqtts:" ? "wss:" : "ws:";
        const host = source.hostname;
        if (!host) return "";

        const port = Number(wsPort) > 0 ? Number(wsPort) : (protocol === "wss:" ? 8084 : 8083);
        const path = String(wsPath || "/mqtt").startsWith("/") ? String(wsPath || "/mqtt") : `/${wsPath}`;
        return `${protocol}//${host}:${port}${path}`;
    } catch (_error) {
        return "";
    }
}

function buildMqttWsUrlFromHost(host, wsPort, wsPath) {
    const hostname = String(host || "").trim();
    if (!hostname) return "";
    const port = Number(wsPort) > 0 ? Number(wsPort) : 8083;
    const path = String(wsPath || "/mqtt").startsWith("/") ? String(wsPath || "/mqtt") : `/${wsPath}`;
    return `ws://${hostname}:${port}${path}`;
}

async function refreshRuntimeSnapshot() {
    if (mqttClient && mqttClient.connected) return;

    try {
        const response = await runtimeRequest(`/snapshot?device_id=${encodeURIComponent(DEVICE_ID)}`);
        if (response?.runtime) {
            applyRuntimePayload(response.runtime, true);
        }
    } catch (err) {
        console.warn("runtime snapshot failed", err);
    }
}

function initMqttBridge() {
    if (!MQTT_WS_URL || typeof mqtt === "undefined") {
        console.info("MQTT bridge belum aktif. History Mongo tetap bisa dimuat tanpa koneksi realtime.");
        updateConnectionStatus(false);
        return;
    }

    mqttClient = mqtt.connect(MQTT_WS_URL, {
        clientId: `web-inkubator-${DEVICE_ID}-${Math.random().toString(16).slice(2, 8)}`,
        username: webConfig.mqttUsername || undefined,
        password: webConfig.mqttPassword || undefined,
        connectTimeout: 10000,
        keepalive: 30,
        reconnectPeriod: 3000,
        clean: true,
    });

    mqttClient.on("connect", () => {
        setRealtimeValue(".info/connected", true);
        updateConnectionStatus(true);

        mqttClient.subscribe([MQTT_TOPICS.telemetry, MQTT_TOPICS.status, MQTT_TOPICS.alert], { qos: 1 }, (err) => {
            if (err) console.warn("MQTT subscribe gagal", err);
        });
    });

    mqttClient.on("close", () => {
        setRealtimeValue(".info/connected", false);
        updateConnectionStatus(false);
    });
    mqttClient.on("offline", () => {
        setRealtimeValue(".info/connected", false);
        updateConnectionStatus(false);
    });
    mqttClient.on("error", (err) => {
        console.warn("MQTT error", err);
        setRealtimeValue(".info/connected", false);
        updateConnectionStatus(false);
    });

    mqttClient.on("message", (topic, payloadBuffer) => {
        const payload = safeJsonParse(payloadBuffer?.toString("utf8") || "");
        if (!payload) return;

        if (topic === MQTT_TOPICS.telemetry) {
            applyRuntimePayload({
                temperature: payload.temperature,
                humidity: payload.humidity,
                soil_moisture: payload.soil_moisture,
                last_seen: Math.floor(Date.now() / 1000),
            }, false);
            pushEnvironmentHistoryPoint({
                temperature: payload.temperature,
                humidity: payload.humidity,
                soil_moisture: payload.soil_moisture,
                timestamp: Math.floor(Date.now() / 1000),
            });
            return;
        }

        if (topic === MQTT_TOPICS.status) {
            applyRuntimePayload(payload, false);
            return;
        }

        if (topic === MQTT_TOPICS.alert) {
            handleAlertPayload(payload);
        }
    });
}

function handleAlertPayload(payload) {
    const type = String(payload?.type || "").toLowerCase();
    if (type === "temp_high") showTemporaryNotification("Peringatan suhu tinggi terdeteksi.", "warning");
    else if (type === "humidity_low") showTemporaryNotification("Peringatan kelembaban rendah terdeteksi.", "warning");
    else if (type === "sprayer_on") {
        setRealtimeValue(DEVICE_PATH + "/relay/sprayer", true);
    } else if (type === "sprayer_off") {
        setRealtimeValue(DEVICE_PATH + "/relay/sprayer", false);
    }
}

function safeJsonParse(raw) {
    try { return JSON.parse(raw); } catch (_) { return null; }
}

function applyRuntimePayload(runtime, fromInflux) {
    const relays = runtime?.relay || {};

    if (runtime?.temperature !== undefined && runtime?.temperature !== null && !Number.isNaN(Number(runtime.temperature))) {
        setRealtimeValue(DEVICE_PATH + "/sensor/temperature", Number(runtime.temperature));
    }
    if (runtime?.humidity !== undefined && runtime?.humidity !== null && !Number.isNaN(Number(runtime.humidity))) {
        setRealtimeValue(DEVICE_PATH + "/sensor/humidity", Number(runtime.humidity));
    }
    if (runtime?.soil_moisture !== undefined && runtime?.soil_moisture !== null && !Number.isNaN(Number(runtime.soil_moisture))) {
        setRealtimeValue(DEVICE_PATH + "/sensor/soil_moisture", Number(runtime.soil_moisture));
    }
    if (typeof runtime?.mode === "string" && runtime.mode !== "") {
        localShadow.mode = runtime.mode;
        setRealtimeValue(DEVICE_PATH + "/mode", runtime.mode);
    }
    if (runtime?.lamp_pwm !== undefined && runtime?.lamp_pwm !== null && !Number.isNaN(Number(runtime.lamp_pwm))) {
        localShadow.lamp_pwm = Number(runtime.lamp_pwm);
        setRealtimeValue(DEVICE_PATH + "/lamp_pwm", Number(runtime.lamp_pwm));
    }
    // Runtime snapshot dari backend saat ini lebih andal untuk sensor/config
    // daripada status relay sesaat. Status relay live diprioritaskan dari MQTT
    // status/alert agar toggle tidak kembali OFF saat auto sprayer sedang aktif.
    if (!fromInflux) {
        if (relays?.fan !== undefined) setRealtimeValue(DEVICE_PATH + "/relay/fan", relays.fan === true);
        if (relays?.sprayer !== undefined) setRealtimeValue(DEVICE_PATH + "/relay/sprayer", relays.sprayer === true);
        if (relays?.lamp !== undefined) setRealtimeValue(DEVICE_PATH + "/relay/lamp", relays.lamp === true);
    }
    if (runtime?.sprayer_duration !== undefined && runtime?.sprayer_duration !== null && !Number.isNaN(Number(runtime.sprayer_duration))) {
        setRealtimeValue(DEVICE_PATH + "/manual/sprayer_duration", Number(runtime.sprayer_duration));
    }
    if (Array.isArray(runtime?.sprayer_times)) {
        setRealtimeValue(DEVICE_PATH + "/manual/sprayer_times", normalizeTimes(runtime.sprayer_times));
    }
    if (runtime?.light_schedule && typeof runtime.light_schedule === "object") {
        setRealtimeValue(DEVICE_PATH + "/manual/light_schedule", runtime.light_schedule);
    }
    if (runtime?.active_plant !== undefined && runtime?.active_plant !== null) {
        activePlantId = String(runtime.active_plant);
        localShadow.active_plant = activePlantId;
        setRealtimeValue(DEVICE_PATH + "/active_plant", activePlantId);
        syncSelectedPlantFromActivePlant();
    }

    const nowSec = Math.floor(Date.now() / 1000);
    const lastSeen = Number(runtime?.last_seen || 0);
    if (lastSeen > 0) setRealtimeValue(DEVICE_PATH + "/last_seen", lastSeen);
    else if (!fromInflux) setRealtimeValue(DEVICE_PATH + "/last_seen", nowSec);
    persistUiState();
    maybeRepairAutoPlantSync(fromInflux ? "runtime_snapshot" : "mqtt_runtime");
}

function publishMqttCommand(command) {
    mqttCommandQueue = mqttCommandQueue
        .catch(() => Promise.resolve())
        .then(() => publishMqttCommandInternal(command));
    return mqttCommandQueue;
}

function publishMqttCommandInternal(command) {
    return new Promise((resolve, reject) => {
        if (!mqttClient || !mqttClient.connected) {
            reject(new Error("MQTT belum terkoneksi"));
            return;
        }

        const payload = JSON.stringify(command || {});
        mqttClient.publish(MQTT_TOPICS.command, payload, { qos: 1, retain: false }, (err) => {
            if (err) reject(err);
            else resolve();
        });
    });
}

function normalizeRealtimePath(path) {
    if (!path || path === "/") return "/";
    if (path === ".info/connected") return path;
    return "/" + String(path).replace(/^\/+/, "").replace(/\/+$/, "");
}

function cloneRealtimeValue(value) {
    if (value === undefined || value === null) return null;
    if (typeof structuredClone === "function") return structuredClone(value);
    return JSON.parse(JSON.stringify(value));
}

function getRealtimeValue(path) {
    const normalized = normalizeRealtimePath(path);
    if (normalized === ".info/connected") return REALTIME_STORE.__connected === true;
    if (normalized === "/") return cloneRealtimeValue(REALTIME_STORE);

    const tokens = normalized.split("/").filter(Boolean);
    let cursor = REALTIME_STORE;
    for (const token of tokens) {
        if (cursor === null || typeof cursor !== "object" || !(token in cursor)) return null;
        cursor = cursor[token];
    }
    return cloneRealtimeValue(cursor);
}

function shouldNotifyRealtimePath(listenerPath, changedPath) {
    if (listenerPath === changedPath) return true;
    if (listenerPath === "/" || changedPath === "/") return true;
    if (listenerPath === ".info/connected" || changedPath === ".info/connected") return listenerPath === changedPath;
    return changedPath.startsWith(listenerPath + "/") || listenerPath.startsWith(changedPath + "/");
}

function notifyRealtimeListeners(changedPath) {
    REALTIME_LISTENERS.forEach((callbacks, listenerPath) => {
        if (!callbacks || callbacks.size === 0) return;
        if (!shouldNotifyRealtimePath(listenerPath, changedPath)) return;
        const snapshot = { val: () => getRealtimeValue(listenerPath) };
        callbacks.forEach((cb) => cb(snapshot));
    });
}

function setRealtimeValue(path, value, options = {}) {
    const normalized = normalizeRealtimePath(path);
    const silent = options.silent === true;

    if (normalized === ".info/connected") {
        REALTIME_STORE.__connected = value === true;
        if (!silent) notifyRealtimeListeners(normalized);
        return;
    }

    const tokens = normalized.split("/").filter(Boolean);
    let cursor = REALTIME_STORE;
    for (let i = 0; i < tokens.length - 1; i++) {
        const token = tokens[i];
        if (!(token in cursor) || typeof cursor[token] !== "object" || cursor[token] === null) {
            cursor[token] = {};
        }
        cursor = cursor[token];
    }
    cursor[tokens[tokens.length - 1]] = value;
    if (!silent) notifyRealtimeListeners(normalized);
    if (normalized.startsWith(DEVICE_PATH + "/") || normalized === ".info/connected") {
        persistUiState();
    }
}

function removeRealtimeValue(path) {
    const normalized = normalizeRealtimePath(path);
    if (normalized === ".info/connected") {
        REALTIME_STORE.__connected = false;
        notifyRealtimeListeners(normalized);
        return;
    }

    const tokens = normalized.split("/").filter(Boolean);
    let cursor = REALTIME_STORE;
    for (let i = 0; i < tokens.length - 1; i++) {
        const token = tokens[i];
        if (!(token in cursor) || typeof cursor[token] !== "object" || cursor[token] === null) return;
        cursor = cursor[token];
    }
    delete cursor[tokens[tokens.length - 1]];
    notifyRealtimeListeners(normalized);
}

function createRealtimeDbAdapter() {
    async function applyWrite(path, value) {
        setRealtimeValue(path, value);

        if (path === DEVICE_PATH + "/mode") {
            localShadow.mode = String(value || "manual");
            return publishMqttCommand({ type: "set_mode", value: localShadow.mode });
        }

        if (path.startsWith(DEVICE_PATH + "/relay/")) {
            const relay = path.split("/").pop();
            const payload = { type: "set_relay", relay, value: value === true };
            if (relay === "sprayer" && value === true) {
                payload.duration = getEffectiveSprayerDuration();
            }
            return publishMqttCommand(payload);
        }

        if (path === DEVICE_PATH + "/lamp_pwm") {
            const pwm = Math.max(0, Math.min(100, parseInt(value, 10) || 0));
            localShadow.lamp_pwm = pwm;
            return publishMqttCommand({ type: "set_lamp_pwm", value: pwm });
        }

        if (path === DEVICE_PATH + "/manual/sprayer_times") {
            localShadow.manual.sprayer_times = Array.isArray(value) ? [...value] : [];
            return Promise.resolve();
        }

        if (path === DEVICE_PATH + "/manual/sprayer_duration") {
            localShadow.manual.sprayer_duration = parseInt(value, 10) || 10;
            return Promise.resolve();
        }

        if (path === DEVICE_PATH + "/manual/light_schedule") {
            localShadow.manual.light_schedule = value && typeof value === "object" ? value : {};
            return Promise.resolve();
        }

        if (path === DEVICE_PATH + "/active_plant") {
            activePlantId = value ? String(value) : "";
            localShadow.active_plant = activePlantId;
            if (activePlantId === "") return publishMqttCommand({ type: "set_active_plant", value: null });
            return Promise.resolve();
        }

        return Promise.resolve();
    }

    return {
        ref(path) {
            const normalized = normalizeRealtimePath(path);
            return {
                on(eventName, callback) {
                    if (eventName !== "value" || typeof callback !== "function") return callback;
                    if (!REALTIME_LISTENERS.has(normalized)) REALTIME_LISTENERS.set(normalized, new Set());
                    REALTIME_LISTENERS.get(normalized).add(callback);
                    callback({ val: () => getRealtimeValue(normalized) });
                    return callback;
                },
                once(eventName, callback) {
                    if (eventName !== "value") return Promise.resolve({ val: () => null });
                    const snapshot = { val: () => getRealtimeValue(normalized) };
                    if (typeof callback === "function") callback(snapshot);
                    return Promise.resolve(snapshot);
                },
                off(eventName, callback) {
                    if (eventName !== "value") return;
                    const set = REALTIME_LISTENERS.get(normalized);
                    if (!set) return;
                    if (callback) set.delete(callback);
                    else set.clear();
                },
                set(value) {
                    return applyWrite(normalized, value);
                },
                update(patch) {
                    if (!patch || typeof patch !== "object") return Promise.resolve();
                    const tasks = Object.entries(patch).map(([key, val]) => applyWrite(`${normalized}/${key}`, val));
                    return Promise.all(tasks).then(() => undefined);
                },
                push(value) {
                    const key = `k_${Date.now()}_${Math.random().toString(16).slice(2, 8)}`;
                    return applyWrite(`${normalized}/${key}`, value).then(() => ({ key }));
                },
                remove() {
                    removeRealtimeValue(normalized);
                    return Promise.resolve();
                },
            };
        }
    };
}
function renderPlantButtons() {
    const container = document.querySelector(".plant-options");
    if (!container) return;
    container.innerHTML = "";

    for (const [id, plant] of Object.entries(plantsList)) {
        const btn = document.createElement("button");
        btn.className = "plant-btn";
        btn.dataset.plantId = id;
        btn.innerHTML = `<i class="fas fa-seedling"></i><span>${plant.name || "Tanaman"}</span>`;
        btn.addEventListener("click", () => selectPlantById(id));
        container.appendChild(btn);
    }

    const customBtn = document.createElement("button");
    customBtn.className = "plant-btn";
    customBtn.dataset.plantId = "custom";
    customBtn.innerHTML = '<i class="fas fa-plus"></i><span>Custom</span>';
    customBtn.addEventListener("click", showCustomPlantForm);
    container.appendChild(customBtn);
}

function selectPlantById(plantId) {
    if (plantId === "custom") {
        showCustomPlantForm();
        return;
    }

    const plant = plantsList[plantId];
    if (!plant) return;

    const times = normalizeTimes(plant.watering?.times || ["08:00", "15:00"]);
    const lightCycle = plant.light_cycle || {};
    const darkDays = Number(lightCycle.dark_days || 7);
    const lightDaysCount = Number(lightCycle.light_days || 7);
    const startDate = lightCycle.start_date || plant.lighting?.start_date || todayDate();
    const startPhase = String(lightCycle.start_phase || "dark").toLowerCase() === "light" ? "light" : "dark";
    const phaseOrder = Array.isArray(lightCycle.phase_order) && lightCycle.phase_order.length > 0
        ? [...lightCycle.phase_order]
        : ["dark", "light"];
    currentPlant = {
        id: plantId,
        name: plant.name,
        tempMin: plant.temp_optimal?.min || 20,
        tempMax: plant.temp_optimal?.max || 30,
        lightPWM: plant.light_pwm || 60,
        wateringDuration: plant.watering?.duration || 10,
        wateringTimes: times,
        lightStartDate: plant.lighting?.start_date || startDate,
        lightStartTime: plant.lighting?.start_time || "06:00",
        lightEndTime: plant.lighting?.end_time || "17:00",
        lightDays: Array.isArray(plant.lighting?.days) ? plant.lighting.days : [0,1,2,3,4,5,6],
        lightCycle: {
            phase_order: phaseOrder,
            dark_days: Math.max(1, darkDays),
            light_days: Math.max(1, lightDaysCount),
            start_phase: startPhase,
            start_date: startDate
        },
        auto: plant.auto !== false
    };

    updatePlantInfo(currentPlant);
    syncActivePlantControls(currentPlant);
    activePlantClosed = false;
    db.ref(DEVICE_PATH + "/active_plant").set(plantId);

    document.querySelectorAll(".plant-btn").forEach(btn => btn.classList.remove("active"));
    const activeBtn = Array.from(document.querySelectorAll(".plant-btn")).find(btn => btn.dataset.plantId === plantId);
    if (activeBtn) activeBtn.classList.add("active");

    document.getElementById("customDarkDays").value = String(currentPlant.lightCycle?.dark_days || 7);
    document.getElementById("customLightCycleDays").value = String(currentPlant.lightCycle?.light_days || 7);

    hideCustomPlantForm();
    showPlantActions();
    renderActivePlantOverview();
    persistUiState();
    maybeRepairAutoPlantSync("select_plant");
}

function syncActivePlantControls(plant) {
    if (!plant) return;

    document.getElementById("minTemp").value = plant.tempMin;
    document.getElementById("maxTemp").value = plant.tempMax;
    updateTempRange();

    scheduleTimes = [...normalizeTimes(plant.wateringTimes || [])];
    renderScheduleList(scheduleTimes);
    setSprayerDurationValue(plant.wateringDuration);
    document.getElementById("lampStartDate").value = plant.lightStartDate || todayDate();
    document.getElementById("lampStartTime").value = plant.lightStartTime || "06:00";
    document.getElementById("lampEndTime").value = plant.lightEndTime || "17:00";
    setSelectedDays("lampActiveDays", plant.lightDays || [0, 1, 2, 3, 4, 5, 6]);
}

function updatePlantInfo(plant) {
    document.querySelector(".plant-name").textContent = plant.name;
    const darkDays = plant.lightCycle?.dark_days || 7;
    const lightDays = plant.lightCycle?.light_days || 7;
    document.querySelector(".plant-status").textContent = `Siram: ${plant.wateringTimes.join(", ")} | Siklus lampu: gelap ${darkDays} hari -> terang ${lightDays} hari`;
    document.getElementById("tempRequirement").textContent = `${plant.tempMin}C - ${plant.tempMax}C`;
    document.getElementById("tempReqRange").textContent = `Min: ${plant.tempMin}C, Max: ${plant.tempMax}C`;
    const midTemp = (plant.tempMin + plant.tempMax) / 2;
    document.getElementById("tempReqFill").style.width = (midTemp / 50 * 100) + "%";

    document.getElementById("humidityRequirement").textContent = "60%";
    document.getElementById("humidityReqRange").textContent = "Optimal: 60%";
    document.getElementById("humidityReqFill").style.width = "60%";
}

function showPlantActions() { document.getElementById("plantActions").style.display = "flex"; }
function hidePlantActions() { document.getElementById("plantActions").style.display = "none"; }

function showCustomPlantForm() {
    editingPlantId = null;
    document.querySelector("#plantCustomForm .custom-title").textContent = "Tanaman Custom";
    document.getElementById("saveCustomBtn").innerHTML = '<i class="fas fa-save"></i> Simpan Tanaman';
    document.getElementById("customName").value = "";
    document.getElementById("customMinTemp").value = "20";
    document.getElementById("customMaxTemp").value = "30";
    document.getElementById("customLightPWM").value = "60";
    document.getElementById("customLightValue").textContent = "60%";
    document.getElementById("customDuration").value = "10";
    document.getElementById("customAuto").checked = true;
    document.getElementById("customLightStartDate").value = todayDate();
    document.getElementById("customDarkDays").value = "7";
    document.getElementById("customLightCycleDays").value = "7";
    document.getElementById("customStartPhase").value = "dark";
    document.getElementById("customLightStartTime").value = "06:00";
    document.getElementById("customLightEndTime").value = "17:00";
    setSelectedDays("customLightDays", [0,1,2,3,4,5,6]);
    customScheduleTimes = ["08:00", "15:00"];
    renderCustomScheduleList(customScheduleTimes);
    document.getElementById("plantCustomForm").style.display = "block";
    hidePlantActions();
    updateSprayerDurationInfo();
}

function hideCustomPlantForm() { document.getElementById("plantCustomForm").style.display = "none"; }

function saveCustomPlant() {
    const name = document.getElementById("customName").value.trim();
    const minTemp = parseInt(document.getElementById("customMinTemp").value, 10);
    const maxTemp = parseInt(document.getElementById("customMaxTemp").value, 10);
    const lightPWM = parseInt(document.getElementById("customLightPWM").value, 10);
    const duration = parseInt(document.getElementById("customDuration").value, 10);
    const auto = document.getElementById("customAuto").checked;
    const lightStartDate = document.getElementById("customLightStartDate").value;
    const lightStartTime = document.getElementById("customLightStartTime").value;
    const lightEndTime = document.getElementById("customLightEndTime").value;
    const darkDays = Math.max(1, parseInt(document.getElementById("customDarkDays").value, 10) || 7);
    const lightDaysCount = Math.max(1, parseInt(document.getElementById("customLightCycleDays").value, 10) || 7);
    const startPhase = document.getElementById("customStartPhase").value === "light" ? "light" : "dark";
    const times = getCustomScheduleTimes();

    if (!name) return showTemporaryNotification("Masukkan nama tanaman!", "error");
    if (minTemp >= maxTemp) return showTemporaryNotification("Suhu minimum harus kurang dari maksimum!", "error");
    if (duration < 1 || duration > 60) return showTemporaryNotification("Durasi harus 1-60 detik!", "error");
    if (!lightStartDate) return showTemporaryNotification("Pilih tanggal mulai penyinaran!", "error");
    if (!lightStartTime || !lightEndTime) return showTemporaryNotification("Jam penyinaran belum lengkap!", "error");
    if (times.length === 0) return showTemporaryNotification("Tambahkan minimal 1 jam penyiraman!", "error");

    const plantData = {
        name,
        auto,
        light_kelvin: 6500,
        light_pwm: lightPWM,
        par_target: 200,
        temp_optimal: { min: minTemp, max: maxTemp },
        watering: { duration, times },
        lighting: {
            start_date: lightStartDate,
            start_time: lightStartTime,
            end_time: lightEndTime
        },
        light_cycle: {
            phase_order: ["dark", "light"],
            dark_days: darkDays,
            light_days: lightDaysCount,
            start_phase: startPhase,
            start_date: lightStartDate
        }
    };

    if (editingPlantId) {
        const updateId = editingPlantId;
        return db.ref("/plants/" + updateId).update(plantData)
            .then(() => syncRequest("/plant", "POST", { ...plantData, id: updateId, device_id: DEVICE_ID }))
            .then(() => {
                plantsList[updateId] = plantData;
                renderPlantButtons();
                showTemporaryNotification("Tanaman berhasil diperbarui!", "success");
                editingPlantId = null;
                hideCustomPlantForm();
                selectPlantById(updateId);
            })
            .catch(() => showTemporaryNotification("Gagal memperbarui tanaman!", "error"));
    }

    const plantId = "plant_" + Date.now();
    db.ref("/plants/" + plantId).set(plantData)
        .then(() => syncRequest("/plant", "POST", { ...plantData, id: plantId, device_id: DEVICE_ID }))
        .then(() => {
            plantsList[plantId] = plantData;
            renderPlantButtons();
            showTemporaryNotification("Tanaman berhasil disimpan!", "success");
            editingPlantId = null;
            hideCustomPlantForm();
            selectPlantById(plantId);
        })
        .catch(() => showTemporaryNotification("Gagal menyimpan tanaman!", "error"));
}

function cancelCustomPlant() {
    hideCustomPlantForm();
    editingPlantId = null;
    db.ref(DEVICE_PATH + "/active_plant").once("value", (snap) => {
        const activeId = snap.val();
        if (activeId && plantsList[activeId]) selectPlantById(activeId);
        else resetPlantInfo();
    });
}

function applyPlantSettings() {
    if (!currentPlant) return showToast("Tidak ada tanaman yang dipilih", "warning");

    syncActivePlantControls(currentPlant);

    const payload = {
        active_plant_id: currentPlant.id,
        times: scheduleTimes,
        duration: currentPlant.wateringDuration,
        light_schedule: {
            start_date: currentPlant.lightStartDate || todayDate(),
            start_time: currentPlant.lightStartTime || "06:00",
            end_time: currentPlant.lightEndTime || "17:00",
            days: currentPlant.lightDays || [0,1,2,3,4,5,6]
        },
        light_cycle: currentPlant.lightCycle || null
    };

    Promise.all([
        db.ref(DEVICE_PATH + "/lamp_pwm").set(currentPlant.lightPWM),
        db.ref(DEVICE_PATH + "/manual/sprayer_times").set(scheduleTimes),
        db.ref(DEVICE_PATH + "/manual/sprayer_duration").set(currentPlant.wateringDuration),
        db.ref(DEVICE_PATH + "/manual/light_schedule").set(payload.light_schedule),
        db.ref(DEVICE_PATH + "/auto_schedule").set(payload)
    ]).then(() => syncRequest("/apply-plant", "POST", {
        device_id: DEVICE_ID,
        active_plant_id: currentPlant.id,
        sprayer_duration: currentPlant.wateringDuration,
        sprayer_times: scheduleTimes,
        light_schedule: payload.light_schedule,
        lamp_pwm: currentPlant.lightPWM
    })).then(() => publishMqttCommand({
        type: "set_active_plant",
        value: buildActivePlantCommandPayload(currentPlant)
    })).then(() => {
        saveAppliedPlantHistory(currentPlant);
        pushSystemLog("apply_plant_settings", { plantName: currentPlant.name, wateringTimes: scheduleTimes.join(", "), light: `${payload.light_schedule.start_time}-${payload.light_schedule.end_time}` });
        activePlantClosed = false;
        renderActivePlantOverview();
        persistUiState();
        maybeRepairAutoPlantSync("apply_plant");
        showTemporaryNotification(`Pengaturan ${currentPlant.name} diterapkan`, "success");
    }).catch(() => showTemporaryNotification("Gagal menerapkan pengaturan tanaman", "error"));
}

function removeCurrentPlant() {
    if (!currentPlant || !currentPlant.id) return;
    if (!confirm(`Hapus tanaman ${currentPlant.name}?`)) return;
    const removedName = currentPlant.name;

    db.ref("/plants/" + currentPlant.id).remove()
        .then(() => syncRequest(`/plant/${currentPlant.id}`, "DELETE"))
        .then(() => {
            showTemporaryNotification("Tanaman dihapus", "success");
            resetPlantInfo();
            db.ref(DEVICE_PATH + "/active_plant").set("");
            pushSystemLog("remove_plant", { plantName: removedName });
            renderActivePlantOverview();
        })
        .catch(() => showTemporaryNotification("Gagal menghapus", "error"));
}

function resetPlantInfo() {
    currentPlant = null;
    document.querySelector(".plant-name").textContent = "Belum ada tanaman";
    document.querySelector(".plant-status").textContent = "Pilih tanaman untuk melihat kebutuhan";
    document.getElementById("tempRequirement").textContent = "--C";
    document.getElementById("tempReqRange").textContent = "Min: --C, Max: --C";
    document.getElementById("tempReqFill").style.width = "0%";
    document.getElementById("humidityRequirement").textContent = "--%";
    document.getElementById("humidityReqRange").textContent = "Optimal: --%";
    document.getElementById("humidityReqFill").style.width = "0%";
    hidePlantActions();
    hideCustomPlantForm();
    document.querySelectorAll(".plant-btn").forEach(btn => btn.classList.remove("active"));
    updateSprayerDurationInfo();
    renderActivePlantOverview();
}

function editPlant() {
    if (!currentPlant || !currentPlant.id) return;

    document.getElementById("customName").value = currentPlant.name;
    document.getElementById("customMinTemp").value = currentPlant.tempMin;
    document.getElementById("customMaxTemp").value = currentPlant.tempMax;
    document.getElementById("customLightPWM").value = currentPlant.lightPWM;
    document.getElementById("customLightValue").textContent = currentPlant.lightPWM + "%";
    document.getElementById("customDuration").value = currentPlant.wateringDuration;
    document.getElementById("customAuto").checked = currentPlant.auto;
    document.getElementById("customLightStartDate").value = currentPlant.lightStartDate || todayDate();
    document.getElementById("customDarkDays").value = String(currentPlant.lightCycle?.dark_days || 7);
    document.getElementById("customLightCycleDays").value = String(currentPlant.lightCycle?.light_days || 7);
    document.getElementById("customStartPhase").value = currentPlant.lightCycle?.start_phase === "light" ? "light" : "dark";
    document.getElementById("customLightStartTime").value = currentPlant.lightStartTime || "06:00";
    document.getElementById("customLightEndTime").value = currentPlant.lightEndTime || "17:00";
    setSelectedDays("customLightDays", currentPlant.lightDays || [0,1,2,3,4,5,6]);
    customScheduleTimes = normalizeTimes(currentPlant.wateringTimes || []);
    renderCustomScheduleList(customScheduleTimes);

    editingPlantId = currentPlant.id;
    document.querySelector("#plantCustomForm .custom-title").textContent = "Edit Tanaman";
    document.getElementById("saveCustomBtn").innerHTML = '<i class="fas fa-save"></i> Update Tanaman';
    hidePlantActions();
    document.getElementById("plantCustomForm").style.display = "block";
}

function renderScheduleList(times) {
    const container = document.getElementById("scheduleList");
    const sourceInfo = document.getElementById("scheduleSourceInfo");
    if (!container) return;
    container.innerHTML = "";

    const displayTimes = normalizeTimes(
        currentPlant?.wateringTimes?.length
            ? currentPlant.wateringTimes
            : (Array.isArray(times) && times.length > 0
                ? times
                : (localShadow.manual?.sprayer_times || []))
    );

    if (sourceInfo) {
        sourceInfo.textContent = currentPlant
            ? `Menampilkan jadwal sprayer dari tanaman aktif "${currentPlant.name}".`
            : "Pilih tanaman terlebih dahulu agar jadwal sprayer yang tersimpan bisa tampil di sini.";
    }

    if (!displayTimes || displayTimes.length === 0) {
        container.innerHTML = `<p class="schedule-empty">${
            currentPlant
                ? "Tanaman aktif belum memiliki jadwal penyiraman. Atur dari menu tambah/edit tanaman."
                : "Belum ada jadwal yang ditampilkan. Pilih tanaman yang sudah diatur terlebih dahulu."
        }</p>`;
        return;
    }

    scheduleTimes = [...displayTimes];

    displayTimes.forEach((time, index) => {
        const item = document.createElement("div");
        item.className = "schedule-time-item";
        item.innerHTML = `<input type="time" class="schedule-time-input" data-index="${index}" value="${time}"><button type="button" class="remove-time" data-index="${index}"><i class="fas fa-times"></i></button>`;
        container.appendChild(item);
    });

    document.querySelectorAll(".schedule-time-input").forEach((input) => {
        input.addEventListener("change", function () {
            const idx = parseInt(this.dataset.index, 10);
            scheduleTimes[idx] = this.value;
            scheduleTimes = normalizeTimes(scheduleTimes);
        });
    });

    document.querySelectorAll(".remove-time").forEach((btn) => {
        btn.addEventListener("click", function () {
            const idx = parseInt(this.dataset.index, 10);
            scheduleTimes.splice(idx, 1);
            scheduleTimes = normalizeTimes(scheduleTimes);
            renderScheduleList(scheduleTimes);
        });
    });
}

function renderCustomScheduleList(times) {
    const container = document.getElementById("customScheduleList");
    if (!container) return;
    container.innerHTML = "";

    if (!times || times.length === 0) {
        container.innerHTML = '<p style="color: #81c784; text-align: center;">Belum ada jam penyiraman.</p>';
        return;
    }

    times.forEach((time, index) => {
        const item = document.createElement("div");
        item.className = "schedule-time-item";
        item.innerHTML = `<input type="time" class="custom-schedule-time-input" data-index="${index}" value="${time}"><button type="button" class="remove-custom-time" data-index="${index}"><i class="fas fa-times"></i></button>`;
        container.appendChild(item);
    });

    document.querySelectorAll(".custom-schedule-time-input").forEach(input => {
        input.addEventListener("change", function () {
            const idx = parseInt(this.dataset.index, 10);
            customScheduleTimes[idx] = this.value;
        });
    });

    document.querySelectorAll(".remove-custom-time").forEach(btn => {
        btn.addEventListener("click", function () {
            const idx = parseInt(this.dataset.index, 10);
            customScheduleTimes.splice(idx, 1);
            renderCustomScheduleList(customScheduleTimes);
        });
    });
}

function getCustomScheduleTimes() { return normalizeTimes(customScheduleTimes); }
function normalizeTimes(times) {
    const filtered = (times || []).filter(t => typeof t === "string" && t.trim() !== "");
    const uniq = [...new Set(filtered)];
    return uniq.sort();
}

function normalizeTimeInput(value) {
    const raw = String(value || "").trim();
    if (!raw) return null;
    const match = /^(\d{1,2}):(\d{1,2})$/.exec(raw);
    if (!match) return null;
    const hours = Number(match[1]);
    const minutes = Number(match[2]);
    if (!Number.isFinite(hours) || !Number.isFinite(minutes)) return null;
    if (hours < 0 || hours > 23 || minutes < 0 || minutes > 59) return null;
    return `${String(hours).padStart(2, "0")}:${String(minutes).padStart(2, "0")}`;
}

function initInlineTimeAdder(config) {
    const trigger = document.getElementById(config.triggerId);
    const wrapper = document.getElementById(config.wrapperId);
    const input = document.getElementById(config.inputId);
    const ok = document.getElementById(config.okId);
    const cancel = document.getElementById(config.cancelId);
    if (!trigger || !wrapper || !input || !ok || !cancel) return;

    const open = () => {
        const times = config.getTimes();
        const last = Array.isArray(times) && times.length ? String(times[times.length - 1]) : "12:00";
        input.value = normalizeTimeInput(last) || "12:00";
        wrapper.style.display = "flex";
        input.focus();
    };

    const close = () => {
        wrapper.style.display = "none";
    };

    trigger.addEventListener("click", (event) => {
        event.preventDefault();
        const visible = wrapper.style.display !== "none" && wrapper.style.display !== "";
        if (visible) {
            close();
            return;
        }
        open();
    });

    ok.addEventListener("click", (event) => {
        event.preventDefault();
        const selected = normalizeTimeInput(input.value);
        if (!selected) {
            showToast("Format jam tidak valid. Gunakan HH:MM, contoh 07:00", "warning");
            return;
        }
        const next = normalizeTimes([...(config.getTimes() || []), selected]);
        config.setTimes(next);
        config.render(next);
        close();
    });

    cancel.addEventListener("click", (event) => {
        event.preventDefault();
        close();
    });

    wrapper.addEventListener("keydown", (event) => {
        if (event.key === "Escape") close();
        if (event.key === "Enter") ok.click();
    });
}

function buildActivePlantCommandPayload(plant) {
    if (!plant || !plant.id) return null;

    const cycle = plant.lightCycle || {};
    return {
        id: String(plant.id),
        name: String(plant.name || ""),
        temp_optimal_max: Number(plant.tempMax || 35),
        light_pwm: Number(plant.lightPWM || 100),
        lighting_start: plant.lightStartTime || "06:00",
        lighting_end: plant.lightEndTime || "17:00",
        dark_days: Math.max(1, parseInt(cycle.dark_days || 7, 10)),
        light_days: Math.max(1, parseInt(cycle.light_days || 7, 10)),
        cycle_start_date: cycle.start_date || plant.lightStartDate || todayDate(),
        cycle_start_phase: cycle.start_phase || "dark",
        lighting_days: Array.isArray(plant.lightDays) ? plant.lightDays : [0, 1, 2, 3, 4, 5, 6],
        watering_times: normalizeTimes(plant.wateringTimes || []),
        watering_duration: Math.max(1, parseInt(plant.wateringDuration || 10, 10)),
    };
}

function setSprayerDurationValue(value) {
    const normalized = Math.max(1, parseInt(value, 10) || 10);
    const input = document.getElementById("sprayerDurasi");
    if (input) input.value = normalized;
    localShadow.manual.sprayer_duration = normalized;
    updateSprayerDurationInfo();
    return normalized;
}

function getEffectiveSprayerDuration() {
    const plantDuration = parseInt(currentPlant?.wateringDuration, 10);
    if (Number.isFinite(plantDuration) && plantDuration > 0) return plantDuration;

    const inputDuration = parseInt(document.getElementById("sprayerDurasi")?.value, 10);
    if (Number.isFinite(inputDuration) && inputDuration > 0) return inputDuration;

    const cachedDuration = parseInt(localShadow.manual?.sprayer_duration, 10);
    if (Number.isFinite(cachedDuration) && cachedDuration > 0) return cachedDuration;

    return 10;
}

function updateSprayerDurationInfo() {
    const duration = getEffectiveSprayerDuration();
    const infoEl = document.getElementById("sprayerDurationInfo");
    const hintEl = document.getElementById("sprayerDurationHint");

    if (infoEl) {
        infoEl.textContent = `Sprayer menyala selama ${duration} detik setiap jadwal aktif.`;
    }

    if (hintEl) {
        hintEl.textContent = currentPlant
            ? `Durasi mengikuti tanaman aktif "${currentPlant.name}". Ubah dari menu tambah/edit tanaman bila perlu.`
            : `Durasi bawaan saat ini ${duration} detik. Pilih tanaman aktif atau edit tanaman custom untuk mengubahnya.`;
    }
}

function getLightSchedulePayload() {
    return {
        start_date: document.getElementById("lampStartDate").value,
        start_time: document.getElementById("lampStartTime").value,
        end_time: document.getElementById("lampEndTime").value,
        days: getSelectedDays("lampActiveDays"),
    };
}

function persistManualSchedulePayload(durasi, validTimes, lightSchedule) {
    return Promise.all([
        db.ref(DEVICE_PATH + "/manual/sprayer_times").set(validTimes),
        db.ref(DEVICE_PATH + "/manual/sprayer_duration").set(durasi),
        db.ref(DEVICE_PATH + "/manual/light_schedule").set(lightSchedule),
    ]).then(() => syncRequest("/manual-schedule", "POST", {
        device_id: DEVICE_ID,
        sprayer_duration: durasi,
        sprayer_times: validTimes,
        light_schedule: lightSchedule,
    }));
}

function getSelectedDays(containerId) {
    const container = document.getElementById(containerId);
    if (!container) return [0, 1, 2, 3, 4, 5, 6];

    const values = Array.from(container.querySelectorAll('input[type="checkbox"]:checked'))
        .map((el) => parseInt(el.value, 10))
        .filter((n) => !Number.isNaN(n));

    return values.length > 0 ? values : [0, 1, 2, 3, 4, 5, 6];
}

function setSelectedDays(containerId, days) {
    const container = document.getElementById(containerId);
    if (!container) return;
    const selected = Array.isArray(days) ? days.map((d) => parseInt(d, 10)) : [0, 1, 2, 3, 4, 5, 6];

    container.querySelectorAll('input[type="checkbox"]').forEach((checkbox) => {
        const value = parseInt(checkbox.value, 10);
        checkbox.checked = selected.includes(value);
    });
}

function saveSprayerSchedule() {
    if (currentMode === "auto") {
        return showToast("Mode AUTO digunakan untuk mengatur kontrol perangkat saja. Ganti ke MANUAL untuk mengubah jadwal.", "info");
    }

    const validTimes = normalizeTimes(scheduleTimes);
    if (validTimes.length === 0) return showTemporaryNotification("Setidaknya satu jadwal harus diisi!", "error");
    scheduleTimes = validTimes;
    renderScheduleList(scheduleTimes);
    const durasi = setSprayerDurationValue(getEffectiveSprayerDuration());
    const lightSchedule = getLightSchedulePayload();

    persistManualSchedulePayload(durasi, scheduleTimes, lightSchedule).then(() => publishMqttCommand({
        type: "sync_state",
        value: {
            sprayer_times: scheduleTimes,
            sprayer_duration: durasi
        }
    })).then(() => {
        updateSprayerDurationInfo();
        pushSystemLog("save_schedule", { duration: durasi, wateringTimes: scheduleTimes.join(", ") });
        showTemporaryNotification("Jadwal sprayer tersimpan!", "success");
    }).catch(() => showTemporaryNotification("Gagal menyimpan jadwal!", "error"));
}

function saveLightingSchedule() {
    if (currentMode === "auto") {
        return showToast("Mode AUTO digunakan untuk mengatur kontrol perangkat saja. Ganti ke MANUAL untuk mengubah jadwal.", "info");
    }

    const lightSchedule = getLightSchedulePayload();
    const validTimes = normalizeTimes(scheduleTimes);
    const durasi = setSprayerDurationValue(getEffectiveSprayerDuration());

    if (validTimes.length === 0) return showTemporaryNotification("Simpan minimal satu jadwal sprayer terlebih dahulu!", "error");
    if (!lightSchedule.start_date || !lightSchedule.start_time || !lightSchedule.end_time) {
        return showTemporaryNotification("Pengaturan penyinaran belum lengkap!", "error");
    }

    persistManualSchedulePayload(durasi, validTimes, lightSchedule).then(() => {
        if (currentPlant) {
            currentPlant.lightStartDate = lightSchedule.start_date;
            currentPlant.lightStartTime = lightSchedule.start_time;
            currentPlant.lightEndTime = lightSchedule.end_time;
            currentPlant.lightDays = lightSchedule.days;
            renderActivePlantOverview();
        }
        pushSystemLog("save_lighting_schedule", {
            light: `${lightSchedule.start_time}-${lightSchedule.end_time}`,
            activeDays: (lightSchedule.days || []).join(", "),
        });
        showTemporaryNotification("Jadwal penyinaran lampu tersimpan!", "success");
    }).catch(() => showTemporaryNotification("Gagal menyimpan jadwal lampu!", "error"));
}

function initEventListeners() {
    document.getElementById("autoModeBtn").addEventListener("click", () => setMode("auto"));
    document.getElementById("manualModeBtn").addEventListener("click", () => setMode("manual"));

    document.getElementById("kipasToggle").addEventListener("change", (e) => currentMode === "manual" ? setRelay("fan", e.target.checked) : rollbackToggle(e));
    document.getElementById("sprayerToggle").addEventListener("change", (e) => currentMode === "manual" ? setRelay("sprayer", e.target.checked) : rollbackToggle(e));
    document.getElementById("lampuRelayToggle").addEventListener("change", (e) => currentMode === "manual" ? setRelay("lamp", e.target.checked) : rollbackToggle(e));
    document.getElementById("lampPWMToggle").addEventListener("change", (e) => currentMode === "manual" ? setRelay("lamp", e.target.checked) : rollbackToggle(e));

    const brightnessSlider = document.getElementById("brightnessSlider");
    const brightnessValue = document.getElementById("brightnessValue");
    brightnessSlider.addEventListener("input", (e) => brightnessValue.textContent = e.target.value + "%");
    brightnessSlider.addEventListener("change", (e) => {
        if (currentMode !== "manual") return showToast("Mode Auto aktif! Ganti ke Manual dulu.", "warning");
        const brightness = parseInt(e.target.value, 10);
        db.ref(DEVICE_PATH + "/lamp_pwm").set(brightness);
        pushSystemLog("set_lamp_brightness", { brightness: brightness + "%" });
        showTemporaryNotification(`Kecerahan lampu: ${brightness}%`, "success");
    });

    document.getElementById("saveSetpointBtn").addEventListener("click", () => showToast("Setpoint suhu mengikuti tanaman yang dipilih", "info"));
    document.getElementById("saveSprayerBtn").addEventListener("click", (event) => {
        event.preventDefault();
        saveSprayerSchedule();
    });
    document.getElementById("saveLightingBtn").addEventListener("click", (event) => {
        event.preventDefault();
        saveLightingSchedule();
    });
    initInlineTimeAdder({
        triggerId: "addScheduleBtn",
        wrapperId: "addScheduleInline",
        inputId: "addScheduleInlineInput",
        okId: "addScheduleInlineOk",
        cancelId: "addScheduleInlineCancel",
        getTimes: () => scheduleTimes,
        setTimes: (next) => { scheduleTimes = next; },
        render: (next) => renderScheduleList(next),
    });

    initInlineTimeAdder({
        triggerId: "customAddScheduleBtn",
        wrapperId: "customAddScheduleInline",
        inputId: "customAddScheduleInlineInput",
        okId: "customAddScheduleInlineOk",
        cancelId: "customAddScheduleInlineCancel",
        getTimes: () => customScheduleTimes,
        setTimes: (next) => { customScheduleTimes = next; },
        render: (next) => renderCustomScheduleList(next),
    });

    document.getElementById("closeBanner")?.addEventListener("click", hideBanner);

    document.addEventListener("click", function (event) {
        const target = event.target instanceof Element ? event.target : null;
        if (!target) return;
        const btn = target.closest("[data-action='show-light-cycle']");
        if (!btn) return;
        openLightCycleModal();
    });

    document.getElementById("lightCycleModalClose")?.addEventListener("click", closeLightCycleModal);
    document.getElementById("lightCycleModalOk")?.addEventListener("click", closeLightCycleModal);
    document.getElementById("lightCycleModal")?.addEventListener("click", function (event) {
        if (event.target === this) closeLightCycleModal();
    });
    document.getElementById("cancelCustomBtn").addEventListener("click", cancelCustomPlant);
    document.getElementById("saveCustomBtn").addEventListener("click", saveCustomPlant);
    document.getElementById("applySettingsBtn").addEventListener("click", () => currentPlant ? applyPlantSettings() : showToast("Pilih tanaman terlebih dahulu", "warning"));
    document.getElementById("removePlantBtn").addEventListener("click", removeCurrentPlant);
    document.getElementById("editPlantBtn").addEventListener("click", editPlant);
    document.getElementById("finishActivePlantBtn")?.addEventListener("click", finishActivePlant);


    const customLight = document.getElementById("customLightPWM");
    const customLightVal = document.getElementById("customLightValue");
    if (customLight && customLightVal) customLight.addEventListener("input", (e) => customLightVal.textContent = e.target.value + "%");
}

function rollbackToggle(e) {
    e.target.checked = !e.target.checked;
    showToast("Mode Auto aktif! Ganti ke Manual dulu.", "warning");
}

function setMode(mode) {
    const next = mode === "auto" ? "auto" : "manual";
    const prev = currentMode;

    // Optimistic UI update to prevent accidental relay toggles while waiting for Firebase propagation.
    updateModeUI(next);

    db.ref(DEVICE_PATH + "/mode").set(next)
        .then(() => {
            pushSystemLog("change_mode", { mode: next.toUpperCase() });
            if (next === "auto") {
                // Safety: pastikan sprayer tidak carry-over dari manual ketika masuk AUTO.
                return db.ref(DEVICE_PATH + "/relay/sprayer").set(false).catch(() => undefined);
            }
            return undefined;
        })
        .then(() => {
            showTemporaryNotification(`Mode diubah ke ${next.toUpperCase()}`, "success");
        })
        .catch(() => {
            updateModeUI(prev);
            showTemporaryNotification("Gagal mengubah mode!", "error");
        });
}

function setRelay(relay, value) {
    db.ref(DEVICE_PATH + "/relay/" + relay).set(value)
        .then(() => { pushSystemLog("relay_control", { relay, state: value ? "ON" : "OFF" }); showTemporaryNotification(`Relay ${relay} ${value ? "ON" : "OFF"}`, "success"); })
        .catch(() => showTemporaryNotification(`Gagal mengontrol ${relay}!`, "error"));
}

function startAutoScheduler() {
    // Auto logic (lamp/sprayer by schedule) dijalankan di ESP agar konsisten dengan APK.
    if (autoSchedulerInterval) {
        clearInterval(autoSchedulerInterval);
        autoSchedulerInterval = null;
    }
}

function runAutoSchedulerTick() {
    if (currentMode !== "auto" || !currentPlant) return;

    const now = new Date();
    const currentTime = `${String(now.getHours()).padStart(2, "0")}:${String(now.getMinutes()).padStart(2, "0")}`;

    // Sprayer: selalu berdasarkan jam penyiraman (tanpa tanggal mulai).
    const times = normalizeTimes(currentPlant.wateringTimes || []);
    if (times.includes(currentTime)) {
        const minuteKey = `${todayDate()}_${currentPlant.id}_${currentTime}`;
        if (lastAutoSprayMinuteKey !== minuteKey) {
            lastAutoSprayMinuteKey = minuteKey;
            triggerAutoSprayer(currentPlant.wateringDuration || 5, currentPlant.name, currentTime);
        }
    }

    // Lampu: berdasarkan tanggal mulai + hari aktif + jam aktif.
    syncLampByLightSchedule(now);
}

function triggerAutoSprayer(duration, plantName, scheduleTime) {
    db.ref(DEVICE_PATH + "/relay/sprayer").set(true)
        .then(() => {
            setTimeout(() => db.ref(DEVICE_PATH + "/relay/sprayer").set(false), duration * 1000);
        })
        .catch(() => showTemporaryNotification("Gagal trigger sprayer otomatis", "error"));
}

function syncLampByLightSchedule(now) {
    const cycle = currentPlant?.lightCycle || null;
    const startTime = currentPlant?.lightStartTime || document.getElementById("lampStartTime")?.value || "06:00";
    const endTime = currentPlant?.lightEndTime || document.getElementById("lampEndTime")?.value || "17:00";
    const hhmm = `${String(now.getHours()).padStart(2, "0")}:${String(now.getMinutes()).padStart(2, "0")}`;
    let shouldLampOn = false;

    if (cycle && cycle.start_date) {
        const startDate = new Date(`${cycle.start_date}T00:00:00`);
        const today = new Date(`${todayDate()}T00:00:00`);
        const diffDays = Math.floor((today.getTime() - startDate.getTime()) / (1000 * 60 * 60 * 24));

        if (diffDays >= 0) {
            const darkDays = Math.max(1, Number(cycle.dark_days || 7));
            const lightDays = Math.max(1, Number(cycle.light_days || 7));
            const total = darkDays + lightDays;
            const index = diffDays % total;
            const inDark = index < darkDays;
            const timeAllowed = isNowWithinRange(hhmm, startTime, endTime);
            shouldLampOn = !inDark && timeAllowed;
        }
    } else {
        const startDate = currentPlant?.lightStartDate || document.getElementById("lampStartDate")?.value;
        const today = todayDate();
        const dateReady = !!startDate && today >= startDate;
        const timeAllowed = isNowWithinRange(hhmm, startTime, endTime);
        shouldLampOn = dateReady && timeAllowed;
    }

    if (deviceState.lamp !== shouldLampOn) {
        db.ref(DEVICE_PATH + "/relay/lamp").set(shouldLampOn)
            .then(() => Promise.resolve())
            .catch(() => showTemporaryNotification("Gagal sinkronisasi lampu otomatis", "error"));
    }
}

function isNowWithinRange(nowTime, startTime, endTime) {
    if (!startTime || !endTime) return false;
    if (startTime <= endTime) {
        return nowTime >= startTime && nowTime < endTime;
    }

    // Handle over-midnight range.
    return nowTime >= startTime || nowTime < endTime;
}

function updateTemperatureUI(suhu) {
    latestTemperature = Number(suhu);
    document.getElementById("temperatureValue").textContent = suhu.toFixed(1);
    const fanCurrent = document.getElementById("fanCurrentTemp");
    if (fanCurrent) fanCurrent.textContent = suhu.toFixed(1);
    const fanSet = document.getElementById("fanSetTempMax");
    const maxEl = document.getElementById("maxTemp");
    if (fanSet && maxEl) fanSet.textContent = String(maxEl.value || "--");
    document.getElementById("tempProgress").style.width = Math.min((suhu / 50) * 100, 100) + "%";
    applyRealtimePlantTemperatureComparison();
    persistUiState();
    maybeRepairAutoPlantSync("temperature_ui");
}

function updateHumidityUI(hum) {
    latestHumidity = Number(hum);
    document.getElementById("humidityValue").textContent = hum.toFixed(1);
    document.getElementById("humProgress").style.width = hum + "%";
    persistUiState();
}

function getSoilMoistureStatus(value) {
    const soil = Number(value);
    if (!Number.isFinite(soil)) {
        return { label: "Membaca...", color: "#81c784", range: "Kondisi tanah" };
    }

    if (soil <= 30) {
        return { label: "Kering", color: "#ef5350", range: "Perlu kelembaban lebih" };
    }

    if (soil <= 70) {
        return { label: "Lembab", color: "#f9a825", range: "Kondisi cukup stabil" };
    }

    return { label: "Basah", color: "#43a047", range: "Kondisi tanah basah" };
}

function updateSoilMoistureUI(soil) {
    latestSoilMoisture = Number(soil);
    const valueEl = document.getElementById("soilMoistureValue");
    const progressEl = document.getElementById("soilProgress");
    const statusEl = document.getElementById("soilMoistureStatus");
    const rangeEl = document.getElementById("soilRange");
    const soilStatus = getSoilMoistureStatus(soil);

    if (valueEl) valueEl.textContent = Number(soil).toFixed(0);
    if (progressEl) progressEl.style.width = `${Math.max(0, Math.min(Number(soil), 100))}%`;
    if (statusEl) {
        statusEl.textContent = soilStatus.label;
        statusEl.style.color = soilStatus.color;
    }
    if (rangeEl) {
        rangeEl.textContent = soilStatus.range;
        rangeEl.style.color = soilStatus.color;
    }
    persistUiState();
}

function getRealtimePlantTemperatureComparison() {
    const temp = Number(latestTemperature);
    if (!Number.isFinite(temp)) {
        return {
            status: "Membaca...",
            rangeText: currentPlant ? `${currentPlant.tempMin}°C-${currentPlant.tempMax}°C` : "Belum ada tanaman aktif",
            color: "#81c784"
        };
    }

    if (!currentPlant) {
        return {
            status: `Suhu realtime ${temp.toFixed(1)}°C`,
            rangeText: "Belum ada tanaman aktif",
            color: "#81c784"
        };
    }

    const min = Number(currentPlant.tempMin ?? 20);
    const max = Number(currentPlant.tempMax ?? 30);
    if (temp < min) {
        return {
            status: `Terlalu dingin (${temp.toFixed(1)}°C < ${min.toFixed(1)}°C)`,
            rangeText: `${min.toFixed(1)}°C-${max.toFixed(1)}°C`,
            color: "#42a5f5"
        };
    }
    if (temp > max) {
        return {
            status: `Terlalu panas (${temp.toFixed(1)}°C > ${max.toFixed(1)}°C)`,
            rangeText: `${min.toFixed(1)}°C-${max.toFixed(1)}°C`,
            color: "#ff7043"
        };
    }
    return {
        status: `Optimal untuk ${currentPlant.name} (${temp.toFixed(1)}°C)`,
        rangeText: `${min.toFixed(1)}°C-${max.toFixed(1)}°C`,
        color: "#66bb6a"
    };
}

function applyRealtimePlantTemperatureComparison() {
    const statusEl = document.getElementById("temperatureStatus");
    const rangeEl = document.getElementById("tempRange");
    if (!statusEl || !rangeEl) return;
    const comparison = getRealtimePlantTemperatureComparison();
    statusEl.textContent = comparison.status;
    statusEl.style.color = comparison.color;
    rangeEl.textContent = comparison.rangeText;
    rangeEl.style.color = comparison.color;
}

const legacyInitEnvironmentHistoryChart = function () {
    const canvas = document.getElementById("environmentHistoryChart");
    if (!(canvas instanceof HTMLCanvasElement) || typeof Chart === "undefined") return;

    environmentHistoryChart = new Chart(canvas, {
        type: "line",
        data: {
            labels: [],
            datasets: [
                {
                    label: "Suhu (°C)",
                    data: [],
                    borderColor: "#f59e0b",
                    backgroundColor: "rgba(245, 158, 11, 0.18)",
                    tension: 0.3,
                    borderWidth: 2,
                    pointRadius: 3,
                    pointHoverRadius: 5,
                    fill: false,
                    spanGaps: true,
                },
                {
                    label: "Kelembaban (%)",
                    data: [],
                    borderColor: "#2196f3",
                    backgroundColor: "rgba(33, 150, 243, 0.18)",
                    tension: 0.3,
                    borderWidth: 2,
                    pointRadius: 3,
                    pointHoverRadius: 5,
                    fill: false,
                    spanGaps: true,
                },
                {
                    label: "Kelembaban Tanah (%)",
                    data: [],
                    borderColor: "#43a047",
                    backgroundColor: "rgba(67, 160, 71, 0.18)",
                    tension: 0.3,
                    borderWidth: 2,
                    pointRadius: 3,
                    pointHoverRadius: 5,
                    fill: false,
                    spanGaps: true,
                },
            ],
        },
        options: {
            responsive: true,
            maintainAspectRatio: false,
            interaction: {
                mode: "index",
                intersect: false,
            },
            plugins: {
                legend: {
                    position: "top",
                },
                tooltip: {
                    callbacks: {
                        title(items) {
                            const index = items?.[0]?.dataIndex ?? -1;
                            const point = environmentHistoryPoints[index] || null;
                            if (!point || !Number.isFinite(Number(point.timestamp))) return "";
                            return new Date(Number(point.timestamp) * 1000).toLocaleString("id-ID");
                        },
                    },
                },
            },
            scales: {
                x: {
                    ticks: {
                        maxTicksLimit: 8,
                    },
                    grid: {
                        color: "rgba(45, 90, 39, 0.08)",
                    },
                },
                y: {
                    beginAtZero: true,
                    grid: {
                        color: "rgba(45, 90, 39, 0.08)",
                    },
                },
            },
        },
    });
};

function initEnvironmentHistoryChart() {
    const canvas = document.getElementById("environmentHistoryChart");
    if (!(canvas instanceof HTMLCanvasElement) || typeof Chart === "undefined") return;

    environmentHistoryChart = new Chart(canvas, {
        type: "line",
        data: {
            labels: [],
            datasets: [
                {
                    label: "Suhu Udara (°C)",
                    data: [],
                    borderColor: "#f59e0b",
                    backgroundColor: "rgba(245, 158, 11, 0.18)",
                    tension: 0.3,
                    borderWidth: 2,
                    pointRadius: 0,
                    fill: false,
                },
                {
                    label: "Kelembaban Udara (%)",
                    data: [],
                    borderColor: "#2196f3",
                    backgroundColor: "rgba(33, 150, 243, 0.18)",
                    tension: 0.3,
                    borderWidth: 2,
                    pointRadius: 0,
                    fill: false,
                },
                {
                    label: "Kelembaban Tanah (%)",
                    data: [],
                    borderColor: "#43a047",
                    backgroundColor: "rgba(67, 160, 71, 0.18)",
                    tension: 0.3,
                    borderWidth: 2,
                    pointRadius: 0,
                    fill: false,
                },
            ],
        },
        options: {
            responsive: true,
            maintainAspectRatio: false,
            interaction: {
                mode: "index",
                intersect: false,
            },
            plugins: {
                legend: {
                    position: "top",
                },
            },
            scales: {
                x: {
                    ticks: {
                        maxTicksLimit: 8,
                    },
                    grid: {
                        color: "rgba(45, 90, 39, 0.08)",
                    },
                },
                y: {
                    beginAtZero: true,
                    grid: {
                        color: "rgba(45, 90, 39, 0.08)",
                    },
                },
            },
        },
    });

    applyEnvironmentChartFilter(environmentChartFilter);
}

function initEnvironmentChartFilters() {
    const buttons = document.querySelectorAll(".chart-filter-btn");
    if (!buttons.length) return;

    buttons.forEach((btn) => {
        btn.addEventListener("click", () => {
            const series = btn.getAttribute("data-series") || "all";
            applyEnvironmentChartFilter(series);
        });
    });

    applyEnvironmentChartFilter(environmentChartFilter);
}

function applyEnvironmentChartFilter(series) {
    environmentChartFilter = series || "all";

    const buttons = document.querySelectorAll(".chart-filter-btn");
    buttons.forEach((btn) => {
        const isActive = (btn.getAttribute("data-series") || "all") === environmentChartFilter;
        btn.classList.toggle("active", isActive);
    });

    if (!environmentHistoryChart) return;

    const seriesIndex = {
        temperature: 0,
        humidity: 1,
        soil: 2,
    };

    const showAll = environmentChartFilter === "all";
    environmentHistoryChart.data.datasets.forEach((dataset, index) => {
        dataset.hidden = !showAll && index !== seriesIndex[environmentChartFilter];
    });
    environmentHistoryChart.update("none");
}

async function loadEnvironmentHistory() {
    const plans = [
        { range: "-1d", window: "15m" },
        { range: "-7d", window: "1h" },
        { range: "-30d", window: "1h" },
    ];

    try {
        let points = [];
        for (const plan of plans) {
            const params = new URLSearchParams();
            params.set("device_id", DEVICE_ID);
            params.set("measurement", "incubator_sensor");
            params.set("driver", "mongodb");
            params.set("range", plan.range);
            params.set("window", plan.window);
            params.set("fields", "temperature,humidity,soil_moisture");
            let response = await syncRequest(`/sensor-history?${params.toString()}`);
            let nextPoints = Array.isArray(response?.data) ? response.data : [];
            if (!nextPoints.length) {
                params.delete("fields");
                response = await syncRequest(`/sensor-history?${params.toString()}`);
                nextPoints = Array.isArray(response?.data) ? response.data : [];
            }
            if (nextPoints.length > 0) {
                points = nextPoints;
                break;
            }
        }

        const normalizedPoints = points
            .map((point) => {
                const rawTimestamp = Number(point?.timestamp);
                const parsedTime = Number.isFinite(rawTimestamp)
                    ? rawTimestamp
                    : Math.floor(Date.parse(String(point?.time || "")) / 1000);
                return {
                    timestamp: Number.isFinite(parsedTime) ? parsedTime : null,
                    temperature: Number.isFinite(Number(point?.temperature)) ? Number(point.temperature) : null,
                    humidity: Number.isFinite(Number(point?.humidity)) ? Number(point.humidity) : null,
                    soil_moisture: Number.isFinite(Number(point?.soil_moisture)) ? Number(point.soil_moisture) : null,
                };
            })
            .filter((point) => Number.isFinite(Number(point?.timestamp)))
            .map((point) => ({
                timestamp: Number(point.timestamp),
                temperature: Number.isFinite(Number(point?.temperature)) ? Number(point.temperature) : null,
                humidity: Number.isFinite(Number(point?.humidity)) ? Number(point.humidity) : null,
                soil_moisture: Number.isFinite(Number(point?.soil_moisture)) ? Number(point.soil_moisture) : null,
            }));
        // Jangan menimpa cache chart dengan array kosong ketika backend history sedang terlambat.
        if (normalizedPoints.length > 0) {
            environmentHistoryPoints = normalizedPoints.sort((a, b) => a.timestamp - b.timestamp);
        } else if (Number.isFinite(Number(latestTemperature)) || Number.isFinite(Number(latestHumidity)) || Number.isFinite(Number(latestSoilMoisture))) {
            environmentHistoryPoints = [{
                timestamp: Math.floor(Date.now() / 1000),
                temperature: Number.isFinite(Number(latestTemperature)) ? Number(latestTemperature) : null,
                humidity: Number.isFinite(Number(latestHumidity)) ? Number(latestHumidity) : null,
                soil_moisture: Number.isFinite(Number(latestSoilMoisture)) ? Number(latestSoilMoisture) : null,
            }];
        }
        renderEnvironmentHistoryChart();
        persistUiState();
    } catch (error) {
        console.warn("load environment history failed", error);
        updateEnvironmentHistorySummary();
    }
}

function pushEnvironmentHistoryPoint(temperatureOrPoint, humidity, timestampSec) {
    const point = (typeof temperatureOrPoint === "object" && temperatureOrPoint !== null)
        ? temperatureOrPoint
        : {
            temperature: temperatureOrPoint,
            humidity,
            timestamp: timestampSec,
        };

    const timestamp = Number(point.timestamp);
    if (!Number.isFinite(timestamp)) return;

    environmentHistoryPoints.push({
        timestamp,
        temperature: Number.isFinite(Number(point.temperature)) ? Number(point.temperature) : null,
        humidity: Number.isFinite(Number(point.humidity)) ? Number(point.humidity) : null,
        soil_moisture: Number.isFinite(Number(point.soil_moisture)) ? Number(point.soil_moisture) : null,
    });

    const minTimestamp = timestamp - (24 * 60 * 60);
    environmentHistoryPoints = environmentHistoryPoints
        .filter((point) => point.timestamp >= minTimestamp)
        .sort((a, b) => a.timestamp - b.timestamp);

    renderEnvironmentHistoryChart();
    persistUiState();
}

function renderEnvironmentHistoryChart() {
    if (!environmentHistoryChart) {
        updateEnvironmentHistorySummary();
        return;
    }

    const points = environmentHistoryPoints.slice(-96);
    environmentHistoryChart.data.datasets.forEach((dataset) => {
        dataset.pointRadius = points.length <= 1 ? 5 : 3;
        dataset.pointHoverRadius = points.length <= 1 ? 6 : 5;
    });
    environmentHistoryChart.data.labels = points.map((point) => formatHistoryTime(point.timestamp));
    environmentHistoryChart.data.datasets[0].data = points.map((point) => point.temperature);
    environmentHistoryChart.data.datasets[1].data = points.map((point) => point.humidity);
    environmentHistoryChart.data.datasets[2].data = points.map((point) => point.soil_moisture);
    environmentHistoryChart.update("none");
    updateEnvironmentHistorySummary(points);
}

const legacyUpdateEnvironmentHistorySummary = function (points = environmentHistoryPoints) {
    const summary = document.getElementById("environmentHistorySummary");
    if (!summary) return;

    if (!Array.isArray(points) || points.length === 0) {
        summary.textContent = "Data grafik belum tersedia. Grafik akan terisi setelah history atau telemetry terbaru diterima.";
        return;
    }

    const latest = points[points.length - 1] || {};
    const latestTime = Number.isFinite(Number(latest.timestamp))
        ? new Date(Number(latest.timestamp) * 1000).toLocaleString("id-ID")
        : "-";
    const tempText = Number.isFinite(Number(latest.temperature)) ? `${Number(latest.temperature).toFixed(1)} °C` : "-";
    const humText = Number.isFinite(Number(latest.humidity)) ? `${Number(latest.humidity).toFixed(1)} %` : "-";

    summary.textContent = `Update terakhir ${latestTime}. Suhu ${tempText}, kelembaban ${humText}.`;
};

function updateEnvironmentHistorySummary(points = environmentHistoryPoints) {
    const summary = document.getElementById("environmentHistorySummary");
    if (!summary) return;

    if (!Array.isArray(points) || points.length === 0) {
        summary.textContent = "Data grafik belum tersedia. Grafik akan terisi setelah history atau telemetry terbaru diterima.";
        return;
    }

    const latest = points[points.length - 1] || {};
    const latestTime = Number.isFinite(Number(latest.timestamp))
        ? new Date(Number(latest.timestamp) * 1000).toLocaleString("id-ID")
        : "-";
    const tempText = Number.isFinite(Number(latest.temperature)) ? `${Number(latest.temperature).toFixed(1)} °C` : "-";
    const humText = Number.isFinite(Number(latest.humidity)) ? `${Number(latest.humidity).toFixed(1)} %` : "-";
    const soilText = Number.isFinite(Number(latest.soil_moisture)) ? `${Number(latest.soil_moisture).toFixed(0)} %` : "-";

    summary.textContent = `Update terakhir ${latestTime}. Suhu udara ${tempText}, kelembaban udara ${humText}, kelembaban tanah ${soilText}.`;
}

function formatHistoryTime(timestampSec) {
    const date = new Date(Number(timestampSec) * 1000);
    return date.toLocaleTimeString("id-ID", { hour: "2-digit", minute: "2-digit" });
}

function getActiveEnvironmentMetric() {
    return ENVIRONMENT_METRICS[selectedEnvironmentMetric] || ENVIRONMENT_METRICS.temperature;
}

function getActiveEnvironmentRangeMeta() {
    return ENVIRONMENT_HISTORY_RANGE_OPTIONS[selectedEnvironmentHistoryRange] || ENVIRONMENT_HISTORY_RANGE_OPTIONS["24h"];
}

function renderEnvironmentMetricButtons() {
    const container = document.getElementById("environmentMetricButtons");
    if (!container) return;

    container.innerHTML = Object.entries(ENVIRONMENT_METRICS).map(([key, metric]) => `
        <button type="button" class="chart-filter-btn ${selectedEnvironmentMetric === key ? "active" : ""}" data-environment-metric="${key}">
            ${metric.label}
        </button>
    `).join("");

    container.querySelectorAll("[data-environment-metric]").forEach((button) => {
        button.addEventListener("click", () => {
            const metric = button.getAttribute("data-environment-metric") || "temperature";
            if (!ENVIRONMENT_METRICS[metric]) return;
            selectedEnvironmentMetric = metric;
            renderEnvironmentMetricButtons();
            renderEnvironmentHistoryChart();
            persistUiState();
        });
    });
}

function renderEnvironmentHistoryRangeButtons() {
    const container = document.getElementById("environmentHistoryRangeButtons");
    if (!container) return;

    container.innerHTML = Object.entries(ENVIRONMENT_HISTORY_RANGE_OPTIONS).map(([key, option]) => `
        <button type="button" class="chart-filter-btn ${selectedEnvironmentHistoryRange === key ? "active" : ""}" data-environment-range="${key}">
            ${option.label}
        </button>
    `).join("");

    container.querySelectorAll("[data-environment-range]").forEach((button) => {
        button.addEventListener("click", async () => {
            const rangeKey = button.getAttribute("data-environment-range") || "24h";
            if (!ENVIRONMENT_HISTORY_RANGE_OPTIONS[rangeKey]) return;
            selectedEnvironmentHistoryRange = rangeKey;
            renderEnvironmentHistoryRangeButtons();
            updateEnvironmentRangeBadge();
            await loadEnvironmentHistory();
            persistUiState();
        });
    });
}

function updateEnvironmentRangeBadge() {
    const badge = document.getElementById("environmentActiveRangeBadge");
    if (!badge) return;
    badge.textContent = getActiveEnvironmentRangeMeta().label;
}

function getEnvironmentPointsForActiveRange() {
    const rangeMeta = getActiveEnvironmentRangeMeta();
    const cutoff = Math.floor(Date.now() / 1000) - Number(rangeMeta.seconds || 0);
    return environmentHistoryPoints
        .filter((point) => Number.isFinite(Number(point?.timestamp)) && Number(point.timestamp) >= cutoff)
        .sort((a, b) => a.timestamp - b.timestamp);
}

function initEnvironmentHistoryChart() {
    const canvas = document.getElementById("environmentHistoryChart");
    if (!(canvas instanceof HTMLCanvasElement) || typeof Chart === "undefined") return;

    environmentHistoryChart = new Chart(canvas, {
        type: "line",
        data: {
            labels: [],
            datasets: [{
                label: "",
                data: [],
                borderColor: "#f59e0b",
                backgroundColor: "#f59e0b",
                tension: 0.35,
                borderWidth: 2,
                pointRadius: 0,
                pointHoverRadius: 5,
                spanGaps: true,
                fill: false,
            }],
        },
        options: {
            responsive: true,
            maintainAspectRatio: false,
            interaction: {
                mode: "index",
                intersect: false,
            },
            plugins: {
                legend: {
                    position: "top",
                },
                tooltip: {
                    callbacks: {
                        title(items) {
                            const index = items?.[0]?.dataIndex ?? -1;
                            const points = getEnvironmentPointsForActiveRange()
                                .filter((point) => Number.isFinite(Number(point?.[selectedEnvironmentMetric])));
                            const point = points[index] || null;
                            if (!point || !Number.isFinite(Number(point.timestamp))) return "";
                            return new Date(Number(point.timestamp) * 1000).toLocaleString("id-ID");
                        },
                        label(item) {
                            const metric = getActiveEnvironmentMetric();
                            const value = Number(item.raw);
                            if (!Number.isFinite(value)) return `${metric.label}: -`;
                            return `${metric.label}: ${value.toFixed(metric.digits)}${metric.suffix}`;
                        },
                    },
                },
            },
            scales: {
                x: {
                    ticks: {
                        maxTicksLimit: 8,
                    },
                    grid: {
                        color: "rgba(45, 90, 39, 0.08)",
                    },
                },
                y: {
                    beginAtZero: false,
                    grid: {
                        color: "rgba(45, 90, 39, 0.08)",
                    },
                },
            },
        },
    });
}

async function loadEnvironmentHistory() {
    const rangeMeta = getActiveEnvironmentRangeMeta();
    updateEnvironmentRangeBadge();

    try {
        const params = new URLSearchParams();
        params.set("device_id", DEVICE_ID);
        params.set("measurement", "incubator_sensor");
        params.set("driver", "mongodb");
        params.set("range", rangeMeta.range);
        params.set("window", rangeMeta.window);
        params.set("fields", "temperature,humidity,soil_moisture");
        params.set("_ts", String(Date.now()));

        let response = await syncRequest(`/sensor-history?${params.toString()}`);
        let points = Array.isArray(response?.data) ? response.data : [];
        if (!points.length) {
            params.delete("fields");
            response = await syncRequest(`/sensor-history?${params.toString()}`);
            points = Array.isArray(response?.data) ? response.data : [];
        }

        const normalizedPoints = points
            .map((point) => ({
                timestamp: parseEnvironmentHistoryTimestamp(point?.timestamp ?? point?.time ?? point?.recorded_at ?? point?.created_at),
                temperature: Number.isFinite(Number(point?.temperature)) ? Number(point.temperature) : null,
                humidity: Number.isFinite(Number(point?.humidity)) ? Number(point.humidity) : null,
                soil_moisture: Number.isFinite(Number(point?.soil_moisture)) ? Number(point.soil_moisture) : null,
            }))
            .filter((point) => Number.isFinite(Number(point?.timestamp)))
            .map((point) => ({
                timestamp: Number(point.timestamp),
                temperature: Number.isFinite(Number(point?.temperature)) ? Number(point.temperature) : null,
                humidity: Number.isFinite(Number(point?.humidity)) ? Number(point.humidity) : null,
                soil_moisture: Number.isFinite(Number(point?.soil_moisture)) ? Number(point.soil_moisture) : null,
            }));

        if (normalizedPoints.length > 0) {
            environmentHistoryPoints = normalizedPoints.sort((a, b) => a.timestamp - b.timestamp);
        } else if (Array.isArray(environmentHistoryPoints) && environmentHistoryPoints.length > 0) {
            environmentHistoryPoints = environmentHistoryPoints
                .filter((point) => Number.isFinite(Number(point?.timestamp)))
                .sort((a, b) => a.timestamp - b.timestamp);
        } else if (Number.isFinite(Number(latestTemperature)) || Number.isFinite(Number(latestHumidity)) || Number.isFinite(Number(latestSoilMoisture))) {
            environmentHistoryPoints = [{
                timestamp: Math.floor(Date.now() / 1000),
                temperature: Number.isFinite(Number(latestTemperature)) ? Number(latestTemperature) : null,
                humidity: Number.isFinite(Number(latestHumidity)) ? Number(latestHumidity) : null,
                soil_moisture: Number.isFinite(Number(latestSoilMoisture)) ? Number(latestSoilMoisture) : null,
            }];
        } else {
            environmentHistoryPoints = [];
        }

        renderEnvironmentHistoryChart();
        persistUiState();
    } catch (error) {
        console.warn("load environment history failed", error);
        updateEnvironmentHistorySummary();
    }
}

function pushEnvironmentHistoryPoint(temperatureOrPoint, humidity, timestampSec) {
    const point = (typeof temperatureOrPoint === "object" && temperatureOrPoint !== null)
        ? temperatureOrPoint
        : {
            temperature: temperatureOrPoint,
            humidity,
            timestamp: timestampSec,
        };

    const timestamp = Number(point.timestamp);
    if (!Number.isFinite(timestamp)) return;

    environmentHistoryPoints.push({
        timestamp,
        temperature: Number.isFinite(Number(point.temperature)) ? Number(point.temperature) : null,
        humidity: Number.isFinite(Number(point.humidity)) ? Number(point.humidity) : null,
        soil_moisture: Number.isFinite(Number(point.soil_moisture)) ? Number(point.soil_moisture) : null,
    });

    const maxRangeSeconds = Math.max(...Object.values(ENVIRONMENT_HISTORY_RANGE_OPTIONS).map((option) => Number(option.seconds || 0)));
    const minTimestamp = timestamp - maxRangeSeconds;
    environmentHistoryPoints = environmentHistoryPoints
        .filter((pointItem) => pointItem.timestamp >= minTimestamp)
        .sort((a, b) => a.timestamp - b.timestamp);

    renderEnvironmentHistoryChart();
    persistUiState();
}

function renderEnvironmentHistoryChart() {
    if (!environmentHistoryChart) {
        updateEnvironmentHistorySummary();
        return;
    }

    updateEnvironmentRangeBadge();
    const metric = getActiveEnvironmentMetric();
    const points = getEnvironmentPointsForActiveRange()
        .filter((point) => Number.isFinite(Number(point?.[selectedEnvironmentMetric])));

    environmentHistoryChart.data.labels = points.map((point) => formatHistoryTime(point.timestamp));
    environmentHistoryChart.data.datasets[0].label = metric.legend;
    environmentHistoryChart.data.datasets[0].data = points.map((point) => point[selectedEnvironmentMetric]);
    environmentHistoryChart.data.datasets[0].borderColor = metric.color;
    environmentHistoryChart.data.datasets[0].backgroundColor = metric.color;
    environmentHistoryChart.data.datasets[0].pointRadius = points.length <= 1 ? 5 : 0;
    environmentHistoryChart.data.datasets[0].pointHoverRadius = points.length <= 1 ? 6 : 5;
    environmentHistoryChart.update("none");
    updateEnvironmentHistorySummary(points);
}

function updateEnvironmentHistorySummary(points = environmentHistoryPoints) {
    const summary = document.getElementById("environmentHistorySummary");
    if (!summary) return;

    const rangeMeta = getActiveEnvironmentRangeMeta();
    if (!Array.isArray(points) || points.length === 0) {
        summary.textContent = `Belum ada data MongoDB pada rentang ${rangeMeta.label}. Grafik akan terisi setelah histori perangkat tersedia.`;
        return;
    }

    const latest = points[points.length - 1] || {};
    const latestTime = Number.isFinite(Number(latest.timestamp))
        ? new Date(Number(latest.timestamp) * 1000).toLocaleString("id-ID")
        : "-";
    const tempText = Number.isFinite(Number(latest.temperature)) ? `${Number(latest.temperature).toFixed(1)} °C` : "-";
    const humText = Number.isFinite(Number(latest.humidity)) ? `${Number(latest.humidity).toFixed(1)} %` : "-";
    const soilText = Number.isFinite(Number(latest.soil_moisture)) ? `${Number(latest.soil_moisture).toFixed(0)} %` : "-";

    summary.textContent = `Range ${rangeMeta.label} | ${points.length} titik | Update terakhir ${latestTime}. Suhu udara ${tempText}, kelembaban udara ${humText}, kelembaban tanah ${soilText}.`;
}

function updateRelayUI(relay, status) {
    const stateEl = document.getElementById(relay + "Status");
    const toggleEl = document.getElementById(relay + "Toggle");
    if (stateEl) {
        stateEl.textContent = status === 1 ? "ON" : "OFF";
        stateEl.style.color = status === 1 ? "#4caf50" : "#ff5252";
    }
    if (toggleEl) toggleEl.checked = status === 1;
    if (relay === "kipas") deviceState.fan = status === 1;
    if (relay === "sprayer") deviceState.sprayer = status === 1;
    persistUiState();

    if (relay === "sprayer") {
        if (status === 1) {
            if (!sprayerUiRunning) {
                const duration = currentMode === "manual" ? getEffectiveSprayerDuration() : (currentPlant?.wateringDuration || 5);
                startSprayerCountdown(duration);
                sprayerUiRunning = true;
            }
        } else stopSprayerCountdown();
    }
}

function updateLampuRelayUI(status) {
    const stateEl = document.getElementById("lampuRelayStatus");
    const toggleEl = document.getElementById("lampuRelayToggle");
    const pwmToggle = document.getElementById("lampPWMToggle");
    if (stateEl) {
        stateEl.textContent = status === 1 ? "ON" : "OFF";
        stateEl.style.color = status === 1 ? "#4caf50" : "#ff5252";
    }
    if (toggleEl) toggleEl.checked = status === 1;
    if (pwmToggle) pwmToggle.checked = status === 1;
    deviceState.lamp = status === 1;
    persistUiState();
}

function updateBrightnessUI(brightness) {
    document.getElementById("brightnessValue").textContent = brightness + "%";
    document.getElementById("brightnessSlider").value = brightness;
}

function updateLampPWMStatus() {
    db.ref(DEVICE_PATH + "/relay/lamp").once("value", (snap) => {
        const status = snap.val();
        const lampStatus = document.getElementById("lampPWMStatus");
        if (!lampStatus) return;
        lampStatus.textContent = status ? "ON" : "OFF";
        lampStatus.style.color = status ? "#4caf50" : "#ff5252";
    });
}

function updateModeUI(mode) {
    const autoBtn = document.getElementById("autoModeBtn");
    const manualBtn = document.getElementById("manualModeBtn");
    const modeBadge = document.getElementById("currentModeBadge");

    if (mode === "auto") {
        autoBtn.classList.add("active");
        manualBtn.classList.remove("active");
        modeBadge.textContent = "AUTO";
        modeBadge.style.background = "#4caf50";
    } else {
        autoBtn.classList.remove("active");
        manualBtn.classList.add("active");
        modeBadge.textContent = "MANUAL";
        modeBadge.style.background = "#9c27b0";
    }

    const isAuto = mode === "auto";
    ["kipasToggle", "sprayerToggle", "lampuRelayToggle", "lampPWMToggle", "brightnessSlider", "lampStartDate", "lampStartTime", "lampEndTime"].forEach(id => {
        const el = document.getElementById(id);
        if (el) el.disabled = isAuto;
    });
    document.querySelectorAll("#lampActiveDays input[type='checkbox']").forEach((el) => {
        el.disabled = isAuto;
    });
    document.querySelectorAll(".schedule-time-input, .remove-time").forEach((el) => {
        el.disabled = isAuto;
    });
    const addScheduleBtn = document.getElementById("addScheduleBtn");
    if (addScheduleBtn) addScheduleBtn.disabled = isAuto;
    ["saveSprayerBtn", "saveLightingBtn"].forEach((id) => {
        const el = document.getElementById(id);
        if (el) el.disabled = isAuto;
    });
    currentMode = mode === "auto" ? "auto" : "manual";
    localShadow.mode = currentMode;
    updateSprayerDurationInfo();
    persistUiState();
    maybeRepairAutoPlantSync("mode_ui");
}

function updateTempRange() {
    const min = document.getElementById("minTemp").value;
    const max = document.getElementById("maxTemp").value;
    document.getElementById("tempRange").textContent = min + "-" + max + "C";
}

function updateESPStatus(online) {
    const espStatus = document.getElementById("esp32Status");
    const wifiStatus = document.getElementById("wifiStatus");
    espOffline = !online;

    if (online) {
        espStatus.textContent = "Online";
        espStatus.className = "status-value online";
        wifiStatus.textContent = "Terhubung";
        wifiStatus.className = "status-value online";
        hideBanner();
    } else {
        espStatus.textContent = "Offline";
        espStatus.className = "status-value offline";
        wifiStatus.textContent = "Terputus";
        wifiStatus.className = "status-value offline";
        showBanner("ESP32 tidak terhubung! Periksa koneksi perangkat.", "error");
    }
}

function updateConnectionStatus(connected) {
    const connectionText = document.getElementById("connectionText");
    const connectionDot = document.getElementById("connectionDot");
    const firebaseStatus = document.getElementById("firebaseStatus");
    const streamStatus = document.getElementById("streamStatus");
    if (connected) {
        connectionText.textContent = "Terhubung ke MQTT Broker";
        connectionDot.className = "status-dot connected";
        firebaseStatus.textContent = "Aktif";
        firebaseStatus.className = "status-value online";
        streamStatus.textContent = "Aktif";
        streamStatus.className = "status-value online";
    } else {
        connectionText.textContent = "Terputus dari MQTT Broker";
        connectionDot.className = "status-dot";
        firebaseStatus.textContent = "Offline";
        firebaseStatus.className = "status-value offline";
        streamStatus.textContent = "Offline";
        streamStatus.className = "status-value offline";
    }
}

function updateTime() {
    const now = new Date();
    const timeStr = now.toLocaleTimeString("id-ID");
    document.getElementById("sensorUpdateTime").textContent = timeStr;
    document.getElementById("lastUpdate").innerHTML = `<i class="fas fa-clock"></i><span>Terakhir update: ${timeStr}</span>`;

    const minuteKey = `${now.getFullYear()}-${now.getMonth()}-${now.getDate()}-${now.getHours()}-${now.getMinutes()}`;
    if (currentPlant && minuteKey !== lastActivePlantMetaMinuteKey) {
        lastActivePlantMetaMinuteKey = minuteKey;
        renderActivePlantOverview();
    }
}

function updatePlantStatusIndicators() {
    if (!currentPlant) return;
    applyRealtimePlantTemperatureComparison();
    renderActivePlantOverview();
    maybeRepairAutoPlantSync("plant_status_indicator");
}

function saveAppliedPlantHistory(plant) {
    db.ref(DEVICE_PATH + "/applied_plants_history").push({
        timestamp: Date.now(),
        date: todayDate(),
        plantId: plant.id,
        plantName: plant.name,
        lightStartDate: plant.lightStartDate || todayDate(),
        lightStartTime: plant.lightStartTime || "06:00",
        lightEndTime: plant.lightEndTime || "17:00",
        duration: plant.wateringDuration,
        times: plant.wateringTimes || []
    });
}

function pushSystemLog(action, details = {}, options = {}) {
    db.ref(DEVICE_PATH + "/system_activity_logs").push({
        timestamp: Date.now(),
        date: todayDate(),
        action,
        details,
        mode: currentMode
    });

    const moduleName = typeof options?.module === "string" && options.module.trim()
        ? options.module.trim()
        : "inkubator";

    syncRequest("/activity", "POST", {
        action: `web.${action}`,
        module: moduleName,
        device_id: DEVICE_ID,
        description: buildActivityDescription(action, details),
        metadata: {
            mode: currentMode,
            details
        },
        performed_at: new Date().toISOString()
    }).catch((e) => console.warn("sync activity failed", e));
}

let lastButtonLog = { key: "", at: 0 };
function initButtonClickLogging() {
    document.addEventListener("click", function (event) {
        const target = event.target instanceof Element ? event.target : null;
        if (!target) return;

        const el = target.closest("button, .btn, [role='button'], input[type='button'], input[type='submit'], a[data-log-click]");
        if (!el) return;
        if (el.hasAttribute("data-log-ignore")) return;

        const label = resolveButtonLabel(el);
        if (!label) return;

        const key = `${el.tagName}:${label}`;
        const now = Date.now();
        if (lastButtonLog.key === key && (now - lastButtonLog.at) < 600) {
            return;
        }
        lastButtonLog = { key, at: now };

        pushSystemLog("ui_button_click", {
            label,
            tag: el.tagName.toLowerCase(),
            id: el.id || null,
            className: (el.className || "").toString().trim() || null
        });
    });
}

function resolveButtonLabel(el) {
    if (!el) return "";
    const attrs = ["data-log-label", "aria-label", "title", "name"];
    for (const attr of attrs) {
        const v = el.getAttribute(attr);
        if (v && v.trim()) return v.trim();
    }
    const text = (el.innerText || el.textContent || "").replace(/\s+/g, " ").trim();
    if (text) return text;
    return el.id || "";
}

function renderActivePlantOverview() {
    const emptyEl = document.getElementById("activePlantEmpty");
    const contentEl = document.getElementById("activePlantContent");
    const titleEl = document.getElementById("activePlantTitle");
    const metaEl = document.getElementById("activePlantMeta");
    const settingsEl = document.getElementById("activePlantSettings");
    const systemsEl = document.getElementById("activePlantSystems");
    if (!emptyEl || !contentEl || !titleEl || !metaEl || !settingsEl || !systemsEl) return;

    if (!currentPlant || activePlantClosed) {
        contentEl.style.display = "none";
        emptyEl.style.display = "block";
        emptyEl.textContent = "Belum ada tumbuhan aktif.";
        applyRealtimePlantTemperatureComparison();
        return;
    }

    emptyEl.style.display = "none";
    contentEl.style.display = "block";
    titleEl.innerHTML = `<i class="fas fa-seedling"></i> ${currentPlant.name || "Tanaman Aktif"}`;
    const nextWateringText = getNextWateringText(currentPlant);
    const remainingDaysText = getPlantRemainingDaysText(currentPlant);
    metaEl.innerHTML = `
        <i class="fas fa-calendar-day"></i> Penyinaran mulai ${formatDate(currentPlant.lightStartDate)}
        <span style="margin:0 6px;">|</span>
        <i class="fas fa-clock"></i> Siram ${(currentPlant.wateringTimes || []).join(", ")}
        <span style="margin:0 6px;">|</span>
        <i class="fas fa-droplet"></i> Berikutnya ${nextWateringText}
        <span style="margin:0 6px;">|</span>
        <i class="fas fa-hourglass-end"></i> Sisa ${remainingDaysText}
    `;

    const settings = [
        { icon: "fa-gear", text: `Mode ${String(currentMode).toUpperCase()}` },
        { icon: "fa-thermometer-half", text: `Suhu ${currentPlant.tempMin}C-${currentPlant.tempMax}C` },
        { icon: "fa-lightbulb", text: `Lampu ${currentPlant.lightPWM}%` },
        { icon: "fa-hourglass-half", text: `Durasi sprayer ${currentPlant.wateringDuration}s` },
        {
            html: `<button type="button" class="active-plant-pill active-plant-pill-action" data-action="show-light-cycle">
                <i class="fas fa-sun"></i>
                Siklus gelap/terang
            </button>`
        },
    ];
    const tempCompare = getRealtimePlantTemperatureComparison();
    settings.push({
        icon: "fa-temperature-high",
        text: `Realtime ${tempCompare.status}`
    });
    settingsEl.innerHTML = settings
        .map((x) => {
            if (x.html) return x.html;
            return `<span class="active-plant-pill"><i class="fas ${x.icon}"></i>${x.text}</span>`;
        })
        .join("");

    const fanTempEl = document.getElementById("fanSetTempMax");
    if (fanTempEl) fanTempEl.textContent = String(currentPlant.tempMax ?? "--");

    const sprayerDurationEl = document.getElementById("sprayerConfiguredDuration");
    if (sprayerDurationEl) sprayerDurationEl.textContent = String(currentPlant.wateringDuration ?? "-");

    const nextScheduleEl = document.getElementById("sprayerNextSchedule");
    if (nextScheduleEl) nextScheduleEl.textContent = getNextWateringText(currentPlant);

    const systems = [
        { icon: "fa-wind", label: "Kipas", on: deviceState.fan },
        { icon: "fa-spray-can", label: "Sprayer", on: deviceState.sprayer },
        { icon: "fa-lightbulb", label: "Lampu", on: deviceState.lamp },
    ];
    systemsEl.innerHTML = systems
        .map((x) => `<span class="active-plant-pill ${x.on ? "on" : "off"}"><i class="fas ${x.icon}"></i>${x.label} ${x.on ? "ON" : "OFF"}</span>`)
        .join("");
    applyRealtimePlantTemperatureComparison();
    persistUiState();
}

function openLightCycleModal() {
    const modal = document.getElementById("lightCycleModal");
    const body = document.getElementById("lightCycleModalBody");
    if (!modal || !body) return;

    if (!currentPlant) {
        body.innerHTML = "Belum ada tumbuhan aktif.";
        modal.style.display = "flex";
        return;
    }

    const cycle = currentPlant.lightCycle || {};
    const startDateRaw = String(cycle.start_date || currentPlant.lightStartDate || todayDate());
    const startPhase = String(cycle.start_phase || "dark").toLowerCase() === "light" ? "light" : "dark";
    const darkDays = Math.max(1, Number(cycle.dark_days || 7));
    const lightDays = Math.max(1, Number(cycle.light_days || 7));

    const start = new Date(`${startDateRaw}T00:00:00`);
    if (Number.isNaN(start.getTime())) {
        body.innerHTML = "Format tanggal siklus tidak valid.";
        modal.style.display = "flex";
        return;
    }

    const addDays = (date, days) => {
        const d = new Date(date.getTime());
        d.setDate(d.getDate() + days);
        return d;
    };

    let darkStart = start;
    let lightStart = start;
    if (startPhase === "dark") {
        darkStart = start;
        lightStart = addDays(start, darkDays);
    } else {
        lightStart = start;
        darkStart = addDays(start, lightDays);
    }
    const darkEnd = addDays(darkStart, darkDays - 1);
    const lightEnd = addDays(lightStart, lightDays - 1);

    const fmt = (d) => d.toLocaleDateString("id-ID", { day: "2-digit", month: "short", year: "numeric" });

    body.innerHTML = `
        <div><strong>Mulai siklus:</strong> ${startDateRaw} (${startPhase.toUpperCase()})</div>
        <div style="margin-top:10px;"><strong>Masa gelap:</strong> ${fmt(darkStart)} s/d ${fmt(darkEnd)} (${darkDays} hari)</div>
        <div style="margin-top:6px;"><strong>Masa terang:</strong> ${fmt(lightStart)} s/d ${fmt(lightEnd)} (${lightDays} hari)</div>
    `;
    modal.style.display = "flex";
}

function closeLightCycleModal() {
    const modal = document.getElementById("lightCycleModal");
    if (!modal) return;
    modal.style.display = "none";
}

function finishActivePlant() {
    if (!currentPlant) return;
    const finishedName = currentPlant.name;
    activePlantClosed = true;
    db.ref(DEVICE_PATH + "/active_plant").set("");
    pushSystemLog("finish_active_plant", { plantName: finishedName });
    renderActivePlantOverview();
    showTemporaryNotification(`Tumbuhan ${finishedName} selesai`, "success");
}

function summarizeDetails(details) {
    if (!details || typeof details !== "object") return "-";
    return Object.entries(details).map(([k, v]) => `${k}: ${v}`).join(" | ");
}

function getRelayDisplayName(relay) {
    if (relay === "fan") return "Kipas";
    if (relay === "sprayer") return "Sprayer";
    if (relay === "lamp") return "Lampu";
    return relay;
}

function buildActivityDescription(action, details = {}) {
    if (action === "ui_button_click") {
        return `Klik tombol "${details.label || ''}"`;
    }

    if (action === "auto_repair_active_plant_sync") {
        return `Penyelarasan suhu otomatis: Suhu saat ini ${details.temperature || '--'}°C (Batas maksimum optimal: ${details.tempMax || '--'}°C)`;
    }

    if (action === "relay_control") {
        const relayLabel = getRelayDisplayName(details.relay);
        const stateLabel = details.state === "ON" ? "menyala" : "mati";
        return `Relay ${relayLabel} ${stateLabel} (manual)`;
    }

    if (action === "auto_relay_activity") {
        const relayLabel = getRelayDisplayName(details.relay);
        const stateLabel = details.state === "ON" ? "menyala" : "mati";
        return `Relay ${relayLabel} ${stateLabel} (sistem)`;
    }

    if (action === "auto_sprayer_triggered") {
        const plantPart = details.plantName ? ` untuk ${details.plantName}` : "";
        return `Relay Sprayer menyala (sistem)${plantPart}`;
    }

    if (action === "auto_lamp_schedule") {
        return `Relay Lampu ${details.state === "ON" ? "menyala" : "mati"} (sistem)`;
    }

    return summarizeDetails(details);
}

function logAutoRelayActivity(relay, isOn) {
    const stateBucket = relayLogState[relay];
    if (!stateBucket) return;

    if (!stateBucket.initialized) {
        stateBucket.initialized = true;
        stateBucket.last = isOn;
        return;
    }

    if (stateBucket.last === isOn) return;
    stateBucket.last = isOn;

    if (currentMode !== "auto") return;

    const now = new Date();
    const hhmm = now.toLocaleTimeString("id-ID", { hour: "2-digit", minute: "2-digit" });
    const stateText = isOn ? "ON" : "OFF";
    const dedupKey = `${todayDate()}|${relay}|${stateText}|${hhmm}`;
    if (autoActivityLogDedup.has(dedupKey)) return;

    autoActivityLogDedup.set(dedupKey, now.getTime());
    if (autoActivityLogDedup.size > 120) {
        const oldestKey = autoActivityLogDedup.keys().next().value;
        if (oldestKey) autoActivityLogDedup.delete(oldestKey);
    }

    let reason = "sinkronisasi mode otomatis";
    if (relay === "fan") {
        const comparison = getRealtimePlantTemperatureComparison();
        reason = comparison?.status ? `berdasarkan suhu realtime: ${comparison.status}` : reason;
    } else if (relay === "lamp") {
        reason = isOn ? "masuk masa terang" : "di luar masa terang";
    } else if (relay === "sprayer") {
        reason = isOn ? "jadwal penyiraman otomatis aktif" : "durasi penyiraman otomatis selesai";
    }

    pushSystemLog("auto_relay_activity", {
        relay,
        relayLabel: getRelayDisplayName(relay),
        state: stateText,
        time: hhmm,
        plantId: currentPlant?.id || "",
        plantName: currentPlant?.name || "",
        reason,
    }, { module: "system" });
}

function showBanner(message, type = "error") {
    const banner = document.getElementById("notificationBanner");
    const bannerMessage = document.getElementById("bannerMessage");
    if (!banner || !bannerMessage) return;
    bannerMessage.textContent = message;
    banner.className = "notification-banner " + type;
    banner.style.display = "block";
}
function hideBanner() { const banner = document.getElementById("notificationBanner"); if (banner) banner.style.display = "none"; }

function showTemporaryNotification(message, type = "info", timeout = 3000) {
    if (!espOffline) { showBanner(message, type); setTimeout(hideBanner, timeout); }
    else showToast(message, type);
}

function showToast(message, type = "success") {
    const existing = document.querySelector(".toast-incubator");
    if (existing) existing.remove();
    const toast = document.createElement("div");
    toast.className = "toast-incubator";
    toast.style.cssText = `position: fixed; top: 30px; right: 30px; padding: 15px 25px; background: ${type === "success" ? "#4caf50" : type === "error" ? "#f44336" : "#ff9800"}; color: white; border-radius: 10px; font-weight: 500; z-index: 3000; animation: slideInRight 0.3s ease; box-shadow: 0 5px 20px rgba(0,0,0,0.2); display: flex; align-items: center; gap: 10px;`;
    const icon = type === "success" ? "fa-check-circle" : type === "error" ? "fa-exclamation-circle" : "fa-exclamation-triangle";
    toast.innerHTML = `<i class="fas ${icon}"></i><span>${message}</span>`;
    document.body.appendChild(toast);
    setTimeout(() => { toast.style.animation = "slideOutRight 0.3s ease"; setTimeout(() => toast.remove(), 300); }, 3000);
}

const style = document.createElement("style");
style.textContent = "@keyframes slideInRight { from { transform: translateX(100%); opacity: 0; } to { transform: translateX(0); opacity: 1; } } @keyframes slideOutRight { from { transform: translateX(0); opacity: 1; } to { transform: translateX(100%); opacity: 0; } }";
document.head.appendChild(style);

function startSprayerCountdown(durationSeconds) {
    if (countdownInterval) clearInterval(countdownInterval);
    sprayerEndTime = Date.now() + durationSeconds * 1000;
    const countdownEl = document.getElementById("sprayerCountdown");
    const timeEl = document.getElementById("countdownTime");
    if (!countdownEl || !timeEl) return;
    countdownEl.style.display = "flex";
    countdownInterval = setInterval(() => {
        const remaining = Math.max(0, Math.floor((sprayerEndTime - Date.now()) / 1000));
        timeEl.textContent = remaining + "s";
        if (remaining <= 0) {
            clearInterval(countdownInterval);
            countdownInterval = null;
            countdownEl.style.display = "none";
            if (currentMode === "manual") setRelay("sprayer", false);
        }
    }, 1000);
}

function stopSprayerCountdown() {
    if (countdownInterval) { clearInterval(countdownInterval); countdownInterval = null; }
    const countdownEl = document.getElementById("sprayerCountdown");
    if (countdownEl) countdownEl.style.display = "none";
    sprayerUiRunning = false;
}

function checkESPConnection() {
    const nowSec = Math.floor(Date.now() / 1000);
    if (lastSeenTime > 0) updateESPStatus(nowSec - lastSeenTime <= 20);
    else updateESPStatus((Date.now() - lastSensorTime) <= 20000);
}

function todayDate() {
    const now = new Date();
    return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}-${String(now.getDate()).padStart(2, "0")}`;
}

function formatDate(value) {
    if (!value) return "-";
    const dt = new Date(value + "T00:00:00");
    return dt.toLocaleDateString("id-ID", { day: "2-digit", month: "short", year: "numeric" });
}

function formatDateTime(timestamp) {
    if (!timestamp) return "-";
    return new Date(timestamp).toLocaleString("id-ID");
}

function parsePlantDate(value) {
    if (!value || typeof value !== "string") return null;
    const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value.trim());
    if (!match) return null;
    const year = Number(match[1]);
    const month = Number(match[2]) - 1;
    const day = Number(match[3]);
    const date = new Date(year, month, day);
    if (Number.isNaN(date.getTime())) return null;
    date.setHours(0, 0, 0, 0);
    return date;
}

function parseTodayTime(timeStr, now = new Date()) {
    if (!timeStr || typeof timeStr !== "string") return null;
    const match = /^(\d{1,2}):(\d{2})$/.exec(timeStr.trim());
    if (!match) return null;
    const hours = Number(match[1]);
    const minutes = Number(match[2]);
    if (hours < 0 || hours > 23 || minutes < 0 || minutes > 59) return null;
    return new Date(
        now.getFullYear(),
        now.getMonth(),
        now.getDate(),
        hours,
        minutes,
        0,
        0
    );
}

function getNextWateringText(plant) {
    const times = normalizeTimes(Array.isArray(plant?.wateringTimes) ? plant.wateringTimes : []);
    if (times.length === 0) return "-";

    const now = new Date();
    const candidates = times
        .map((time) => ({ time, date: parseTodayTime(time, now) }))
        .filter((item) => item.date instanceof Date && !Number.isNaN(item.date.getTime()));

    if (candidates.length === 0) return "-";

    let next = candidates.find((item) => item.date.getTime() >= now.getTime());
    let dayLabel = "hari ini";
    if (!next) {
        next = candidates[0];
        dayLabel = "besok";
    }

    return `${next.time} (${dayLabel})`;
}

function getPlantRemainingDaysText(plant) {
    const cycle = plant?.lightCycle || {};
    const darkDays = Math.max(1, parseInt(cycle.dark_days, 10) || 0);
    const lightDays = Math.max(1, parseInt(cycle.light_days, 10) || 0);
    const totalDays = darkDays + lightDays;
    const startDate = parsePlantDate(cycle.start_date || plant?.lightStartDate);

    if (!startDate || totalDays <= 0) return "-";

    const today = new Date();
    today.setHours(0, 0, 0, 0);
    const diffMs = today.getTime() - startDate.getTime();
    const elapsedDays = diffMs <= 0 ? 0 : Math.floor(diffMs / 86400000);
    const remainingDays = Math.max(totalDays - elapsedDays, 0);

    if (remainingDays === 0) return "0 hari";
    return `${remainingDays} hari dari ${totalDays} hari siklus`;
}

