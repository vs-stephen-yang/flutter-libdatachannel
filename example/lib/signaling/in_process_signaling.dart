import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart' as fwrtc;
import 'package:flutter_libdatachannel/flutter_libdatachannel.dart' as ldc;

class PlaybackResult {
  PlaybackResult({required this.stream, required this.ldcSendTrack});
  final fwrtc.MediaStream stream;
  final ldc.RTCTrack ldcSendTrack;
}

/// ICE configuration for local in-process connections (no STUN needed).
const Map<String, dynamic> kLocalFwrtcConfig = {
  'iceServers': <Map<String, dynamic>>[],
  'iceTransportPolicy': 'all',
};

/// ldc config with auto-negotiation disabled (for send/manual track management).
final ldc.RTCConfiguration kLocalLdcConfig =
    ldc.RTCConfiguration(iceServers: [], disableAutoNegotiation: true);

/// ldc config with auto-negotiation enabled (for receive - on_track fires).
final ldc.RTCConfiguration kLocalLdcRecvConfig =
    ldc.RTCConfiguration(iceServers: [], disableAutoNegotiation: false);

/// Buffers ICE candidates during SDP exchange, then drains and switches to
/// live forwarding. Eliminates duplicate buffering logic across signaling paths.
class _IceBridge {
  _IceBridge({
    required fwrtc.RTCPeerConnection fwrtcPc,
    required ldc.RTCPeerConnection ldcPc,
    required void Function(String) log,
  })  : _fwrtcPc = fwrtcPc,
        _ldcPc = ldcPc,
        _log = log {
    fwrtcPc.onIceCandidate = (c) {
      _log('[fwrtc] ICE: ${c.candidate}');
      _fwrtcBuf.add(c);
    };
    _ldcBufSub = ldcPc.onLocalCandidate.listen((c) {
      _log('[ldc] ICE: ${c.candidate}');
      _ldcBuf.add(c);
    });
  }

  final fwrtc.RTCPeerConnection _fwrtcPc;
  final ldc.RTCPeerConnection _ldcPc;
  final void Function(String) _log;
  final _fwrtcBuf = <fwrtc.RTCIceCandidate>[];
  final _ldcBuf = <ldc.RTCIceCandidate>[];
  StreamSubscription? _ldcBufSub;

  /// Drain buffered candidates and switch to live forwarding.
  /// Live forwarding subscriptions are cleaned up when the PCs are disposed.
  Future<void> drainAndForward() async {
    _log('Draining ${_fwrtcBuf.length} fwrtc + ${_ldcBuf.length} ldc buffered candidates');
    for (final c in List.of(_fwrtcBuf)) {
      await _ldcPc.addIceCandidate(ldc.RTCIceCandidate(
        candidate: c.candidate!,
        sdpMid: c.sdpMid,
      ));
    }
    for (final c in List.of(_ldcBuf)) {
      await _fwrtcPc.addCandidate(fwrtc.RTCIceCandidate(
        c.candidate,
        c.sdpMid,
        0,
      ));
    }
    _fwrtcBuf.clear();
    _ldcBuf.clear();

    // Switch to live forwarding
    _fwrtcPc.onIceCandidate = (c) {
      _ldcPc.addIceCandidate(ldc.RTCIceCandidate(
        candidate: c.candidate!,
        sdpMid: c.sdpMid,
      ));
    };
    _ldcPc.onLocalCandidate.listen((c) {
      _fwrtcPc.addCandidate(fwrtc.RTCIceCandidate(
        c.candidate,
        c.sdpMid,
        0,
      ));
    });

    await _ldcBufSub?.cancel();
    _ldcBufSub = null;
  }
}

