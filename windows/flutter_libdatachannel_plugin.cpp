#include "flutter_libdatachannel_plugin.h"

#include <windows.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/encodable_value.h>

#include <rtc/rtc.h>

#include <memory>
#include <string>
#include <vector>
#include <mutex>


namespace flutter_libdatachannel {

namespace {

// Global plugin pointer for libdatachannel callbacks (only one instance exists).
FlutterLibdatachannelPlugin* g_plugin = nullptr;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

flutter::EncodableMap MakeEvent(const std::string& name) {
    flutter::EncodableMap m;
    m[flutter::EncodableValue("event")] = flutter::EncodableValue(name);
    return m;
}

std::string GetRtcString(int (*func)(int, char*, int), int id) {
    int needed = func(id, nullptr, 0);
    if (needed <= 0) return "";
    std::string buf(needed, '\0');
    if (func(id, &buf[0], needed) < 0) return "";
    while (!buf.empty() && buf.back() == '\0') buf.pop_back();
    return buf;
}

std::string GetStringArg(const flutter::EncodableMap& args, const std::string& key) {
    auto it = args.find(flutter::EncodableValue(key));
    if (it != args.end() && std::holds_alternative<std::string>(it->second)) {
        return std::get<std::string>(it->second);
    }
    return "";
}

int GetIntArg(const flutter::EncodableMap& args, const std::string& key, int default_val = 0) {
    auto it = args.find(flutter::EncodableValue(key));
    if (it != args.end()) {
        if (std::holds_alternative<int>(it->second))
            return std::get<int>(it->second);
        if (std::holds_alternative<int64_t>(it->second))
            return static_cast<int>(std::get<int64_t>(it->second));
    }
    return default_val;
}

uint32_t GetUint32Arg(const flutter::EncodableMap& args, const std::string& key, uint32_t default_val = 0) {
    auto it = args.find(flutter::EncodableValue(key));
    if (it != args.end()) {
        if (std::holds_alternative<int>(it->second))
            return static_cast<uint32_t>(std::get<int>(it->second));
        if (std::holds_alternative<int64_t>(it->second))
            return static_cast<uint32_t>(std::get<int64_t>(it->second));
    }
    return default_val;
}

flutter::EncodableMap GetMapArg(const flutter::EncodableMap& args, const std::string& key) {
    auto it = args.find(flutter::EncodableValue(key));
    if (it != args.end() && std::holds_alternative<flutter::EncodableMap>(it->second)) {
        return std::get<flutter::EncodableMap>(it->second);
    }
    return {};
}

std::vector<uint8_t> GetBytesArg(const flutter::EncodableMap& args, const std::string& key) {
    auto it = args.find(flutter::EncodableValue(key));
    if (it != args.end() && std::holds_alternative<std::vector<uint8_t>>(it->second)) {
        return std::get<std::vector<uint8_t>>(it->second);
    }
    return {};
}

// ---------------------------------------------------------------------------
// libdatachannel callbacks -- run on worker threads, enqueue EncodableMap
// ---------------------------------------------------------------------------

void OnLocalDescription(int pc, const char* sdp, const char* type, void*) {
    auto m = MakeEvent("onLocalDescription");
    m[flutter::EncodableValue("pcId")] = flutter::EncodableValue(pc);
    m[flutter::EncodableValue("sdp")]  = flutter::EncodableValue(std::string(sdp ? sdp : ""));
    m[flutter::EncodableValue("type")] = flutter::EncodableValue(std::string(type ? type : ""));
    if (g_plugin) g_plugin->EnqueueEvent(std::move(m));
}

void OnLocalCandidate(int pc, const char* cand, const char* mid, void*) {
    auto m = MakeEvent("onLocalCandidate");
    m[flutter::EncodableValue("pcId")]      = flutter::EncodableValue(pc);
    m[flutter::EncodableValue("candidate")] = flutter::EncodableValue(std::string(cand ? cand : ""));
    m[flutter::EncodableValue("mid")]       = flutter::EncodableValue(std::string(mid ? mid : ""));
    if (g_plugin) g_plugin->EnqueueEvent(std::move(m));
}

void OnStateChange(int pc, rtcState state, void*) {
    static const char* names[] = {"new","connecting","connected","disconnected","failed","closed"};
    const char* name = (state >= 0 && state <= 5) ? names[state] : "unknown";
    auto m = MakeEvent("onStateChange");
    m[flutter::EncodableValue("pcId")]  = flutter::EncodableValue(pc);
    m[flutter::EncodableValue("state")] = flutter::EncodableValue(std::string(name));
    if (g_plugin) g_plugin->EnqueueEvent(std::move(m));
}

void OnIceStateChange(int pc, rtcIceState state, void*) {
    static const char* names[] = {"new","checking","connected","completed","failed","disconnected","closed"};
    const char* name = (state >= 0 && state <= 6) ? names[state] : "unknown";
    auto m = MakeEvent("onIceStateChange");
    m[flutter::EncodableValue("pcId")]  = flutter::EncodableValue(pc);
    m[flutter::EncodableValue("state")] = flutter::EncodableValue(std::string(name));
    if (g_plugin) g_plugin->EnqueueEvent(std::move(m));
}

void OnGatheringStateChange(int pc, rtcGatheringState state, void*) {
    static const char* names[] = {"new","inprogress","complete"};
    const char* name = (state >= 0 && state <= 2) ? names[state] : "unknown";
    auto m = MakeEvent("onGatheringStateChange");
    m[flutter::EncodableValue("pcId")]  = flutter::EncodableValue(pc);
    m[flutter::EncodableValue("state")] = flutter::EncodableValue(std::string(name));
    if (g_plugin) g_plugin->EnqueueEvent(std::move(m));
}

void OnSignalingStateChange(int pc, rtcSignalingState state, void*) {
    static const char* names[] = {"stable","have-local-offer","have-remote-offer",
                                   "have-local-pranswer","have-remote-pranswer"};
    const char* name = (state >= 0 && state <= 4) ? names[state] : "unknown";
    auto m = MakeEvent("onSignalingStateChange");
    m[flutter::EncodableValue("pcId")]  = flutter::EncodableValue(pc);
    m[flutter::EncodableValue("state")] = flutter::EncodableValue(std::string(name));
    if (g_plugin) g_plugin->EnqueueEvent(std::move(m));
}

void SetupTrackCallbacks(int tr) {
    rtcSetOpenCallback(tr, [](int id, void*) {
        auto m = MakeEvent("onTrackOpen");
        m[flutter::EncodableValue("trId")] = flutter::EncodableValue(id);
        if (g_plugin) g_plugin->EnqueueEvent(std::move(m));
    });
    rtcSetClosedCallback(tr, [](int id, void*) {
        auto m = MakeEvent("onTrackClosed");
        m[flutter::EncodableValue("trId")] = flutter::EncodableValue(id);
        if (g_plugin) g_plugin->EnqueueEvent(std::move(m));
    });
    rtcSetErrorCallback(tr, [](int id, const char* error, void*) {
        auto m = MakeEvent("onTrackError");
        m[flutter::EncodableValue("trId")]  = flutter::EncodableValue(id);
        m[flutter::EncodableValue("error")] = flutter::EncodableValue(std::string(error ? error : ""));
        if (g_plugin) g_plugin->EnqueueEvent(std::move(m));
    });
    rtcSetMessageCallback(tr, [](int id, const char* message, int size, void*) {
        int actual = size >= 0 ? size : -size;
        auto m = MakeEvent("onTrackMessage");
        m[flutter::EncodableValue("trId")] = flutter::EncodableValue(id);
        m[flutter::EncodableValue("data")] = flutter::EncodableValue(
            std::vector<uint8_t>(reinterpret_cast<const uint8_t*>(message),
                                 reinterpret_cast<const uint8_t*>(message) + actual));
        if (g_plugin) g_plugin->EnqueueEvent(std::move(m));
    });
}

void OnTrack(int pc, int tr, void*) {
    std::string mid = GetRtcString(rtcGetTrackMid, tr);
    SetupTrackCallbacks(tr);

    auto m = MakeEvent("onTrack");
    m[flutter::EncodableValue("pcId")] = flutter::EncodableValue(pc);
    m[flutter::EncodableValue("trId")] = flutter::EncodableValue(tr);
    m[flutter::EncodableValue("mid")]  = flutter::EncodableValue(mid);
    if (g_plugin) g_plugin->EnqueueEvent(std::move(m));
}

// ---------------------------------------------------------------------------
// Parse track/packetizer init from EncodableMap (replaces JSON parsing)
// ---------------------------------------------------------------------------

rtcTrackInit ParseTrackInit(const flutter::EncodableMap& map,
                            std::string& mid_buf, std::string& name_buf,
                            std::string& msid_buf, std::string& track_id_buf,
                            std::string& profile_buf) {
    rtcTrackInit init = {};

    std::string dir = GetStringArg(map, "direction");
    if (dir == "sendonly")       init.direction = RTC_DIRECTION_SENDONLY;
    else if (dir == "recvonly")  init.direction = RTC_DIRECTION_RECVONLY;
    else if (dir == "sendrecv")  init.direction = RTC_DIRECTION_SENDRECV;
    else if (dir == "inactive")  init.direction = RTC_DIRECTION_INACTIVE;

    std::string codec = GetStringArg(map, "codec");
    if (codec == "h264")      init.codec = RTC_CODEC_H264;
    else if (codec == "vp8")  init.codec = RTC_CODEC_VP8;
    else if (codec == "vp9")  init.codec = RTC_CODEC_VP9;
    else if (codec == "h265") init.codec = RTC_CODEC_H265;
    else if (codec == "av1")  init.codec = RTC_CODEC_AV1;
    else if (codec == "opus") init.codec = RTC_CODEC_OPUS;
    else if (codec == "pcmu") init.codec = RTC_CODEC_PCMU;
    else if (codec == "pcma") init.codec = RTC_CODEC_PCMA;

    init.payloadType = GetIntArg(map, "payloadType", 96);
    init.ssrc = GetUint32Arg(map, "ssrc", 0);

    mid_buf      = GetStringArg(map, "mid");
    name_buf     = GetStringArg(map, "name");
    msid_buf     = GetStringArg(map, "msid");
    track_id_buf = GetStringArg(map, "trackId");
    profile_buf  = GetStringArg(map, "profile");

    init.mid     = mid_buf.empty()      ? nullptr : mid_buf.c_str();
    init.name    = name_buf.empty()      ? nullptr : name_buf.c_str();
    init.msid    = msid_buf.empty()      ? nullptr : msid_buf.c_str();
    init.trackId = track_id_buf.empty()  ? nullptr : track_id_buf.c_str();
    init.profile = profile_buf.empty()   ? nullptr : profile_buf.c_str();

    return init;
}

rtcPacketizerInit ParsePacketizerInit(const flutter::EncodableMap& map,
                                       std::string& cname_buf) {
    rtcPacketizerInit init = {};
    init.ssrc            = GetUint32Arg(map, "ssrc", 0);
    init.payloadType     = static_cast<uint8_t>(GetIntArg(map, "payloadType", 96));
    init.clockRate       = GetUint32Arg(map, "clockRate", 90000);
    init.sequenceNumber  = static_cast<uint16_t>(GetIntArg(map, "sequenceNumber", 0));
    init.timestamp       = GetUint32Arg(map, "timestamp", 0);
    init.maxFragmentSize = static_cast<uint16_t>(GetIntArg(map, "maxFragmentSize", 0));

    std::string nal_sep = GetStringArg(map, "nalSeparator");
    if (nal_sep == "length")             init.nalSeparator = RTC_NAL_SEPARATOR_LENGTH;
    else if (nal_sep == "longStartSequence")  init.nalSeparator = RTC_NAL_SEPARATOR_LONG_START_SEQUENCE;
    else if (nal_sep == "shortStartSequence") init.nalSeparator = RTC_NAL_SEPARATOR_SHORT_START_SEQUENCE;
    else if (nal_sep == "startSequence")      init.nalSeparator = RTC_NAL_SEPARATOR_START_SEQUENCE;

    cname_buf = GetStringArg(map, "cname");
    init.cname = cname_buf.empty() ? nullptr : cname_buf.c_str();

    return init;
}

} // anonymous namespace

// ---------------------------------------------------------------------------
// Plugin lifecycle
// ---------------------------------------------------------------------------

// static
void FlutterLibdatachannelPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "flutter_libdatachannel",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<FlutterLibdatachannelPlugin>(registrar);

  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto &call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  registrar->AddPlugin(std::move(plugin));
}

