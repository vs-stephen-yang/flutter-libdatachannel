import 'dart:async';

import 'dump_format.dart';
import 'method_channel.dart';
import 'rtc_track.dart';

class BitstreamRecorder {
  final _channel = LdcMethodChannel.instance;
  bool _recording = false;
  bool _hadError = false;
  int? _trId;
  StreamSubscription? _errorSub;

  bool get isRecording => _recording;

  /// Whether a write error occurred during recording.
  /// Check this after [stop] to detect I/O failures (e.g., disk full).
  bool get hadError => _hadError;

  Future<void> start(RTCTrack track, String filePath,
      {DumpCodec codec = DumpCodec.h264}) async {
    if (_recording) throw StateError('Already recording');
    _trId = track.id;
    _hadError = false;

    _errorSub = _channel.events
        .where((e) =>
            e['event'] == 'onRecordingError' && e['trId'] == track.id)
        .listen((_) {
      _recording = false;
      _hadError = true;
      _errorSub?.cancel();
      _errorSub = null;
    });

    await _channel.invoke('startRecording', {
      'trId': track.id,
      'filePath': filePath,
      'codec': codec.value,
    });
    _recording = true;
  }

  Future<void> stop() async {
    _errorSub?.cancel();
    _errorSub = null;
    if (!_recording) return;
    await _channel.invoke('stopRecording', {
      'trId': _trId,
    });
    _recording = false;
    _trId = null;
  }
}
