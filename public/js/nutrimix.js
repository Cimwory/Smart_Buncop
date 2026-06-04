const webConfig = window.BUNCOP_WEB_CONFIG || {};
const firebaseConfig = {
    apiKey: webConfig.firebaseApiKey || "",
    databaseURL: webConfig.firebaseDatabaseUrl || "",
};

if (!firebaseConfig.apiKey || !firebaseConfig.databaseURL) {
    throw new Error("Firebase config belum diset. Periksa BUNCOP_WEB_CONFIG pada blade.");
}

if (!firebase.apps.length) {
    firebase.initializeApp(firebaseConfig);
}

const db = firebase.database();
const NUTRIMIX_DEVICE_ID = webConfig.nutrimixDeviceId || "";
if (!NUTRIMIX_DEVICE_ID) {
    throw new Error("nutrimixDeviceId belum diset pada BUNCOP_WEB_CONFIG.");
}
const DEVICE_PATH = `/device/${NUTRIMIX_DEVICE_ID}`;
const COMMAND_PATH = `${DEVICE_PATH}/command`;

const cached = {
    weight: 0,
    target: null,
};

document.addEventListener("DOMContentLoaded", () => {
    initMqttListeners();
    initControls();
    setInterval(refreshDeviceStatus, 5000);
    refreshDeviceStatus();
});

function initMqttListeners() {
    BuncopMqtt.onConnectionChange((connected) => {
        isMqttConnected = connected;
        updateMqttStatus();
        refreshDeviceStatus();
    });

    const telemetryTopic = BuncopMqtt.topic("nutrimix", NUTRIMIX_DEVICE_ID, "telemetry");
    const statusTopic = BuncopMqtt.topic("nutrimix", NUTRIMIX_DEVICE_ID, "status");

    BuncopMqtt.subscribe(telemetryTopic, (payload) => {
        if (payload.weight_g !== undefined) {
            cached.weight = Number(payload.weight_g) || 0;
            updateWeightUI();
        }
    });

    BuncopMqtt.subscribe(statusTopic, (payload) => {
        if (payload.last_seen !== undefined) {
            lastSeenTimestamp = payload.last_seen;
            updateLastSeenUI();
            refreshDeviceStatus();
        }

        if (payload.weight_g !== undefined) {
            cached.weight = Number(payload.weight_g) || 0;
            updateWeightUI();
        }

        if (payload.target_g !== undefined) {
            cached.target = payload.target_g === null ? null : Number(payload.target_g);
            updateTargetUI();
        }

        if (payload.state !== undefined || payload.process_state !== undefined) {
            updateProcessState(payload.state || payload.process_state);
        }

        if (payload.mode !== undefined) {
            updateModeUI(payload.mode);
        }

        if (payload.screw !== undefined) {
            updateToggleUI("screw", normalizeBool(payload.screw));
        }
        if (payload.relay && payload.relay.screw !== undefined) {
            updateToggleUI("screw", normalizeBool(payload.relay.screw));
        }

        if (payload.trimmer !== undefined) {
            updateToggleUI("trimmer", normalizeBool(payload.trimmer));
        }
        if (payload.relay && payload.relay.trimmer !== undefined) {
            updateToggleUI("trimmer", normalizeBool(payload.relay.trimmer));
        }

        if (payload.servo !== undefined) {
            updateServoUI(payload.servo);
        }

        if (payload.hx711_ready !== undefined || payload.hx_ready !== undefined) {
            const hxStatus = document.getElementById("hxStatus");
            if (hxStatus) {
                const isReady = normalizeBool(payload.hx711_ready ?? payload.hx_ready);
                hxStatus.textContent = isReady ? "READY" : "NOT READY";
                hxStatus.style.color = isReady ? "#2e7d32" : "#dc2626";
            }
        }

        if (payload.error !== undefined) {
            const errorEl = document.getElementById("errorStatus");
            if (errorEl) errorEl.textContent = payload.error ? String(payload.error) : "-";
        }

        if (payload.trimmer_duration_s !== undefined || payload.trimmer_duration !== undefined) {
            const el = document.getElementById("trimmerDuration");
            if (el) {
                const v = payload.trimmer_duration_s ?? payload.trimmer_duration;
                el.textContent = (v === null || v === undefined || v === "") ? "--" : `${v} s`;
            }
        }

        if (payload.eta !== undefined || payload.eta_ts !== undefined) {
            const el = document.getElementById("etaValue");
            if (el) {
                const v = payload.eta ?? payload.eta_ts;
                if (!v) { el.textContent = "--"; }
                else if (typeof v === "number") { el.textContent = new Date(v).toLocaleTimeString("id-ID"); }
                else { el.textContent = String(v); }
            }
        }

        if (payload.online !== undefined) {
            refreshDeviceStatus();
        }
    });

    BuncopMqtt.connect();
}