LRESULT CALLBACK FlutterLibdatachannelPlugin::DrainWndProc(
    HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  if (msg == kDrainMessage) {
    auto* self = reinterpret_cast<FlutterLibdatachannelPlugin*>(
        GetWindowLongPtr(hwnd, GWLP_USERDATA));
    if (self) self->DrainEventQueue();
    return 0;
  }
  return DefWindowProc(hwnd, msg, wp, lp);
}

FlutterLibdatachannelPlugin::FlutterLibdatachannelPlugin(
    flutter::PluginRegistrarWindows *registrar) : registrar_(registrar) {
  g_plugin = this;
  rtcInitLogger(RTC_LOG_WARNING, nullptr);
  rtcPreload();

  // Create a hidden message-only window for thread marshalling.
  // Worker threads PostMessage to this window; the platform thread's
  // message loop dispatches to DrainWndProc which drains the event queue.
  static bool wc_registered = false;
  if (!wc_registered) {
    WNDCLASSW wc = {};
    wc.lpfnWndProc = DrainWndProc;
    wc.lpszClassName = L"FlutterLdcDrain";
    wc.hInstance = GetModuleHandle(nullptr);
    RegisterClassW(&wc);
    wc_registered = true;
  }
  hwnd_ = CreateWindowExW(0, L"FlutterLdcDrain", L"", 0,
                           0, 0, 0, 0, HWND_MESSAGE,
                           nullptr, GetModuleHandle(nullptr), nullptr);
  SetWindowLongPtr(hwnd_, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));

  SetupEventChannel(registrar);
}

