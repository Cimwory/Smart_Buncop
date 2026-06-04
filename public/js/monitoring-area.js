const areaCatalog = {
    bc1: {
        code: "BC-1",
        name: "Buncob 1",
        summary: "Screen House",
        subAreas: [
            { id: "bc1-screenhouse", name: "Screen House BC-1", area: "monitoring", deviceId: "bc1_screenhouse" }
        ]
    },
    bc2: {
        code: "BC-2",
        name: "Buncob 2",
        summary: "Area Hidroponik, Rumah Kaca Anggrek, Screen House",
        underDevelopment: true,
        subAreas: []
    },
    atc: {
        code: "ATC",
        name: "Agro Tech Center",
        summary: "Enviro Control, Smart Hidroponik, Irigasi",
        subAreas: [
            { id: "atc-enviro-control", name: "Enviro Control", area: "monitoring", deviceId: "atc_enviro", kind: "enviro" },
            { id: "atc-smart-hidroponik", name: "Smart Hidroponik", area: "monitoring", deviceId: "atc_smart_hidroponik", kind: "hydro" },
            { id: "atc-irigasi-rkk", name: "Irigasi RKK", area: "monitoring", deviceId: "atc_irigasi_rkk", kind: "irrigation" },
            { id: "atc-irigasi-rkb", name: "Irigasi RKB", area: "monitoring", deviceId: "atc_irigasi_rkb", kind: "irrigation" }
        ]
    }
};

const subAreaState = {};
let openedAreaId = null;
let mqttConnected = false;
const mqttSubscriptions = {};
const monitoringStateStorageKey = "buncop.monitoring-area.state.v1";
const chartHistoryLimit = 120;
const influxHistoryAutoRange = "-1h";
const influxHistoryAutoWindow = "1m";
const influxHistoryRefreshMs = 30000;
let influxHistoryTimer = null;
const influxHistoryInFlight = new Set();
const miniChartInstances = {};
const influxHistoryTargets = {
    "bc1-screenhouse": {
        deviceId: "bc1_screenhouse",
        measurement: "monitoring_bc1_screenhouse",
        fields: ["temperature", "humidity"],
    },
    "atc-irigasi-rkk": {
        deviceId: "atc_irigasi_rkk",
        measurement: "monitoring_atc_irigasi_rkk",
        fields: ["temperature", "humidity", "soil_moisture"],
    },
    "atc-irigasi-rkb": {
        deviceId: "atc_irigasi_rkb",
        measurement: "monitoring_atc_irigasi_rkb",
        fields: ["temperature", "humidity", "soil_moisture"],
    },
    "atc-enviro-control": {
        deviceId: "atc_enviro",
        measurement: "monitoring_atc_enviro",
        fields: ["nh3", "ch4"],
    },
    "atc-smart-hidroponik": {
        deviceId: "atc_smart_hidroponik",
        measurement: "monitoring_atc_smart_hidroponik",
        fields: ["ph", "tds"],
    },
};

function getAreaIdFromQuery() {
    const forced = String(window.BUNCOP_MONITORING_AREA_ID || "").trim().toLowerCase();
    if (forced && areaCatalog[forced]) return forced;
    try {
        const params = new URLSearchParams(window.location.search);
        const raw = String(params.get("area") || "").trim().toLowerCase();
        if (raw && areaCatalog[raw]) return raw;
    } catch (error) {
        console.warn("[monitoring-area] gagal membaca query area", error);
    }
    return null;
}

function clonePlain(value) {
    return JSON.parse(JSON.stringify(value));
}

function loadPersistedMonitoringState() {
    try {
        const raw = window.localStorage.getItem(monitoringStateStorageKey);
        if (!raw) return {};
        const parsed = JSON.parse(raw);
        return parsed && typeof parsed === "object" ? parsed : {};
    } catch (error) {
        console.warn("[monitoring-area] failed to load persisted state", error);
        return {};
    }
}

function persistMonitoringState() {
    try {
        const payload = {};
        Object.entries(subAreaState).forEach(([subAreaId, state]) => {
            payload[subAreaId] = clonePlain(state);
        });
        window.localStorage.setItem(monitoringStateStorageKey, JSON.stringify(payload));
    } catch (error) {
        console.warn("[monitoring-area] failed to persist state", error);
    }
}

function formatLocalDateTime(dt) {
    if (!(dt instanceof Date) || Number.isNaN(dt.getTime())) return "";
    const y = dt.getFullYear().toString().padStart(4, "0");
    const m = (dt.getMonth() + 1).toString().padStart(2, "0");
    const d = dt.getDate().toString().padStart(2, "0");
    const hh = dt.getHours().toString().padStart(2, "0");
    const mm = dt.getMinutes().toString().padStart(2, "0");
    const ss = dt.getSeconds().toString().padStart(2, "0");
    return `${y}-${m}-${d} ${hh}:${mm}:${ss}`;
}

function getAreaMeta(areaId) {
    return areaCatalog[areaId] || null;
}

function logFrontendActivity(payload) {
    const cfg = window.BUNCOP_WEB_CONFIG || {};
    if (!cfg.activityLogUrl) return Promise.resolve(false);

    return fetch(cfg.activityLogUrl, {
        method: "POST",
        credentials: "same-origin",
        headers: {
            "Content-Type": "application/json",
            "Accept": "application/json",
            "X-Requested-With": "XMLHttpRequest",
            "X-CSRF-TOKEN": cfg.csrfToken || "",
        },
        body: JSON.stringify({
            ...payload,
            module: payload.module || "monitoring",
            performed_at: payload.performed_at || formatLocalDateTime(new Date()),
        }),
    })
        .then((response) => response.ok)
        .catch(() => false);
}

function logMonitoringAction({
    areaId = null,
    subAreaId = null,
    action,
    description,
    deviceId = null,
    metadata = {},
}) {
    const areaMeta = areaId ? getAreaMeta(areaId) : null;
    const subAreaMeta = subAreaId ? getSubAreaById(subAreaId) : null;
    return logFrontendActivity({
        action,
        module: "monitoring",
        device_id: deviceId || subAreaMeta?.deviceId || null,
        description,
        metadata: {
            area_id: areaId || null,
            area_code: areaMeta?.code || null,
            area_name: areaMeta?.name || null,
            subarea_id: subAreaId || null,
            subarea_name: subAreaMeta?.name || null,
            ...metadata,
        },
    });
}

function buildInitialState() {
    const persisted = loadPersistedMonitoringState();
    Object.values(areaCatalog).forEach((area) => {
        area.subAreas.forEach((subArea) => {
            const isEnviro = subArea.kind === "enviro";
            const isHydro = subArea.kind === "hydro";
            const isIrrigation = subArea.kind === "irrigation";
            const baseState = {
                modeProfile: isEnviro ? "enviro" : (isHydro ? "hydro" : (isIrrigation ? "irrigation" : "sprayer")),
                temperature: null,
                humidity: null,
                autoMode: false,
                manualMode: false,
                relay: [false, false, false],
                schedule: [],
                duration: 10,
                online: null,
                nh3: null,
                ch4: null,
                r0Mq135: null,
                r0Mq2: null,
                message: "-",
                nh3Upper: 25,
                nh3Lower: 10,
                autoNh3: isEnviro,
                relayManual: !isEnviro,
                relayActive: false,
                calibrationPending: false,
                ph: null,
                tds: null,
                autoPhTds: subArea.kind === "hydro",
                relayNutrisi: false,
                relayPhDown: false,
                phMin: 5.5,
                phMax: 6.5,
                tdsMin: 800,
                tdsMax: 1200,
                soilMoisture: null,
                relayPompa: false,
                relaySprayerIrigasi: false,
                pumpSchedule: [],
                sprayerSchedule: [],
                timerPompa: 30,
                timerSprayer: 20,
                pumpRemaining: null,
                sprayerRemaining: null,
                pumpScheduleDirty: false,
                sprayerScheduleDirty: false,
                lastRelayLog: {
                    enviro: null,
                    nutrisi: null,
                    phdown: null,
                    pompa: null,
                    sprayer: null,
                },
                lastRelayLogAt: {},
                chartMetric: isIrrigation ? "temperature" : "temperature",
                chartHistory: {
                    temperature: [],
                    humidity: [],
                    soilMoisture: [],
                },
                historyLastSyncAt: null,
                historySyncStatus: "idle",
                historySyncMessage: "",
            };
            const cachedState = persisted[subArea.id];
            subAreaState[subArea.id] = cachedState && typeof cachedState === "object"
                ? { ...baseState, ...cachedState, modeProfile: baseState.modeProfile }
                : baseState;
        });
    });
}

function formatRelayDescription(label, isOn, origin, deviceLabel = "") {
    const stateLabel = isOn ? "menyala" : "mati";
    const suffix = deviceLabel ? ` - ${deviceLabel}` : "";
    return `Relay ${label}${suffix} ${stateLabel} (${origin})`;
}

function shouldThrottleRelayLog(state, key, ttlMs = 60_000) {
    const now = Date.now();
    const lastAt = Number(state.lastRelayLogAt?.[key] || 0);
    if (lastAt && (now - lastAt) < ttlMs) return true;
    state.lastRelayLogAt = state.lastRelayLogAt || {};
    state.lastRelayLogAt[key] = now;
    return false;
}

function getSubAreaById(subAreaId) {
    for (const area of Object.values(areaCatalog)) {
        const found = area.subAreas.find((item) => item.id === subAreaId);
        if (found) return found;
    }
    return null;
}

function renderAllCurtains() {
    Object.entries(areaCatalog).forEach(([areaId, area]) => {
        const container = document.getElementById(`curtainInner-${areaId}`);
        if (!container) return;
        container.innerHTML = buildAreaCurtainHtml(areaId, area);
    });
    renderRealtimeChartsForArea(openedAreaId);
}

function buildAreaCurtainHtml(areaId, area) {
    const onlineSummary = computeAreaOnline(area);
    const summaryClass = onlineSummary.className;
    const summaryText = onlineSummary.label;

    if (area.underDevelopment) {
        return `
            <div class="area-detail-header">
                <div>
                    <p class="detail-code">${area.code}</p>
                    <h3 class="detail-title">${area.name}</h3>
                    <p class="detail-subtitle">${area.summary}</p>
                </div>
                <span class="status-badge ${summaryClass}">
                    <span class="status-dot"></span>
                    <span>${summaryText}</span>
                </span>
            </div>
            <div class="subarea-placeholder">
                <h4>Fitur dalam tahap Pengembangan</h4>
                <p>Area Buncob 2 untuk sementara dikosongkan dulu sambil menunggu penyempurnaan integrasi kontrol dan monitoring.</p>
            </div>
        `;
    }

    const subAreaCards = area.subAreas.map((subArea) => {
        const state = subAreaState[subArea.id];
        return buildSubAreaCardHtml(areaId, subArea, state);
    }).join("");

    return `
        <div class="area-detail-header">
            <div>
                <p class="detail-code">${area.code}</p>
                <h3 class="detail-title">${area.name}</h3>
                <p class="detail-subtitle">${area.summary}</p>
            </div>
            <span class="status-badge ${summaryClass}">
                <span class="status-dot"></span>
                <span>${summaryText}</span>
            </span>
        </div>
        <div class="subarea-cards">${subAreaCards}</div>
    `;
}

