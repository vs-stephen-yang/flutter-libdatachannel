#include "flutter_libdatachannel_plugin.h"

#include <windows.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/encodable_value.h>

#include <memory>
#include <string>
#include <sstream>
#include <vector>
#include <mutex>
#include <functional>

#include "flutter_libdatachannel.h"

// Simple JSON parser to extract values for event forwarding
#include <climits>
#include <cstdlib>
#include <cstring>

namespace flutter_libdatachannel {

namespace {

// Parse a JSON string to EncodableMap for event forwarding
// Handles: {"event":"...", "pcId":N, "sdp":"...", "type":"...", ...}
flutter::EncodableMap ParseEventJson(const std::string& json) {
    flutter::EncodableMap result;

    size_t pos = 0;
    while (pos < json.size()) {
        // Find key
        auto key_start = json.find('"', pos);
        if (key_start == std::string::npos) break;
        key_start++;
        auto key_end = json.find('"', key_start);
        if (key_end == std::string::npos) break;
        std::string key = json.substr(key_start, key_end - key_start);

        // Find colon
        pos = json.find(':', key_end + 1);
        if (pos == std::string::npos) break;
        pos++;

        // Skip whitespace
        while (pos < json.size() && (json[pos] == ' ' || json[pos] == '\t')) pos++;

        if (pos >= json.size()) break;

        if (json[pos] == '"') {
            // String value
            pos++; // skip opening quote
            std::string value;
            while (pos < json.size() && json[pos] != '"') {
                if (json[pos] == '\\' && pos + 1 < json.size()) {
                    pos++;
                    switch (json[pos]) {
                        case '"': value += '"'; break;
                        case '\\': value += '\\'; break;
                        case 'n': value += '\n'; break;
                        case 'r': value += '\r'; break;
                        case 't': value += '\t'; break;
                        default: value += json[pos]; break;
                    }
                } else {
                    value += json[pos];
                }
                pos++;
            }
            if (pos < json.size()) pos++; // skip closing quote
            result[flutter::EncodableValue(key)] = flutter::EncodableValue(value);
        } else if (json[pos] == '-' || (json[pos] >= '0' && json[pos] <= '9')) {
            // Number value
            auto num_start = pos;
            bool is_float = false;
            while (pos < json.size() && (json[pos] == '-' || json[pos] == '.' ||
                   (json[pos] >= '0' && json[pos] <= '9'))) {
                if (json[pos] == '.') is_float = true;
                pos++;
            }
            std::string num_str = json.substr(num_start, pos - num_start);
            if (is_float) {
                result[flutter::EncodableValue(key)] = flutter::EncodableValue(std::stod(num_str));
            } else {
                char* end = nullptr;
                long val = strtol(num_str.c_str(), &end, 10);
                if (val > INT_MAX || val < INT_MIN) {
                    result[flutter::EncodableValue(key)] = flutter::EncodableValue(static_cast<int64_t>(val));
                } else {
                    result[flutter::EncodableValue(key)] = flutter::EncodableValue(static_cast<int>(val));
                }
            }
        } else if (json.compare(pos, 4, "true") == 0) {
            result[flutter::EncodableValue(key)] = flutter::EncodableValue(true);
            pos += 4;
        } else if (json.compare(pos, 5, "false") == 0) {
            result[flutter::EncodableValue(key)] = flutter::EncodableValue(false);
            pos += 5;
        } else if (json.compare(pos, 4, "null") == 0) {
            result[flutter::EncodableValue(key)] = flutter::EncodableValue(std::monostate{});
            pos += 4;
        } else {
            // Skip unknown values
            while (pos < json.size() && json[pos] != ',' && json[pos] != '}') pos++;
        }
    }

    return result;
}

// Helper to get string from EncodableValue map args
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
        if (std::holds_alternative<int>(it->second)) {
            return std::get<int>(it->second);
        }
        if (std::holds_alternative<int64_t>(it->second)) {
            return static_cast<int>(std::get<int64_t>(it->second));
        }
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

// Convert an EncodableMap to a JSON string (for passing to the C core)
std::string MapToJson(const flutter::EncodableMap& map) {
    std::ostringstream ss;
    ss << "{";
    bool first = true;
    for (auto& [k, v] : map) {
        if (!first) ss << ",";
        first = false;
        if (std::holds_alternative<std::string>(k)) {
            ss << "\"" << std::get<std::string>(k) << "\":";
        }
        if (std::holds_alternative<std::string>(v)) {
            // Escape the string
            ss << "\"";
            for (char c : std::get<std::string>(v)) {
                switch (c) {
                    case '"': ss << "\\\""; break;
                    case '\\': ss << "\\\\"; break;
                    case '\n': ss << "\\n"; break;
                    case '\r': ss << "\\r"; break;
                    case '\t': ss << "\\t"; break;
                    default: ss << c; break;
                }
            }
            ss << "\"";
        } else if (std::holds_alternative<int>(v)) {
            ss << std::get<int>(v);
        } else if (std::holds_alternative<int64_t>(v)) {
            ss << std::get<int64_t>(v);
        } else if (std::holds_alternative<double>(v)) {
            ss << std::get<double>(v);
        } else if (std::holds_alternative<bool>(v)) {
            ss << (std::get<bool>(v) ? "true" : "false");
        } else if (std::holds_alternative<std::monostate>(v)) {
            ss << "null";
        }
    }
    ss << "}";
    return ss.str();
}

} // anonymous namespace

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

FlutterLibdatachannelPlugin::FlutterLibdatachannelPlugin(
    flutter::PluginRegistrarWindows *registrar) : registrar_(registrar) {
  ldc_init();

  // Obtain the platform HWND for PostMessage-based thread marshalling
  hwnd_ = registrar->GetView()->GetNativeWindow();

  SetupEventChannel(registrar);
}

FlutterLibdatachannelPlugin::~FlutterLibdatachannelPlugin() {
  ldc_set_event_callback(nullptr, nullptr);
  ldc_set_binary_event_callback(nullptr, nullptr);

  if (window_proc_delegate_id_ != 0) {
    registrar_->UnregisterTopLevelWindowProcDelegate(window_proc_delegate_id_);
    window_proc_delegate_id_ = 0;
  }

  ldc_cleanup();
}

void FlutterLibdatachannelPlugin::DrainEventQueue() {
  // Swap the queue under lock so we hold the lock only briefly
  std::queue<PendingEvent> batch;
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    batch.swap(event_queue_);
  }

