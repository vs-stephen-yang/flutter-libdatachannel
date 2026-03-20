import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as fwrtc;
import 'package:flutter_libdatachannel/flutter_libdatachannel.dart' as ldc;
import 'package:path_provider/path_provider.dart';

import '../signaling/in_process_signaling.dart';

class ReceiveDumpPage extends StatefulWidget {
  const ReceiveDumpPage({super.key});

  @override
  State<ReceiveDumpPage> createState() => ReceiveDumpPageState();
}

class ReceiveDumpPageState extends State<ReceiveDumpPage> {

  final _localRenderer = fwrtc.RTCVideoRenderer();
  fwrtc.RTCPeerConnection? _fwrtcPc;
  ldc.RTCPeerConnection? _ldcPc;
  fwrtc.MediaStream? _screenStream;
  ldc.RTCTrack? _ldcTrack;
  final _recorder = ldc.BitstreamRecorder();

  String _status = 'idle';
  String? _dumpFilePath;
  int? _dumpFileSize;
  final _logMessages = <String>[];
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _localRenderer.initialize();
  }

  @override
  void dispose() {
    _cleanup();
    _localRenderer.dispose();
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

  Future<void> _startCapture() async {
    setState(() => _status = 'capturing');
    try {
      fwrtc.DesktopCapturerSource? selectedSource;

      // On desktop, use desktopCapturer to pick a screen/window source
      if (fwrtc.WebRTC.platformIsDesktop) {
        final sources = await fwrtc.desktopCapturer.getSources(
          types: [fwrtc.SourceType.Screen, fwrtc.SourceType.Window],
        );
        _log('Found ${sources.length} capture sources');

        if (!mounted) return;

        // Show picker dialog
        selectedSource = await showDialog<fwrtc.DesktopCapturerSource>(
          context: context,
          builder: (context) => _ScreenSourcePickerDialog(sources: sources),
        );

        if (selectedSource == null) {
          _log('Screen capture cancelled');
          setState(() => _status = 'idle');
          return;
        }
        _log('Selected source: ${selectedSource.name}');
      }

      // Get the display media stream
      _screenStream =
          await fwrtc.navigator.mediaDevices.getDisplayMedia(<String, dynamic>{
        'video': selectedSource == null
            ? true
            : {
                'deviceId': {'exact': selectedSource.id},
                'mandatory': {'frameRate': 30.0},
              },
      });
      _localRenderer.srcObject = _screenStream;
      _log('Screen capture started');
      setState(() => _status = 'previewing');
    } catch (e) {
      _log('Error starting capture: $e');
      setState(() => _status = 'idle');
    }
  }

  Future<void> _startRecording() async {
    if (_screenStream == null) return;
    setState(() => _status = 'connecting');
    try {
      // Create peer connections (no STUN — local in-process connection)
      _fwrtcPc = await fwrtc.createPeerConnection(kLocalFwrtcConfig);
      _log('fwrtc PeerConnection created');

      _ldcPc = await ldc.RTCPeerConnection.create(kLocalLdcRecvConfig);
      _log('ldc PeerConnection created (id: ${_ldcPc!.id})');

      // Monitor connection states
      _fwrtcPc!.onConnectionState = (state) {
        _log('[fwrtc] Connection state: ${state.name}');
      };
      _ldcPc!.onConnectionStateChange.listen((state) {
        _log('[ldc] Connection state: ${state.value}');
      });

      // Connect via in-process signaling
      _ldcTrack = await InProcessSignaling.connectForReceiveDump(
        fwrtcPc: _fwrtcPc!,
        ldcPc: _ldcPc!,
        screenStream: _screenStream!,
        onLog: _log,
      );
      _log('Signaling complete — ldc track mid: ${_ldcTrack!.mid}');

      // Start recording
      final dir = await getApplicationDocumentsDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      _dumpFilePath = '${dir.path}/dump_$timestamp.fldc';
      await _recorder.start(_ldcTrack!, _dumpFilePath!);
      _log('Recording to: $_dumpFilePath');
      setState(() => _status = 'recording');
    } catch (e) {
      _log('Error: $e');
      setState(() => _status = 'previewing');
    }
  }

  Future<void> _stopRecording() async {
    setState(() => _status = 'stopping');
    try {
      await _recorder.stop();
      _log('Recording stopped');

      if (_dumpFilePath != null) {
        final file = File(_dumpFilePath!);
        if (await file.exists()) {
          _dumpFileSize = await file.length();
          _log('File: $_dumpFilePath');
          _log('Size: ${_formatBytes(_dumpFileSize!)}');
        }
      }

      setState(() => _status = 'done');
    } catch (e) {
      _log('Error stopping: $e');
      setState(() => _status = 'previewing');
    }
  }

  Future<void> _cleanup() async {
    if (_recorder.isRecording) await _recorder.stop();
    await _ldcTrack?.dispose();
    _ldcTrack = null;
    await _ldcPc?.close();
    await _ldcPc?.dispose();
    _ldcPc = null;
    await _fwrtcPc?.close();
    await _fwrtcPc?.dispose();
    _fwrtcPc = null;
    _screenStream?.getTracks().forEach((t) => t.stop());
    _screenStream?.dispose();
    _screenStream = null;
    _localRenderer.srcObject = null;
  }

  Future<void> reset() async {
    await _cleanup();
    if (mounted) {
      setState(() {
        _status = 'idle';
        _dumpFilePath = null;
        _dumpFileSize = null;
        _logMessages.clear();
      });
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

          // Video preview
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
                  _localRenderer,
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
                  onPressed: _startCapture,
                  icon: const Icon(Icons.screen_share),
                  label: const Text('Start Capture'),
                ),
              if (_status == 'previewing')
                ElevatedButton.icon(
                  onPressed: _startRecording,
                  icon: const Icon(Icons.fiber_manual_record),
                  label: const Text('Record'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                  ),
                ),
              if (_status == 'recording')
                ElevatedButton.icon(
                  onPressed: _stopRecording,
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop'),
                ),
              if (_status == 'done' || _status == 'previewing')
                OutlinedButton.icon(
                  onPressed: reset,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Reset'),
                ),
            ],
          ),

          // File info
          if (_dumpFilePath != null && _dumpFileSize != null) ...[
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('File: $_dumpFilePath',
                        style: const TextStyle(fontSize: 12)),
                    Text('Size: ${_formatBytes(_dumpFileSize!)}',
                        style: const TextStyle(fontSize: 12)),
                  ],
                ),
              ),
            ),
          ],
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
                  style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
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
      case 'recording':
        return Colors.red;
      case 'connecting':
        return Colors.orange;
      case 'previewing':
        return Colors.blue;
      case 'done':
        return Colors.green;
      default:
        return Colors.grey;
    }
  }
}