class InProcessSignaling {
  /// fwrtc offers (screen capture sender), ldc answers (receiver).
  /// Returns the ldc RTCTrack that receives incoming RTP data.
  static Future<ldc.RTCTrack> connectForReceiveDump({
    required fwrtc.RTCPeerConnection fwrtcPc,
    required ldc.RTCPeerConnection ldcPc,
    required fwrtc.MediaStream screenStream,
    void Function(String)? onLog,
  }) async {
    void log(String msg) => onLog?.call(msg);

    final ice = _IceBridge(fwrtcPc: fwrtcPc, ldcPc: ldcPc, log: log);

    // Add screen capture tracks to fwrtc peer connection
    for (final track in screenStream.getTracks()) {
      await fwrtcPc.addTrack(track, screenStream);
      log('[fwrtc] Added ${track.kind} track');
    }

    // fwrtc creates offer
    final fwrtcOffer = await fwrtcPc.createOffer();
    await fwrtcPc.setLocalDescription(fwrtcOffer);
    log('[fwrtc] Offer created');

    // With disableAutoNegotiation=false, setRemoteDescription(offer) will:
    //   1. Fire on_track for each media section in the offer
    //   2. Auto-generate an answer (fires onLocalDescription)
    // Set up listeners BEFORE calling setRemoteDescription.
    final trackCompleter = Completer<ldc.RTCTrack>();
    final answerCompleter = Completer<ldc.RTCSessionDescription>();
    final extraTracks = <ldc.RTCTrack>[];

    final trackSub = ldcPc.onTrack.listen((track) {
      log('[ldc] on_track fired - mid: ${track.mid}, id: ${track.id}');
      if (!trackCompleter.isCompleted) {
        trackCompleter.complete(track);
      } else {
        extraTracks.add(track);
      }
    });
    final descSub = ldcPc.onLocalDescription.listen((desc) {
      log('[ldc] onLocalDescription fired - type: ${desc.type}');
      if (!answerCompleter.isCompleted && desc.type == 'answer') {
        answerCompleter.complete(desc);
      }
    });

    // Pass offer to ldc - triggers on_track + auto-answer
    await ldcPc.setRemoteDescription(ldc.RTCSessionDescription(
      sdp: fwrtcOffer.sdp!,
      type: fwrtcOffer.type!,
    ));
    log('[ldc] Remote description set (offer)');

    // Wait for on_track
    ldc.RTCTrack ldcTrack;
    try {
      ldcTrack = await trackCompleter.future.timeout(
        const Duration(seconds: 5),
      );
      log('[ldc] Got track from on_track - mid: ${ldcTrack.mid}');
    } on TimeoutException {
      await trackSub.cancel();
      await descSub.cancel();
      log('[ldc] ERROR: on_track never fired after setRemoteDescription');
      throw Exception('ldc on_track never fired - cannot receive media');
    }

    // Chain RTCP receiving session for proper RTP reception
    await ldcTrack.chainRtcpReceivingSession();
    log('[ldc] RTCP receiving session chained');

    // Wait for auto-generated answer
    ldc.RTCSessionDescription ldcAnswer;
    try {
      ldcAnswer = await answerCompleter.future.timeout(
        const Duration(seconds: 5),
      );
    } on TimeoutException {
      // Fallback: try to get it directly
      log('[ldc] onLocalDescription timeout - trying getLocalDescription');
      final desc = await ldcPc.getLocalDescription();
      if (desc != null && desc.sdp.isNotEmpty) {
        ldcAnswer = desc;
      } else {
        await trackSub.cancel();
        await descSub.cancel();
        throw Exception('Failed to get ldc answer');
      }
    }
    await trackSub.cancel();
    await descSub.cancel();
    log('[ldc] Answer type: "${ldcAnswer.type}", sdp length: ${ldcAnswer.sdp.length}');

    // Dispose extra tracks (e.g., audio track from multi-media offers)
    for (final t in extraTracks) {
      log('[ldc] Disposing extra track mid: ${t.mid}');
      await t.dispose();
    }

    // Patch ldc answer SDP for fwrtc compatibility
    var patchedAnswerSdp = _patchLdcSdpForFwrtc(
      ldcAnswer.sdp,
      fwrtcOffer.sdp!,
      log,
    );

    // Force H264 and strip RED/ULPFEC so fwrtc sends clean H264 RTP.
    patchedAnswerSdp = _forceH264NoRed(patchedAnswerSdp, log);

    // Pass answer to fwrtc
    try {
      await fwrtcPc.setRemoteDescription(fwrtc.RTCSessionDescription(
        patchedAnswerSdp,
        ldcAnswer.type,
      ));
      log('[fwrtc] Remote description set (answer)');
    } catch (e) {
      log('[fwrtc] setRemoteDescription FAILED: $e');
      log('[fwrtc] Patched SDP:\n$patchedAnswerSdp');
      rethrow;
    }

    // Exchange ICE candidates
    await ice.drainAndForward();

    return ldcTrack;
  }

