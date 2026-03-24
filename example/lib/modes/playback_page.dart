import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as fwrtc;
import 'package:flutter_libdatachannel/flutter_libdatachannel.dart' as ldc;
import 'package:path_provider/path_provider.dart';

import '../signaling/in_process_signaling.dart' show InProcessSignaling, kLocalFwrtcConfig, kLocalLdcConfig;

class PlaybackPage extends StatefulWidget {
  const PlaybackPage({super.key});

  @override
  State<PlaybackPage> createState() => PlaybackPageState();
}

class PlaybackPageState extends State<PlaybackPage> {

  final _remoteRenderer = fwrtc.RTCVideoRenderer();
  fwrtc.RTCPeerConnection? _fwrtcPc;
  ldc.RTCPeerConnection? _ldcPc;
  ldc.RTCTrack? _ldcSendTrack;
  final _player = ldc.BitstreamPlayer();

  String _status = 'idle';
  List<FileSystemEntity> _dumpFiles = [];
  String? _selectedFile;
  double _selectedSpeed = 1.0;
  final _logMessages = <String>[];
  final _scrollController = ScrollController();
  Timer? _statsTimer;

  @override
  void initState() {
    super.initState();
    _remoteRenderer.initialize();
    _loadDumpFiles();
  }

  @override
  void dispose() {
    _cleanup();
    _remoteRenderer.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _log(String msg) {
    setState(() {
      _logMessages.add(msg);
      if (_logMessages.length > 200) _logMessages.removeAt(0);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _loadDumpFiles() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final files = dir
          .listSync()
          .where((f) => f.path.endsWith('.fldc'))
          .toList()
        ..sort((a, b) => b.path.compareTo(a.path));
      setState(() => _dumpFiles = files);
    } catch (e) {
      _log('Error loading files: $e');
    }
  }

  Future<void> _startPlayback() async {
    if (_selectedFile == null) return;
    setState(() => _status = 'connecting');
    try {
      // Read dump header to determine codec
      final raf = await File(_selectedFile!).open(mode: FileMode.read);
      final headerBytes = Uint8List(16);
      await raf.readInto(headerBytes);
      await raf.close();
      final header = ldc.DumpHeader.fromBytes(headerBytes);
      final codec = _dumpCodecToRtcCodec(header.codec);
      _log('File codec: ${header.codec.name}');

      // Create peer connections (no STUN — local in-process connection)
      _ldcPc = await ldc.RTCPeerConnection.create(kLocalLdcConfig);
      _log('ldc PeerConnection created (id: ${_ldcPc!.id})');

      _fwrtcPc = await fwrtc.createPeerConnection(kLocalFwrtcConfig);
      _log('fwrtc PeerConnection created');

      // Monitor connection states
      _fwrtcPc!.onConnectionState = (state) {
        _log('[fwrtc] Connection state: ${state.name}');
      };
      _ldcPc!.onConnectionStateChange.listen((state) {
        _log('[ldc] Connection state: ${state.value}');
      });

      // Connect via in-process signaling — track created inside with correct PT
      final result = await InProcessSignaling.connectForPlayback(
        ldcPc: _ldcPc!,
        codec: codec,
        fwrtcPc: _fwrtcPc!,
        onLog: _log,
      );
      _ldcSendTrack = result.ldcSendTrack;
      _log('Signaling complete, send track id=${_ldcSendTrack!.id}');

      // Monitor send track events
      _ldcSendTrack!.onOpen.listen((_) => _log('[ldc] send track OPEN'));
      _ldcSendTrack!.onClosed.listen((_) => _log('[ldc] send track CLOSED'));
      _ldcSendTrack!.onError.listen((e) => _log('[ldc] send track ERROR: $e'));

      // Display received video
      _remoteRenderer.srcObject = result.stream;
      _log('Remote stream attached to renderer');

      // Wait for connection + track to stabilize
      await Future.delayed(const Duration(milliseconds: 500));

      // Start stats polling
      _statsTimer = Timer.periodic(const Duration(seconds: 2), (_) => _logStats());

      // Start playback
      setState(() => _status = 'playing');
      _log('Starting playback at ${_selectedSpeed}x speed...');
      await _player.play(_ldcSendTrack!, _selectedFile!,
          speed: _selectedSpeed);
      _statsTimer?.cancel();
      _statsTimer = null;
      await _logStats();
      _log('Playback complete');
      setState(() => _status = 'done');
    } catch (e) {
      _log('Error: $e');
      setState(() => _status = 'idle');
    }
  }

  Future<void> _togglePause() async {
    if (_player.isPaused) {
      _player.resume();
      _log('Resumed');
      setState(() => _status = 'playing');
    } else {
      _player.pause();
      _log('Paused');
      setState(() => _status = 'paused');
    }
  }

  Future<void> _stopPlayback() async {
    await _player.stop();
    _log('Playback stopped');
    setState(() => _status = 'done');
  }

  Future<void> _logStats() async {
    if (_fwrtcPc == null) return;
    try {
      final stats = await _fwrtcPc!.getStats();
      for (final report in stats) {
        final values = report.values;
        final kind = values['kind'] ?? '';
        if (report.type == 'inbound-rtp' && kind == 'video') {
          final msg = '[stats] pkts=${values['packetsReceived']} '
              'bytes=${values['bytesReceived']} '
              'lost=${values['packetsLost']} '
              'jitter=${values['jitter']}\n'
              '[stats] framesRecv=${values['framesReceived']} '
              'decoded=${values['framesDecoded']} '
              'dropped=${values['framesDropped']} '
              'keyFrames=${values['keyFramesDecoded']}\n'
              '[stats] pli=${values['pliCount']} '
              'nack=${values['nackCount']} '
              'fir=${values['firCount']}';
          _log(msg);
          debugPrint(msg);
        }
      }
    } catch (e) {
      _log('[stats] Error: $e');
    }
  }

  Future<void> _cleanup() async {
    _statsTimer?.cancel();
    _statsTimer = null;
    if (_player.isPlaying) await _player.stop();
    await _ldcSendTrack?.dispose();
    _ldcSendTrack = null;
    await _ldcPc?.close();
    await _ldcPc?.dispose();
    _ldcPc = null;
    await _fwrtcPc?.close();
    await _fwrtcPc?.dispose();
    _fwrtcPc = null;
    _remoteRenderer.srcObject = null;
  }

  Future<void> reset() async {
    await _cleanup();
    if (mounted) {
      setState(() {
        _status = 'idle';
        _logMessages.clear();
      });
    }
    await _loadDumpFiles();
  }

  ldc.RTCCodec _dumpCodecToRtcCodec(ldc.DumpCodec dc) {
    switch (dc) {
      case ldc.DumpCodec.h264:
        return ldc.RTCCodec.h264;
      case ldc.DumpCodec.opus:
        return ldc.RTCCodec.opus;
      case ldc.DumpCodec.h265:
        return ldc.RTCCodec.h265;
      case ldc.DumpCodec.av1:
        return ldc.RTCCodec.av1;
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Status bar
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: _statusColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _statusColor),
            ),
            child: Text(
              'Status: $_status',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: _statusColor,
              ),
            ),
          ),
          const SizedBox(height: 8),