  // Now deliver events on the platform thread (no lock needed for sink_mutex_
  // since we are already on the platform thread, but take it for safety in
  // case the stream handler cancels concurrently).
  std::lock_guard<std::mutex> lock(sink_mutex_);
  if (!event_sink_) return;

  while (!batch.empty()) {
    auto& ev = batch.front();
    if (ev.kind == PendingEvent::Kind::Json) {
      auto map = ParseEventJson(ev.json);
      event_sink_->Success(flutter::EncodableValue(map));
    } else {
      flutter::EncodableMap map;
      map[flutter::EncodableValue("event")] = flutter::EncodableValue("onTrackMessage");
      map[flutter::EncodableValue("trId")] = flutter::EncodableValue(ev.tr_id);
      map[flutter::EncodableValue("data")] = flutter::EncodableValue(std::move(ev.data));
      event_sink_->Success(flutter::EncodableValue(map));
    }
    batch.pop();
  }
}

void FlutterLibdatachannelPlugin::SetupEventChannel(
    flutter::PluginRegistrarWindows *registrar) {
  event_channel_ = std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
      registrar->messenger(), "flutter_libdatachannel/events",
      &flutter::StandardMethodCodec::GetInstance());

  // Register a window proc delegate to handle our custom drain message
  window_proc_delegate_id_ = registrar->RegisterTopLevelWindowProcDelegate(
      [this](HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) -> std::optional<LRESULT> {
        if (msg == kDrainMessage) {
          DrainEventQueue();
          return 0;
        }
        return std::nullopt;
      });

  auto handler = std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
      [this](const flutter::EncodableValue* arguments,
             std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events)
          -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
        {
          std::lock_guard<std::mutex> lock(sink_mutex_);
          event_sink_ = std::move(events);
        }

        // Set up the native event callback — pushes to queue + PostMessage
        ldc_set_event_callback([](const char* event_json, void* user_data) {
            auto* self = static_cast<FlutterLibdatachannelPlugin*>(user_data);
            PendingEvent ev;
            ev.kind = PendingEvent::Kind::Json;
            ev.json = event_json;
            {
              std::lock_guard<std::mutex> lock(self->queue_mutex_);
              self->event_queue_.push(std::move(ev));
            }
            PostMessage(self->hwnd_, kDrainMessage, 0, 0);
        }, this);

        // Set up binary event callback — pushes to queue + PostMessage
        ldc_set_binary_event_callback([](int tr_id, const uint8_t* data, int size, void* user_data) {
            auto* self = static_cast<FlutterLibdatachannelPlugin*>(user_data);
            PendingEvent ev;
            ev.kind = PendingEvent::Kind::Binary;
            ev.tr_id = tr_id;
            ev.data.assign(data, data + size);
            {
              std::lock_guard<std::mutex> lock(self->queue_mutex_);
              self->event_queue_.push(std::move(ev));
            }
            PostMessage(self->hwnd_, kDrainMessage, 0, 0);
        }, this);

        return nullptr;
      },
      [this](const flutter::EncodableValue* arguments)
          -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
        ldc_set_event_callback(nullptr, nullptr);
        ldc_set_binary_event_callback(nullptr, nullptr);
        std::lock_guard<std::mutex> lock(sink_mutex_);
        event_sink_ = nullptr;
        return nullptr;
      });

  event_channel_->SetStreamHandler(std::move(handler));
}

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
    std::string ice_servers = GetStringArg(args, "iceServers");
    int pc_id = ldc_create_peer_connection(ice_servers.empty() ? nullptr : ice_servers.c_str());
    if (pc_id < 0) {
      result->Error("CREATE_FAILED", "Failed to create peer connection");
    } else {
      result->Success(flutter::EncodableValue(pc_id));
    }
  } else if (method == "closePeerConnection") {
    int pc_id = GetIntArg(args, "pcId");
    ldc_close_peer_connection(pc_id);
    result->Success();
  } else if (method == "deletePeerConnection") {
    int pc_id = GetIntArg(args, "pcId");
    ldc_delete_peer_connection(pc_id);
    result->Success();
  } else if (method == "setLocalDescription") {
    int pc_id = GetIntArg(args, "pcId");
    std::string type = GetStringArg(args, "type");
    int ret = ldc_set_local_description(pc_id, type.empty() ? nullptr : type.c_str());
    if (ret < 0) {
      result->Error("SET_LOCAL_DESC_FAILED", "Failed to set local description");
    } else {
      result->Success();
    }
  } else if (method == "setRemoteDescription") {
    int pc_id = GetIntArg(args, "pcId");
    std::string sdp = GetStringArg(args, "sdp");
    std::string type = GetStringArg(args, "type");
    int ret = ldc_set_remote_description(pc_id, sdp.c_str(), type.c_str());
    if (ret < 0) {
      result->Error("SET_REMOTE_DESC_FAILED", "Failed to set remote description");
    } else {
      result->Success();
    }
  } else if (method == "addRemoteCandidate") {
    int pc_id = GetIntArg(args, "pcId");
    std::string candidate = GetStringArg(args, "candidate");
    std::string mid = GetStringArg(args, "mid");
    int ret = ldc_add_remote_candidate(pc_id, candidate.c_str(),
                                        mid.empty() ? nullptr : mid.c_str());
    if (ret < 0) {
      result->Error("ADD_CANDIDATE_FAILED", "Failed to add remote candidate");
    } else {
      result->Success();
    }
  } else if (method == "getLocalDescription") {
    int pc_id = GetIntArg(args, "pcId");
    char* sdp = ldc_get_local_description(pc_id);
    char* type = ldc_get_local_description_type(pc_id);
    flutter::EncodableMap desc;
    desc[flutter::EncodableValue("sdp")] = flutter::EncodableValue(sdp ? std::string(sdp) : "");
    desc[flutter::EncodableValue("type")] = flutter::EncodableValue(type ? std::string(type) : "");
    if (sdp) ldc_free(sdp);
    if (type) ldc_free(type);
    result->Success(flutter::EncodableValue(desc));
  } else if (method == "getRemoteDescription") {
    int pc_id = GetIntArg(args, "pcId");
    char* sdp = ldc_get_remote_description(pc_id);
    char* type = ldc_get_remote_description_type(pc_id);
    flutter::EncodableMap desc;
    desc[flutter::EncodableValue("sdp")] = flutter::EncodableValue(sdp ? std::string(sdp) : "");
    desc[flutter::EncodableValue("type")] = flutter::EncodableValue(type ? std::string(type) : "");
    if (sdp) ldc_free(sdp);
    if (type) ldc_free(type);
    result->Success(flutter::EncodableValue(desc));
  } else if (method == "addTrack") {
    int pc_id = GetIntArg(args, "pcId");
    auto init_map = GetMapArg(args, "init");
    std::string init_json = MapToJson(init_map);
    int tr_id = ldc_add_track(pc_id, init_json.c_str());
    if (tr_id < 0) {
      result->Error("ADD_TRACK_FAILED", "Failed to add track");
    } else {
      result->Success(flutter::EncodableValue(tr_id));
    }
  } else if (method == "deleteTrack") {
    int tr_id = GetIntArg(args, "trId");
    ldc_delete_track(tr_id);
    result->Success();
  } else if (method == "sendTrackMessage") {
    int tr_id = GetIntArg(args, "trId");
    auto data = GetBytesArg(args, "data");
    if (data.empty()) {
      result->Error("INVALID_DATA", "No data provided");
    } else {
      int ret = ldc_send_track_message(tr_id, data.data(), static_cast<int>(data.size()));
      if (ret < 0) {
        result->Error("SEND_FAILED", "Failed to send track message");
      } else {
        result->Success();
      }
    }
  } else if (method == "setH264Packetizer") {
    int tr_id = GetIntArg(args, "trId");
    auto init_map = GetMapArg(args, "init");
    std::string init_json = MapToJson(init_map);
    int ret = ldc_set_h264_packetizer(tr_id, init_json.c_str());
    if (ret < 0) {
      result->Error("SET_PACKETIZER_FAILED", "Failed to set H264 packetizer");
    } else {
      result->Success();
    }
  } else if (method == "setOpusPacketizer") {
    int tr_id = GetIntArg(args, "trId");
    auto init_map = GetMapArg(args, "init");
    std::string init_json = MapToJson(init_map);
    int ret = ldc_set_opus_packetizer(tr_id, init_json.c_str());
    if (ret < 0) {
      result->Error("SET_PACKETIZER_FAILED", "Failed to set Opus packetizer");
    } else {
      result->Success();
    }
  } else if (method == "chainRtcpReceivingSession") {
    int tr_id = GetIntArg(args, "trId");
    int ret = ldc_chain_rtcp_receiving_session(tr_id);
    if (ret < 0) {
      result->Error("CHAIN_FAILED", "Failed to chain RTCP receiving session");
    } else {
      result->Success();
    }
  } else if (method == "chainRtcpSrReporter") {
    int tr_id = GetIntArg(args, "trId");
    int ret = ldc_chain_rtcp_sr_reporter(tr_id);
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
