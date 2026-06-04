/**
 * Paho MQTT loader with CDN fallbacks.
 */
(function () {
    "use strict";

    const sources = [
        "/js/paho-mqtt.min.js",
        "https://cdnjs.cloudflare.com/ajax/libs/paho-mqtt/1.1.0/paho-mqtt.min.js",
        "https://cdn.jsdelivr.net/npm/paho-mqtt@1.1.0/paho-mqtt.min.js",
        "https://unpkg.com/paho-mqtt@1.1.0/paho-mqtt.min.js",
    ];

    function resolvePahoGlobal() {
        const candidates = [
            window.Paho,
            globalThis.Paho,
            typeof self !== "undefined" ? self.Paho : undefined,
            typeof exports !== "undefined" ? exports : undefined,
            typeof module !== "undefined" ? module.exports : undefined,
            window.exports,
            window.module && window.module.exports,
        ];

        for (const candidate of candidates) {
            if (candidate && typeof candidate === "object") {
                if (candidate.MQTT && candidate.MQTT.Client) {
                    window.Paho = candidate;
                    return window.Paho;
                }
                if (candidate.Client) {
                    window.Paho = { MQTT: candidate };
                    return window.Paho;
                }
            }
        }

        return null;
    }

    function isReady() {
        return !!resolvePahoGlobal();
    }

    function notify(name) {
        window.dispatchEvent(new CustomEvent(name));
    }

    function loadSequentially(index) {
        if (isReady()) {
            notify("buncop:paho-ready");
            return;
        }

        if (index >= sources.length) {
            console.error("[BuncopMqtt] Gagal memuat library Paho MQTT dari semua sumber.");
            notify("buncop:paho-error");
            return;
        }

        const src = sources[index];
        const script = document.createElement("script");
        script.src = src;
        script.async = false;

        script.onload = function () {
            const paho = resolvePahoGlobal();
            if (paho && paho.MQTT && paho.MQTT.Client) {
                notify("buncop:paho-ready");
            } else {
                console.warn("[BuncopMqtt] Library termuat tetapi Paho MQTT tidak tersedia:", src);
                loadSequentially(index + 1);
            }
        };

        script.onerror = function () {
            console.warn("[BuncopMqtt] Gagal memuat library MQTT:", src);
            loadSequentially(index + 1);
        };

        document.head.appendChild(script);
    }

    if (isReady()) {
        notify("buncop:paho-ready");
    } else {
        loadSequentially(0);
    }
})();