          // File selector
          if (_status == 'idle') ...[
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _selectedFile,
                    decoration: const InputDecoration(
                      labelText: 'Select dump file',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: _dumpFiles.map((f) {
                      final name = f.path.split(Platform.pathSeparator).last;
                      final size = (f as File).lengthSync();
                      return DropdownMenuItem(
                        value: f.path,
                        child: Text('$name (${_formatBytes(size)})'),
                      );
                    }).toList(),
                    onChanged: (v) => setState(() => _selectedFile = v),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: _loadDumpFiles,
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Refresh file list',
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Speed selector
            Row(
              children: [
                const Text('Speed: '),
                ...[0.5, 1.0, 2.0].map((speed) => Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text('${speed}x'),
                        selected: _selectedSpeed == speed,
                        onSelected: (_) =>
                            setState(() => _selectedSpeed = speed),
                      ),
                    )),
              ],
            ),
            const SizedBox(height: 8),
          ],

          // Video view
          Expanded(
            flex: 2,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(8),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: fwrtc.RTCVideoView(
                  _remoteRenderer,
                  objectFit:
                      fwrtc.RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),

          // Controls
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (_status == 'idle')
                ElevatedButton.icon(
                  onPressed: _selectedFile != null ? _startPlayback : null,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Play'),
                ),
              if (_status == 'playing' || _status == 'paused')
                ElevatedButton.icon(
                  onPressed: _togglePause,
                  icon: Icon(
                      _status == 'paused' ? Icons.play_arrow : Icons.pause),
                  label: Text(_status == 'paused' ? 'Resume' : 'Pause'),
                ),
              if (_status == 'playing' || _status == 'paused')
                ElevatedButton.icon(
                  onPressed: _stopPlayback,
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop'),
                ),
              if (_status == 'done')
                OutlinedButton.icon(
                  onPressed: reset,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Reset'),
                ),
            ],
          ),
          const SizedBox(height: 8),

          // Log
          Expanded(
            flex: 1,
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade300),
                borderRadius: BorderRadius.circular(4),
              ),
              child: SingleChildScrollView(
                controller: _scrollController,
                padding: const EdgeInsets.all(8),
                child: SelectableText(
                  _logMessages.join('\n'),
                  style:
                      const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Color get _statusColor {
    switch (_status) {
      case 'playing':
        return Colors.green;
      case 'paused':
        return Colors.orange;
      case 'connecting':
        return Colors.orange;
      case 'done':
        return Colors.blue;
      default:
        return Colors.grey;
    }
  }
}
