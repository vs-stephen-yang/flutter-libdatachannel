import 'dart:async';

import 'method_channel.dart';
import 'rtc_track.dart';

class BitstreamPlayer {
  final _channel = LdcMethodChannel.instance;
  bool _playing = false;
  bool _paused = false;
  int? _trId;
  Completer<void>? _playCompleter;
  StreamSubscription? _eventSub;

  bool get isPlaying => _playing;
  bool get isPaused => _paused;

  Future<void> play(RTCTrack track, String filePath,
      {double speed = 1.0}) async {
    if (_playing) throw StateError('Already playing');
    _playing = true;
    _paused = false;
    _trId = track.id;
    _playCompleter = Completer<void>();

    _eventSub = _channel.events
        .where((e) =>
            e['event'] == 'onPlaybackComplete' && e['trId'] == track.id)
        .listen((_) {
      _playing = false;
      _paused = false;
      _playCompleter?.complete();
      _playCompleter = null;
      _eventSub?.cancel();
      _eventSub = null;
    });

    try {
      await _channel.invoke('startPlayback', {
        'trId': track.id,
        'filePath': filePath,
        'speed': speed,
      });
      await _playCompleter?.future;
    } catch (e) {
      _playing = false;
      _paused = false;
      _eventSub?.cancel();
      _eventSub = null;
      _playCompleter = null;
      rethrow;
    }
  }

  Future<void> pause() async {
    if (_playing && !_paused) {
      await _channel.invoke('pausePlayback', {'trId': _trId});
      _paused = true;
    }
  }

  Future<void> resume() async {
    if (_playing && _paused) {
      await _channel.invoke('resumePlayback', {'trId': _trId});
      _paused = false;
    }
  }

  Future<void> stop() async {
    if (!_playing) return;
    await _channel.invoke('stopPlayback', {'trId': _trId});
    _playing = false;
    _paused = false;
    _eventSub?.cancel();
    _eventSub = null;
    // The completion callback may or may not fire after stop,
    // so complete the completer if still pending
    if (_playCompleter != null && !_playCompleter!.isCompleted) {
      _playCompleter!.complete();
    }
    _playCompleter = null;
  }
}