  /// fwrtc offers (recvonly video), ldc creates matching sendonly track & answers.
  /// Returns ({fwrtc.MediaStream stream, ldc.RTCTrack ldcSendTrack}).
  static Future<PlaybackResult> connectForPlayback({
    required ldc.RTCPeerConnection ldcPc,
    required ldc.RTCCodec codec,
    required fwrtc.RTCPeerConnection fwrtcPc,
    void Function(String)? onLog,
  }) async {
    void log(String msg) => onLog?.call(msg);

    final remoteStreamCompleter = Completer<fwrtc.MediaStream>();
    final ice = _IceBridge(fwrtcPc: fwrtcPc, ldcPc: ldcPc, log: log);

    fwrtcPc.onTrack = (fwrtc.RTCTrackEvent event) {
      log('[fwrtc] onTrack fired - kind: ${event.track.kind}');
      if (!remoteStreamCompleter.isCompleted && event.streams.isNotEmpty) {
        remoteStreamCompleter.complete(event.streams.first);
      }
    };

    // Add a recvonly transceiver on fwrtc
    await fwrtcPc.addTransceiver(
      kind: fwrtc.RTCRtpMediaType.RTCRtpMediaTypeVideo,
      init: fwrtc.RTCRtpTransceiverInit(
        direction: fwrtc.TransceiverDirection.RecvOnly,
      ),
    );
    log('[fwrtc] Added recvonly video transceiver');

    // fwrtc creates offer
    final fwrtcOffer = await fwrtcPc.createOffer();
    await fwrtcPc.setLocalDescription(fwrtcOffer);
    log('[fwrtc] Offer created');

    // Parse offer to find the correct payload type for the requested codec
    final codecName = _ldcCodecToSdpName(codec);
    final pt = _findPayloadType(fwrtcOffer.sdp!, codecName, log);
    log('[parse] Found $codecName at PT $pt in offer');

    // Find the video mid from the offer
    final videoMid = _findVideoMid(fwrtcOffer.sdp!);
    log('[parse] Video mid: $videoMid');

    // Now add the ldc sendonly track with the correct PT from the offer
    final ldcSendTrack = await ldcPc.addTrack(ldc.RTCTrackInit(
      direction: ldc.RTCTrackDirection.sendonly,
      codec: codec,
      payloadType: pt,
      ssrc: 1,
      mid: videoMid,
    ));
    log('[ldc] Send track added - mid: ${ldcSendTrack.mid}, PT: $pt');

    // Set up H264 packetizer — the player depacketizes raw RTP from the
    // dump into H.264 NALUs (Annex B) before sending through the packetizer.
    if (codec == ldc.RTCCodec.h264) {
      await ldcSendTrack.setH264Packetizer(ldc.RTCPacketizerInit(
        ssrc: 1,
        payloadType: pt,
        clockRate: 90000,
        nalSeparator: 'longStartSequence',
      ));
      log('[ldc] H264 packetizer configured with PT $pt');
    }
    await ldcSendTrack.chainRtcpSrReporter();
    log('[ldc] RTCP SR reporter chained');

    // Pass fwrtc offer to ldc
    await ldcPc.setRemoteDescription(ldc.RTCSessionDescription(
      sdp: fwrtcOffer.sdp!,
      type: fwrtcOffer.type!,
    ));
    log('[ldc] Remote description set (offer)');

    // ldc creates answer
    final ldcAnswer = await ldcPc.createAnswer();
    log('[ldc] Answer type: "${ldcAnswer.type}", sdp length: ${ldcAnswer.sdp.length}');

    // Patch ldc answer SDP for fwrtc compatibility
    final patchedAnswerSdp = _patchLdcSdpForFwrtc(
      ldcAnswer.sdp,
      fwrtcOffer.sdp!,
      log,
    );

    // Pass ldc answer to fwrtc
    try {
      await fwrtcPc.setRemoteDescription(fwrtc.RTCSessionDescription(
        patchedAnswerSdp,
        ldcAnswer.type,
      ));
      log('[fwrtc] Remote description set (answer)');
    } catch (e) {
      log('[fwrtc] setRemoteDescription FAILED: $e');
      log('[fwrtc] Patched SDP:\n$patchedAnswerSdp');
      rethrow;
    }

    // Exchange ICE candidates
    await ice.drainAndForward();

    // Wait for remote stream
    fwrtc.MediaStream remoteStream;
    try {
      remoteStream = await remoteStreamCompleter.future.timeout(
        const Duration(seconds: 10),
      );
    } on TimeoutException {
      log('[fwrtc] onTrack did not fire yet - waiting longer...');
      final laterCompleter = Completer<fwrtc.MediaStream>();
      fwrtcPc.onTrack = (fwrtc.RTCTrackEvent event) {
        log('[fwrtc] onTrack fired (late) - kind: ${event.track.kind}');
        if (!laterCompleter.isCompleted && event.streams.isNotEmpty) {
          laterCompleter.complete(event.streams.first);
        }
      };
      remoteStream = await laterCompleter.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () =>
            throw TimeoutException('fwrtc onTrack never fired'),
      );
    }