class _ScreenSourcePickerDialog extends StatefulWidget {
  const _ScreenSourcePickerDialog({required this.sources});

  final List<fwrtc.DesktopCapturerSource> sources;

  @override
  State<_ScreenSourcePickerDialog> createState() =>
      _ScreenSourcePickerDialogState();
}

class _ScreenSourcePickerDialogState extends State<_ScreenSourcePickerDialog> {
  fwrtc.DesktopCapturerSource? _selected;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Choose what to share'),
      content: SizedBox(
        width: 500,
        height: 400,
        child: widget.sources.isEmpty
            ? const Center(child: Text('No screen sources available'))
            : GridView.builder(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
          ),
          itemCount: widget.sources.length,
          itemBuilder: (context, index) {
            final source = widget.sources[index];
            final isSelected = _selected?.id == source.id;
            return InkWell(
              onTap: () => setState(() => _selected = source),
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: isSelected ? Colors.blue : Colors.grey.shade300,
                    width: isSelected ? 2 : 1,
                  ),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Column(
                  children: [
                    Expanded(
                      child: source.thumbnail != null
                          ? Image.memory(
                              source.thumbnail!,
                              gaplessPlayback: true,
                              fit: BoxFit.contain,
                            )
                          : const Center(child: Icon(Icons.desktop_windows)),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(4),
                      child: Text(
                        source.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight:
                              isSelected ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed:
              _selected != null ? () => Navigator.pop(context, _selected) : null,
          child: const Text('Share'),
        ),
      ],
    );
  }
}
