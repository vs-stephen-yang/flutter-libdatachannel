import 'dart:async';

import 'dump_format.dart';
import 'method_channel.dart';
import 'rtc_track.dart';

class BitstreamRecorder {
  final _channel = LdcMethodChannel.instance;
  bool _recording = false;
  int? _trId;

  bool get isRecording => _recording;

  Future<void> start(RTCTrack track, String filePath,
      {DumpCodec codec = DumpCodec.h264}) async {
    if (_recording) throw StateError('Already recording');
    _trId = track.id;
    await _channel.invoke('startRecording', {
      'trId': track.id,
      'filePath': filePath,
      'codec': codec.value,
    });
    _recording = true;
  }

  Future<void> stop() async {
    if (!_recording) return;
    await _channel.invoke('stopRecording', {
      'trId': _trId,
    });
    _recording = false;
    _trId = null;
  }
}