FlutterLibdatachannelPlugin::~FlutterLibdatachannelPlugin() {
  if (hwnd_) {
    DestroyWindow(hwnd_);
    hwnd_ = nullptr;
  }

  rtcCleanup();
  g_plugin = nullptr;
}

// ---------------------------------------------------------------------------
// Event queue (thread-safe enqueue from workers, drain on platform thread)
// ---------------------------------------------------------------------------

void FlutterLibdatachannelPlugin::EnqueueEvent(flutter::EncodableMap map) {
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    event_queue_.push(std::move(map));
  }
  PostMessage(hwnd_, kDrainMessage, 0, 0);
}

void FlutterLibdatachannelPlugin::DrainEventQueue() {
  std::queue<flutter::EncodableMap> batch;
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    batch.swap(event_queue_);
  }

  std::lock_guard<std::mutex> lock(sink_mutex_);
  if (!event_sink_) return;

  while (!batch.empty()) {
    event_sink_->Success(flutter::EncodableValue(std::move(batch.front())));
    batch.pop();
  }
}

void FlutterLibdatachannelPlugin::SetupEventChannel(
    flutter::PluginRegistrarWindows *registrar) {
  event_channel_ = std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
      registrar->messenger(), "flutter_libdatachannel/events",
      &flutter::StandardMethodCodec::GetInstance());

  auto handler = std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
      [this](const flutter::EncodableValue* arguments,
             std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events)
          -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
        std::lock_guard<std::mutex> lock(sink_mutex_);
        event_sink_ = std::move(events);
        return nullptr;
      },
      [this](const flutter::EncodableValue* arguments)
          -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
        std::lock_guard<std::mutex> lock(sink_mutex_);
        event_sink_ = nullptr;
        return nullptr;
      });

  event_channel_->SetStreamHandler(std::move(handler));
}