function buildSubAreaCardHtml(areaId, subArea, state) {
    if (subArea.kind === "enviro") {
        return buildEnviroControlCardHtml(areaId, subArea, state);
    }
    if (subArea.kind === "hydro") {
        return buildHydroControlCardHtml(areaId, subArea, state);
    }
    if (subArea.kind === "irrigation") {
        return buildIrrigationControlCardHtml(areaId, subArea, state);
    }

    const status = computeSubAreaOnline(state);
    const scheduleHtml = buildScheduleRowsHtml(areaId, subArea.id, state.schedule);
    const relayText = state.relay.map((isOn, idx) => `R${idx + 1}:${isOn ? "ON" : "OFF"}`).join(" ");
    const tempText = Number.isFinite(state.temperature) ? state.temperature.toFixed(1) : "--";
    const humText = Number.isFinite(state.humidity) ? state.humidity.toFixed(1) : "--";
    const durationVal = Math.max(1, Math.min(600, state.duration || 10));

    const manualControlsStyle = state.autoMode ? "display:none;" : "";
    const autoControlsStyle = state.autoMode ? "" : "display:none;";

    return `
        <article class="subarea-card" data-subarea-id="${subArea.id}" data-area-id="${areaId}">
            <div class="subarea-head">
                <h4 class="subarea-name">${subArea.name}</h4>
                <span class="status-badge ${status.className}">
                    <span class="status-dot"></span>
                    <span>${status.label}</span>
                </span>
            </div>

            <div class="sensor-grid">
                <div class="sensor-box">
                    <div class="sensor-icon"><i class="fas fa-temperature-high"></i></div>
                    <div>
                        <p class="sensor-name">Suhu</p>
                        <p class="sensor-value">${tempText} C</p>
                    </div>
                </div>
                <div class="sensor-box">
                    <div class="sensor-icon"><i class="fas fa-droplet"></i></div>
                    <div>
                        <p class="sensor-name">Kelembaban</p>
                        <p class="sensor-value">${humText} %</p>
                    </div>
                </div>
            </div>

            ${buildRealtimeChartHtml(subArea.id, state, [
                { key: "temperature", label: "Suhu", unit: "C" },
                { key: "humidity", label: "Kelembapan", unit: "%" },
            ])}

            <div class="control-list">
                <div class="control-row">
                    <div>
                        <p class="control-title">Mode Otomatis Valve</p>
                        <p class="control-sub">Jadwal valve akan berjalan otomatis sesuai jam dan durasi.</p>
                    </div>
                    <label class="switch">
                        <input type="checkbox" data-action="toggle-auto" ${state.autoMode ? "checked" : ""}>
                        <span class="slider"></span>
                    </label>
                </div>

                <div class="control-row" style="${manualControlsStyle}">
                    <div>
                        <p class="control-title">Mode Manual Valve</p>
                        <p class="control-sub">${relayText}</p>
                    </div>
                    <label class="switch">
                        <input type="checkbox" data-action="toggle-manual" ${state.manualMode ? "checked" : ""}>
                        <span class="slider"></span>
                    </label>
                </div>
            </div>

            <div class="relay-controls" style="${manualControlsStyle}opacity:${state.manualMode ? "1" : "0.5"};">
                <button type="button" class="relay-btn ${state.relay[0] ? "active" : ""}" data-action="toggle-relay" data-relay-index="0">Relay 1</button>
                <button type="button" class="relay-btn ${state.relay[1] ? "active" : ""}" data-action="toggle-relay" data-relay-index="1">Relay 2</button>
                <button type="button" class="relay-btn ${state.relay[2] ? "active" : ""}" data-action="toggle-relay" data-relay-index="2">Relay 3</button>
                <button type="button" class="relay-btn trigger-btn" data-action="spray-now">Semprot Manual Sekarang</button>
            </div>

            <div class="duration-control" style="${autoControlsStyle}">
                <div class="control-row">
                    <div>
                        <p class="control-title">Durasi Buka Valve</p>
                        <p class="control-sub">${durationVal} detik</p>
                    </div>
                    <input type="range" min="1" max="600" value="${durationVal}" data-action="change-duration" class="duration-slider">
                </div>
            </div>

            <div class="schedule-wrap">
                <div class="schedule-head">
                    <h4>Jadwal Buka Valve (Auto)</h4>
                    <button type="button" class="btn-add" data-action="add-schedule"><i class="fas fa-plus"></i> Tambah Jam</button>
                </div>
                <div class="schedule-list">${scheduleHtml}</div>
                <button type="button" class="btn-save" data-action="save-schedule"><i class="fas fa-save"></i> Simpan Jadwal</button>
            </div>
        </article>
    `;
}

function buildHydroControlCardHtml(areaId, subArea, state) {
    const status = computeSubAreaOnline(state);
    const phValue = Number.isFinite(state.ph) ? state.ph.toFixed(2) : "-";
    const tdsValue = Number.isFinite(state.tds) ? state.tds.toFixed(0) : "-";
    const phMin = clampThreshold(state.phMin, 0, 14);
    const phMax = clampThreshold(state.phMax, phMin, 14);
    const tdsMin = clampThreshold(state.tdsMin, 0, 3000);
    const tdsMax = clampThreshold(state.tdsMax, tdsMin, 3000);

    return `
        <article class="subarea-card subarea-card-hydro" data-subarea-id="${subArea.id}" data-area-id="${areaId}">
            <div class="subarea-head hydro-subarea-head">
                <div>
                    <h4 class="subarea-name">${subArea.name}</h4>
                    <p class="hydro-device-copy">ATC Smart Hidroponik (${subArea.deviceId})</p>
                </div>
                <span class="status-badge ${status.className}">
                    <span class="status-dot"></span>
                    <span>${status.label}</span>
                </span>
            </div>

            <div class="sensor-grid hydro-sensor-grid">
                <div class="sensor-box sensor-box-hydro">
                    <div class="sensor-icon"><i class="fas fa-vial-circle-check"></i></div>
                    <div>
                        <p class="sensor-name">pH</p>
                        <p class="sensor-value">${phValue}</p>
                    </div>
                </div>
                <div class="sensor-box sensor-box-hydro">
                    <div class="sensor-icon"><i class="fas fa-droplet"></i></div>
                    <div>
                        <p class="sensor-name">TDS</p>
                        <p class="sensor-value">${tdsValue} ppm</p>
                    </div>
                </div>
            </div>

            ${buildRealtimeChartHtml(subArea.id, state, [
                { key: "ph", label: "pH", unit: "pH" },
                { key: "tds", label: "TDS", unit: "ppm" },
            ])}

            <div class="hydro-message-box">
                <span>System message: ${escapeHtml(state.message || "-")}</span>
            </div>

            <div class="control-list hydro-control-list">
                <div class="control-row">
                    <div>
                        <p class="control-title">Mode Otomatis pH/TDS</p>
                        <p class="control-sub">Kontrol akan mengikuti rentang pH dan TDS yang ditetapkan.</p>
                    </div>
                    <label class="switch">
                        <input type="checkbox" data-action="toggle-auto-hydro" ${state.autoPhTds ? "checked" : ""}>
                        <span class="slider"></span>
                    </label>
                </div>

                <div class="control-row">
                    <div>
                        <p class="control-title">Relay Nutrisi</p>
                        <p class="control-sub">${state.relayNutrisi ? "Aktif" : "Nonaktif"}</p>
                    </div>
                    <label class="switch">
                        <input type="checkbox" data-action="toggle-relay-nutrisi" ${state.relayNutrisi ? "checked" : ""}>
                        <span class="slider"></span>
                    </label>
                </div>

                <div class="control-row">
                    <div>
                        <p class="control-title">Relay pH Down</p>
                        <p class="control-sub">${state.relayPhDown ? "Aktif" : "Nonaktif"}</p>
                    </div>
                    <label class="switch">
                        <input type="checkbox" data-action="toggle-relay-phdown" ${state.relayPhDown ? "checked" : ""}>
                        <span class="slider"></span>
                    </label>
                </div>
            </div>

            <div class="hydro-threshold-card">
                <div class="hydro-threshold-head">
                    <h4>Rentang pH / TDS</h4>
                    <p>Atur nilai minimum dan maksimum untuk monitoring dan kontrol otomatis.</p>
                </div>

                <div class="hydro-input-grid">
                    ${buildHydroRangeControlHtml(subArea.id, "ph-min", "pH Min", phMin, 0, 14, 0.1)}
                    ${buildHydroRangeControlHtml(subArea.id, "ph-max", "pH Max", phMax, 0, 14, 0.1)}
                    ${buildHydroRangeControlHtml(subArea.id, "tds-min", "TDS Min", tdsMin, 0, 3000, 10)}
                    ${buildHydroRangeControlHtml(subArea.id, "tds-max", "TDS Max", tdsMax, 0, 3000, 10)}
                </div>
            </div>
        </article>
    `;
}

function buildHydroRangeControlHtml(subAreaId, key, label, value, min, max, step) {
    return `
        <div class="hydro-range-control">
            <div class="hydro-range-head">
                <label class="hydro-range-label" for="${key}-${subAreaId}">${label}</label>
                <input
                    id="${key}-${subAreaId}"
                    class="hydro-number-input"
                    type="number"
                    min="${min}"
                    max="${max}"
                    step="${step}"
                    value="${value}"
                    data-action="change-${key}-input"
                >
            </div>
            <input
                class="hydro-range-slider"
                type="range"
                min="${min}"
                max="${max}"
                step="${step}"
                value="${value}"
                data-action="change-${key}-slider"
            >
        </div>
    `;
}

function buildIrrigationControlCardHtml(areaId, subArea, state) {
    const status = computeSubAreaOnline(state);
    const tempValue = Number.isFinite(state.temperature) ? state.temperature.toFixed(1) : "-";
    const humValue = Number.isFinite(state.humidity) ? state.humidity.toFixed(1) : "-";
    const soilValue = Number.isFinite(state.soilMoisture) ? state.soilMoisture.toFixed(1) : "-";
    const timerPompa = clampThreshold(state.timerPompa, 5, 300);
    const timerSprayer = clampThreshold(state.timerSprayer, 5, 300);

    return `
        <article class="subarea-card subarea-card-irrigation" data-subarea-id="${subArea.id}" data-area-id="${areaId}">
            <div class="subarea-head irrigation-subarea-head">
                <div>
                    <h4 class="subarea-name">${subArea.name}</h4>
                    <p class="irrigation-device-copy">${subArea.name} (${subArea.deviceId})</p>
                </div>
                <span class="status-badge ${status.className}">
                    <span class="status-dot"></span>
                    <span>${status.label}</span>
                </span>
            </div>

            <div class="sensor-grid irrigation-sensor-grid">
                <div class="sensor-box sensor-box-irrigation">
                    <div class="sensor-icon"><i class="fas fa-temperature-high"></i></div>
                    <div>
                        <p class="sensor-name">Suhu</p>
                        <p class="sensor-value">${tempValue} C</p>
                    </div>
                </div>
                <div class="sensor-box sensor-box-irrigation">
                    <div class="sensor-icon"><i class="fas fa-droplet"></i></div>
                    <div>
                        <p class="sensor-name">Kelembapan</p>
                        <p class="sensor-value">${humValue} %</p>
                    </div>
                </div>
                <div class="sensor-box sensor-box-irrigation">
                    <div class="sensor-icon"><i class="fas fa-seedling"></i></div>
                    <div>
                        <p class="sensor-name">Kelembapan Tanah</p>
                        <p class="sensor-value">${soilValue} %</p>
                    </div>
                </div>
            </div>

            ${buildRealtimeChartHtml(subArea.id, state, [
                { key: "temperature", label: "Suhu", unit: "C" },
                { key: "humidity", label: "Kelembapan", unit: "%" },
                { key: "soilMoisture", label: "Kelembapan Tanah", unit: "%" },
            ])}

            <div class="control-list irrigation-control-list">
                <div class="control-row">
                    <div>
                        <p class="control-title">Monitoring Sensor</p>
                        <p class="control-sub">Suhu, kelembapan, dan kelembapan tanah hanya untuk monitoring realtime.</p>
                    </div>
                </div>
            </div>

            ${buildIrrigationScheduleCardHtml(areaId, subArea.id, "pump", "Jadwal Relay Pompa", timerPompa, state.pumpSchedule || [], state.relayPompa, !!state.pumpScheduleDirty, state.pumpRemaining)}
            ${buildIrrigationScheduleCardHtml(areaId, subArea.id, "sprayer", "Jadwal Relay Sprayer", timerSprayer, state.sprayerSchedule || [], state.relaySprayerIrigasi, !!state.sprayerScheduleDirty, state.sprayerRemaining)}
        </article>
    `;
}

