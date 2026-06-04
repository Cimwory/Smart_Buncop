/**
 * BunCOP MQTT WebSocket Client
 *
 * MQTT over WebSocket client for BunCOP (EMQX).
 * Uses Paho MQTT.js loaded in Blade templates or by paho-loader.js.
 */
const BuncopMqtt = (function () {
    "use strict";

    let client = null;
    let connected = false;
    let reconnectTimer = null;
    let pendingConnectRequested = false;
    const subscriptions = {};
    const retainedCache = {};

    const defaultConfig = {
        host: "",
        port: 8083,
        path: "/mqtt",
        username: "buncop_app_ctrl",
        password: "",
        useTls: false,
        topicPrefix: "buncop",
        clientId: "web_" + Math.random().toString(36).substring(2, 10),
        reconnectDelay: 3000,
    };

    let config = { ...defaultConfig };
    let connectionListeners = [];

    function configure(opts) {
        config = { ...defaultConfig, ...opts };
    }

    function connect() {
        if (client && connected) return;
        if (!config.host) {
            console.warn("[BuncopMqtt] No host configured - skipping connect.");
            return;
        }

        if (!window.Paho || !window.Paho.MQTT || !window.Paho.MQTT.Client) {
            pendingConnectRequested = true;
            connected = false;
            notifyConnectionListeners(false);
            scheduleReconnect();
            return;
        }

        const wsUrl = (config.useTls ? "wss://" : "ws://") +
            config.host + ":" + config.port + config.path;

        pendingConnectRequested = false;
        let pahoClient = null;
        try {
            pahoClient = new window.Paho.MQTT.Client(wsUrl, config.clientId);
        } catch (error) {
            connected = false;
            client = null;
            notifyConnectionListeners(false);
            console.warn("[BuncopMqtt] Gagal membuat MQTT client:", error);
            scheduleReconnect();
            return;
        }
        client = pahoClient;

        client.onConnectionLost = function (responseObject) {
            connected = false;
            client = null;
            notifyConnectionListeners(false);
            if (responseObject.errorCode !== 0) {
                console.warn("[BuncopMqtt] Connection lost:", responseObject.errorMessage);
                scheduleReconnect();
            }
        };

        client.onMessageArrived = function (message) {
            const topic = message.destinationName;
            let payload;
            try {
                payload = JSON.parse(message.payloadString);
            } catch (_) {
                payload = message.payloadString;
            }
            retainedCache[topic] = payload;

            const callbacks = getMatchingCallbacks(topic);
            callbacks.forEach(function (cb) {
                try { cb(payload, topic); } catch (e) { console.error("[BuncopMqtt] Callback error:", e); }
            });
        };

        try {
            client.connect({
                userName: config.username,
                password: config.password,
                useSSL: config.useTls,
                timeout: 10,
                keepAliveInterval: 30,
                cleanSession: true,
                onSuccess: function () {
                    connected = true;
                    notifyConnectionListeners(true);
                    Object.keys(subscriptions).forEach(function (topic) {
                        client.subscribe(topic, { qos: 0 });
                    });
                },
                onFailure: function (err) {
                    connected = false;
                    client = null;
                    notifyConnectionListeners(false);
                    console.warn("[BuncopMqtt] Connect failed:", err.errorMessage);
                    scheduleReconnect();
                },
            });
        } catch (error) {
            connected = false;
            client = null;
            notifyConnectionListeners(false);
            console.warn("[BuncopMqtt] MQTT connect melempar error:", error);
            scheduleReconnect();
        }
    }

    function disconnect() {
        if (reconnectTimer) {
            clearTimeout(reconnectTimer);
            reconnectTimer = null;
        }
        pendingConnectRequested = false;
        if (client && connected) {
            try { client.disconnect(); } catch (_) {}
        }
        connected = false;
        client = null;
    }

    function scheduleReconnect() {
        if (reconnectTimer) return;
        reconnectTimer = setTimeout(function () {
            reconnectTimer = null;
            connect();
        }, config.reconnectDelay);
    }

    function subscribe(topic, callback) {
        if (!subscriptions[topic]) {
            subscriptions[topic] = [];
            if (client && connected) {
                client.subscribe(topic, { qos: 0 });
            }
        }
        subscriptions[topic].push(callback);
    }

    function unsubscribe(topic, callback) {
        if (!subscriptions[topic]) return;
        subscriptions[topic] = subscriptions[topic].filter(function (cb) { return cb !== callback; });
        if (subscriptions[topic].length === 0) {
            delete subscriptions[topic];
            if (client && connected) {
                try { client.unsubscribe(topic); } catch (_) {}
            }
        }
    }

    function publish(topic, payload, retain) {
        if (!client || !connected) {
            console.warn("[BuncopMqtt] Not connected - cannot publish to", topic);
            return false;
        }
        const message = new window.Paho.MQTT.Message(
            typeof payload === "string" ? payload : JSON.stringify(payload)
        );
        message.destinationName = topic;
        message.qos = 1;
        message.retained = !!retain;
        client.send(message);
        return true;
    }

    function topic(area, deviceId, suffix) {
        return config.topicPrefix + "/" + area + "/" + deviceId + "/" + suffix;
    }

    function sendCommand(area, deviceId, commandPayload) {
        const t = topic(area, deviceId, "command");
        commandPayload.source = "web";
        commandPayload.ts = Math.floor(Date.now() / 1000);
        return publish(t, commandPayload, false);
    }

    function onConnectionChange(listener) {
        connectionListeners.push(listener);
    }

    function isConnected() {
        return connected;
    }

    function getCachedValue(topic) {
        return retainedCache[topic] !== undefined ? retainedCache[topic] : null;
    }

    function notifyConnectionListeners(status) {
        connectionListeners.forEach(function (fn) {
            try { fn(status); } catch (_) {}
        });
    }

    function getMatchingCallbacks(topic) {
        const results = [];
        Object.keys(subscriptions).forEach(function (pattern) {
            if (topicMatches(pattern, topic)) {
                subscriptions[pattern].forEach(function (cb) {
                    results.push(cb);
                });
            }
        });
        return results;
    }

    function topicMatches(pattern, topic) {
        if (pattern === topic) return true;
        if (pattern === "#") return true;

        const patternParts = pattern.split("/");
        const topicParts = topic.split("/");

        for (let i = 0; i < patternParts.length; i++) {
            if (patternParts[i] === "#") return true;
            if (patternParts[i] === "+") continue;
            if (i >= topicParts.length || patternParts[i] !== topicParts[i]) return false;
        }

        return patternParts.length === topicParts.length;
    }

    window.addEventListener("buncop:paho-ready", function () {
        if (!config.host) return;
        if (!pendingConnectRequested && (client || connected)) return;
        pendingConnectRequested = false;
        connect();
    });

    window.addEventListener("buncop:paho-error", function () {
        connected = false;
        notifyConnectionListeners(false);
    });

    return {
        configure: configure,
        connect: connect,
        disconnect: disconnect,
        subscribe: subscribe,
        unsubscribe: unsubscribe,
        publish: publish,
        topic: topic,
        sendCommand: sendCommand,
        onConnectionChange: onConnectionChange,
        isConnected: isConnected,
        getCachedValue: getCachedValue,
    };
})();
