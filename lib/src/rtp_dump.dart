import 'dart:typed_data';

import 'enums.dart';

/// Standard rtptools `.rtpdump` format — interoperable with Wireshark,
/// `rtpplay`, and `rtpdump`.
///
/// Layout:
///   [text]  `#!rtpplay1.0 <ip>/<port>\n`
///   [16B]   RD_hdr_t:  start.tv_sec(u32) start.tv_usec(u32) source(u32)
///                      port(u16) padding(u16)
///   repeat  RD_packet_t (8B) + packet bytes:
///     length(u16)  bytes stored incl. this 8B header
///     plen(u16)    RTP header+payload length (0 for RTCP)
///     offset(u32)  milliseconds since recording start
///
/// All multi-byte fields are network byte order (big-endian). The codec is not
/// stored; it is inferred from the RTP payload type of the packets.
const String kRtpDumpPreamble = '#!rtpplay1.0 0.0.0.0/0\n';
const int kRtpDumpFileHeaderSize = 16;
const int kRtpDumpRecordHeaderSize = 8;

/// Codec hint retained for [BitstreamRecorder] API compatibility. The standard
/// format infers codec from the RTP payload type, so this value is not written
/// to the file.
enum DumpCodec {
  h264(0),
  opus(1),
  h265(2),
  av1(3);

  const DumpCodec(this.value);
  final int value;

  static DumpCodec fromValue(int v) {
    return values.firstWhere((e) => e.value == v, orElse: () => DumpCodec.h264);
  }
}

/// The rtptools file header (RD_hdr_t) plus its position in the byte stream.
class RtpDumpHeader {
  RtpDumpHeader({
    this.startSec = 0,
    this.startUsec = 0,
    this.source = 0,
    this.port = 0,
    this.headerEnd = 0,
  });

  final int startSec;
  final int startUsec;
  final int source;
  final int port;

  /// Byte offset of the first [RtpDumpPacket] record (i.e. end of the
  /// preamble + RD_hdr_t).
  final int headerEnd;

  Uint8List toBytes() {
    final preamble = Uint8List.fromList(kRtpDumpPreamble.codeUnits);
    final out = Uint8List(preamble.length + kRtpDumpFileHeaderSize);
    out.setAll(0, preamble);
    final data = ByteData.sublistView(out, preamble.length);
    data.setUint32(0, startSec, Endian.big);
    data.setUint32(4, startUsec, Endian.big);
    data.setUint32(8, source, Endian.big);
    data.setUint16(12, port, Endian.big);
    data.setUint16(14, 0, Endian.big); // padding
    return out;
  }

  /// Parses the preamble line + RD_hdr_t from [bytes].
  static RtpDumpHeader fromBytes(Uint8List bytes) {
    // Preamble: text up to and including the first newline.
    int nl = bytes.indexOf(0x0A);
    if (nl < 0) {
      throw const FormatException('Missing rtpdump preamble newline');
    }
    final hdrStart = nl + 1;
    if (bytes.length < hdrStart + kRtpDumpFileHeaderSize) {
      throw const FormatException('File too short for rtpdump header');
    }
    final data = ByteData.sublistView(bytes, hdrStart);
    return RtpDumpHeader(
      startSec: data.getUint32(0, Endian.big),
      startUsec: data.getUint32(4, Endian.big),
      source: data.getUint32(8, Endian.big),
      port: data.getUint16(12, Endian.big),
      headerEnd: hdrStart + kRtpDumpFileHeaderSize,
    );
  }
}

/// One recorded packet (RD_packet_t + stored bytes).
class RtpDumpPacket {
  RtpDumpPacket({required this.offsetMs, required this.payload});

  /// Milliseconds since recording start.
  final int offsetMs;

  /// Stored packet bytes (a full RTP packet for our recordings).
  final Uint8List payload;

  /// RTP payload type (second byte, low 7 bits), or -1 if too short.
  int get payloadType => payload.length >= 2 ? payload[1] & 0x7F : -1;

  Uint8List toBytes() {
    final out = Uint8List(kRtpDumpRecordHeaderSize + payload.length);
    final data = ByteData.sublistView(out);
    data.setUint16(0, kRtpDumpRecordHeaderSize + payload.length, Endian.big);
    data.setUint16(2, payload.length, Endian.big); // plen
    data.setUint32(4, offsetMs, Endian.big);
    out.setAll(kRtpDumpRecordHeaderSize, payload);
    return out;
  }

  /// Parses a record starting at [offset]. Returns null if the buffer does not
  /// hold a complete record.
  static RtpDumpPacket? fromByteData(ByteData data, int offset) {
    if (offset + kRtpDumpRecordHeaderSize > data.lengthInBytes) return null;
    final length = data.getUint16(offset, Endian.big);
    final offsetMs = data.getUint32(offset + 4, Endian.big);
    final storedLen =
        length >= kRtpDumpRecordHeaderSize ? length - kRtpDumpRecordHeaderSize : 0;
    final dataStart = offset + kRtpDumpRecordHeaderSize;
    if (dataStart + storedLen > data.lengthInBytes) return null;
    final payload = Uint8List.sublistView(
      data.buffer.asUint8List(),
      data.offsetInBytes + dataStart,
      data.offsetInBytes + dataStart + storedLen,
    );
    return RtpDumpPacket(offsetMs: offsetMs, payload: payload);
  }

  /// Serialized size of this record (header + stored bytes).
  int get sizeInFile => kRtpDumpRecordHeaderSize + payload.length;
}

/// A parsed rtpdump file.
class RtpDump {
  RtpDump({required this.header, required this.packets});

  final RtpDumpHeader header;
  final List<RtpDumpPacket> packets;

  static RtpDump parse(Uint8List bytes) {
    final header = RtpDumpHeader.fromBytes(bytes);
    final data = ByteData.sublistView(bytes);
    final packets = <RtpDumpPacket>[];
    int offset = header.headerEnd;
    while (true) {
      final pkt = RtpDumpPacket.fromByteData(data, offset);
      if (pkt == null) break;
      packets.add(pkt);
      offset += pkt.sizeInFile;
    }
    return RtpDump(header: header, packets: packets);
  }

  /// The most common RTP payload type across recorded packets, or -1.
  int get primaryPayloadType {
    final counts = <int, int>{};
    for (final p in packets) {
      final pt = p.payloadType;
      if (pt >= 0) counts[pt] = (counts[pt] ?? 0) + 1;
    }
    int best = -1, bestCount = 0;
    counts.forEach((pt, c) {
      if (c > bestCount) {
        bestCount = c;
        best = pt;
      }
    });
    return best;
  }
}

/// Best-effort mapping from an RTP payload type to a codec. Dynamic payload
/// types (96–127) are ambiguous, so callers that know the codec (e.g. from a
/// test-corpus fourCC) should override. This default assumes the common
/// AirSync mapping (96 → H.264, 98 → VP9).
RTCCodec codecForPayloadType(int pt, {RTCCodec fallback = RTCCodec.h264}) {
  switch (pt) {
    case 98:
      return RTCCodec.vp9;
    case 111:
      return RTCCodec.opus;
    case 96:
    default:
      return fallback;
  }
}
