class RTCConfiguration {
  RTCConfiguration({this.iceServers = const []});

  final List<String> iceServers;

  Map<String, dynamic> toMap() => {
        'iceServers': iceServers,
      };
}
