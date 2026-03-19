class RTCSessionDescription {
  RTCSessionDescription({required this.sdp, required this.type});

  final String sdp;
  final String type;

  Map<String, dynamic> toMap() => {'sdp': sdp, 'type': type};

  factory RTCSessionDescription.fromMap(Map<dynamic, dynamic> map) {
    return RTCSessionDescription(
      sdp: map['sdp'] as String? ?? '',
      type: map['type'] as String? ?? '',
    );
  }

  @override
  String toString() => 'RTCSessionDescription(type: $type, sdp: ${sdp.substring(0, sdp.length.clamp(0, 80))}...)';
}