function sendCommand(type, value) {
    const sent = BuncopMqtt.sendCommand("nutrimix", NUTRIMIX_DEVICE_ID, { type, value });
    if (!sent) {
        showToast("Gagal mengirim perintah", "error");
    }
}

function initControls() {
    const startBtn = document.getElementById("startAuto");
    const stopBtn = document.getElementById("stopAuto");
    const targetInput = document.getElementById("targetWeight");

    if (startBtn) {
        startBtn.addEventListener("click", () => {
            const targetValue = Number(targetInput?.value || 0);
            if (!targetValue || targetValue <= 0) {
                showToast("Masukkan target berat yang valid", "warning");
                return;
            }
            sendCommand("start_auto", { target_g: targetValue });
            showToast("Perintah auto dikirim", "success");
        });
    }

    if (stopBtn) {
        stopBtn.addEventListener("click", () => {
            sendCommand("stop", true);
            showToast("Perintah stop dikirim", "warning");
        });
    }

    const screwToggle = document.getElementById("screwToggle");
    if (screwToggle) {
        screwToggle.addEventListener("change", () => {
            sendCommand("manual_screw", screwToggle.checked);
        });
    }

    const trimmerToggle = document.getElementById("trimmerToggle");
    if (trimmerToggle) {
        trimmerToggle.addEventListener("change", () => {
            sendCommand("manual_trimmer", trimmerToggle.checked);
        });
    }

    const servoOpen = document.getElementById("servoOpen");
    if (servoOpen) {
        servoOpen.addEventListener("click", () => {
            sendCommand("manual_servo", "open");
            showToast("Perintah servo buka dikirim", "success");
        });
    }

    const servoClose = document.getElementById("servoClose");
    if (servoClose) {
        servoClose.addEventListener("click", () => {
            sendCommand("manual_servo", "close");
            showToast("Perintah servo tutup dikirim", "success");
        });
    }
}

function normalizeBool(value) {
    if (typeof value === "boolean") {
        return value;
    }

    if (typeof value === "number") {
        return value === 1;
    }

    if (typeof value === "string") {
        const lower = value.toLowerCase();
        return lower === "1" || lower === "on" || lower === "true" || lower === "open";
    }

    return false;
}

function updateWeightUI() {
    const currentWeight = document.getElementById("currentWeight");
    const weightValue = document.getElementById("weightValue");

    if (currentWeight) {
        currentWeight.textContent = `${cached.weight.toFixed(1)} g`;
    }

    if (weightValue) {
        weightValue.textContent = `${cached.weight.toFixed(1)} g`;
    }

    updateProgress();
}

function updateTargetUI() {
    const activeTarget = document.getElementById("activeTarget");
    const targetValue = document.getElementById("targetValue");

    if (activeTarget) {
        activeTarget.textContent = cached.target ? `${cached.target} g` : "--";
    }

    if (targetValue) {
        targetValue.textContent = cached.target ? `${cached.target} g` : "--";
    }

    updateProgress();
}