function buildIrrigationScheduleCardHtml(areaId, subAreaId, role, label, duration, schedule, relayActive, isDirty, remainingSeconds) {
    const saveLabel = isDirty
        ? '<i class="fas fa-triangle-exclamation"></i> Simpan Jadwal Baru'
        : '<i class="fas fa-check"></i> Jadwal Tersimpan';
    const saveClass = isDirty ? "btn-save btn-save-dirty" : "btn-save btn-save-clean";
    const subLabel = isDirty
        ? "Perubahan belum dikirim ke ESP"
        : (relayActive ? "Sedang aktif" : "Tersimpan di ESP");
    const activeNow = Number.isFinite(remainingSeconds) && Number(remainingSeconds) > 0;
    const timerChipLabel = activeNow ? `Aktif: ${remainingSeconds} dtk` : "Aktif: standby";
    const timerChipClass = activeNow ? "timer-status-chip is-active" : "timer-status-chip";
    return `
        <div class="irrigation-control-card">
            <div class="irrigation-control-head">
                <div>
                    <p class="control-title">${label}</p>
                    <p class="control-sub">${relayActive ? "Sedang aktif" : "Standby"} • ${duration} detik</p>
                </div>
                <span class="${timerChipClass}">${timerChipLabel}</span>
            </div>
            <div class="irrigation-duration-row">
                <p class="irrigation-duration-label">Durasi aktif: ${duration} detik</p>
                <input
                    class="irrigation-number-input"
                    type="number"
                    min="5"
                    max="300"
                    step="1"
                    value="${duration}"
                    data-action="change-irrigation-duration"
                    data-schedule-role="${role}"
                >
            </div>
            <div class="schedule-wrap">
                <div class="schedule-head">
                    <h4>Jam Menyala Harian</h4>
                    <button type="button" class="btn-add" data-action="add-schedule" data-schedule-role="${role}"><i class="fas fa-plus"></i> Tambah Jam</button>
                </div>
                <div class="schedule-list">${buildScheduleRowsHtml(areaId, subAreaId, schedule, role)}</div>
                <button type="button" class="${saveClass}" data-action="save-schedule" data-schedule-role="${role}">${saveLabel}</button>
            </div>
        </div>
    `;
}

function buildEnviroControlCardHtml(areaId, subArea, state) {
    const status = computeSubAreaOnline(state);
    const nh3Text = Number.isFinite(state.nh3) ? state.nh3.toFixed(1) : "-";
    const ch4Text = Number.isFinite(state.ch4) ? state.ch4.toFixed(1) : "-";
    const lowerValue = clampThreshold(state.nh3Lower, 0, 100);
    const upperValue = clampThreshold(state.nh3Upper, lowerValue, 100);

    return `
        <article class="subarea-card subarea-card-enviro" data-subarea-id="${subArea.id}" data-area-id="${areaId}">
            <div class="enviro-hero">
                <div>
                    <p class="detail-code">Monitoring ATC</p>
                    <h4 class="detail-title enviro-detail-title">ATC - Agro Tech Center</h4>
                    <p class="detail-subtitle enviro-detail-subtitle">Enviro Control</p>
                    <div class="hero-pills enviro-pills">
                        <span class="hero-pill">Titik: 1</span>
                        <span class="hero-pill">ESP Monitoring</span>
                        <span class="hero-pill">Realtime MQTT</span>
                    </div>
                </div>
            </div>

            <div class="subarea-head enviro-subarea-head">
                <div>
                    <h4 class="subarea-name">${subArea.name}</h4>
                    <p class="enviro-device-copy">ATC Enviro Control (${subArea.deviceId})</p>
                </div>
                <span class="status-badge ${status.className}">
                    <span class="status-dot"></span>
                    <span>${status.label}</span>
                </span>
            </div>

            <div class="sensor-grid enviro-sensor-grid">
                <div class="sensor-box sensor-box-enviro">
                    <div class="sensor-icon"><i class="fas fa-flask-vial"></i></div>
                    <div>
                        <p class="sensor-name">NH3</p>
                        <p class="sensor-value">${nh3Text} ppm</p>
                    </div>
                </div>
                <div class="sensor-box sensor-box-enviro">
                    <div class="sensor-icon"><i class="fas fa-fire-flame-curved"></i></div>
                    <div>
                        <p class="sensor-name">CH4</p>
                        <p class="sensor-value">${ch4Text} ppm</p>
                    </div>
                </div>
            </div>

            ${buildRealtimeChartHtml(subArea.id, state, [
                { key: "nh3", label: "NH3", unit: "ppm" },
                { key: "ch4", label: "CH4", unit: "ppm" },
            ])}

            <div class="enviro-message-box">
                <span>System message: ${escapeHtml(state.message || "-")}</span>
            </div>

            <div class="control-list enviro-control-list">
                <div class="control-row">
                    <div>
                        <p class="control-title">Mode Otomatis NH3</p>
                        <p class="control-sub">Relay akan mengikuti ambang NH3 lower dan upper.</p>
                    </div>
                    <label class="switch">
                        <input type="checkbox" data-action="toggle-auto-nh3" ${state.autoNh3 ? "checked" : ""}>
                        <span class="slider"></span>
                    </label>
                </div>

                <div class="control-row ${state.autoNh3 ? "enviro-row-disabled" : ""}">
                    <div>
                        <p class="control-title">Relay Manual</p>
                        <p class="control-sub">${state.relayActive ? "Relay ON" : "Relay OFF"}</p>
                    </div>
                    <label class="switch">
                        <input type="checkbox" data-action="toggle-manual-relay" ${state.relayActive ? "checked" : ""} ${state.autoNh3 ? "disabled" : ""}>
                        <span class="slider"></span>
                    </label>
                </div>
            </div>

            <div class="enviro-threshold-card">
                <div class="enviro-threshold-head">
                    <h4>Batas NH3 (Upper: ${upperValue.toFixed(1)} | Lower: ${lowerValue.toFixed(1)})</h4>
                    <p>Atur rentang ambang NH3 untuk kontrol otomatis relay.</p>
                </div>

                <div class="enviro-slider-group">
                    <label class="enviro-slider-label" for="nh3Lower-${subArea.id}">Lower</label>
                    <input id="nh3Lower-${subArea.id}" type="range" min="0" max="100" step="0.5" value="${lowerValue}" data-action="change-nh3-lower">
                </div>

                <div class="enviro-slider-group">
                    <label class="enviro-slider-label" for="nh3Upper-${subArea.id}">Upper</label>
                    <input id="nh3Upper-${subArea.id}" type="range" min="0" max="100" step="0.5" value="${upperValue}" data-action="change-nh3-upper">
                </div>
            </div>

            <div class="enviro-threshold-card">
                <div class="enviro-threshold-head">
                    <h4>Kalibrasi Manual Sensor</h4>
                    <p>Atur nilai kalibrasi R0 untuk MQ135 (Amonia) dan MQ2 (Metana).</p>
                </div>
                <div class="hydro-input-grid">
                    <div class="hydro-range-control">
                        <div class="hydro-range-head">
                            <span class="hydro-range-label">Set Cal Amonia (R0 MQ135)</span>
                            <input
                                class="hydro-number-input"
                                type="number"
                                min="0.0001"
                                max="100000"
                                step="0.0001"
                                value="${Number.isFinite(state.r0Mq135) ? Number(state.r0Mq135).toFixed(4) : "100.0000"}"
                                data-action="edit-r0-mq135"
                            >
                        </div>
                        <button type="button" class="btn-add" data-action="save-r0-mq135">Simpan Cal Amonia</button>
                    </div>
                    <div class="hydro-range-control">
                        <div class="hydro-range-head">
                            <span class="hydro-range-label">Set Cal Metana (R0 MQ2)</span>
                            <input
                                class="hydro-number-input"
                                type="number"
                                min="0.0001"
                                max="100000"
                                step="0.0001"
                                value="${Number.isFinite(state.r0Mq2) ? Number(state.r0Mq2).toFixed(4) : "2.0000"}"
                                data-action="edit-r0-mq2"
                            >
                        </div>
                        <button type="button" class="btn-add" data-action="save-r0-mq2">Simpan Cal Metana</button>
                    </div>
                </div>
            </div>

            <button type="button" class="btn-save btn-calibration ${state.calibrationPending ? "is-pending" : ""}" data-action="start-calibration">
                <i class="fas fa-flask"></i>
                <span>${state.calibrationPending ? "Kalibrasi Diminta" : "Start Kalibrasi"}</span>
            </button>
        </article>
    `;
}

function buildScheduleRowsHtml(areaId, subAreaId, schedule, role = "default") {
    if (!Array.isArray(schedule) || schedule.length === 0) {
        return '<p class="schedule-empty">Belum ada jadwal. Klik Tambah Jam.</p>';
    }

    return schedule.map((timeValue, index) => `
        <div class="schedule-item">
            <input type="time" value="${timeValue}" data-action="edit-time" data-time-index="${index}" data-schedule-role="${role}" data-subarea-id="${subAreaId}" data-area-id="${areaId}">
            <button type="button" class="remove-schedule" data-action="remove-time" data-time-index="${index}" data-schedule-role="${role}" data-subarea-id="${subAreaId}" data-area-id="${areaId}">
                <i class="fas fa-trash"></i>
            </button>
        </div>
    `).join("");
}

function buildRealtimeChartHtml(subAreaId, state, metricOptions) {
    const validMetrics = Array.isArray(metricOptions) ? metricOptions : [];
    if (validMetrics.length === 0) return "";
    const selected = validMetrics.some((item) => item.key === state.chartMetric)
        ? state.chartMetric
        : validMetrics[0].key;
    const selectedMeta = validMetrics.find((item) => item.key === selected) || validMetrics[0];
    const points = getChartPoints(state, selected);

    const chipsHtml = validMetrics.map((item) => `
        <button
            type="button"
            class="chart-chip ${item.key === selected ? "is-active" : ""}"
            data-action="select-chart-metric"
            data-chart-metric="${item.key}"
        >${item.label}</button>
    `).join("");

    const canvasId = `monitorChart-${subAreaId}`;
    const chartBody = `
        <canvas
            id="${canvasId}"
            class="mini-chart-canvas"
            data-subarea-id="${subAreaId}"
            data-chart-metric="${selected}"
        ></canvas>
        <div class="mini-chart-empty" id="${canvasId}-empty"${points.length > 0 ? ' style="display:none;"' : ""}>Belum ada data chart realtime.</div>
    `;

    const latestText = points.length > 0
        ? `${selectedMeta.label} ${points[points.length - 1].v.toFixed(1)} ${selectedMeta.unit}`
        : `${selectedMeta.label} -`;

    const historyText = buildChartHistoryStatusText(state);

    return `
        <div class="monitor-chart-card" data-subarea-id="${subAreaId}">
            <div class="monitor-chart-head">
                <p class="monitor-chart-title">Chart Realtime</p>
                <p class="monitor-chart-sub">120 titik terbaru sesi monitoring</p>
            </div>
            <div class="chart-chip-list">${chipsHtml}</div>
            <div class="mini-chart-wrap">${chartBody}</div>
            <p class="mini-chart-latest">${latestText}</p>
            <p class="mini-chart-history">${historyText}</p>
        </div>
    `;
}

