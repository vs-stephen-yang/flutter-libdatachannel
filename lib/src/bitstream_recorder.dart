import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'dump_format.dart';
import 'rtc_track.dart';

class BitstreamRecorder {
  RandomAccessFile? _file;
  StreamSubscription? _sub;
  int? _startTimeUs;
  Future<void> _writeFuture = Future.value();
  bool _writeError = false;

  bool get isRecording => _file != null;

  /// Whether a write error occurred during recording.
  /// Check this after [stop] to detect I/O failures (e.g., disk full).
  bool get hadWriteError => _writeError;

  Future<void> start(RTCTrack track, String filePath, {DumpCodec codec = DumpCodec.h264}) async {
    if (_file != null) throw StateError('Already recording');

    _file = await File(filePath).open(mode: FileMode.write);
    _startTimeUs = null;
    _writeFuture = Future.value();
    _writeError = false;

    // Write header
    final header = DumpHeader(codec: codec);
    await _file!.writeFrom(header.toBytes());

    _sub = track.onMessage.listen((Uint8List data) {
      _writeRecord(data);
    });
  }

  void _writeRecord(Uint8List payload) {
    if (_file == null || _writeError) return;

    final nowUs = DateTime.now().microsecondsSinceEpoch;
    _startTimeUs ??= nowUs;
    final relativeUs = nowUs - _startTimeUs!;

    final record = DumpRecord(timestampUs: relativeUs, payload: payload);
    final bytes = record.toBytes();
    _writeFuture = _writeFuture.then((_) async {
      await _file?.writeFrom(bytes);
    }).catchError((Object e) {
      _writeError = true;
    });
  }

  Future<void> stop() async {
    final sub = _sub;
    _sub = null;
    await sub?.cancel();
    try {
      await _writeFuture;
    } catch (_) {
      _writeError = true;
    }
    try {
      await _file?.flush();
      await _file?.close();
    } catch (_) {
      _writeError = true;
    }
    _file = null;
    _startTimeUs = null;
  }
}
