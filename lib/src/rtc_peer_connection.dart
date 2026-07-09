import 'dart:async';

import 'enums.dart';
import 'method_channel.dart';
import 'rtc_configuration.dart';
import 'rtc_ice_candidate.dart';
import 'rtc_session_description.dart';
import 'rtc_track.dart';

class RTCPeerConnection {
  RTCPeerConnection._(this._pcId);

  final int _pcId;
  int get id => _pcId;

  final _channel = LdcMethodChannel.instance;

  StreamSubscription? _eventSub;
  final _onLocalDescription = StreamController<RTCSessionDescription>.broadcast();
  final _onLocalCandidate = StreamController<RTCIceCandidate>.broadcast();
  final _onConnectionStateChange = StreamController<RTCPeerConnectionState>.broadcast();
  final _onIceConnectionStateChange = StreamController<RTCIceConnectionState>.broadcast();
  final _onIceGatheringStateChange = StreamController<RTCIceGatheringState>.broadcast();
  final _onSignalingStateChange = StreamController<RTCSignalingState>.broadcast();
  final _onTrack = StreamController<RTCTrack>.broadcast();
  bool _listening = false;
  bool _closed = false;

  static Future<RTCPeerConnection> create(RTCConfiguration config) async {
    final channel = LdcMethodChannel.instance;
    final pcId = await channel.invoke<int>('createPeerConnection', {
      'iceServers': config.iceServers,
      'disableAutoNegotiation': config.disableAutoNegotiation ? 1 : 0,
    });
    if (pcId == null) throw Exception('Failed to create peer connection');
    final pc = RTCPeerConnection._(pcId);
    pc._startListening();
    return pc;
  }

  void _startListening() {
    if (_listening) return;
    _listening = true;
    _eventSub = _channel.events
        .where((e) => e['pcId'] == _pcId)
        .listen((event) {
      switch (event['event']) {
        case 'onLocalDescription':
          _onLocalDescription.add(RTCSessionDescription(
            sdp: event['sdp'] as String? ?? '',
            type: event['type'] as String? ?? '',
          ));
          break;
        case 'onLocalCandidate':
          _onLocalCandidate.add(RTCIceCandidate(
            candidate: event['candidate'] as String? ?? '',
            sdpMid: event['mid'] as String?,
          ));
          break;
        case 'onStateChange':
          _onConnectionStateChange.add(
              RTCPeerConnectionState.fromString(event['state'] as String? ?? 'new'));
          break;
        case 'onIceStateChange':
          _onIceConnectionStateChange.add(
              RTCIceConnectionState.fromString(event['state'] as String? ?? 'new'));
          break;
        case 'onGatheringStateChange':
          _onIceGatheringStateChange.add(
              RTCIceGatheringState.fromString(event['state'] as String? ?? 'new'));
          break;
        case 'onSignalingStateChange':
          _onSignalingStateChange.add(
              RTCSignalingState.fromString(event['state'] as String? ?? 'stable'));
          break;
        case 'onTrack':
          final trId = event['trId'] as int;
          final mid = event['mid'] as String? ?? '';
          _onTrack.add(RTCTrack.create(trId, mid));
          break;
      }
    });
  }

  Stream<RTCSessionDescription> get onLocalDescription => _onLocalDescription.stream;
  Stream<RTCIceCandidate> get onLocalCandidate => _onLocalCandidate.stream;
  Stream<RTCPeerConnectionState> get onConnectionStateChange => _onConnectionStateChange.stream;
  Stream<RTCIceConnectionState> get onIceConnectionStateChange => _onIceConnectionStateChange.stream;
  Stream<RTCIceGatheringState> get onIceGatheringStateChange => _onIceGatheringStateChange.stream;
  Stream<RTCSignalingState> get onSignalingStateChange => _onSignalingStateChange.stream;
  Stream<RTCTrack> get onTrack => _onTrack.stream;

  Future<RTCSessionDescription> createOffer() async {
    await _channel.invoke('setLocalDescription', {
      'pcId': _pcId,
      'type': 'offer',
    });
    final result = await _channel.invokeMap('getLocalDescription', {'pcId': _pcId});
    if (result == null) throw Exception('Failed to get local description');
    return RTCSessionDescription.fromMap(result);
  }

  Future<RTCSessionDescription> createAnswer() async {
    await _channel.invoke('setLocalDescription', {
      'pcId': _pcId,
      'type': 'answer',
    });
    final result = await _channel.invokeMap('getLocalDescription', {'pcId': _pcId});
    if (result == null) throw Exception('Failed to get local description');
    return RTCSessionDescription.fromMap(result);
  }

  Future<void> setLocalDescription(RTCSessionDescription desc) async {
    await _channel.invoke('setLocalDescription', {
      'pcId': _pcId,
      'type': desc.type,
    });
  }

  Future<void> setRemoteDescription(RTCSessionDescription desc) async {
    await _channel.invoke('setRemoteDescription', {
      'pcId': _pcId,
      'sdp': desc.sdp,
      'type': desc.type,
    });
  }

  Future<void> addIceCandidate(RTCIceCandidate candidate) async {
    await _channel.invoke('addRemoteCandidate', {
      'pcId': _pcId,
      'candidate': candidate.candidate,
      'mid': candidate.sdpMid ?? '',
    });
  }

  /// The selected ICE candidate pair as "local || remote", or null if none is
  /// selected yet. Diagnostic for connectivity issues.
  Future<String?> getSelectedCandidatePair() async {
    final s = await _channel.invoke<String>(
        'getSelectedCandidatePair', {'pcId': _pcId});
    return (s == null || s.isEmpty) ? null : s;
  }

  Future<RTCTrack> addTrack(RTCTrackInit init) async {
    final trId = await _channel.invoke<int>('addTrack', {
      'pcId': _pcId,
      'init': init.toMap(),
    });
    if (trId == null) throw Exception('Failed to add track');
    return RTCTrack.create(trId, init.mid ?? '');
  }

  Future<RTCSessionDescription?> getLocalDescription() async {
    final result = await _channel.invokeMap('getLocalDescription', {'pcId': _pcId});
    if (result == null) return null;
    return RTCSessionDescription.fromMap(result);
  }

  Future<RTCSessionDescription?> getRemoteDescription() async {
    final result = await _channel.invokeMap('getRemoteDescription', {'pcId': _pcId});
    if (result == null) return null;
    return RTCSessionDescription.fromMap(result);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _channel.invoke('closePeerConnection', {'pcId': _pcId});
  }

  Future<void> dispose() async {
    if (!_closed) await close();
    await _eventSub?.cancel();
    await _onLocalDescription.close();
    await _onLocalCandidate.close();
    await _onConnectionStateChange.close();
    await _onIceConnectionStateChange.close();
    await _onIceGatheringStateChange.close();
    await _onSignalingStateChange.close();
    await _onTrack.close();
    await _channel.invoke('deletePeerConnection', {'pcId': _pcId});
  }
}