function buildChartHistoryStatusText(state) {
    if (state.historySyncStatus === "error") {
        return `History Influx gagal sinkron${state.historySyncMessage ? `: ${state.historySyncMessage}` : ""}`;
    }
    if (state.historyLastSyncAt) {
        return `History Influx tersinkron ${formatClock(state.historyLastSyncAt)} | Realtime MQTT aktif`;
    }
    if (state.historySyncStatus === "loading") {
        return "Sinkron history Influx...";
    }
    return "History Influx menunggu sinkron awal | Realtime MQTT aktif";
}

function getChartPoints(state, metricKey) {
    const list = state?.chartHistory?.[metricKey];
    if (!Array.isArray(list)) return [];
    return list
        .filter((item) => item && Number.isFinite(Number(item.v)) && Number.isFinite(Number(item.t)))
        .map((item) => ({ t: Number(item.t), v: Number(item.v) }))
        .slice(-chartHistoryLimit);
}

function getMetricOptionsForSubArea(subAreaId) {
    const subArea = getSubAreaById(subAreaId);
    if (!subArea) return [];
    if (subArea.kind === "enviro") {
        return [
            { key: "nh3", label: "NH3", unit: "ppm" },
            { key: "ch4", label: "CH4", unit: "ppm" },
        ];
    }
    if (subArea.kind === "hydro") {
        return [
            { key: "ph", label: "pH", unit: "pH" },
            { key: "tds", label: "TDS", unit: "ppm" },
        ];
    }
    if (subArea.kind === "irrigation") {
        return [
            { key: "temperature", label: "Suhu", unit: "C" },
            { key: "humidity", label: "Kelembapan", unit: "%" },
            { key: "soilMoisture", label: "Kelembapan Tanah", unit: "%" },
        ];
    }
    return [
        { key: "temperature", label: "Suhu", unit: "C" },
        { key: "humidity", label: "Kelembapan", unit: "%" },
    ];
}

function metricColor(metricKey) {
    if (metricKey === "temperature") return "#f59e0b";
    if (metricKey === "humidity") return "#2196f3";
    if (metricKey === "nh3") return "#ef4444";
    if (metricKey === "ch4") return "#f97316";
    if (metricKey === "ph") return "#7c3aed";
    if (metricKey === "tds") return "#14b8a6";
    return "#10b981";
}

function renderRealtimeChartsForArea(areaId) {
    if (!areaId || typeof Chart === "undefined") return;
    const area = areaCatalog[areaId];
    if (!area || !Array.isArray(area.subAreas)) return;
    area.subAreas.forEach((subArea) => {
        renderRealtimeChartForSubArea(subArea.id);
    });
}

function renderRealtimeChartForSubArea(subAreaId) {
    const state = subAreaState[subAreaId];
    if (!state) return;
    const options = getMetricOptionsForSubArea(subAreaId);
    if (options.length === 0) return;
    const selectedKey = options.some((opt) => opt.key === state.chartMetric) ? state.chartMetric : options[0].key;
    const selected = options.find((opt) => opt.key === selectedKey) || options[0];
    const points = getChartPoints(state, selectedKey);
    const canvas = document.getElementById(`monitorChart-${subAreaId}`);
    const emptyEl = document.getElementById(`monitorChart-${subAreaId}-empty`);
    if (!(canvas instanceof HTMLCanvasElement)) return;

    const existed = miniChartInstances[subAreaId];
    if (existed) {
        existed.destroy();
        delete miniChartInstances[subAreaId];
    }

    if (!Array.isArray(points) || points.length === 0) {
        if (emptyEl) emptyEl.style.display = "flex";
        return;
    }
    if (emptyEl) emptyEl.style.display = "none";

    miniChartInstances[subAreaId] = new Chart(canvas, {
        type: "line",
        data: {
            labels: points.map((point) => formatClock(point.t)),
            datasets: [
                {
                    label: `${selected.label} (${selected.unit})`,
                    data: points.map((point) => point.v),
                    borderColor: metricColor(selectedKey),
                    backgroundColor: metricColor(selectedKey),
                    borderWidth: 2,
                    tension: 0.3,
                    pointRadius: 0,
                    fill: false,
                },
            ],
        },
        options: {
            responsive: true,
            maintainAspectRatio: false,
            interaction: { mode: "index", intersect: false },
            plugins: {
                legend: { position: "top" },
                tooltip: {
                    callbacks: {
                        label: (ctx) => `${selected.label}: ${Number(ctx.parsed.y).toFixed(1)} ${selected.unit}`,
                    },
                },
            },
            scales: {
                x: {
                    ticks: { maxTicksLimit: 8 },
                    grid: { color: "rgba(45, 90, 39, 0.08)" },
                },
                y: {
                    beginAtZero: false,
                    grid: { color: "rgba(45, 90, 39, 0.08)" },
                },
            },
        },
    });
}

function computeSubAreaOnline(state) {
    if (!mqttConnected) return { className: "offline", label: "MQTT Offline" };
    if (state.online === true) return { className: "online", label: "Online" };
    if (state.online === false) return { className: "offline", label: "Offline" };
    return { className: "waiting", label: "Menunggu Data" };
}

function computeAreaOnline(area) {
    if (area.underDevelopment) return { className: "waiting", label: "Pengembangan" };
    const states = area.subAreas.map((s) => subAreaState[s.id]);
    if (!mqttConnected) return { className: "offline", label: "MQTT Offline" };
    if (states.some((s) => s.online === true)) return { className: "online", label: "Online" };
    if (states.every((s) => s.online === false)) return { className: "offline", label: "Offline" };
    return { className: "waiting", label: "Menunggu Data" };
}

function updateAccordionOpenState() {
    document.querySelectorAll(".area-accordion").forEach((acc) => {
        acc.classList.toggle("is-open", acc.dataset.areaId === openedAreaId);
    });
}

function openOrCloseArea(areaId) {
    const nextOpened = openedAreaId === areaId ? null : areaId;
    openedAreaId = nextOpened;
    if (nextOpened) {
        const area = getAreaMeta(nextOpened);
        void logMonitoringAction({
            areaId: nextOpened,
            action: "monitoring.area.open",
            description: `Membuka area monitoring ${area?.code || nextOpened} (${area?.name || nextOpened}) di web`,
        });
        void refreshInfluxHistoryForOpenedArea();
    }
    updateAccordionOpenState();
}

function rerenderOpenedArea() {
    persistMonitoringState();
    if (!openedAreaId) return;
    const area = areaCatalog[openedAreaId];
    const container = document.getElementById("selectedAreaContent");
    const legacyBullet = String.fromCharCode(226, 128, 162);
    const doubleLegacyBullet = String.fromCharCode(195, 162) + String.fromCharCode(226, 130, 172) + String.fromCharCode(194, 162);
    if (!area || !container) return;
    container.innerHTML = `<div class="curtain-inner">${buildAreaCurtainHtml(openedAreaId, area)}</div>`;
    container.innerHTML = container.innerHTML.split(legacyBullet).join("-");
    container.innerHTML = container.innerHTML.split(doubleLegacyBullet).join("-");
    // Normalisasi karakter mojibake lama agar teks tetap bersih.
    container.innerHTML = container.innerHTML.replace(/â€¢/g, "•");
    renderRealtimeChartsForArea(openedAreaId);
}

function initMqtt() {
    const cfg = window.BUNCOP_WEB_CONFIG || {};
    if (!cfg.mqttHost) {
        console.warn("MQTT host belum diset pada BUNCOP_WEB_CONFIG.");
        rerenderOpenedArea();
        return;
    }

    BuncopMqtt.configure({
        host: cfg.mqttHost || "",
        port: cfg.mqttPort || 8083,
        path: cfg.mqttWsPath || "/mqtt",
        username: cfg.mqttUsername || "",
        password: cfg.mqttPassword || "",
        useTls: !!cfg.mqttUseTls,
        topicPrefix: cfg.mqttTopicPrefix || "buncop",
    });

    BuncopMqtt.onConnectionChange((connected) => {
        mqttConnected = connected;
        persistMonitoringState();
        rerenderOpenedArea();
    });

    subscribeAllSubAreas();
    BuncopMqtt.connect();
    startInfluxHistoryAutoRefresh();
}

function subscribeAllSubAreas() {
    Object.values(areaCatalog).forEach((area) => {
        area.subAreas.forEach((subArea) => {
            if (!subArea.deviceId) return;

            const statusTopic = BuncopMqtt.topic(subArea.area, subArea.deviceId, "status");
            const telemetryTopic = BuncopMqtt.topic(subArea.area, subArea.deviceId, "telemetry");

            const statusHandler = (payload) => {
                applyRealtimePayload(subArea.id, payload);
                persistMonitoringState();
                rerenderOpenedArea();
            };
            const telemetryHandler = (payload) => {
                applyRealtimePayload(subArea.id, payload);
                persistMonitoringState();
                rerenderOpenedArea();
            };

            BuncopMqtt.subscribe(statusTopic, statusHandler);
            BuncopMqtt.subscribe(telemetryTopic, telemetryHandler);

            mqttSubscriptions[subArea.id] = { statusTopic, telemetryTopic, statusHandler, telemetryHandler };
        });
    });
}

function getSubAreaMeta(subAreaId) {
    for (const area of Object.values(areaCatalog)) {
        const found = area.subAreas.find((item) => item.id === subAreaId);
        if (found) return found;
    }
    return null;
}

function normalizeStateMode(state) {
    if (!state || state.modeProfile === "enviro") return;
    if (state.manualMode) state.autoMode = false;
    if (state.autoMode) state.manualMode = false;
}

