package com.example.flutter_libdatachannel

import androidx.annotation.NonNull
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import org.json.JSONObject

class FlutterLibdatachannelPlugin : FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler {

    private lateinit var channel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var eventSink: EventChannel.EventSink? = null

    companion object {
        init {
            System.loadLibrary("flutter_libdatachannel_native")
        }
    }

    // JNI methods
    private external fun nativeSetEventHandler(handler: Any?)
    private external fun nativeCreatePeerConnection(iceServersJson: String?, disableAutoNegotiation: Int): Int
    private external fun nativeClosePeerConnection(pcId: Int)
    private external fun nativeDeletePeerConnection(pcId: Int)
    private external fun nativeSetLocalDescription(pcId: Int, type: String?): Int
    private external fun nativeSetRemoteDescription(pcId: Int, sdp: String?, type: String?): Int
    private external fun nativeAddRemoteCandidate(pcId: Int, candidate: String?, mid: String?): Int
    private external fun nativeGetLocalDescription(pcId: Int): String?
    private external fun nativeGetLocalDescriptionType(pcId: Int): String?
    private external fun nativeGetRemoteDescription(pcId: Int): String?
    private external fun nativeGetRemoteDescriptionType(pcId: Int): String?
    private external fun nativeAddTrack(pcId: Int, initJson: String?): Int
    private external fun nativeDeleteTrack(trId: Int)
    private external fun nativeSendTrackMessage(trId: Int, data: ByteArray): Int
    private external fun nativeSetH264Packetizer(trId: Int, initJson: String?): Int
    private external fun nativeSetOpusPacketizer(trId: Int, initJson: String?): Int
    private external fun nativeChainRtcpReceivingSession(trId: Int): Int
    private external fun nativeChainRtcpSrReporter(trId: Int): Int
    private external fun nativeStartRecording(trId: Int, filePath: String?, codec: Int): Int
    private external fun nativeStopRecording(trId: Int): Int
    private external fun nativeStartPlayback(trId: Int, filePath: String?, speed: Double): Int
    private external fun nativePausePlayback(trId: Int): Int
    private external fun nativeResumePlayback(trId: Int): Int
    private external fun nativeStopPlayback(trId: Int): Int

    // Called from JNI when events arrive
    @Suppress("unused")
    fun onEvent(eventJson: String) {
        val map = jsonToMap(eventJson)
        eventSink?.success(map)
    }

