import 'dart:convert';

import 'package:flutter/services.dart';

class LdcMethodChannel {
  LdcMethodChannel._();
  static final instance = LdcMethodChannel._();

  final _methodChannel = const MethodChannel('flutter_libdatachannel');
  final _eventChannel = const EventChannel('flutter_libdatachannel/events');

  Stream<Map<String, dynamic>>? _eventStream;

  Stream<Map<String, dynamic>> get events {
    _eventStream ??= _eventChannel.receiveBroadcastStream().map((event) {
      if (event is Map) {
        return Map<String, dynamic>.from(event);
      }
      if (event is String) {
        return Map<String, dynamic>.from(json.decode(event) as Map);
      }
      return <String, dynamic>{};
    });
    return _eventStream!;
  }

  Future<T?> invoke<T>(String method, [Map<String, dynamic>? args]) {
    return _methodChannel.invokeMethod<T>(method, args);
  }

  Future<Map<String, dynamic>?> invokeMap(
      String method, Map<String, dynamic> args) async {
    final result = await _methodChannel.invokeMethod<Map>(method, args);
    if (result == null) return null;
    return Map<String, dynamic>.from(result);
  }
}
