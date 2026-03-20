class RTCConfiguration {
  RTCConfiguration({
    this.iceServers = const [],
    this.disableAutoNegotiation = true,
  });

  final List<String> iceServers;

  /// When true (default), the user must call setLocalDescription manually
  /// after adding tracks. When false, libdatachannel auto-generates
  /// offers/answers and fires on_track for incoming media.
  final bool disableAutoNegotiation;

  Map<String, dynamic> toMap() => {
        'iceServers': iceServers,
        'disableAutoNegotiation': disableAutoNegotiation,
      };
}
