import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'dump_format.dart';
import 'rtc_track.dart';

class BitstreamPlayer {
  bool _playing = false;
  bool _paused = false;
  Completer<void>? _pauseCompleter;
  Completer<void>? _playCompleter;
  int? _wallClockStartUs;

  bool get isPlaying => _playing;
  bool get isPaused => _paused;

  Future<void> play(RTCTrack track, String filePath, {double speed = 1.0}) async {
    if (_playing) throw StateError('Already playing');
    _playing = true;
    _paused = false;
    _playCompleter = Completer<void>();

    try {
      final file = await File(filePath).open(mode: FileMode.read);
      try {
        // Read header
        final headerBytes = Uint8List(kDumpHeaderSize);
        await file.readInto(headerBytes);
        DumpHeader.fromBytes(headerBytes); // validate

        final fileLength = await file.length();
        int offset = kDumpHeaderSize;
        _wallClockStartUs = null;

        while (_playing && offset < fileLength) {
          // Check for pause
          if (_paused) {
            _pauseCompleter = Completer<void>();
            await _pauseCompleter!.future;
            // Reset wall clock after resume so pause duration is not counted
            _wallClockStartUs = null;
            if (!_playing) break;
          }

          // Read record header
          final recordHeaderBytes = Uint8List(kDumpRecordHeaderSize);
          await file.setPosition(offset);
          final bytesRead = await file.readInto(recordHeaderBytes);
          if (bytesRead < kDumpRecordHeaderSize) break;

          final data = ByteData.sublistView(recordHeaderBytes);
          final timestampUs = data.getUint64(0, Endian.little);
          final payloadLength = data.getUint32(8, Endian.little);

          // Read payload
          final payload = Uint8List(payloadLength);
          await file.readInto(payload);

          // Wait using absolute wall-clock targeting to avoid drift
          if (speed > 0) {
            final nowUs = DateTime.now().microsecondsSinceEpoch;
            _wallClockStartUs ??= nowUs;
            final targetUs = (timestampUs / speed).round();
            final delayUs = targetUs - (nowUs - _wallClockStartUs!);
            if (delayUs > 0) {
              await Future.delayed(Duration(microseconds: delayUs));
            }
          }

          if (!_playing) break;

          // Send the packet
          await track.send(payload);

          offset += kDumpRecordHeaderSize + payloadLength;
        }
      } finally {
        await file.close();
      }
    } finally {
      _playing = false;
      _paused = false;
      _wallClockStartUs = null;
      _playCompleter?.complete();
      _playCompleter = null;
    }
  }

  void pause() {
    if (_playing && !_paused) {
      _paused = true;
    }
  }

  void resume() {
    if (_playing && _paused) {
      _paused = false;
      _pauseCompleter?.complete();
      _pauseCompleter = null;
    }
  }

  Future<void> stop() async {
    if (!_playing) return;
    _playing = false;
    _paused = false;
    _wallClockStartUs = null;
    _pauseCompleter?.complete();
    _pauseCompleter = null;
    await _playCompleter?.future;
  }
}
