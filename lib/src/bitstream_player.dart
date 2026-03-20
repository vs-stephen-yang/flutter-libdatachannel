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

  Future<void> play(RTCTrack track, String filePath,
      {double speed = 1.0}) async {
    if (_playing) throw StateError('Already playing');
    _playing = true;
    _paused = false;
    _playCompleter = Completer<void>();

    try {
      // Load entire file into memory for fast access.
      final bytes = await File(filePath).readAsBytes();
      final data = ByteData.sublistView(bytes);
      DumpHeader.fromBytes(Uint8List.sublistView(bytes, 0, kDumpHeaderSize));

      // Parse all records and detect primary PT in one pass.
      final records = <_DumpRecord>[];
      final ptCounts = <int, int>{};
      int offset = kDumpHeaderSize;
      while (offset + kDumpRecordHeaderSize <= bytes.length) {
        final timestampUs = data.getUint64(offset, Endian.little);
        final payloadLength = data.getUint32(offset + 8, Endian.little);
        offset += kDumpRecordHeaderSize;
        if (offset + payloadLength > bytes.length) break;
        final rtpPacket = Uint8List.sublistView(bytes, offset, offset + payloadLength);
        offset += payloadLength;
        if (rtpPacket.length < 12) continue;
        final pt = rtpPacket[1] & 0x7F;
        ptCounts[pt] = (ptCounts[pt] ?? 0) + 1;
        records.add(_DumpRecord(timestampUs, pt, rtpPacket));
      }

      // Find primary PT (most common).
      int? primaryPt;
      if (ptCounts.isNotEmpty) {
        primaryPt = ptCounts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
      }

      // Depacketize and group into access units by RTP timestamp.
      final depack = _H264RtpDepacketizer();
      final frames = <_Frame>[];
      int? prevRtpTs;
      var naluBatch = BytesBuilder();
      int? batchTimestampUs;

      for (final rec in records) {
        if (primaryPt != null && rec.pt != primaryPt) continue;

        final rtpTs = (rec.rtpPacket[4] << 24) | (rec.rtpPacket[5] << 16) |
            (rec.rtpPacket[6] << 8) | rec.rtpPacket[7];

        if (prevRtpTs != null && rtpTs != prevRtpTs && naluBatch.length > 0) {
          frames.add(_Frame(batchTimestampUs ?? 0, naluBatch.toBytes()));
          naluBatch = BytesBuilder();
          batchTimestampUs = rec.timestampUs;
        }
        prevRtpTs = rtpTs;
        batchTimestampUs ??= rec.timestampUs;

        for (final nalu in depack.process(rec.rtpPacket)) {
          naluBatch.add(nalu);
        }
      }
      if (naluBatch.length > 0) {
        frames.add(_Frame(batchTimestampUs ?? 0, naluBatch.toBytes()));
      }

      // Play frames with timing.
      _wallClockStartUs = null;
      for (final frame in frames) {
        if (!_playing) break;

        if (_paused) {
          _pauseCompleter = Completer<void>();
          await _pauseCompleter!.future;
          _wallClockStartUs = null;
          if (!_playing) break;
        }

        if (speed > 0) {
          final nowUs = DateTime.now().microsecondsSinceEpoch;
          _wallClockStartUs ??= nowUs;
          final targetUs = (frame.timestampUs / speed).round();
          final delayUs = targetUs - (nowUs - _wallClockStartUs!);
          if (delayUs > 0) {
            await Future.delayed(Duration(microseconds: delayUs));
          }
        }
        if (!_playing) break;
        await track.send(frame.data);
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
    if (_playing && !_paused) _paused = true;
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

class _DumpRecord {
  _DumpRecord(this.timestampUs, this.pt, this.rtpPacket);
  final int timestampUs;
  final int pt;
  final Uint8List rtpPacket;
}

class _Frame {
  _Frame(this.timestampUs, this.data);
  final int timestampUs;
  final Uint8List data;
}

/// Depacketizes H.264 RTP packets into NAL units with Annex B start codes.
class _H264RtpDepacketizer {
  BytesBuilder _fuBuffer = BytesBuilder();

  static int _rtpPayloadOffset(Uint8List pkt) {
    if (pkt.length < 12) return pkt.length;
    int offset = 12 + (pkt[0] & 0x0F) * 4;
    if ((pkt[0] & 0x10) != 0 && offset + 4 <= pkt.length) {
      final extLen = (pkt[offset + 2] << 8) | pkt[offset + 3];
      offset += 4 + extLen * 4;
    }
    return offset;
  }

  List<Uint8List> process(Uint8List rtpPacket) {
    final payloadOffset = _rtpPayloadOffset(rtpPacket);
    if (payloadOffset >= rtpPacket.length) return [];
    final payload = Uint8List.sublistView(rtpPacket, payloadOffset);

    Uint8List effective = payload;
    if ((rtpPacket[0] & 0x20) != 0 && payload.isNotEmpty) {
      final padLen = rtpPacket[rtpPacket.length - 1];
      final end = payload.length - padLen;
      if (end <= 0) return [];
      effective = Uint8List.sublistView(payload, 0, end);
    }

    if (effective.isEmpty) return [];
    final nalType = effective[0] & 0x1F;

    if (nalType >= 1 && nalType <= 23) {
      return [_withStartCode(effective)];
    } else if (nalType == 24) {
      return _parseStapA(effective);
    } else if (nalType == 28) {
      return _parseFuA(effective);
    }
    return [];
  }

  static Uint8List _withStartCode(Uint8List nalu) {
    final result = Uint8List(4 + nalu.length);
    result[3] = 1;
    result.setRange(4, result.length, nalu);
    return result;
  }

  static List<Uint8List> _parseStapA(Uint8List payload) {
    final nalus = <Uint8List>[];
    int off = 1;
    while (off + 2 <= payload.length) {
      final len = (payload[off] << 8) | payload[off + 1];
      off += 2;
      if (off + len > payload.length) break;
      nalus.add(_withStartCode(Uint8List.sublistView(payload, off, off + len)));
      off += len;
    }
    return nalus;
  }

  List<Uint8List> _parseFuA(Uint8List payload) {
    if (payload.length < 2) return [];
    final fuIndicator = payload[0];
    final fuHeader = payload[1];
    final start = (fuHeader & 0x80) != 0;
    final end = (fuHeader & 0x40) != 0;
    final nalType = fuHeader & 0x1F;
    final nri = fuIndicator & 0x60;

    if (start) {
      _fuBuffer = BytesBuilder();
      _fuBuffer.addByte(nri | nalType);
    }
    if (payload.length > 2) {
      _fuBuffer.add(Uint8List.sublistView(payload, 2));
    }
    if (end) {
      final nalu = _fuBuffer.toBytes();
      _fuBuffer = BytesBuilder();
      return [_withStartCode(Uint8List.fromList(nalu))];
    }
    return [];
  }
}
