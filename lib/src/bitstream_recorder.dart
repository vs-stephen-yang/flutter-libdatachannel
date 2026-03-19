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

  bool get isRecording => _file != null;

  Future<void> start(RTCTrack track, String filePath, {DumpCodec codec = DumpCodec.h264}) async {
    if (_file != null) throw StateError('Already recording');

    _file = await File(filePath).open(mode: FileMode.write);
    _startTimeUs = null;
    _writeFuture = Future.value();

    // Write header
    final header = DumpHeader(codec: codec);
    await _file!.writeFrom(header.toBytes());

    _sub = track.onMessage.listen((Uint8List data) {
      _writeRecord(data);
    });
  }

  void _writeRecord(Uint8List payload) {
    if (_file == null) return;

    final nowUs = DateTime.now().microsecondsSinceEpoch;
    _startTimeUs ??= nowUs;
    final relativeUs = nowUs - _startTimeUs!;

    final record = DumpRecord(timestampUs: relativeUs, payload: payload);
    final bytes = record.toBytes();
    _writeFuture = _writeFuture.then((_) => _file?.writeFrom(bytes));
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    await _writeFuture;
    await _file?.flush();
    await _file?.close();
    _file = null;
    _startTimeUs = null;
  }
}