function updateProgress() {
    const progressFill = document.getElementById("progressFill");
    const progressLabel = document.getElementById("progressLabel");

    if (!progressFill || !progressLabel) return;

    if (!cached.target || cached.target <= 0) {
        progressFill.style.width = "0%";
        progressLabel.textContent = "0%";
        return;
    }

    const ratio = Math.min(cached.weight / cached.target, 1);
    const percentage = Math.round(ratio * 100);
    progressFill.style.width = `${percentage}%`;
    progressLabel.textContent = `${percentage}%`;
}

function updateProcessState(value) {
    const stateEl = document.getElementById("processState");
    if (!stateEl) return;
    stateEl.textContent = value ? String(value) : "Idle";
}

function updateModeUI(value) {
    const modeEl = document.getElementById("deviceMode");
    if (!modeEl) return;
    modeEl.textContent = value ? String(value) : "Auto";
}

function updateToggleUI(type, enabled) {
    const statusEl = document.getElementById(`${type}Status`);
    const stateEl = document.getElementById(`${type}State`);
    const toggleEl = document.getElementById(`${type}Toggle`);

    if (statusEl) {
        statusEl.textContent = enabled ? "ON" : "OFF";
        statusEl.style.color = enabled ? "#2e7d32" : "#dc2626";
    }

    if (stateEl) {
        stateEl.textContent = enabled ? "ON" : "OFF";
    }

    if (toggleEl) {
        toggleEl.checked = enabled;
    }
}

function updateServoUI(value) {
    const servoStatus = document.getElementById("servoStatus");
    const servoState = document.getElementById("servoState");

    const normalized = normalizeBool(value);
    const display = typeof value === "string" ? value.toUpperCase() : normalized ? "OPEN" : "CLOSE";

    if (servoStatus) {
        servoStatus.textContent = display;
    }

    if (servoState) {
        servoState.textContent = display;
    }
}

function refreshDeviceStatus() {
    const now = Math.floor(Date.now() / 1000);
    const isDeviceOnline = lastSeenTimestamp > 0 && now - lastSeenTimestamp <= 30;

    updateWifiStatus(isDeviceOnline);
    updateConnectionBadge(isMqttConnected, isDeviceOnline);
}

function updateMqttStatus() {
    const mqttStatus = document.getElementById("mqttStatus");
    if (!mqttStatus) {
        return;
    }

    mqttStatus.textContent = isMqttConnected ? "Terhubung" : "Terputus";
    mqttStatus.style.color = isMqttConnected ? "#2e7d32" : "#dc2626";
}

function updateWifiStatus(isOnline) {
    const wifiStatus = document.getElementById("wifiStatus");
    if (!wifiStatus) {
        return;
    }

    wifiStatus.textContent = isOnline ? "Online" : "Offline";
    wifiStatus.style.color = isOnline ? "#2e7d32" : "#dc2626";
}

function updateLastSeenUI() {
    const lastSeenEl = document.getElementById("lastSeen");
    if (!lastSeenEl) {
        return;
    }

    if (!lastSeenTimestamp) {
        lastSeenEl.textContent = "--";
        return;
    }

    const localDate = new Date(lastSeenTimestamp * 1000);
    lastSeenEl.textContent = localDate.toLocaleString("id-ID");
}

function updateConnectionBadge(mqttOnline, deviceOnline) {
    const badge = document.getElementById("connectionBadge");
    if (!badge) {
        return;
    }

    if (!mqttOnline) {
        badge.textContent = "MQTT Offline";
        badge.style.backgroundColor = "#dc2626";
        return;
    }

    if (!deviceOnline) {
        badge.textContent = "Perangkat Offline";
        badge.style.backgroundColor = "#f59e0b";
        return;
    }

    badge.textContent = "Terhubung";
    badge.style.backgroundColor = "rgba(255, 255, 255, 0.3)";
}

function showToast(message, type = "info") {
    const existing = document.querySelector(".nutrimix-toast");
    if (existing) {
        existing.remove();
    }

    const toast = document.createElement("div");
    toast.className = `nutrimix-toast ${type}`;
    toast.textContent = message;

    document.body.appendChild(toast);

    setTimeout(() => {
        toast.remove();
    }, 2500);
}


