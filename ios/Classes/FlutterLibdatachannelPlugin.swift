import Flutter
import UIKit

public class FlutterLibdatachannelPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private var eventSink: FlutterEventSink?
    private static var instance: FlutterLibdatachannelPlugin?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "flutter_libdatachannel",
            binaryMessenger: registrar.messenger()
        )
        let eventChannel = FlutterEventChannel(
            name: "flutter_libdatachannel/events",
            binaryMessenger: registrar.messenger()
        )
        let pluginInstance = FlutterLibdatachannelPlugin()
        instance = pluginInstance
        registrar.addMethodCallDelegate(pluginInstance, channel: channel)
        eventChannel.setStreamHandler(pluginInstance)

        ldc_init()
    }

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        setupCallbacks()
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        ldc_set_event_callback(nil, nil)
        ldc_set_binary_event_callback(nil, nil)
        return nil
    }

    private func setupCallbacks() {
        let pointer = Unmanaged.passUnretained(self).toOpaque()

        ldc_set_event_callback({ (eventJson, userData) in
            guard let userData = userData,
                  let json = eventJson else { return }
            let plugin = Unmanaged<FlutterLibdatachannelPlugin>.fromOpaque(userData).takeUnretainedValue()
            let jsonStr = String(cString: json)
            if let data = jsonStr.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                DispatchQueue.main.async {
                    plugin.eventSink?(dict)
                }
            }
        }, pointer)

        ldc_set_binary_event_callback({ (trId, data, size, userData) in
            guard let userData = userData, let data = data else { return }
            let plugin = Unmanaged<FlutterLibdatachannelPlugin>.fromOpaque(userData).takeUnretainedValue()
            let flutterData = FlutterStandardTypedData(bytes: Data(bytes: data, count: Int(size)))
            let map: [String: Any] = [
                "event": "onTrackMessage",
                "trId": Int(trId),
                "data": flutterData,
            ]
            DispatchQueue.main.async {
                plugin.eventSink?(map)
            }
        }, pointer)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any] else {
            if call.method == "createPeerConnection" {
                let pcId = ldc_create_peer_connection(nil, 0)
                result(Int(pcId))
                return
            }
            result(FlutterMethodNotImplemented)
            return
        }

        switch call.method {
        case "createPeerConnection":
            let iceServers = args["iceServers"] as? String
            let disableAutoNeg = args["disableAutoNegotiation"] as? Int ?? 0
            let pcId = ldc_create_peer_connection(iceServers, Int32(disableAutoNeg))
            if pcId < 0 {
                result(FlutterError(code: "CREATE_FAILED", message: "Failed to create peer connection", details: nil))
            } else {
                result(Int(pcId))
            }

        case "closePeerConnection":
            ldc_close_peer_connection(Int32(args["pcId"] as! Int))
            result(nil)

        case "deletePeerConnection":
            ldc_delete_peer_connection(Int32(args["pcId"] as! Int))
            result(nil)

        case "setLocalDescription":
            let pcId = Int32(args["pcId"] as! Int)
            let type = args["type"] as? String
            let ret = ldc_set_local_description(pcId, type)
            if ret < 0 {
                result(FlutterError(code: "SET_LOCAL_DESC_FAILED", message: "Failed", details: nil))
            } else {
                result(nil)
            }

        case "setRemoteDescription":
            let pcId = Int32(args["pcId"] as! Int)
            let sdp = args["sdp"] as? String
            let type = args["type"] as? String
            let ret = ldc_set_remote_description(pcId, sdp, type)
            if ret < 0 {
                result(FlutterError(code: "SET_REMOTE_DESC_FAILED", message: "Failed", details: nil))
            } else {
                result(nil)
            }

        case "addRemoteCandidate":
            let pcId = Int32(args["pcId"] as! Int)
            let candidate = args["candidate"] as? String
            let mid = args["mid"] as? String
            let ret = ldc_add_remote_candidate(pcId, candidate, mid)
            if ret < 0 {
                result(FlutterError(code: "ADD_CANDIDATE_FAILED", message: "Failed", details: nil))
            } else {
                result(nil)
            }

        case "getLocalDescription":
            let pcId = Int32(args["pcId"] as! Int)
            let sdp = ldc_get_local_description(pcId)
            let type = ldc_get_local_description_type(pcId)
            let desc: [String: String] = [
                "sdp": sdp.map { String(cString: $0) } ?? "",
                "type": type.map { String(cString: $0) } ?? "",
            ]
            if let sdp = sdp { ldc_free(sdp) }
            if let type = type { ldc_free(type) }
            result(desc)

        case "getRemoteDescription":
            let pcId = Int32(args["pcId"] as! Int)
            let sdp = ldc_get_remote_description(pcId)
            let type = ldc_get_remote_description_type(pcId)
            let desc: [String: String] = [
                "sdp": sdp.map { String(cString: $0) } ?? "",
                "type": type.map { String(cString: $0) } ?? "",
            ]
            if let sdp = sdp { ldc_free(sdp) }
            if let type = type { ldc_free(type) }
            result(desc)

        case "addTrack":
            let pcId = Int32(args["pcId"] as! Int)
            let initMap = args["init"] as? [String: Any] ?? [:]
            let initJson = mapToJson(initMap)
            let trId = ldc_add_track(pcId, initJson)
            if trId < 0 {
                result(FlutterError(code: "ADD_TRACK_FAILED", message: "Failed", details: nil))
            } else {
                result(Int(trId))
            }

        case "deleteTrack":
            ldc_delete_track(Int32(args["trId"] as! Int))
            result(nil)

        case "sendTrackMessage":
            let trId = Int32(args["trId"] as! Int)
            if let data = args["data"] as? FlutterStandardTypedData {
                let bytes = [UInt8](data.data)
                let ret = ldc_send_track_message(trId, bytes, Int32(bytes.count))
                if ret < 0 {
                    result(FlutterError(code: "SEND_FAILED", message: "Failed", details: nil))
                } else {
                    result(nil)
                }
            } else {
                result(FlutterError(code: "INVALID_DATA", message: "No data", details: nil))
            }

        case "setH264Packetizer":
            let trId = Int32(args["trId"] as! Int)
            let initMap = args["init"] as? [String: Any] ?? [:]
            let ret = ldc_set_h264_packetizer(trId, mapToJson(initMap))
            if ret < 0 {
                result(FlutterError(code: "SET_PACKETIZER_FAILED", message: "Failed", details: nil))
            } else {
                result(nil)
            }

        case "setOpusPacketizer":
            let trId = Int32(args["trId"] as! Int)
            let initMap = args["init"] as? [String: Any] ?? [:]
            let ret = ldc_set_opus_packetizer(trId, mapToJson(initMap))
            if ret < 0 {
                result(FlutterError(code: "SET_PACKETIZER_FAILED", message: "Failed", details: nil))
            } else {
                result(nil)
            }

        case "startRecording":
            let trId = Int32(args["trId"] as! Int)
            let filePath = args["filePath"] as? String
            let codec = Int32(args["codec"] as? Int ?? 0)
            let ret = ldc_start_recording(trId, filePath, codec)
            if ret < 0 {
                result(FlutterError(code: "START_RECORDING_FAILED", message: "Failed", details: nil))
            } else {
                result(nil)
            }

        case "stopRecording":
            let trId = Int32(args["trId"] as! Int)
            let ret = ldc_stop_recording(trId)
            if ret < 0 {
                result(FlutterError(code: "STOP_RECORDING_FAILED", message: "Failed", details: nil))
            } else {
                result(nil)
            }

        case "getSelectedCandidatePair":
            let pcId = Int32(args["pcId"] as! Int)
            if let cstr = ldc_get_selected_candidate_pair(pcId) {
                let s = String(cString: cstr)
                ldc_free(cstr)
                result(s)
            } else {
                result(nil)
            }

        case "chainRtcpReceivingSession":
            let ret = ldc_chain_rtcp_receiving_session(Int32(args["trId"] as! Int))
            if ret < 0 {
                result(FlutterError(code: "CHAIN_FAILED", message: "Failed", details: nil))
            } else {
                result(nil)
            }

        case "chainRtcpSrReporter":
            let ret = ldc_chain_rtcp_sr_reporter(Int32(args["trId"] as! Int))
            if ret < 0 {
                result(FlutterError(code: "CHAIN_FAILED", message: "Failed", details: nil))
            } else {
                result(nil)
            }

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func mapToJson(_ map: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: map),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}