function buildCommandPayloadFromState(state) {
    if (state.modeProfile === "enviro") {
        const lower = clampThreshold(state.nh3Lower, 0, 100);
        const upper = clampThreshold(state.nh3Upper, lower, 100);
        const mode = state.autoNh3 ? "auto" : "manual";

        return {
            // ESP_MONITORING_ATC_ENVIRO_MQTT:
            // type=sync_state, value={mode, relay, nh3_upper_limit, nh3_lower_limit}
            type: "sync_state",
            value: {
                mode,
                relay: {
                    relay1: !!state.relayActive,
                },
                nh3_upper_limit: upper,
                nh3_lower_limit: lower,
            },
        };
    }

    if (state.modeProfile === "hydro") {
        const phMin = clampThreshold(state.phMin, 0, 14);
        const phMax = clampThreshold(state.phMax, phMin, 14);
        const tdsMin = clampThreshold(state.tdsMin, 0, 3000);
        const tdsMax = clampThreshold(state.tdsMax, tdsMin, 3000);
        const mode = state.autoPhTds ? "auto" : "manual";

        return {
            // ESP_MONITORING_ATC_SMART_HIDROPONIK_MQTT:
            // type=sync_state, value={mode, relay, pH_min, pH_max, tds_min, tds_max}
            type: "sync_state",
            value: {
                mode,
                relay: {
                    relay_nutrient: !!state.relayNutrisi,
                    relay_ph_down: !!state.relayPhDown,
                },
                pH_min: phMin,
                pH_max: phMax,
                tds_min: tdsMin,
                tds_max: tdsMax,
            }
        };
    }

    if (state.modeProfile === "irrigation") {
        const pumpTimes = sanitizeScheduleTimes(state.pumpSchedule);
        const sprayerTimes = sanitizeScheduleTimes(state.sprayerSchedule);
        return {
            type: "sync_state",
            value: {
                control_mode: "schedule",
                schedule: {
                    pump_times: pumpTimes,
                    sprayer_times: sprayerTimes,
                    pump_duration: clampThreshold(state.timerPompa, 5, 300),
                    sprayer_duration: clampThreshold(state.timerSprayer, 5, 300),
                },
            },
        };
    }

    const schedule = Array.from(new Set(
        (state.schedule || [])
            .map((item) => String(item || "").trim())
            .filter((item) => /^([01]\d|2[0-3]):[0-5]\d$/.test(item))
    )).sort();

    const mode = state.autoMode ? "auto" : "manual";
    const duration = Math.max(1, Math.min(600, Math.round(state.duration || 10)));

    return {
        type: "sync_state",
        value: {
            mode,
            relay: {
                relay1: !!state.relay[0],
                relay2: !!state.relay[1],
                relay3: !!state.relay[2],
            },
            sprayer_times: schedule,
            sprayer_duration: duration,
        }
    };
}

function sanitizeScheduleTimes(list) {
    return Array.from(new Set(
        (Array.isArray(list) ? list : [])
            .map((item) => String(item || "").trim())
            .filter((item) => /^([01]\d|2[0-3]):[0-5]\d$/.test(item))
    )).sort();
}

function setIrrigationScheduleDirty(state, role, dirty) {
    if (role === "pump") {
        state.pumpScheduleDirty = dirty;
    } else {
        state.sprayerScheduleDirty = dirty;
    }
}

function queueStateSync(subAreaId) {
    const state = subAreaState[subAreaId];
    const meta = getSubAreaMeta(subAreaId);
    if (!state || !meta || !mqttConnected) return Promise.resolve(false);

    normalizeStateMode(state);
    const commandPayload = buildCommandPayloadFromState(state);

    const sent = BuncopMqtt.sendCommand(meta.area, meta.deviceId, commandPayload);
    return Promise.resolve(sent);
}

function queueDirectCommand(subAreaId, commandPayload) {
    const meta = getSubAreaMeta(subAreaId);
    if (!meta || !mqttConnected) return Promise.resolve(false);

    // Placeholder:
    // ini tempat command MQTT keluar ke alat IoT.
    // tetap dipisah agar nanti mudah mengganti payload command khusus device enviro.
    const sent = BuncopMqtt.sendCommand(meta.area, meta.deviceId, commandPayload);
    return Promise.resolve(sent);
}

function applyRealtimePayload(subAreaId, payload) {
    const state = subAreaState[subAreaId];
    if (!state) return;
    const meta = getSubAreaById(subAreaId);
    const deviceLabel = meta?.name || subAreaId;

    if (!payload || typeof payload !== "object") {
        state.online = false;
        return;
    }

    state.temperature = pickNumber(payload, [
        "sensor.temperature", "sensor.suhu", "temperature", "suhu", "env.temperature"
    ], state.temperature);
    state.humidity = pickNumber(payload, [
        "sensor.humidity", "sensor.kelembaban", "humidity", "kelembaban", "env.humidity"
    ], state.humidity);

    if (state.modeProfile === "enviro") {
        const prevRelay = !!state.relayActive;
        state.nh3 = pickNumber(payload, [
            "sensor.nh3", "gas.nh3", "nh3", "env.nh3"
        ], state.nh3);
        state.ch4 = pickNumber(payload, [
            "sensor.ch4", "gas.ch4", "ch4", "env.ch4"
        ], state.ch4);
        state.r0Mq135 = pickNumber(payload, [
            "r0_mq135", "sensor.r0_mq135", "calibration.r0_mq135"
        ], state.r0Mq135);
        state.r0Mq2 = pickNumber(payload, [
            "r0_mq2", "sensor.r0_mq2", "calibration.r0_mq2"
        ], state.r0Mq2);
        state.message = pickString(payload, [
            "message", "system_message", "status.message", "env.message"
        ], state.message || "-");

        const upper = pickNumber(payload, [
            "threshold.nh3.upper", "threshold.upper", "nh3_threshold.upper", "upper"
        ], state.nh3Upper);
        const lower = pickNumber(payload, [
            "threshold.nh3.lower", "threshold.lower", "nh3_threshold.lower", "lower"
        ], state.nh3Lower);
        state.nh3Lower = clampThreshold(lower, 0, 100);
        state.nh3Upper = clampThreshold(upper, state.nh3Lower, 100);

        const autoNh3 = pickBool(payload, [
            "auto_nh3", "mode.auto_nh3", "env.auto_nh3", "control.auto_nh3"
        ], null);
        if (autoNh3 !== null) state.autoNh3 = autoNh3;

        const relayState = pickEnviroRelayState(payload);
        if (relayState !== null) state.relayActive = relayState;

        state.relayManual = !state.autoNh3;

        if (relayState !== null && prevRelay !== !!state.relayActive && state.autoNh3) {
            const next = !!state.relayActive;
            if (state.lastRelayLog.enviro !== next && !shouldThrottleRelayLog(state, "enviro")) {
                state.lastRelayLog.enviro = next;
                void logMonitoringAction({
                    subAreaId,
                    action: "monitoring.system.relay.change",
                    description: formatRelayDescription("Enviro", next, "sistem", deviceLabel),
                    metadata: { relay: "enviro", state: next ? "ON" : "OFF", source: "telemetry" },
                });
            }
        }
    } else if (state.modeProfile === "hydro") {
        const prevNutrisi = !!state.relayNutrisi;
        const prevPhDown = !!state.relayPhDown;
        state.ph = pickNumber(payload, [
            "sensor.ph", "water.ph", "ph"
        ], state.ph);
        state.tds = pickNumber(payload, [
            "sensor.tds", "water.tds", "tds"
        ], state.tds);
        state.message = pickString(payload, [
            "message", "system_message", "status.message", "hydro.message"
        ], state.message || "-");

        const autoPhTds = pickBool(payload, [
            "auto_ph_tds", "mode.auto_ph_tds", "hydro.auto_ph_tds"
        ], null);
        if (autoPhTds !== null) state.autoPhTds = autoPhTds;

        const relayNutrisi = pickBool(payload, [
            "relay_nutrisi", "relay.nutrisi", "relay.relay1", "hydro.relay_nutrisi"
        ], null);
        if (relayNutrisi !== null) state.relayNutrisi = relayNutrisi;

        const relayPhDown = pickBool(payload, [
            "relay_ph_down", "relay.ph_down", "relay.relay2", "hydro.relay_ph_down"
        ], null);
        if (relayPhDown !== null) state.relayPhDown = relayPhDown;

        state.phMin = pickNumber(payload, [
            "ph_range.min", "threshold.ph.min", "ph_min"
        ], state.phMin);
        state.phMax = pickNumber(payload, [
            "ph_range.max", "threshold.ph.max", "ph_max"
        ], state.phMax);
        state.tdsMin = pickNumber(payload, [
            "tds_range.min", "threshold.tds.min", "tds_min"
        ], state.tdsMin);
        state.tdsMax = pickNumber(payload, [
            "tds_range.max", "threshold.tds.max", "tds_max"
        ], state.tdsMax);

        state.phMin = clampThreshold(state.phMin, 0, 14);
        state.phMax = clampThreshold(state.phMax, state.phMin, 14);
        state.tdsMin = clampThreshold(state.tdsMin, 0, 3000);
        state.tdsMax = clampThreshold(state.tdsMax, state.tdsMin, 3000);

        if (state.autoPhTds) {
            if (relayNutrisi !== null && prevNutrisi !== !!state.relayNutrisi) {
                const next = !!state.relayNutrisi;
                if (state.lastRelayLog.nutrisi !== next && !shouldThrottleRelayLog(state, "nutrisi")) {
                    state.lastRelayLog.nutrisi = next;
                    void logMonitoringAction({
                        subAreaId,
                        action: "monitoring.system.relay.change",
                        description: formatRelayDescription("Nutrisi", next, "sistem", deviceLabel),
                        metadata: { relay: "nutrisi", state: next ? "ON" : "OFF", source: "telemetry" },
                    });
                }
            }

            if (relayPhDown !== null && prevPhDown !== !!state.relayPhDown) {
                const next = !!state.relayPhDown;
                if (state.lastRelayLog.phdown !== next && !shouldThrottleRelayLog(state, "phdown")) {
                    state.lastRelayLog.phdown = next;
                    void logMonitoringAction({
                        subAreaId,
                        action: "monitoring.system.relay.change",
                        description: formatRelayDescription("pH Down", next, "sistem", deviceLabel),
                        metadata: { relay: "ph_down", state: next ? "ON" : "OFF", source: "telemetry" },
                    });
                }
            }
        }
    } else if (state.modeProfile === "irrigation") {
        const prevPompa = !!state.relayPompa;
        const prevSprayer = !!state.relaySprayerIrigasi;
        state.soilMoisture = pickNumber(payload, [
            "sensor.soil_moisture", "sensor.kelembapan_tanah", "soil_moisture", "kelembapan_tanah"
        ], state.soilMoisture);
        state.message = pickString(payload, [
            "message", "system_message", "status.message", "irigasi.message"
        ], state.message || "-");

        const relayPompa = pickBool(payload, [
            "relay_pompa", "relay.pompa", "relay.relay1", "irigasi.relay_pompa"
        ], null);
        if (relayPompa !== null) state.relayPompa = relayPompa;

        const relaySprayer = pickBool(payload, [
            "relay_sprayer", "relay.sprayer", "relay.relay2", "irigasi.relay_sprayer"
        ], null);
        if (relaySprayer !== null) state.relaySprayerIrigasi = relaySprayer;

        const pumpSchedule = pickSchedule(payload, [
            "schedule.pump_times", "pump_times", "irigasi.pump_times"
        ]);
        if (!state.pumpScheduleDirty && pumpSchedule.length > 0) state.pumpSchedule = pumpSchedule;

        const sprayerSchedule = pickSchedule(payload, [
            "schedule.sprayer_times", "sprayer_times", "irigasi.sprayer_times"
        ]);
        if (!state.sprayerScheduleDirty && sprayerSchedule.length > 0) state.sprayerSchedule = sprayerSchedule;

        if (!state.pumpScheduleDirty) {
            state.timerPompa = pickNumber(payload, [
                "schedule.pump_duration", "pump_duration", "timer_pompa", "timer.pompa"
            ], state.timerPompa);
        }
        if (!state.sprayerScheduleDirty) {
            state.timerSprayer = pickNumber(payload, [
                "schedule.sprayer_duration", "sprayer_duration", "timer_sprayer", "timer.sprayer"
            ], state.timerSprayer);
        }

        state.pumpRemaining = pickNumber(payload, [
            "schedule.pump_remaining", "pump_remaining", "timer.pump_remaining"
        ], state.pumpRemaining);
        state.sprayerRemaining = pickNumber(payload, [
            "schedule.sprayer_remaining", "sprayer_remaining", "timer.sprayer_remaining"
        ], state.sprayerRemaining);

        state.timerPompa = clampThreshold(state.timerPompa, 5, 300);
        state.timerSprayer = clampThreshold(state.timerSprayer, 5, 300);

        if (relayPompa !== null && prevPompa !== !!state.relayPompa) {
            const next = !!state.relayPompa;
            if (state.lastRelayLog.pompa !== next && !shouldThrottleRelayLog(state, "pompa")) {
                state.lastRelayLog.pompa = next;
                void logMonitoringAction({
                    subAreaId,
                    action: "monitoring.system.relay.change",
                    description: formatRelayDescription("Pompa", next, "sistem", deviceLabel),
                    metadata: { relay: "pompa", state: next ? "ON" : "OFF", source: "telemetry" },
                });
            }
        }

        if (relaySprayer !== null && prevSprayer !== !!state.relaySprayerIrigasi) {
            const next = !!state.relaySprayerIrigasi;
            if (state.lastRelayLog.sprayer !== next && !shouldThrottleRelayLog(state, "sprayer")) {
                state.lastRelayLog.sprayer = next;
                void logMonitoringAction({
                    subAreaId,
                    action: "monitoring.system.relay.change",
                    description: formatRelayDescription("Sprayer", next, "sistem", deviceLabel),
                    metadata: { relay: "sprayer", state: next ? "ON" : "OFF", source: "telemetry" },
                });
            }
        }
    } else {
        const autoMode = pickBool(payload, [
            "mode.auto", "mode.auto_valve", "auto_mode", "auto", "sprayer.auto_mode", "valve.auto_mode"
        ], null);
        if (autoMode !== null) state.autoMode = autoMode;

        const manualMode = pickBool(payload, [
            "mode.manual", "mode.manual_valve", "manual_mode", "manual", "sprayer.manual_mode", "valve.manual_mode"
        ], null);
        if (manualMode !== null) state.manualMode = manualMode;

        const modeText = pickValue(payload, [
            "mode", "sprayer.mode", "valve.mode", "manual.mode"
        ]);
        if (typeof modeText === "string") {
            const normalized = modeText.trim().toLowerCase();
            if (normalized === "manual") {
                state.manualMode = true;
                state.autoMode = false;
            } else if (normalized === "auto" || normalized === "otomatis") {
                state.autoMode = true;
                state.manualMode = false;
            }
        }

        const relayValue = pickValue(payload, [
            "relay", "manual.relay", "sprayer.relay", "valve.relay"
        ]);
        const normalizedRelay = normalizeRelay(relayValue, state.relay);
        if (normalizedRelay) state.relay = normalizedRelay;

        const schedule = pickSchedule(payload, [
            "manual.sprayer_times", "schedule", "sprayer_times", "sprayer.schedule", "valve.schedule", "auto_schedule.times"
        ]);
        if (schedule.length > 0) state.schedule = schedule;

        const duration = pickNumber(payload, [
            "manual.sprayer_duration", "sprayer_duration", "valve.duration"
        ], null);
        if (duration !== null) state.duration = Math.max(1, Math.min(600, Math.round(duration)));
    }

    const online = pickBool(payload, [
        "online", "status.online", "connection.online"
    ], null);

    if (online === null) {
        state.online = mqttConnected && (
            Number.isFinite(state.temperature)
            || Number.isFinite(state.humidity)
            || Number.isFinite(state.nh3)
            || Number.isFinite(state.ch4)
            || Number.isFinite(state.ph)
            || Number.isFinite(state.tds)
            || Number.isFinite(state.soilMoisture)
        );
    } else {
        state.online = online;
    }

    rememberChartHistory(state, payload);
    persistMonitoringState();
}

