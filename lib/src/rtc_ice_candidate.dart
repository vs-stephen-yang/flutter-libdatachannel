class RTCIceCandidate {
  RTCIceCandidate({required this.candidate, this.sdpMid});

  final String candidate;
  final String? sdpMid;

  Map<String, dynamic> toMap() => {
        'candidate': candidate,
        if (sdpMid != null) 'mid': sdpMid,
      };

  factory RTCIceCandidate.fromMap(Map<dynamic, dynamic> map) {
    return RTCIceCandidate(
      candidate: map['candidate'] as String? ?? '',
      sdpMid: map['mid'] as String?,
    );
  }

  @override
  String toString() => 'RTCIceCandidate(candidate: $candidate, mid: $sdpMid)';
}
