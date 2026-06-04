import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import '../config/app_config.dart';

/// Low-level MQTT client wrapper.
/// Manages connection, subscriptions, publish, and reconnection.
class MqttService {
  static MqttService? _instance;
  static MqttService get instance => _instance ??= MqttService._();

  MqttServerClient? _client;
  final _topicControllers = <String, StreamController<String>>{};
  final _statusController = StreamController<MqttConnectionState>.broadcast();
  Timer? _reconnectTimer;
  bool _intentionalDisconnect = false;
  StreamSubscription? _updatesSubscription;

  String get _prefix => AppConfig.mqttTopicPrefix;

  MqttService._();

  Stream<MqttConnectionState> get connectionStream => _statusController.stream;

  bool get isConnected =>
      _client?.connectionStatus?.state == MqttConnectionState.connected;

  /// Build a topic string: buncop/{area}/{deviceId}/{suffix}
  String topic(String area, String deviceId, String suffix) =>
      '$_prefix/$area/$deviceId/$suffix';

  /// Connect to the MQTT broker.
  Future<bool> connect() async {
    if (isConnected) return true;
    _intentionalDisconnect = false;

    final host = AppConfig.mqttHost;
    if (host.isEmpty) {
      debugPrint('[MQTT] Host not configured, skipping connect');
      return false;
    }

    debugPrint('[MQTT] Connecting to $host:${AppConfig.mqttPort} '
        'user=${AppConfig.mqttUsername}');

    final clientId =
        'buncop_app_${DateTime.now().millisecondsSinceEpoch % 100000}';

    _client = MqttServerClient.withPort(host, clientId, AppConfig.mqttPort);
    _client!
      ..logging(on: false)
      ..keepAlivePeriod = 30
      ..connectTimeoutPeriod = 10000 // 10 seconds
      ..autoReconnect = true
      ..onAutoReconnect = _onAutoReconnect
      ..onAutoReconnected = _onAutoReconnected
      ..onConnected = _onConnected
      ..onDisconnected = _onDisconnected;

    final connMsg = MqttConnectMessage()
        .withClientIdentifier(clientId)
        .startClean()
        .authenticateAs(AppConfig.mqttUsername, AppConfig.mqttPassword);

    _client!.connectionMessage = connMsg;

    try {
      await _client!.connect();
    } catch (e) {
      debugPrint('[MQTT] Connection error: $e');
      _client?.disconnect();
      _scheduleReconnect();
      return false;
    }

    if (!isConnected) {
      _scheduleReconnect();
      return false;
    }

    // Listen to the updates stream (cancel old sub if reconnecting)
    _updatesSubscription?.cancel();
    _updatesSubscription = _client!.updates!.listen(_onMessage);
    debugPrint('[MQTT] Updates listener attached, topics registered: ${_topicControllers.keys.toList()}');

    // Re-subscribe registered topics that were added before connection
    for (final topicStr in _topicControllers.keys) {
      _client?.subscribe(topicStr, MqttQos.atLeastOnce);
      debugPrint('[MQTT] Post-connect subscribe: $topicStr');
    }

    return true;
  }

  /// Disconnect cleanly.
  Future<void> disconnect() async {
    _intentionalDisconnect = true;
    _reconnectTimer?.cancel();
    _client?.disconnect();
    _client = null;
  }

  /// Subscribe to a topic and get a stream of raw payload strings.
  Stream<String> subscribe(String topicStr, {MqttQos qos = MqttQos.atLeastOnce}) {
    final isNew = !_topicControllers.containsKey(topicStr);
    if (isNew) {
      _topicControllers[topicStr] = StreamController<String>.broadcast();
    }

    if (isConnected) {
      _client!.subscribe(topicStr, qos);
      debugPrint('[MQTT] subscribe($topicStr) → sent to broker');
    } else {
      debugPrint('[MQTT] subscribe($topicStr) → queued (not connected)');
    }

    return _topicControllers[topicStr]!.stream;
  }

