import 'dart:async';
import 'dart:typed_data';

import 'method_channel.dart';
import 'enums.dart';

class RTCTrackInit {
  RTCTrackInit({
    required this.direction,
    required this.codec,
    this.payloadType = 96,
    this.ssrc = 0,
    this.mid,
    this.name,
    this.msid,
    this.trackId,
    this.profile,
  });

  final RTCTrackDirection direction;
  final RTCCodec codec;
  final int payloadType;
  final int ssrc;
  final String? mid;
  final String? name;
  final String? msid;
  final String? trackId;
  final String? profile;

  Map<String, dynamic> toMap() => {
        'direction': direction.name,
        'codec': codec.name,
        'payloadType': payloadType,
        'ssrc': ssrc,
        if (mid != null) 'mid': mid,
        if (name != null) 'name': name,
        if (msid != null) 'msid': msid,
        if (trackId != null) 'trackId': trackId,
        if (profile != null) 'profile': profile,
      };
}

class RTCPacketizerInit {
  RTCPacketizerInit({
    this.ssrc = 0,
    this.cname,
    this.payloadType = 96,
    this.clockRate = 90000,
    this.sequenceNumber = 0,
    this.timestamp = 0,
    this.maxFragmentSize = 0,
    this.nalSeparator,
  });

  final int ssrc;
  final String? cname;
  final int payloadType;
  final int clockRate;
  final int sequenceNumber;
  final int timestamp;
  final int maxFragmentSize;
  final String? nalSeparator;

  Map<String, dynamic> toMap() => {
        'ssrc': ssrc,
        if (cname != null) 'cname': cname,
        'payloadType': payloadType,
        'clockRate': clockRate,
        'sequenceNumber': sequenceNumber,
        'timestamp': timestamp,
        'maxFragmentSize': maxFragmentSize,
        if (nalSeparator != null) 'nalSeparator': nalSeparator,
      };
}

class RTCTrack {
  RTCTrack._(this._trId, this._mid);

  final int _trId;
  final String _mid;

  int get id => _trId;
  String get mid => _mid;

  final _channel = LdcMethodChannel.instance;

  StreamSubscription? _eventSub;
  final _onMessage = StreamController<Uint8List>.broadcast();
  final _onOpen = StreamController<void>.broadcast();
  final _onClosed = StreamController<void>.broadcast();
  final _onError = StreamController<String>.broadcast();
  bool _listening = false;
  bool _disposed = false;

  static RTCTrack create(int trId, String mid) {
    final track = RTCTrack._(trId, mid);
    track._startListening();
    return track;
  }

  void _startListening() {
    if (_listening) return;
    _listening = true;
    _eventSub = _channel.events
        .where((e) => e['trId'] == _trId)
        .listen((event) {
      switch (event['event']) {
        case 'onTrackOpen':
          _onOpen.add(null);
          break;
        case 'onTrackClosed':
          _onClosed.add(null);
          break;
        case 'onTrackMessage':
          final data = event['data'];
          if (data is Uint8List) {
            _onMessage.add(data);
          }
          break;
        case 'onTrackError':
          _onError.add(event['error'] as String? ?? 'unknown error');
          break;
      }
    });
  }

  Stream<Uint8List> get onMessage => _onMessage.stream;
  Stream<void> get onOpen => _onOpen.stream;
  Stream<void> get onClosed => _onClosed.stream;
  Stream<String> get onError => _onError.stream;

  Future<void> send(Uint8List rtpData) async {
    await _channel.invoke('sendTrackMessage', {
      'trId': _trId,
      'data': rtpData,
    });
  }

  Future<void> setH264Packetizer(RTCPacketizerInit init) async {
    await _channel.invoke('setH264Packetizer', {
      'trId': _trId,
      'init': init.toMap(),
    });
  }

  Future<void> setOpusPacketizer(RTCPacketizerInit init) async {
    await _channel.invoke('setOpusPacketizer', {
      'trId': _trId,
      'init': init.toMap(),
    });
  }

  Future<void> chainRtcpReceivingSession() async {
    await _channel.invoke('chainRtcpReceivingSession', {'trId': _trId});
  }

  Future<void> chainRtcpSrReporter() async {
    await _channel.invoke('chainRtcpSrReporter', {'trId': _trId});
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _eventSub?.cancel();
    await _onMessage.close();
    await _onOpen.close();
    await _onClosed.close();
    await _onError.close();
    await _channel.invoke('deleteTrack', {'trId': _trId});
  }
}
