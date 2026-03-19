enum RTCPeerConnectionState {
  newState('new'),
  connecting('connecting'),
  connected('connected'),
  disconnected('disconnected'),
  failed('failed'),
  closed('closed');

  const RTCPeerConnectionState(this.value);
  final String value;

  static RTCPeerConnectionState fromString(String s) {
    return values.firstWhere((e) => e.value == s,
        orElse: () => RTCPeerConnectionState.newState);
  }
}

enum RTCIceConnectionState {
  newState('new'),
  checking('checking'),
  connected('connected'),
  completed('completed'),
  failed('failed'),
  disconnected('disconnected'),
  closed('closed');

  const RTCIceConnectionState(this.value);
  final String value;

  static RTCIceConnectionState fromString(String s) {
    return values.firstWhere((e) => e.value == s,
        orElse: () => RTCIceConnectionState.newState);
  }
}

enum RTCIceGatheringState {
  newState('new'),
  gathering('inprogress'),
  complete('complete');

  const RTCIceGatheringState(this.value);
  final String value;

  static RTCIceGatheringState fromString(String s) {
    return values.firstWhere((e) => e.value == s,
        orElse: () => RTCIceGatheringState.newState);
  }
}

enum RTCSignalingState {
  stable('stable'),
  haveLocalOffer('have-local-offer'),
  haveRemoteOffer('have-remote-offer'),
  haveLocalPranswer('have-local-pranswer'),
  haveRemotePranswer('have-remote-pranswer');

  const RTCSignalingState(this.value);
  final String value;

  static RTCSignalingState fromString(String s) {
    return values.firstWhere((e) => e.value == s,
        orElse: () => RTCSignalingState.stable);
  }
}

enum RTCTrackDirection {
  sendonly,
  recvonly,
  sendrecv,
  inactive,
}

enum RTCCodec {
  h264,
  vp8,
  vp9,
  h265,
  av1,
  opus,
  pcmu,
  pcma,
}