function startInfluxHistoryAutoRefresh() {
    if (influxHistoryTimer) {
        window.clearInterval(influxHistoryTimer);
    }
    influxHistoryTimer = window.setInterval(() => {
        void refreshInfluxHistoryForOpenedArea();
    }, influxHistoryRefreshMs);
}

async function refreshInfluxHistoryForOpenedArea() {
    if (!openedAreaId) return;
    const area = areaCatalog[openedAreaId];
    if (!area || !Array.isArray(area.subAreas)) return;
    const jobs = area.subAreas
        .map((subArea) => subArea?.id)
        .filter((subAreaId) => !!influxHistoryTargets[subAreaId])
        .map((subAreaId) => loadInfluxHistoryForSubArea(subAreaId));
    await Promise.all(jobs);
}

async function loadInfluxHistoryForSubArea(subAreaId) {
    const target = influxHistoryTargets[subAreaId];
    const state = subAreaState[subAreaId];
    const cfg = window.BUNCOP_WEB_CONFIG || {};
    if (!target || !state || !cfg.sensorHistoryUrl) return;
    if (influxHistoryInFlight.has(subAreaId)) return;

    influxHistoryInFlight.add(subAreaId);
    state.historySyncStatus = "loading";
    persistMonitoringState();

    try {
        const rows = await fetchInfluxHistoryRows(cfg.sensorHistoryUrl, target);
        mergeInfluxRowsToChartHistory(state, rows, target.fields);
        state.historyLastSyncAt = Date.now();
        state.historySyncStatus = "ok";
        state.historySyncMessage = "";
        persistMonitoringState();

        if (openedAreaId) {
            const opened = areaCatalog[openedAreaId];
            if (opened && opened.subAreas.some((item) => item.id === subAreaId)) {
                rerenderOpenedArea();
            }
        }
    } catch (error) {
        state.historySyncStatus = "error";
        state.historySyncMessage = error instanceof Error ? error.message : "unknown";
        persistMonitoringState();
        if (openedAreaId) rerenderOpenedArea();
    } finally {
        influxHistoryInFlight.delete(subAreaId);
    }
}

async function fetchInfluxHistoryRows(sensorHistoryUrl, target) {
    const plans = [
        { range: influxHistoryAutoRange, window: influxHistoryAutoWindow },
        { range: "-6h", window: "5m" },
        { range: "-1d", window: "15m" },
        { range: "-7d", window: "1h" },
    ];

    let lastError = null;
    for (const plan of plans) {
        try {
            const query = new URLSearchParams();
            query.set("device_id", target.deviceId);
            query.set("measurement", target.measurement);
            query.set("range", plan.range);
            query.set("window", plan.window);
            query.set("fields", target.fields.join(","));
            query.set("driver", "mongodb");
            query.set("_ts", String(Date.now()));

            const response = await fetch(`${sensorHistoryUrl}?${query.toString()}`, {
                method: "GET",
                credentials: "same-origin",
                cache: "no-store",
                headers: {
                    "Accept": "application/json",
                    "X-Requested-With": "XMLHttpRequest",
                },
            });
            if (!response.ok) {
                throw new Error(`HTTP ${response.status}`);
            }

            const payload = await response.json();
            const rows = Array.isArray(payload?.data) ? payload.data : [];
            if (rows.length > 0) {
                return rows;
            }
        } catch (error) {
            lastError = error;
        }
    }

    if (lastError) {
        throw lastError;
    }
    return [];
}

function mergeInfluxRowsToChartHistory(state, rows, fields) {
    if (!state || !state.chartHistory || !Array.isArray(rows) || !Array.isArray(fields)) return;
    fields.forEach((field) => {
        const metricKey = influxFieldToMetricKey(field);
        const current = Array.isArray(state.chartHistory[metricKey]) ? state.chartHistory[metricKey] : [];
        const mapByTs = new Map(current.map((item) => [Number(item.t), Number(item.v)]));

        rows.forEach((row) => {
            const timestampMs = rowToTimestampMs(row);
            const value = toFiniteNumberOrNull(row?.[field]);
            if (!Number.isFinite(timestampMs) || value === null) return;
            mapByTs.set(timestampMs, value);
        });

        const merged = Array.from(mapByTs.entries())
            .map(([t, v]) => ({ t, v }))
            .sort((a, b) => a.t - b.t)
            .slice(-chartHistoryLimit);

        state.chartHistory[metricKey] = merged;
    });
}

function toFiniteNumberOrNull(value) {
    if (value === null || value === undefined) return null;
    if (typeof value === "string" && value.trim() === "") return null;
    const numeric = Number(value);
    return Number.isFinite(numeric) ? numeric : null;
}

function rowToTimestampMs(row) {
    const ts = Number(row?.timestamp);
    if (Number.isFinite(ts) && ts > 0) {
        return ts > 1000000000000 ? ts : ts * 1000;
    }
    const iso = typeof row?.time === "string" ? Date.parse(row.time) : NaN;
    return Number.isFinite(iso) ? iso : NaN;
}

function influxFieldToMetricKey(field) {
    if (field === "soil_moisture") return "soilMoisture";
    return field;
}

function rememberChartHistory(state, payload) {
    if (!state || !state.chartHistory) return;
    const timestampMs = pickPayloadTimestampMs(payload);
    rememberHistoryPoint(state.chartHistory.temperature, state.temperature, timestampMs);
    rememberHistoryPoint(state.chartHistory.humidity, state.humidity, timestampMs);
    rememberHistoryPoint(state.chartHistory.soilMoisture, state.soilMoisture, timestampMs);
}

function pickPayloadTimestampMs(payload) {
    const raw = pickValue(payload, ["timestamp", "ts", "time", "last_seen", "meta.timestamp"]);
    const numeric = Number(raw);
    if (!Number.isFinite(numeric) || numeric <= 0) return Date.now();
    return numeric > 1000000000000 ? numeric : numeric * 1000;
}

function rememberHistoryPoint(list, value, timestampMs) {
    if (!Array.isArray(list) || !Number.isFinite(Number(value))) return;
    list.push({ t: Number(timestampMs), v: Number(value) });
    if (list.length > chartHistoryLimit) {
        list.splice(0, list.length - chartHistoryLimit);
    }
}

function formatClock(value) {
    const date = new Date(Number(value));
    if (!(date instanceof Date) || Number.isNaN(date.getTime())) return "-";
    const hh = String(date.getHours()).padStart(2, "0");
    const mm = String(date.getMinutes()).padStart(2, "0");
    const ss = String(date.getSeconds()).padStart(2, "0");
    return `${hh}:${mm}:${ss}`;
}

function pickValue(source, paths) {
    for (let i = 0; i < paths.length; i += 1) {
        const value = getByPath(source, paths[i]);
        if (value !== undefined && value !== null) return value;
    }
    return null;
}

function pickNumber(source, paths, fallback) {
    const value = pickValue(source, paths);
    if (value === null || value === undefined || value === "") {
        return fallback;
    }
    if (typeof value === "string" && value.trim() === "") {
        return fallback;
    }
    const num = Number(value);
    return Number.isFinite(num) ? num : fallback;
}

function pickBool(source, paths, fallback) {
    const value = pickValue(source, paths);
    if (typeof value === "boolean") return value;
    if (value === 1 || value === "1" || value === "true" || value === "on") return true;
    if (value === 0 || value === "0" || value === "false" || value === "off") return false;
    return fallback;
}

function pickString(source, paths, fallback) {
    const value = pickValue(source, paths);
    if (typeof value === "string" && value.trim() !== "") return value.trim();
    return fallback;
}