  /// Subscribe and decode JSON messages for a topic.
  Stream<Map<String, dynamic>> subscribeJson(String topicStr,
      {MqttQos qos = MqttQos.atLeastOnce}) {
    return subscribe(topicStr, qos: qos).map((payload) {
      try {
        return Map<String, dynamic>.from(jsonDecode(payload) as Map);
      } catch (_) {
        return <String, dynamic>{};
      }
    });
  }

  /// Publish a JSON message.
  void publishJson(String topicStr, Map<String, dynamic> payload,
      {bool retain = false, MqttQos qos = MqttQos.atLeastOnce}) {
    if (!isConnected) {
      debugPrint('[MQTT] Not connected, cannot publish to $topicStr');
      return;
    }
    final builder = MqttClientPayloadBuilder();
    builder.addString(jsonEncode(payload));
    _client!.publishMessage(topicStr, qos, builder.payload!,
        retain: retain);
  }

  /// Publish a raw string.
  void publishString(String topicStr, String payload,
      {bool retain = false, MqttQos qos = MqttQos.atLeastOnce}) {
    if (!isConnected) return;
    final builder = MqttClientPayloadBuilder();
    builder.addString(payload);
    _client!.publishMessage(topicStr, qos, builder.payload!,
        retain: retain);
  }

  // ── Private handlers ──

  void _onMessage(List<MqttReceivedMessage<MqttMessage?>> messages) {
    for (final msg in messages) {
      final topic = msg.topic;
      final pubMsg = msg.payload as MqttPublishMessage;
      final payload =
          MqttPublishPayload.bytesToStringAsString(pubMsg.payload.message);

      debugPrint('[MQTT] ◀ RECV topic=$topic len=${payload.length}');

      bool dispatched = false;
      final ctrl = _topicControllers[topic];
      if (ctrl != null && !ctrl.isClosed) {
        ctrl.add(payload);
        dispatched = true;
      }

      // Also dispatch to wildcard subscribers
      for (final entry in _topicControllers.entries) {
        if (entry.key == topic) continue; // already handled
        if (_matchesMqttTopic(entry.key, topic) && !entry.value.isClosed) {
          entry.value.add(payload);
          dispatched = true;
        }
      }

      if (!dispatched) {
        debugPrint('[MQTT] ⚠ No handler for topic=$topic, registered=${_topicControllers.keys.toList()}');
      }
    }
  }

  bool _matchesMqttTopic(String pattern, String topic) {
    final patParts = pattern.split('/');
    final topParts = topic.split('/');
    for (var i = 0; i < patParts.length; i++) {
      if (patParts[i] == '#') return true;
      if (i >= topParts.length) return false;
      if (patParts[i] != '+' && patParts[i] != topParts[i]) return false;
    }
    return patParts.length == topParts.length;
  }

  void _onConnected() {
    debugPrint('[MQTT] Connected (callback)');
    _statusController.add(MqttConnectionState.connected);
  }

  void _onDisconnected() {
    debugPrint('[MQTT] Disconnected');
    _statusController.add(MqttConnectionState.disconnected);
    if (!_intentionalDisconnect) {
      _scheduleReconnect();
    }
  }

  void _onAutoReconnect() {
    debugPrint('[MQTT] Auto-reconnecting...');
  }

  void _onAutoReconnected() {
    debugPrint('[MQTT] Auto-reconnected, re-subscribing ${_topicControllers.length} topics');
    _statusController.add(MqttConnectionState.connected);

    // Re-attach updates listener in case it was lost
    _updatesSubscription?.cancel();
    _updatesSubscription = _client?.updates?.listen(_onMessage);

    // Re-subscribe all topics (clean session doesn't preserve subscriptions)
    for (final topicStr in _topicControllers.keys) {
      _client?.subscribe(topicStr, MqttQos.atLeastOnce);
    }
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 5), () {
      if (!isConnected && !_intentionalDisconnect) {
        connect();
      }
    });
  }

  void dispose() {
    _intentionalDisconnect = true;
    _reconnectTimer?.cancel();
    _updatesSubscription?.cancel();
    for (final ctrl in _topicControllers.values) {
      ctrl.close();
    }
    _topicControllers.clear();
    _statusController.close();
    _client?.disconnect();
  }
}
