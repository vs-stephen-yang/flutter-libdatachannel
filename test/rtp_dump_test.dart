import 'dart:typed_data';

import 'package:flutter_libdatachannel/flutter_libdatachannel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('RtpDump round-trips header + packets (rtptools standard)', () {
    final packets = [
      RtpDumpPacket(
        offsetMs: 0,
        payload: Uint8List.fromList(
            [0x80, 0x60, 0x00, 0x01, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6]),
      ),
      RtpDumpPacket(
        offsetMs: 33,
        payload: Uint8List.fromList(List.generate(200, (i) => i & 0xFF)),
      ),
      RtpDumpPacket(
        offsetMs: 66,
        payload: Uint8List.fromList(
            [0x80, 0x60, 0x00, 0x03, 0, 0, 0, 0, 9, 9, 9, 9]),
      ),
    ];

    // Serialize: preamble + header, then each record.
    final b = BytesBuilder();
    b.add(RtpDumpHeader().toBytes());
    for (final p in packets) {
      b.add(p.toBytes());
    }
    final bytes = b.toBytes();

    // Preamble present.
    expect(String.fromCharCodes(bytes.sublist(0, kRtpDumpPreamble.length)),
        equals(kRtpDumpPreamble));

    final dump = RtpDump.parse(bytes);
    expect(dump.packets.length, equals(packets.length));
    for (int i = 0; i < packets.length; i++) {
      expect(dump.packets[i].offsetMs, equals(packets[i].offsetMs));
      expect(dump.packets[i].payload, equals(packets[i].payload));
    }

    // PT is the low 7 bits of the second byte (0x60 → 96).
    expect(dump.primaryPayloadType, equals(96));
  });

  test('codecForPayloadType maps known + falls back', () {
    expect(codecForPayloadType(96), equals(RTCCodec.h264));
    expect(codecForPayloadType(98), equals(RTCCodec.vp9));
    expect(codecForPayloadType(111), equals(RTCCodec.opus));
    expect(codecForPayloadType(96, fallback: RTCCodec.vp8),
        equals(RTCCodec.vp8));
  });

  test('RtpDumpHeader rejects a stream with no preamble newline', () {
    expect(() => RtpDumpHeader.fromBytes(Uint8List(16)),
        throwsA(isA<FormatException>()));
  });
}