    return PlaybackResult(stream: remoteStream, ldcSendTrack: ldcSendTrack);
  }

  /// Find the payload type for a codec name (e.g. "H264") in the video m-line.
  static int _findPayloadType(String sdp, String codecName, void Function(String) log) {
    final pattern = RegExp(r'a=rtpmap:(\d+) ' + RegExp.escape(codecName) + r'/');
    final match = pattern.firstMatch(sdp);
    if (match != null) {
      return int.parse(match.group(1)!);
    }
    log('[parse] WARNING: Could not find $codecName in offer, defaulting to PT 96');
    return 96;
  }

  /// Find the mid value for the video m-line (handles any m-line ordering).
  static String _findVideoMid(String sdp) {
    final lines = sdp.split(RegExp(r'\r?\n'));
    bool inVideo = false;
    for (final line in lines) {
      if (line.startsWith('m=video')) {
        inVideo = true;
      } else if (line.startsWith('m=')) {
        inVideo = false;
      }
      if (inVideo && line.startsWith('a=mid:')) {
        return line.substring(6).trim();
      }
    }
    return '0';
  }

  /// Map ldc codec enum to SDP codec name.
  static String _ldcCodecToSdpName(ldc.RTCCodec codec) {
    switch (codec) {
      case ldc.RTCCodec.h264: return 'H264';
      case ldc.RTCCodec.vp8: return 'VP8';
      case ldc.RTCCodec.vp9: return 'VP9';
      case ldc.RTCCodec.h265: return 'H265';
      case ldc.RTCCodec.av1: return 'AV1';
      case ldc.RTCCodec.opus: return 'opus';
      case ldc.RTCCodec.pcmu: return 'PCMU';
      case ldc.RTCCodec.pcma: return 'PCMA';
    }
  }

  /// Patch libdatachannel SDP to be compatible with libwebrtc (fwrtc).
  ///
  /// libdatachannel generates minimal SDP that may be missing fields
  /// libwebrtc considers mandatory. This function fills in gaps using
  /// the offer SDP as reference.
  static String _patchLdcSdpForFwrtc(
    String ldcSdp,
    String offerSdp,
    void Function(String) log,
  ) {
    // Normalize line endings to \r\n (libwebrtc is strict about this)
    var sdp = ldcSdp
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAll('\n', '\r\n');
    if (!sdp.endsWith('\r\n')) sdp += '\r\n';

    // Parse into lines for manipulation
    final lines = sdp.split('\r\n').where((l) => l.isNotEmpty).toList();
    final result = <String>[];
    bool hasV = false, hasO = false, hasS = false, hasT = false;
    bool hasBundle = false;

    for (final line in lines) {
      if (line.startsWith('v=')) hasV = true;
      if (line.startsWith('o=')) hasO = true;
      if (line.startsWith('s=')) hasS = true;
      if (line.startsWith('t=')) hasT = true;
      if (line.startsWith('a=group:BUNDLE')) hasBundle = true;
    }

    // Build the SDP with required session-level fields
    if (!hasV) {
      result.add('v=0');
      log('[patch] Added v= line');
    }

    for (final line in lines) {
      result.add(line);

      // Insert missing session-level fields after v=
      if (line.startsWith('v=') && !hasO) {
        result.add('o=- 0 0 IN IP4 127.0.0.1');
        log('[patch] Added o= line');
      }

      // Insert s= after o=
      if (line.startsWith('o=') && !hasS) {
        result.add('s=-');
        log('[patch] Added s= line');
      }

      // Insert t= and BUNDLE after the last session-level line we inserted
      if (!hasT) {
        // Only add t= once, on the deepest insertion point
        if (line.startsWith('s=') ||
            (!hasS && line.startsWith('o=')) ||
            (!hasS && !hasO && line.startsWith('v='))) {
          if (!result.contains('t=0 0')) {
            result.add('t=0 0');
            log('[patch] Added t= line');

            if (!hasBundle) {
              final bundleMatch =
                  RegExp(r'a=group:BUNDLE[^\r\n]*').firstMatch(offerSdp);
              if (bundleMatch != null) {
                result.add(bundleMatch.group(0)!);
                log('[patch] Added BUNDLE group from offer');
              }
            }
          }
        }
      }
    }

    // Fix bare a=ssrc:<id> lines (missing cname sub-attribute).
    // RFC 5576 requires: a=ssrc:<ssrc-id> <attribute>:<value>
    // libdatachannel emits bare "a=ssrc:1" which libwebrtc rejects.
    final patched = <String>[];
    final bareSsrcPattern = RegExp(r'^a=ssrc:(\d+)$');
    for (final line in result) {
      final m = bareSsrcPattern.firstMatch(line);
      if (m != null) {
        final ssrcId = m.group(1)!;
        patched.add('a=ssrc:$ssrcId cname:ldc');
        log('[patch] Fixed bare a=ssrc:$ssrcId');
      } else {
        patched.add(line);
      }
    }

    return '${patched.join('\r\n')}\r\n';
  }

  /// Strip RED, ULPFEC, and their RTX from the video m-line, then reorder
  /// so that H264 payload types come first.  This forces libwebrtc to send
  /// clean H264 RTP packets (no RED wrapping) which simplifies recording.
  static String _forceH264NoRed(String sdp, void Function(String) log) {
    final lines = sdp.split(RegExp(r'\r?\n'));

    // Collect PTs to remove (red, ulpfec, and rtx-for-red).
    final removePts = <String>{};
    final rtxAptMap = <String, String>{}; // rtxPt → apt
    for (final line in lines) {
      final rtpmap = RegExp(r'^a=rtpmap:(\d+)\s+(red|ulpfec)/').firstMatch(line);
      if (rtpmap != null) removePts.add(rtpmap.group(1)!);
      final fmtp = RegExp(r'^a=fmtp:(\d+)\s+apt=(\d+)').firstMatch(line);
      if (fmtp != null) rtxAptMap[fmtp.group(1)!] = fmtp.group(2)!;
    }
    // Also remove RTX entries whose apt points to a removed PT.
    for (final entry in rtxAptMap.entries) {
      if (removePts.contains(entry.value)) removePts.add(entry.key);
    }
    if (removePts.isNotEmpty) log('[force-h264] Removing PTs: $removePts');

    // Identify H264 PTs and their RTX PTs.
    final h264Pts = <String>{};
    final h264RtxPts = <String>{};
    for (final line in lines) {
      final m = RegExp(r'^a=rtpmap:(\d+)\s+H264/').firstMatch(line);
      if (m != null) h264Pts.add(m.group(1)!);
    }
    for (final entry in rtxAptMap.entries) {
      if (h264Pts.contains(entry.value)) h264RtxPts.add(entry.key);
    }

    final result = <String>[];
    for (final line in lines) {
      // Rewrite video m-line: remove bad PTs, reorder H264 first.
      if (line.startsWith('m=video')) {
        final parts = line.split(' ');
        // parts[0]='m=video', [1]=port, [2]=proto, [3..]=PTs
        final proto = parts.sublist(0, 3);
        final pts = parts.sublist(3);
        final kept = pts.where((p) => !removePts.contains(p)).toList();
        // Move H264 + its RTX to front.
        final h264 = kept.where((p) => h264Pts.contains(p) || h264RtxPts.contains(p)).toList();
        final rest = kept.where((p) => !h264Pts.contains(p) && !h264RtxPts.contains(p)).toList();
        result.add([...proto, ...h264, ...rest].join(' '));
        log('[force-h264] Reordered m-line: H264 PTs first');
        continue;
      }

      // Drop attribute lines for removed PTs.
      final ptMatch = RegExp(r'^a=(rtpmap|fmtp|rtcp-fb):(\d+)[\s/]').firstMatch(line);
      if (ptMatch != null && removePts.contains(ptMatch.group(2))) continue;

      result.add(line);
    }

    return result.join('\r\n');
  }
}