function pickSchedule(source, paths) {
    const value = pickValue(source, paths);
    let items = [];
    if (Array.isArray(value)) {
        items = value;
    } else if (value && typeof value === "object") {
        items = Object.keys(value).sort((a, b) => Number(a) - Number(b)).map((k) => value[k]);
    } else {
        return [];
    }
    return Array.from(new Set(
        items
            .map((item) => String(item || "").trim())
            .filter((item) => /^([01]\d|2[0-3]):[0-5]\d$/.test(item))
    )).sort();
}

function normalizeRelay(raw, fallbackRelay) {
    if (Array.isArray(raw)) {
        return [0, 1, 2].map((idx) => toBoolean(raw[idx]));
    }
    if (raw && typeof raw === "object") {
        return [
            toBoolean(raw.r1 ?? raw.relay1 ?? raw[0]),
            toBoolean(raw.r2 ?? raw.relay2 ?? raw[1]),
            toBoolean(raw.r3 ?? raw.relay3 ?? raw[2])
        ];
    }
    return fallbackRelay || null;
}

function pickEnviroRelayState(payload) {
    const relayValue = pickValue(payload, [
        "relay_state", "relay.manual", "relay.relay1", "relay", "env.relay"
    ]);

    if (typeof relayValue === "boolean") return relayValue;
    if (relayValue === 1 || relayValue === "1" || relayValue === "true" || relayValue === "on") return true;
    if (relayValue === 0 || relayValue === "0" || relayValue === "false" || relayValue === "off") return false;

    if (relayValue && typeof relayValue === "object") {
        return toBoolean(relayValue.relay1 ?? relayValue.r1 ?? relayValue.manual ?? relayValue[0]);
    }

    return null;
}

function toBoolean(value) {
    if (typeof value === "boolean") return value;
    if (value === 1 || value === "1" || value === "true" || value === "on") return true;
    return false;
}

function getByPath(source, path) {
    const keys = String(path).split(".");
    let current = source;
    for (let i = 0; i < keys.length; i += 1) {
        if (current === null || current === undefined) return undefined;
        current = current[keys[i]];
    }
    return current;
}

function bindAreaClicks() {
    document.querySelectorAll(".area-item").forEach((btn) => {
        btn.addEventListener("click", () => {
            openOrCloseArea(btn.dataset.areaId);
        });
    });
}

function bindCurtainActions() {
    const areaList = document.getElementById("selectedAreaContent");
    if (!areaList) return;

    areaList.addEventListener("change", (event) => {
        const target = event.target;
        if (!(target instanceof HTMLInputElement)) return;
        const cardEl = target.closest(".subarea-card");
        if (!cardEl) return;
        const subAreaId = cardEl.dataset.subareaId;
        const state = subAreaState[subAreaId];
        if (!state) return;

        if (target.dataset.action === "toggle-auto") {
            state.autoMode = target.checked;
            if (state.autoMode) {
                state.manualMode = false;
                state.relay = [false, false, false];
            } else {
                state.manualMode = true;
            }
            void logMonitoringAction({
                subAreaId,
                action: "monitoring.web.mode.change",
                description: `Mode otomatis valve ${state.autoMode ? "aktif" : "nonaktif"} pada ${getSubAreaById(subAreaId)?.name || subAreaId}`,
                metadata: { mode: state.autoMode ? "auto" : "manual" },
            });
            rerenderOpenedArea();
            void queueStateSync(subAreaId);
            return;
        }

        if (target.dataset.action === "toggle-manual") {
            state.manualMode = target.checked;
            if (state.manualMode) {
                state.autoMode = false;
            } else {
                state.autoMode = true;
                state.relay = [false, false, false];
            }
            void logMonitoringAction({
                subAreaId,
                action: "monitoring.web.mode.change",
                description: `Mode manual valve ${state.manualMode ? "aktif" : "nonaktif"} pada ${getSubAreaById(subAreaId)?.name || subAreaId}`,
                metadata: { mode: state.manualMode ? "manual" : "auto" },
            });
            rerenderOpenedArea();
            void queueStateSync(subAreaId);
            return;
        }

        if (target.dataset.action === "toggle-auto-nh3") {
            state.autoNh3 = target.checked;
            state.relayManual = !state.autoNh3;
            if (state.autoNh3) {
                state.relayActive = false;
            }
            void logMonitoringAction({
                subAreaId,
                action: "monitoring.web.enviro.mode.change",
                description: `Mode otomatis NH3 ${state.autoNh3 ? "aktif" : "nonaktif"} pada ${getSubAreaById(subAreaId)?.name || subAreaId}`,
                metadata: { auto_nh3: state.autoNh3 },
            });
            rerenderOpenedArea();
            void queueStateSync(subAreaId);
            return;
        }

        if (target.dataset.action === "toggle-manual-relay") {
            if (state.autoNh3) {
                target.checked = !!state.relayActive;
                return;
            }
            state.relayManual = true;
            state.relayActive = target.checked;
            void logMonitoringAction({
                subAreaId,
                action: "monitoring.web.enviro.relay.toggle",
                description: formatRelayDescription("Enviro", state.relayActive, "manual", deviceLabel),
                metadata: { relay_state: state.relayActive },
            });
            rerenderOpenedArea();
            void queueStateSync(subAreaId);
            return;
        }

        if (target.dataset.action === "toggle-auto-hydro") {
            state.autoPhTds = target.checked;
            void logMonitoringAction({
                subAreaId,
                action: "monitoring.web.hydro.mode.change",
                description: `Mode otomatis pH/TDS ${state.autoPhTds ? "aktif" : "nonaktif"} pada ${getSubAreaById(subAreaId)?.name || subAreaId}`,
                metadata: { auto_ph_tds: state.autoPhTds },
            });
            rerenderOpenedArea();
            void queueStateSync(subAreaId);
            return;
        }

        if (target.dataset.action === "toggle-relay-nutrisi") {
            if (state.autoPhTds) {
                state.autoPhTds = false;
            }
            state.relayNutrisi = target.checked;
            void logMonitoringAction({
                subAreaId,
                action: "monitoring.web.hydro.relay_nutrisi.toggle",
                description: formatRelayDescription("Nutrisi", state.relayNutrisi, "manual", deviceLabel),
                metadata: { relay_nutrisi: state.relayNutrisi },
            });
            rerenderOpenedArea();
            void queueStateSync(subAreaId);
            return;
        }

        if (target.dataset.action === "toggle-relay-phdown") {
            if (state.autoPhTds) {
                state.autoPhTds = false;
            }
            state.relayPhDown = target.checked;
            void logMonitoringAction({
                subAreaId,
                action: "monitoring.web.hydro.relay_phdown.toggle",
                description: formatRelayDescription("pH Down", state.relayPhDown, "manual", deviceLabel),
                metadata: { relay_ph_down: state.relayPhDown },
            });
            rerenderOpenedArea();
            void queueStateSync(subAreaId);
            return;
        }

        if (target.dataset.action === "edit-time") {
            const index = Number(target.dataset.timeIndex);
            if (!Number.isFinite(index) || index < 0) return;
            const role = target.dataset.scheduleRole || "sprayer";
            const list = role === "pump" ? state.pumpSchedule : state.sprayerSchedule;
            list[index] = target.value || list[index] || "06:00";
            setIrrigationScheduleDirty(state, role, true);
            persistMonitoringState();
        }

        if (target.dataset.action === "change-irrigation-duration") {
            const role = target.dataset.scheduleRole || "sprayer";
            const val = Math.max(5, Math.min(300, Number(target.value) || 30));
            if (role === "pump") {
                state.timerPompa = val;
            } else {
                state.timerSprayer = val;
            }
            setIrrigationScheduleDirty(state, role, true);
            void logMonitoringAction({
                subAreaId,
                action: "monitoring.web.irrigation.duration.change",
                description: `Durasi ${role} diubah menjadi ${val} detik pada ${getSubAreaById(subAreaId)?.name || subAreaId}`,
                metadata: { role, duration_seconds: val },
            });
            rerenderOpenedArea();
            return;
        }

        if (target.dataset.action === "change-nh3-lower") {
            const val = clampThreshold(Number(target.value) || 0, 0, 100);
            state.nh3Lower = Math.min(val, state.nh3Upper);
            rerenderOpenedArea();
            void queueStateSync(subAreaId);
            return;
        }

        if (target.dataset.action === "change-nh3-upper") {
            const val = clampThreshold(Number(target.value) || 0, 0, 100);
            state.nh3Upper = Math.max(val, state.nh3Lower);
            rerenderOpenedArea();
            void queueStateSync(subAreaId);
            return;
        }

        if (target.dataset.action?.startsWith("change-ph-") || target.dataset.action?.startsWith("change-tds-")) {
            applyHydroBoundChange(state, target.dataset.action, target.value);
            rerenderOpenedArea();
            void queueStateSync(subAreaId);
            return;
        }

        if (target.dataset.action === "edit-r0-mq135") {
            state.r0Mq135 = clampThreshold(Number(target.value) || 100, 0.0001, 100000);
            persistMonitoringState();
            return;
        }

        if (target.dataset.action === "edit-r0-mq2") {
            state.r0Mq2 = clampThreshold(Number(target.value) || 2, 0.0001, 100000);
            persistMonitoringState();
            return;
        }

    });

    areaList.addEventListener("input", (event) => {
        const target = event.target;
        if (!(target instanceof HTMLInputElement)) return;
        const cardEl = target.closest(".subarea-card");
        if (!cardEl) return;
        const subAreaId = cardEl.dataset.subareaId;
        const state = subAreaState[subAreaId];
        if (!state) return;

        if (target.dataset.action === "change-nh3-lower") {
            const val = clampThreshold(Number(target.value) || 0, 0, 100);
            state.nh3Lower = Math.min(val, state.nh3Upper);
            updateEnviroThresholdTitle(target, state);
            return;
        }

        if (target.dataset.action === "change-nh3-upper") {
            const val = clampThreshold(Number(target.value) || 0, 0, 100);
            state.nh3Upper = Math.max(val, state.nh3Lower);
            updateEnviroThresholdTitle(target, state);
            return;
        }

        if (target.dataset.action?.startsWith("change-ph-") || target.dataset.action?.startsWith("change-tds-")) {
            applyHydroBoundChange(state, target.dataset.action, target.value);
            syncHydroControlInputs(cardEl, state);
            return;
        }

    });

    areaList.addEventListener("click", (event) => {
        const target = event.target;
        if (!(target instanceof Element)) return;
        const actionEl = target.closest("[data-action]");
        if (!actionEl) return;

        const cardEl = actionEl.closest(".subarea-card");
        if (!cardEl) return;
        const subAreaId = cardEl.dataset.subareaId;
        const state = subAreaState[subAreaId];
        if (!state) return;

        const action = actionEl.getAttribute("data-action");
        if (action === "select-chart-metric") {
            const metricKey = String(actionEl.getAttribute("data-chart-metric") || "").trim();
            if (!metricKey) return;
            state.chartMetric = metricKey;
            persistMonitoringState();
            rerenderOpenedArea();
            return;
        }

        if (action === "toggle-relay") {
            if (!state.manualMode) return;
            const idx = Number(actionEl.getAttribute("data-relay-index"));
            if (!Number.isFinite(idx) || idx < 0 || idx > 2) return;
            state.relay[idx] = !state.relay[idx];
            void logMonitoringAction({
                subAreaId,
                action: "monitoring.web.relay.toggle",
                description: formatRelayDescription(`Relay ${idx + 1}`, state.relay[idx], "manual", getSubAreaById(subAreaId)?.name || subAreaId),
                metadata: { relay_index: idx + 1, relay_state: state.relay[idx] },
            });
            rerenderOpenedArea();
            void queueStateSync(subAreaId);
            return;
        }

        if (action === "spray-now") {
            if (!state.manualMode) return;
            state.relay = [true, true, true];
            void logMonitoringAction({
                subAreaId,
                action: "monitoring.web.manual.trigger",
                description: `Trigger manual relay pada ${getSubAreaById(subAreaId)?.name || subAreaId}`,
                metadata: { relays: [1, 2, 3] },
            });
            rerenderOpenedArea();
            void queueStateSync(subAreaId);
            window.setTimeout(() => {
                state.relay = [false, false, false];
                rerenderOpenedArea();
                void queueStateSync(subAreaId);
            }, 1500);
            return;
        }

        if (action === "add-schedule") {
            const role = actionEl.getAttribute("data-schedule-role") || "sprayer";
            const list = role === "pump" ? state.pumpSchedule : state.sprayerSchedule;
            list.push("06:00");
            setIrrigationScheduleDirty(state, role, true);
            void logMonitoringAction({
                subAreaId,
                action: "monitoring.web.schedule.add_time",
                description: `Menambah jam jadwal ${role} pada ${getSubAreaById(subAreaId)?.name || subAreaId}`,
                metadata: { role, time: "06:00" },
            });
            rerenderOpenedArea();
            return;
        }

        if (action === "remove-time") {
            const index = Number(actionEl.getAttribute("data-time-index"));
            if (!Number.isFinite(index) || index < 0) return;
            const role = actionEl.getAttribute("data-schedule-role") || "sprayer";
            const list = role === "pump" ? state.pumpSchedule : state.sprayerSchedule;
            const removed = list[index];
            list.splice(index, 1);
            setIrrigationScheduleDirty(state, role, true);
            void logMonitoringAction({
                subAreaId,
                action: "monitoring.web.schedule.remove_time",
                description: `Menghapus jam jadwal ${role} ${removed || "-"} pada ${getSubAreaById(subAreaId)?.name || subAreaId}`,
                metadata: { role, time: removed || null },
            });
            rerenderOpenedArea();
            return;
        }

        if (action === "save-schedule") {
            const role = actionEl.getAttribute("data-schedule-role") || "sprayer";
            const next = sanitizeScheduleTimes(role === "pump" ? state.pumpSchedule : state.sprayerSchedule);
            if (role === "pump") {
                state.pumpSchedule = next;
            } else {
                state.sprayerSchedule = next;
            }
            void logMonitoringAction({
                subAreaId,
                action: "monitoring.web.schedule.save",
                description: `Menyimpan jadwal ${role} pada ${getSubAreaById(subAreaId)?.name || subAreaId}`,
                metadata: {
                    role,
                    times: next,
                    duration_seconds: role === "pump" ? state.timerPompa : state.timerSprayer,
                },
            });
            rerenderOpenedArea();
            queueStateSync(subAreaId).then((ok) => {
                if (ok) {
                    setIrrigationScheduleDirty(state, role, false);
                    rerenderOpenedArea();
                }
                flashActionButton(
                    actionEl,
                    ok,
                    '<i class="fas fa-check"></i> Jadwal Tersimpan',
                    '<i class="fas fa-triangle-exclamation"></i> Gagal Simpan'
                );
            });
            return;
        }

        if (action === "start-calibration") {
            state.calibrationPending = true;
            rerenderOpenedArea();
            queueDirectCommand(subAreaId, {
                type: "start_calibration",
                target: "enviro",
                // Placeholder:
                // ini tempat command MQTT keluar ke alat IoT.
                // ganti isi command sesuai format final dari rekan firmware.
            }).then((ok) => {
                flashActionButton(
                    actionEl,
                    ok,
                    '<i class="fas fa-check"></i> Kalibrasi Diminta',
                    '<i class="fas fa-triangle-exclamation"></i> Gagal Kalibrasi'
                );
                window.setTimeout(() => {
                    state.calibrationPending = false;
                    rerenderOpenedArea();
                }, 1800);
            });
            return;
        }

        if (action === "start-threshold-calibration") {
            state.thresholdCalibrationPending = true;
            rerenderOpenedArea();
            queueStateSync(subAreaId).then((ok) => {
                flashActionButton(
                    actionEl,
                    ok,
                    '<i class="fas fa-check"></i> Kalibrasi Diminta',
                    '<i class="fas fa-triangle-exclamation"></i> Gagal Kalibrasi'
                );
                window.setTimeout(() => {
                    state.thresholdCalibrationPending = false;
                    rerenderOpenedArea();
                }, 1800);
            });
            return;
        }

        if (action === "save-r0-mq135") {
            const value = clampThreshold(Number(state.r0Mq135) || 100, 0.0001, 100000);
            void logMonitoringAction({
                subAreaId,
                action: "monitoring.web.enviro.calibration_r0.update",
                description: `Set Cal Amonia (R0 MQ135) ke ${value.toFixed(4)} pada ${getSubAreaById(subAreaId)?.name || subAreaId}`,
                metadata: { sensor: "mq135", r0_value: value },
            });
            queueDirectCommand(subAreaId, {
                type: "set_config",
                config_key: "r0_mq135",
                value,
            }).then((ok) => {
                flashActionButton(actionEl, ok, "Tersimpan", "Gagal");
            });
            return;
        }

        if (action === "save-r0-mq2") {
            const value = clampThreshold(Number(state.r0Mq2) || 2, 0.0001, 100000);
            void logMonitoringAction({
                subAreaId,
                action: "monitoring.web.enviro.calibration_r0.update",
                description: `Set Cal Metana (R0 MQ2) ke ${value.toFixed(4)} pada ${getSubAreaById(subAreaId)?.name || subAreaId}`,
                metadata: { sensor: "mq2", r0_value: value },
            });
            queueDirectCommand(subAreaId, {
                type: "set_config",
                config_key: "r0_mq2",
                value,
            }).then((ok) => {
                flashActionButton(actionEl, ok, "Tersimpan", "Gagal");
            });
            return;
        }
    });
}

