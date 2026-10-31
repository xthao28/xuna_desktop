import 'dart:convert';
import 'dart:io';

import 'package:xuna_xtp/xuna_xtp.dart';

/// Single Smart Home appliance entity exposed over the local bridge (`UDC-14` S14.4).
class SmartHomeEntity {
  const SmartHomeEntity({
    required this.entityId,
    required this.domain,
    required this.name,
    required this.state,
    this.value,
  });

  final String entityId;
  final String domain;
  final String name;
  final String state;
  final int? value;

  SmartHomeEntity copyWith({
    String? state,
    int? value,
  }) =>
      SmartHomeEntity(
        entityId: entityId,
        domain: domain,
        name: name,
        state: state ?? this.state,
        value: value ?? this.value,
      );

  Map<String, Object?> toWireJson() => <String, Object?>{
        'entityId': entityId,
        'domain': domain,
        'name': name,
        'state': state,
      };
}

/// Local Smart Home Bridge (Home Assistant LAN / Webhook adapter, `UDC-14` S14.4).
///
/// Strictly enforces [allowedSmartHomeDomains] (`light`, `switch`, `fan`,
/// `climate`, `cover`, `media_player`, `scene`) and hard-denies all physical
/// security domains in [hardDeniedSmartHomeDomains] (`lock`,
/// `alarm_control_panel`, `camera`, `garage_door`, `siren`, `UDC-T36`).
/// Local Home Assistant access tokens stay strictly on the host and are never
/// included in tool outputs or logs.
class AutoSmartHomeBridge {
  AutoSmartHomeBridge({
    List<SmartHomeEntity>? seedEntities,
    Future<Map<String, Object?>> Function({
      required String entityId,
      required String domain,
      required String action,
      int? value,
    })? serviceInvoker,
  }) : _serviceInvoker = serviceInvoker {
    if (seedEntities != null) {
      for (final entity in seedEntities) {
        registerEntity(entity);
      }
    }
  }

  final Map<String, SmartHomeEntity> _entities =
      <String, SmartHomeEntity>{};
  final Future<Map<String, Object?>> Function({
    required String entityId,
    required String domain,
    required String action,
    int? value,
  })? _serviceInvoker;

  /// Registers a safe smart-home entity; silently ignores hard-denied security
  /// domains (`lock`, `alarm_control_panel`, `camera`, `garage_door`, `siren`).
  void registerEntity(SmartHomeEntity entity) {
    if (isHardDeniedSmartHomeEntity(entity.entityId) ||
        !isValidSmartHomeEntityId(entity.entityId)) {
      return;
    }
    _entities[entity.entityId] = entity;
  }

  /// Lists allowlisted smart-home entities (`smarthome.list_entities`, `R1`).
  Future<List<SmartHomeEntity>> listEntities({String? domain}) async {
    _loadLocalConfigIfPresent();
    if (domain != null && domain.trim().isNotEmpty) {
      final norm = domain.trim().toLowerCase();
      if (hardDeniedSmartHomeDomains.contains(norm)) {
        throw StateError('smarthome_domain_forbidden');
      }
      return _entities.values
          .where((e) => e.domain == norm)
          .toList(growable: false);
    }
    return _entities.values.toList(growable: false);
  }

  void _loadLocalConfigIfPresent() {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    if (home.isEmpty) return;
    final sep = Platform.pathSeparator;
    final configFile = File('$home$sep.xuna${sep}smarthome.json');
    if (!configFile.existsSync()) return;
    try {
      final raw = jsonDecode(configFile.readAsStringSync());
      if (raw is Map && raw['entities'] is List) {
        for (final item in raw['entities'] as List) {
          if (item is Map) {
            final entityId =
                (item['entityId'] as String?)?.trim().toLowerCase() ?? '';
            final name = (item['name'] as String?)?.trim() ?? entityId;
            final state = (item['state'] as String?)?.trim() ?? 'off';
            if (isValidSmartHomeEntityId(entityId)) {
              final domain = entityId.split('.').first;
              _entities.putIfAbsent(
                entityId,
                () => SmartHomeEntity(
                  entityId: entityId,
                  domain: domain,
                  name: name,
                  state: state,
                ),
              );
            }
          }
        }
      }
    } catch (_) {}
  }

  /// Controls a smart-home appliance (`smarthome.control`, `R2`, `UDC-14` S14.4).
  /// Refuses any `lock.*`, `alarm_control_panel.*`, `camera.*`, or `garage_door.*`
  /// entity with `StateError('smarthome_domain_forbidden')` (`UDC-T36`).
  Future<
      ({
        SmartHomeEntity entity,
        String previousState,
        int? previousValue,
        String inverseAction,
      })> controlEntity({
    required String entityId,
    required String action,
    int? value,
  }) async {
    final normId = entityId.trim().toLowerCase();
    if (isHardDeniedSmartHomeEntity(normId)) {
      throw StateError('smarthome_domain_forbidden');
    }
    if (!isValidSmartHomeEntityId(normId)) {
      throw ArgumentError.value(
        entityId,
        'entityId',
        'Invalid or unsupported smart-home entityId',
      );
    }
    if (!allowedSmartHomeActions.contains(action)) {
      throw ArgumentError.value(
        action,
        'action',
        'Unsupported smart-home action',
      );
    }
    _loadLocalConfigIfPresent();
    final domain = normId.split('.').first;
    final current = _entities[normId] ??
        SmartHomeEntity(
          entityId: normId,
          domain: domain,
          name: normId,
          state: 'off',
        );

    if (_serviceInvoker != null) {
      await _serviceInvoker(
        entityId: normId,
        domain: domain,
        action: action,
        value: value,
      );
    }

    final prevState = current.state;
    final prevValue = current.value;
    String nextState = current.state;
    int? nextValue = current.value;
    String inverseAction = 'toggle';

    switch (action) {
      case 'turn_on':
        nextState = 'on';
        inverseAction = 'turn_off';
      case 'turn_off':
        nextState = 'off';
        inverseAction = 'turn_on';
      case 'toggle':
        nextState = current.state == 'on' ? 'off' : 'on';
        inverseAction = 'toggle';
      case 'set_brightness':
        nextState = (value ?? 50) > 0 ? 'on' : 'off';
        nextValue = (value ?? 50).clamp(0, 100);
        inverseAction = prevValue != null ? 'set_brightness' : 'turn_off';
      case 'set_temperature':
        nextState = 'cool';
        nextValue = (value ?? 25).clamp(16, 30);
        inverseAction = prevValue != null ? 'set_temperature' : 'turn_off';
      case 'activate_scene':
        nextState = 'active';
        inverseAction = 'turn_off';
    }

    final updated = current.copyWith(state: nextState, value: nextValue);
    _entities[normId] = updated;
    return (
      entity: updated,
      previousState: prevState,
      previousValue: prevValue,
      inverseAction: inverseAction,
    );
  }
}