// ---------------------------------------------------------------------------
// Method call handler -- calls rtc* functions directly
// ---------------------------------------------------------------------------

void FlutterLibdatachannelPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {

  const auto& method = method_call.method_name();
  const auto* args_value = method_call.arguments();
  flutter::EncodableMap args;
  if (args_value && std::holds_alternative<flutter::EncodableMap>(*args_value)) {
    args = std::get<flutter::EncodableMap>(*args_value);
  }

  if (method == "createPeerConnection") {
    // Read ice servers from Dart List<String>
    rtcConfiguration config = {};
    std::vector<std::string> server_strs;
    std::vector<const char*> server_ptrs;
    auto it = args.find(flutter::EncodableValue("iceServers"));
    if (it != args.end() && std::holds_alternative<flutter::EncodableList>(it->second)) {
      for (auto& v : std::get<flutter::EncodableList>(it->second)) {
        if (std::holds_alternative<std::string>(v)) {
          server_strs.push_back(std::get<std::string>(v));
        }
      }
    }
    for (auto& s : server_strs) server_ptrs.push_back(s.c_str());
    config.iceServers = server_ptrs.data();
    config.iceServersCount = static_cast<int>(server_ptrs.size());
    config.disableAutoNegotiation = GetIntArg(args, "disableAutoNegotiation", 1) ? true : false;
    config.forceMediaTransport = true;

    int pc = rtcCreatePeerConnection(&config);
    if (pc < 0) {
      result->Error("CREATE_FAILED", "Failed to create peer connection");
      return;
    }

    rtcSetLocalDescriptionCallback(pc, OnLocalDescription);
    rtcSetLocalCandidateCallback(pc, OnLocalCandidate);
    rtcSetStateChangeCallback(pc, OnStateChange);
    rtcSetIceStateChangeCallback(pc, OnIceStateChange);
    rtcSetGatheringStateChangeCallback(pc, OnGatheringStateChange);
    rtcSetSignalingStateChangeCallback(pc, OnSignalingStateChange);
    rtcSetTrackCallback(pc, OnTrack);

    result->Success(flutter::EncodableValue(pc));

  } else if (method == "closePeerConnection") {
    rtcClosePeerConnection(GetIntArg(args, "pcId"));
    result->Success();

  } else if (method == "deletePeerConnection") {
    rtcDeletePeerConnection(GetIntArg(args, "pcId"));
    result->Success();

  } else if (method == "setLocalDescription") {
    int pc_id = GetIntArg(args, "pcId");
    std::string type = GetStringArg(args, "type");
    int ret = rtcSetLocalDescription(pc_id, type.empty() ? nullptr : type.c_str());
    if (ret < 0) {
      result->Error("SET_LOCAL_DESC_FAILED", "Failed to set local description");
    } else {
      result->Success();
    }

  } else if (method == "setRemoteDescription") {
    int pc_id = GetIntArg(args, "pcId");
    std::string sdp = GetStringArg(args, "sdp");
    std::string type = GetStringArg(args, "type");
    int ret = rtcSetRemoteDescription(pc_id, sdp.c_str(), type.c_str());
    if (ret < 0) {
      result->Error("SET_REMOTE_DESC_FAILED", "Failed to set remote description");
    } else {
      result->Success();
    }

  } else if (method == "addRemoteCandidate") {
    int pc_id = GetIntArg(args, "pcId");
    std::string candidate = GetStringArg(args, "candidate");
    std::string mid = GetStringArg(args, "mid");
    int ret = rtcAddRemoteCandidate(pc_id, candidate.c_str(),
                                     mid.empty() ? nullptr : mid.c_str());
    if (ret < 0) {
      result->Error("ADD_CANDIDATE_FAILED", "Failed to add remote candidate");
    } else {
      result->Success();
    }

  } else if (method == "getLocalDescription") {
    int pc_id = GetIntArg(args, "pcId");
    std::string sdp  = GetRtcString(rtcGetLocalDescription, pc_id);
    std::string type = GetRtcString(rtcGetLocalDescriptionType, pc_id);
    flutter::EncodableMap desc;
    desc[flutter::EncodableValue("sdp")]  = flutter::EncodableValue(sdp);
    desc[flutter::EncodableValue("type")] = flutter::EncodableValue(type);
    result->Success(flutter::EncodableValue(desc));

  } else if (method == "getRemoteDescription") {
    int pc_id = GetIntArg(args, "pcId");
    std::string sdp  = GetRtcString(rtcGetRemoteDescription, pc_id);
    std::string type = GetRtcString(rtcGetRemoteDescriptionType, pc_id);
    flutter::EncodableMap desc;
    desc[flutter::EncodableValue("sdp")]  = flutter::EncodableValue(sdp);
    desc[flutter::EncodableValue("type")] = flutter::EncodableValue(type);
    result->Success(flutter::EncodableValue(desc));

  } else if (method == "addTrack") {
    int pc_id = GetIntArg(args, "pcId");
    auto init_map = GetMapArg(args, "init");
    std::string mid_buf, name_buf, msid_buf, track_id_buf, profile_buf;
    rtcTrackInit init = ParseTrackInit(init_map, mid_buf, name_buf,
                                       msid_buf, track_id_buf, profile_buf);
    int tr = rtcAddTrackEx(pc_id, &init);
    if (tr < 0) {
      result->Error("ADD_TRACK_FAILED", "Failed to add track");
    } else {
      SetupTrackCallbacks(tr);
      result->Success(flutter::EncodableValue(tr));
    }

  } else if (method == "deleteTrack") {
    rtcDeleteTrack(GetIntArg(args, "trId"));
    result->Success();

  } else if (method == "sendTrackMessage") {
    int tr_id = GetIntArg(args, "trId");
    auto data = GetBytesArg(args, "data");
    if (data.empty()) {
      result->Error("INVALID_DATA", "No data provided");
    } else {
      int ret = rtcSendMessage(tr_id, reinterpret_cast<const char*>(data.data()),
                                static_cast<int>(data.size()));
      if (ret < 0) {
        result->Error("SEND_FAILED", "Failed to send track message");
      } else {
        result->Success();
      }
    }

  } else if (method == "setH264Packetizer") {
    int tr_id = GetIntArg(args, "trId");
    auto init_map = GetMapArg(args, "init");
    std::string cname_buf;
    rtcPacketizerInit init = ParsePacketizerInit(init_map, cname_buf);
    if (!init.cname) init.cname = "video";
    int ret = rtcSetH264Packetizer(tr_id, &init);
    if (ret < 0) {
      result->Error("SET_PACKETIZER_FAILED", "Failed to set H264 packetizer");
    } else {
      result->Success();
    }

  } else if (method == "setOpusPacketizer") {
    int tr_id = GetIntArg(args, "trId");
    auto init_map = GetMapArg(args, "init");
    std::string cname_buf;
    rtcPacketizerInit init = ParsePacketizerInit(init_map, cname_buf);
    if (init.clockRate == 90000) init.clockRate = 48000;
    if (!init.cname) init.cname = "audio";
    int ret = rtcSetOpusPacketizer(tr_id, &init);
    if (ret < 0) {
      result->Error("SET_PACKETIZER_FAILED", "Failed to set Opus packetizer");
    } else {
      result->Success();
    }

  } else if (method == "chainRtcpReceivingSession") {
    int ret = rtcChainRtcpReceivingSession(GetIntArg(args, "trId"));
    if (ret < 0) {
      result->Error("CHAIN_FAILED", "Failed to chain RTCP receiving session");
    } else {
      result->Success();
    }

  } else if (method == "chainRtcpSrReporter") {
    int ret = rtcChainRtcpSrReporter(GetIntArg(args, "trId"));
    if (ret < 0) {
      result->Error("CHAIN_FAILED", "Failed to chain RTCP SR reporter");
    } else {
      result->Success();
    }

  } else {
    result->NotImplemented();
  }
}

}  // namespace flutter_libdatachannel