function flashActionButton(button, success, successHtml, errorHtml) {
    if (!(button instanceof HTMLElement)) return;
    const prev = button.innerHTML;
    button.innerHTML = success ? successHtml : errorHtml;
    button.setAttribute("disabled", "disabled");
    window.setTimeout(() => {
        button.innerHTML = prev;
        button.removeAttribute("disabled");
    }, 1200);
}

function updateEnviroThresholdTitle(inputEl, state) {
    const title = inputEl.closest(".enviro-threshold-card")?.querySelector(".enviro-threshold-head h4");
    if (!title) return;
    title.textContent = `Batas NH3 (Upper: ${state.nh3Upper.toFixed(1)} | Lower: ${state.nh3Lower.toFixed(1)})`;
}

function applyHydroBoundChange(state, action, rawValue) {
    const value = Number(rawValue);
    if (!Number.isFinite(value)) return;

    switch (action) {
        case "change-ph-min-input":
        case "change-ph-min-slider":
            state.phMin = clampThreshold(value, 0, 14);
            state.phMax = Math.max(state.phMax, state.phMin);
            break;
        case "change-ph-max-input":
        case "change-ph-max-slider":
            state.phMax = clampThreshold(value, 0, 14);
            state.phMin = Math.min(state.phMin, state.phMax);
            break;
        case "change-tds-min-input":
        case "change-tds-min-slider":
            state.tdsMin = clampThreshold(value, 0, 3000);
            state.tdsMax = Math.max(state.tdsMax, state.tdsMin);
            break;
        case "change-tds-max-input":
        case "change-tds-max-slider":
            state.tdsMax = clampThreshold(value, 0, 3000);
            state.tdsMin = Math.min(state.tdsMin, state.tdsMax);
            break;
        default:
            break;
    }
}

function syncHydroControlInputs(cardEl, state) {
    if (!(cardEl instanceof Element)) return;

    const mappings = [
        ["change-ph-min-input", state.phMin],
        ["change-ph-min-slider", state.phMin],
        ["change-ph-max-input", state.phMax],
        ["change-ph-max-slider", state.phMax],
        ["change-tds-min-input", state.tdsMin],
        ["change-tds-min-slider", state.tdsMin],
        ["change-tds-max-input", state.tdsMax],
        ["change-tds-max-slider", state.tdsMax]
    ];

    mappings.forEach(([action, value]) => {
        const input = cardEl.querySelector(`[data-action="${action}"]`);
        if (input instanceof HTMLInputElement) {
            input.value = String(value);
        }
    });
}

function applyIrrigationBoundChange(state, action, rawValue) {
    const value = Number(rawValue);
    if (!Number.isFinite(value)) return;

    switch (action) {
        case "change-timer-pompa-input":
        case "change-timer-pompa-slider":
            state.timerPompa = clampThreshold(value, 0, 300);
            break;
        case "change-timer-sprayer-input":
        case "change-timer-sprayer-slider":
            state.timerSprayer = clampThreshold(value, 0, 300);
            break;
        case "change-threshold-tanah-input":
        case "change-threshold-tanah-slider":
            state.thresholdTanah = clampThreshold(value, 0, 100);
            break;
        case "change-threshold-udara-input":
        case "change-threshold-udara-slider":
            state.thresholdUdara = clampThreshold(value, 0, 100);
            break;
        default:
            break;
    }
}

function syncIrrigationControlInputs(cardEl, state) {
    if (!(cardEl instanceof Element)) return;

    const mappings = [
        ["change-timer-pompa-input", state.timerPompa],
        ["change-timer-pompa-slider", state.timerPompa],
        ["change-timer-sprayer-input", state.timerSprayer],
        ["change-timer-sprayer-slider", state.timerSprayer],
        ["change-threshold-tanah-input", state.thresholdTanah],
        ["change-threshold-tanah-slider", state.thresholdTanah],
        ["change-threshold-udara-input", state.thresholdUdara],
        ["change-threshold-udara-slider", state.thresholdUdara]
    ];

    mappings.forEach(([action, value]) => {
        const input = cardEl.querySelector(`[data-action="${action}"]`);
        if (input instanceof HTMLInputElement) {
            input.value = String(value);
        }
    });

    const title = cardEl.querySelector(".irrigation-threshold-head h4");
    if (title) {
        title.textContent = `Threshold Otomatis (Tanah ${state.thresholdTanah}% | Udara ${state.thresholdUdara}%)`;
    }
}

function clampThreshold(value, min, max) {
    const numeric = Number(value);
    if (!Number.isFinite(numeric)) return min;
    return Math.min(max, Math.max(min, numeric));
}

function escapeHtml(value) {
    return String(value ?? "")
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;")
        .replace(/'/g, "&#39;");
}

document.addEventListener("DOMContentLoaded", () => {
    buildInitialState();
    openedAreaId = getAreaIdFromQuery();
    bindCurtainActions();
    if (!openedAreaId || !areaCatalog[openedAreaId]) return;
    rerenderOpenedArea();
    const area = getAreaMeta(openedAreaId);
    void logMonitoringAction({
        areaId: openedAreaId,
        action: "monitoring.area.open",
        description: `Membuka area monitoring ${area?.code || openedAreaId} (${area?.name || openedAreaId}) di web`,
    });
    void refreshInfluxHistoryForOpenedArea();
    initMqtt();
});
