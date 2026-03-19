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
final ldc.RTCConfiguration kLocalLdcConfig =
    ldc.RTCConfiguration(iceServers: []);

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

    // Completer for the ldc track that fires from onTrack
    final ldcTrackCompleter = Completer<ldc.RTCTrack>();

    // Buffer ICE candidates until SDP exchange is complete
    final fwrtcCandidates = <fwrtc.RTCIceCandidate>[];
    final ldcCandidates = <ldc.RTCIceCandidate>[];

    // Listen for ldc onTrack
    final ldcTrackSub = ldcPc.onTrack.listen((track) {
      log('[ldc] onTrack fired — mid: ${track.mid}');
      if (!ldcTrackCompleter.isCompleted) {
        ldcTrackCompleter.complete(track);
      }
    });

    // Buffer ICE candidates from both sides
    fwrtcPc.onIceCandidate = (candidate) {
      log('[fwrtc] ICE candidate: ${candidate.candidate}');
      fwrtcCandidates.add(candidate);
    };

    final ldcCandBufSub = ldcPc.onLocalCandidate.listen((candidate) {
      log('[ldc] ICE candidate: ${candidate.candidate}');
      ldcCandidates.add(candidate);
    });

    // Add screen capture tracks to fwrtc peer connection
    for (final track in screenStream.getTracks()) {
      await fwrtcPc.addTrack(track, screenStream);
      log('[fwrtc] Added ${track.kind} track');
    }

    // fwrtc creates offer
    final fwrtcOffer = await fwrtcPc.createOffer();
    await fwrtcPc.setLocalDescription(fwrtcOffer);
    log('[fwrtc] Offer created');
    log('[fwrtc] Offer SDP:\n${fwrtcOffer.sdp}');

    // Pass offer to ldc
    await ldcPc.setRemoteDescription(ldc.RTCSessionDescription(
      sdp: fwrtcOffer.sdp!,
      type: fwrtcOffer.type!,
    ));
    log('[ldc] Remote description set (offer)');

    // Wait for ldc onTrack, with a timeout fallback
    ldc.RTCTrack ldcTrack;
    try {
      ldcTrack = await ldcTrackCompleter.future.timeout(
        const Duration(seconds: 3),
      );
    } on TimeoutException {
      log('[ldc] onTrack did not fire — adding recvonly track manually');
      ldcTrack = await ldcPc.addTrack(ldc.RTCTrackInit(
        direction: ldc.RTCTrackDirection.recvonly,
        codec: ldc.RTCCodec.h264,
        payloadType: 96,
        ssrc: 0,
        mid: '0',
      ));
      log('[ldc] Manual recvonly track added — mid: ${ldcTrack.mid}');
    }

    // ldc creates answer
    final ldcAnswer = await ldcPc.createAnswer();
    log('[ldc] Answer type: "${ldcAnswer.type}", sdp length: ${ldcAnswer.sdp.length}');
    log('[ldc] Answer SDP (raw):\n${ldcAnswer.sdp}');

    // Patch ldc answer SDP for fwrtc compatibility
    final patchedAnswerSdp = _patchLdcSdpForFwrtc(
      ldcAnswer.sdp,
      fwrtcOffer.sdp!,
      log,
    );
    log('[ldc] Answer SDP (patched, ${patchedAnswerSdp.length} chars):\n$patchedAnswerSdp');

    // Pass answer to fwrtc
    try {
      await fwrtcPc.setRemoteDescription(fwrtc.RTCSessionDescription(
        patchedAnswerSdp,
        ldcAnswer.type,
      ));
      log('[fwrtc] Remote description set (answer)');
    } catch (e) {
      log('[fwrtc] setRemoteDescription FAILED: $e');
      log('[fwrtc] type="${ldcAnswer.type}" sdp first 500 chars: ${patchedAnswerSdp.substring(0, patchedAnswerSdp.length.clamp(0, 500))}');
      rethrow;
    }

    // Now exchange buffered ICE candidates
    await _drainCandidates(
      fwrtcCandidates: fwrtcCandidates,
      ldcCandidates: ldcCandidates,
      fwrtcPc: fwrtcPc,
      ldcPc: ldcPc,
      log: log,
    );

    // Set up live ICE candidate forwarding for any late candidates
    fwrtcPc.onIceCandidate = (candidate) {
      log('[fwrtc→ldc] ICE (live): ${candidate.candidate}');
      ldcPc.addIceCandidate(ldc.RTCIceCandidate(
        candidate: candidate.candidate!,
        sdpMid: candidate.sdpMid,
      ));
    };
    ldcPc.onLocalCandidate.listen((candidate) {
      log('[ldc→fwrtc] ICE (live): ${candidate.candidate}');
      fwrtcPc.addCandidate(fwrtc.RTCIceCandidate(
        candidate.candidate,
        candidate.sdpMid,
        0,
      ));
    });

    // Cancel the buffering subscription now that live forwarding is active
    await ldcCandBufSub.cancel();

    await ldcTrackSub.cancel();
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

    // Buffer ICE candidates
    final fwrtcCandidates = <fwrtc.RTCIceCandidate>[];
    final ldcCandidates = <ldc.RTCIceCandidate>[];

    fwrtcPc.onTrack = (fwrtc.RTCTrackEvent event) {
      log('[fwrtc] onTrack fired — kind: ${event.track.kind}');
      if (!remoteStreamCompleter.isCompleted && event.streams.isNotEmpty) {
        remoteStreamCompleter.complete(event.streams.first);
      }
    };

    // Buffer ICE candidates
    fwrtcPc.onIceCandidate = (candidate) {
      log('[fwrtc] ICE candidate: ${candidate.candidate}');
      fwrtcCandidates.add(candidate);
    };

    final ldcCandBufSub = ldcPc.onLocalCandidate.listen((candidate) {
      log('[ldc] ICE candidate: ${candidate.candidate}');
      ldcCandidates.add(candidate);
    });

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
    log('[fwrtc] Offer SDP:\n${fwrtcOffer.sdp}');

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
    log('[ldc] Send track added — mid: ${ldcSendTrack.mid}, PT: $pt');

    // Set up packetizer with matching PT
    if (codec == ldc.RTCCodec.h264) {
      await ldcSendTrack.setH264Packetizer(ldc.RTCPacketizerInit(
        ssrc: 1,
        payloadType: pt,
        clockRate: 90000,
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
    log('[ldc] Answer SDP (raw):\n${ldcAnswer.sdp}');

    // Patch ldc answer SDP for fwrtc compatibility
    final patchedAnswerSdp = _patchLdcSdpForFwrtc(
      ldcAnswer.sdp,
      fwrtcOffer.sdp!,
      log,
    );
    log('[ldc] Answer SDP (patched, ${patchedAnswerSdp.length} chars):\n$patchedAnswerSdp');

    // Pass ldc answer to fwrtc
    try {
      await fwrtcPc.setRemoteDescription(fwrtc.RTCSessionDescription(
        patchedAnswerSdp,
        ldcAnswer.type,
      ));
      log('[fwrtc] Remote description set (answer)');
    } catch (e) {
      log('[fwrtc] setRemoteDescription FAILED: $e');
      log('[fwrtc] type="${ldcAnswer.type}" sdp first 500 chars: ${patchedAnswerSdp.substring(0, patchedAnswerSdp.length.clamp(0, 500))}');
      rethrow;
    }

    // Drain buffered ICE candidates
    await _drainCandidates(
      fwrtcCandidates: fwrtcCandidates,
      ldcCandidates: ldcCandidates,
      fwrtcPc: fwrtcPc,
      ldcPc: ldcPc,
      log: log,
    );

    // Set up live ICE forwarding
    fwrtcPc.onIceCandidate = (candidate) {
      log('[fwrtc→ldc] ICE (live): ${candidate.candidate}');
      ldcPc.addIceCandidate(ldc.RTCIceCandidate(
        candidate: candidate.candidate!,
        sdpMid: candidate.sdpMid,
      ));
    };
    ldcPc.onLocalCandidate.listen((candidate) {
      log('[ldc→fwrtc] ICE (live): ${candidate.candidate}');
      fwrtcPc.addCandidate(fwrtc.RTCIceCandidate(
        candidate.candidate,
        candidate.sdpMid,
        0,
      ));
    });

    // Cancel the buffering subscription now that live forwarding is active
    await ldcCandBufSub.cancel();

    // Wait for remote stream
    fwrtc.MediaStream remoteStream;
    try {
      remoteStream = await remoteStreamCompleter.future.timeout(
        const Duration(seconds: 10),
      );
    } on TimeoutException {
      log('[fwrtc] onTrack did not fire yet — waiting longer...');
      final laterCompleter = Completer<fwrtc.MediaStream>();
      fwrtcPc.onTrack = (fwrtc.RTCTrackEvent event) {
        log('[fwrtc] onTrack fired (late) — kind: ${event.track.kind}');
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
    // Look for a=rtpmap:<pt> <codecName>/... in the video section
    final pattern = RegExp(r'a=rtpmap:(\d+) ' + RegExp.escape(codecName) + r'/');
    final match = pattern.firstMatch(sdp);
    if (match != null) {
      return int.parse(match.group(1)!);
    }
    log('[parse] WARNING: Could not find $codecName in offer, defaulting to PT 96');
    return 96;
  }

  /// Find the mid value for the video m-line.
  static String _findVideoMid(String sdp) {
    final lines = sdp.split(RegExp(r'\r?\n'));
    bool inVideo = false;
    for (final line in lines) {
      if (line.startsWith('m=video')) inVideo = true;
      if (line.startsWith('m=audio')) inVideo = false;
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

  /// Drain buffered ICE candidates after SDP exchange is complete.
  static Future<void> _drainCandidates({
    required List<fwrtc.RTCIceCandidate> fwrtcCandidates,
    required List<ldc.RTCIceCandidate> ldcCandidates,
    required fwrtc.RTCPeerConnection fwrtcPc,
    required ldc.RTCPeerConnection ldcPc,
    required void Function(String) log,
  }) async {
    log('Draining ${fwrtcCandidates.length} fwrtc + ${ldcCandidates.length} ldc buffered candidates');
    final fwrtcSnapshot = List.of(fwrtcCandidates);
    final ldcSnapshot = List.of(ldcCandidates);
    fwrtcCandidates.clear();
    ldcCandidates.clear();
    for (final c in fwrtcSnapshot) {
      await ldcPc.addIceCandidate(ldc.RTCIceCandidate(
        candidate: c.candidate!,
        sdpMid: c.sdpMid,
      ));
    }
    for (final c in ldcSnapshot) {
      await fwrtcPc.addCandidate(fwrtc.RTCIceCandidate(
        c.candidate,
        c.sdpMid,
        0,
      ));
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
    // Step 1: Normalize line endings to \r\n (libwebrtc is strict about this)
    var sdp = ldcSdp
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAll('\n', '\r\n');

    // Ensure SDP ends with \r\n
    if (!sdp.endsWith('\r\n')) {
      sdp += '\r\n';
    }

    // Step 2: Parse into lines for manipulation
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
      if (line.startsWith('v=')) {
        if (!hasO) {
          result.add('o=- 0 0 IN IP4 127.0.0.1');
          log('[patch] Added o= line');
        }
      }

      // Insert s= after o=
      if (line.startsWith('o=') && !hasS) {
        result.add('s=-');
        log('[patch] Added s= line');
      }

      // Insert t= after s=
      if ((line.startsWith('s=') || (!hasS && line.startsWith('o='))) &&
          !hasT) {
        // Only add once
        if (line.startsWith('s=') || !hasS) {
          result.add('t=0 0');
          hasT = true; // prevent double-add
          log('[patch] Added t= line');

          // Add BUNDLE group from offer if missing
          if (!hasBundle) {
            final bundleMatch = RegExp(r'a=group:BUNDLE[^\r\n]*')
                .firstMatch(offerSdp);
            if (bundleMatch != null) {
              result.add(bundleMatch.group(0)!);
              log('[patch] Added BUNDLE group from offer');
            }
          }
        }
      }
    }

    // Step 3: Fix bare a=ssrc:<id> lines (missing cname sub-attribute).
    // RFC 5576 requires: a=ssrc:<ssrc-id> <attribute>:<value>
    // libdatachannel emits bare "a=ssrc:1" which libwebrtc rejects.
    final patched = <String>[];
    final bareSsrcPattern = RegExp(r'^a=ssrc:(\d+)$');
    for (final line in result) {
      final m = bareSsrcPattern.firstMatch(line);
      if (m != null) {
        final ssrcId = m.group(1)!;
        patched.add('a=ssrc:$ssrcId cname:ldc');
        log('[patch] Fixed bare a=ssrc:$ssrcId → added cname');
      } else {
        patched.add(line);
      }
    }

    return '${patched.join('\r\n')}\r\n';
  }
}
