import 'dart:typed_data';

/// Binary dump format for RTP packet recording/playback.
///
/// Header (16 bytes):
///   [4B] Magic: "FLDC"
///   [4B] Version: uint32 LE (1)
///   [4B] Track codec: uint32 LE (0=H264, 1=Opus, 2=H265, 3=AV1)
///   [4B] Reserved
///
/// Per-frame record:
///   [8B] Timestamp: uint64 LE microseconds since recording start
///   [4B] Payload length: uint32 LE
///   [NB] Payload (raw RTP packet data)

const int kDumpMagic = 0x43444C46; // "FLDC" in little-endian
const int kDumpVersion = 1;
const int kDumpHeaderSize = 16;
const int kDumpRecordHeaderSize = 12; // 8 + 4

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

class DumpHeader {
  DumpHeader({required this.codec});

  final DumpCodec codec;

  Uint8List toBytes() {
    final data = ByteData(kDumpHeaderSize);
    data.setUint32(0, kDumpMagic, Endian.little);
    data.setUint32(4, kDumpVersion, Endian.little);
    data.setUint32(8, codec.value, Endian.little);
    data.setUint32(12, 0, Endian.little); // reserved
    return data.buffer.asUint8List();
  }

  static DumpHeader fromBytes(Uint8List bytes) {
    if (bytes.length < kDumpHeaderSize) {
      throw FormatException('Dump file too short for header');
    }
    final data = ByteData.sublistView(bytes);
    final magic = data.getUint32(0, Endian.little);
    if (magic != kDumpMagic) {
      throw FormatException('Invalid dump file magic: 0x${magic.toRadixString(16)}');
    }
    final version = data.getUint32(4, Endian.little);
    if (version != kDumpVersion) {
      throw FormatException('Unsupported dump version: $version');
    }
    final codec = DumpCodec.fromValue(data.getUint32(8, Endian.little));
    return DumpHeader(codec: codec);
  }
}

class DumpRecord {
  DumpRecord({required this.timestampUs, required this.payload});

  final int timestampUs;
  final Uint8List payload;

  Uint8List toBytes() {
    final header = ByteData(kDumpRecordHeaderSize);
    header.setUint64(0, timestampUs, Endian.little);
    header.setUint32(8, payload.length, Endian.little);
    final result = Uint8List(kDumpRecordHeaderSize + payload.length);
    result.setAll(0, header.buffer.asUint8List());
    result.setAll(kDumpRecordHeaderSize, payload);
    return result;
  }

  static DumpRecord? fromByteData(ByteData data, int offset) {
    if (offset + kDumpRecordHeaderSize > data.lengthInBytes) return null;
    final timestampUs = data.getUint64(offset, Endian.little);
    final payloadLength = data.getUint32(offset + 8, Endian.little);
    if (offset + kDumpRecordHeaderSize + payloadLength > data.lengthInBytes) {
      return null;
    }
    final payload = Uint8List.sublistView(
      data.buffer.asUint8List(),
      offset + kDumpRecordHeaderSize,
      offset + kDumpRecordHeaderSize + payloadLength,
    );
    return DumpRecord(timestampUs: timestampUs, payload: payload);
  }
}