    // Called from JNI when binary track data arrives
    @Suppress("unused")
    fun onBinaryEvent(trId: Int, data: ByteArray) {
        val map = HashMap<String, Any>()
        map["event"] = "onTrackMessage"
        map["trId"] = trId
        map["data"] = data
        eventSink?.success(map)
    }

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "flutter_libdatachannel")
        channel.setMethodCallHandler(this)

        eventChannel = EventChannel(flutterPluginBinding.binaryMessenger, "flutter_libdatachannel/events")
        eventChannel.setStreamHandler(this)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        nativeSetEventHandler(this)
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
        nativeSetEventHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "createPeerConnection" -> {
                // Dart sends iceServers as a List<String>; serialize to the JSON
                // array string the native layer expects. disableAutoNegotiation
                // arrives as an int (1/0).
                val iceServersList = call.argument<List<String>>("iceServers") ?: emptyList()
                val iceServersJson = org.json.JSONArray(iceServersList).toString()
                val disableAutoNeg = call.argument<Int>("disableAutoNegotiation") ?: 0
                val pcId = nativeCreatePeerConnection(iceServersJson, disableAutoNeg)
                if (pcId < 0) result.error("CREATE_FAILED", "Failed to create peer connection", null)
                else result.success(pcId)
            }
            "closePeerConnection" -> {
                nativeClosePeerConnection(call.argument<Int>("pcId")!!)
                result.success(null)
            }
            "deletePeerConnection" -> {
                nativeDeletePeerConnection(call.argument<Int>("pcId")!!)
                result.success(null)
            }
            "setLocalDescription" -> {
                val ret = nativeSetLocalDescription(call.argument<Int>("pcId")!!, call.argument<String>("type"))
                if (ret < 0) result.error("SET_LOCAL_DESC_FAILED", "Failed to set local description", null)
                else result.success(null)
            }
            "setRemoteDescription" -> {
                val ret = nativeSetRemoteDescription(
                    call.argument<Int>("pcId")!!,
                    call.argument<String>("sdp"),
                    call.argument<String>("type")
                )
                if (ret < 0) result.error("SET_REMOTE_DESC_FAILED", "Failed to set remote description", null)
                else result.success(null)
            }
            "addRemoteCandidate" -> {
                val ret = nativeAddRemoteCandidate(
                    call.argument<Int>("pcId")!!,
                    call.argument<String>("candidate"),
                    call.argument<String>("mid")
                )
                if (ret < 0) result.error("ADD_CANDIDATE_FAILED", "Failed to add remote candidate", null)
                else result.success(null)
            }
            "getLocalDescription" -> {
                val pcId = call.argument<Int>("pcId")!!
                val sdp = nativeGetLocalDescription(pcId)
                val type = nativeGetLocalDescriptionType(pcId)
                result.success(mapOf("sdp" to (sdp ?: ""), "type" to (type ?: "")))
            }
            "getRemoteDescription" -> {
                val pcId = call.argument<Int>("pcId")!!
                val sdp = nativeGetRemoteDescription(pcId)
                val type = nativeGetRemoteDescriptionType(pcId)
                result.success(mapOf("sdp" to (sdp ?: ""), "type" to (type ?: "")))
            }
            "addTrack" -> {
                val pcId = call.argument<Int>("pcId")!!
                val init = call.argument<Map<String, Any>>("init")
                val initJson = JSONObject(init ?: emptyMap<String, Any>()).toString()
                val trId = nativeAddTrack(pcId, initJson)
                if (trId < 0) result.error("ADD_TRACK_FAILED", "Failed to add track", null)
                else result.success(trId)
            }
            "deleteTrack" -> {
                nativeDeleteTrack(call.argument<Int>("trId")!!)
                result.success(null)
            }
            "sendTrackMessage" -> {
                val trId = call.argument<Int>("trId")!!
                val data = call.argument<ByteArray>("data")
                if (data == null) {
                    result.error("INVALID_DATA", "No data provided", null)
                } else {
                    val ret = nativeSendTrackMessage(trId, data)
                    if (ret < 0) result.error("SEND_FAILED", "Failed to send track message", null)
                    else result.success(null)
                }
            }
            "setH264Packetizer" -> {
                val trId = call.argument<Int>("trId")!!
                val init = call.argument<Map<String, Any>>("init")
                val initJson = JSONObject(init ?: emptyMap<String, Any>()).toString()
                val ret = nativeSetH264Packetizer(trId, initJson)
                if (ret < 0) result.error("SET_PACKETIZER_FAILED", "Failed to set H264 packetizer", null)
                else result.success(null)
            }
            "setOpusPacketizer" -> {
                val trId = call.argument<Int>("trId")!!
                val init = call.argument<Map<String, Any>>("init")
                val initJson = JSONObject(init ?: emptyMap<String, Any>()).toString()
                val ret = nativeSetOpusPacketizer(trId, initJson)
                if (ret < 0) result.error("SET_PACKETIZER_FAILED", "Failed to set Opus packetizer", null)
                else result.success(null)
            }
            "chainRtcpReceivingSession" -> {
                val ret = nativeChainRtcpReceivingSession(call.argument<Int>("trId")!!)
                if (ret < 0) result.error("CHAIN_FAILED", "Failed to chain RTCP receiving session", null)
                else result.success(null)
            }
            "chainRtcpSrReporter" -> {
                val ret = nativeChainRtcpSrReporter(call.argument<Int>("trId")!!)
                if (ret < 0) result.error("CHAIN_FAILED", "Failed to chain RTCP SR reporter", null)
                else result.success(null)
            }
            "startRecording" -> {
                val trId = call.argument<Int>("trId")!!
                val filePath = call.argument<String>("filePath")
                val codec = call.argument<Int>("codec") ?: 0
                val ret = nativeStartRecording(trId, filePath, codec)
                if (ret < 0) result.error("START_RECORDING_FAILED", "Failed to start recording", null)
                else result.success(null)
            }
            "stopRecording" -> {
                val trId = call.argument<Int>("trId")!!
                val ret = nativeStopRecording(trId)
                if (ret < 0) result.error("STOP_RECORDING_FAILED", "Failed to stop recording", null)
                else result.success(null)
            }
            "startPlayback" -> {
                val trId = call.argument<Int>("trId")!!
                val filePath = call.argument<String>("filePath")
                val speed = call.argument<Double>("speed") ?: 1.0
                val ret = nativeStartPlayback(trId, filePath, speed)
                if (ret < 0) result.error("START_PLAYBACK_FAILED", "Failed to start playback", null)
                else result.success(null)
            }
            "pausePlayback" -> {
                val ret = nativePausePlayback(call.argument<Int>("trId")!!)
                if (ret < 0) result.error("PAUSE_PLAYBACK_FAILED", "Failed to pause playback", null)
                else result.success(null)
            }
            "resumePlayback" -> {
                val ret = nativeResumePlayback(call.argument<Int>("trId")!!)
                if (ret < 0) result.error("RESUME_PLAYBACK_FAILED", "Failed to resume playback", null)
                else result.success(null)
            }
            "stopPlayback" -> {
                val ret = nativeStopPlayback(call.argument<Int>("trId")!!)
                if (ret < 0) result.error("STOP_PLAYBACK_FAILED", "Failed to stop playback", null)
                else result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        nativeSetEventHandler(null)
    }

    private fun jsonToMap(json: String): Map<String, Any> {
        val map = HashMap<String, Any>()
        try {
            val obj = JSONObject(json)
            for (key in obj.keys()) {
                map[key] = obj.get(key)
            }
        } catch (e: Exception) {
            // ignore parse errors
        }
        return map
    }
}
