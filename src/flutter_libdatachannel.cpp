#include "flutter_libdatachannel.h"
#include <rtc/rtc.h>

#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <sstream>

// MSVC deprecates strdup in favor of _strdup
#ifdef _MSC_VER
#define portable_strdup _strdup
#else
#define portable_strdup strdup
#endif

// Simple JSON helpers (avoid pulling in a full JSON library for the native core)
namespace {

struct CallbackState {
    ldc_event_callback event_cb = nullptr;
    ldc_binary_event_callback binary_cb = nullptr;
    void* user_data = nullptr;
    std::mutex mutex;
};

static CallbackState g_state;

void fire_event(const std::string& json) {
    std::lock_guard<std::mutex> lock(g_state.mutex);
    if (g_state.event_cb) {
        g_state.event_cb(json.c_str(), g_state.user_data);
    }
}

void fire_binary_event(int tr_id, const uint8_t* data, int size) {
    std::lock_guard<std::mutex> lock(g_state.mutex);
    if (g_state.binary_cb) {
        g_state.binary_cb(tr_id, data, size, g_state.user_data);
    }
}

std::string escape_json_string(const std::string& s) {
    std::string out;
    out.reserve(s.size() + 16);
    for (char c : s) {
        switch (c) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:   out += c; break;
        }
    }
    return out;
}

std::string get_string_from_rtc(int (*func)(int, char*, int), int id) {
    int needed = func(id, nullptr, 0);
    if (needed <= 0) return "";
    std::string buf(needed, '\0');
    int ret = func(id, &buf[0], needed);
    if (ret < 0) return "";
    // Remove trailing null if any
    while (!buf.empty() && buf.back() == '\0') buf.pop_back();
    return buf;
}

char* strdup_export(const std::string& s) {
    if (s.empty()) return nullptr;
    char* p = (char*)malloc(s.size() + 1);
    if (p) {
        memcpy(p, s.c_str(), s.size() + 1);
    }
    return p;
}

// Simple JSON object parser for specific keys
// Parses {"key":"value", ...} format - only handles string and int values
std::string json_get_string(const std::string& json, const std::string& key) {
    std::string needle = "\"" + key + "\"";
    auto pos = json.find(needle);
    if (pos == std::string::npos) return "";
    pos = json.find(':', pos + needle.size());
    if (pos == std::string::npos) return "";
    pos = json.find('"', pos + 1);
    if (pos == std::string::npos) return "";
    pos++; // skip opening quote
    std::string result;
    while (pos < json.size() && json[pos] != '"') {
        if (json[pos] == '\\' && pos + 1 < json.size()) {
            pos++;
            switch (json[pos]) {
                case '"': result += '"'; break;
                case '\\': result += '\\'; break;
                case 'n': result += '\n'; break;
                case 'r': result += '\r'; break;
                case 't': result += '\t'; break;
                default: result += json[pos]; break;
            }
        } else {
            result += json[pos];
        }
        pos++;
    }
    return result;
}

int json_get_int(const std::string& json, const std::string& key, int default_val = 0) {
    std::string needle = "\"" + key + "\"";
    auto pos = json.find(needle);
    if (pos == std::string::npos) return default_val;
    pos = json.find(':', pos + needle.size());
    if (pos == std::string::npos) return default_val;
    pos++; // skip colon
    while (pos < json.size() && (json[pos] == ' ' || json[pos] == '\t')) pos++;
    return atoi(json.c_str() + pos);
}

uint32_t json_get_uint32(const std::string& json, const std::string& key, uint32_t default_val = 0) {
    std::string needle = "\"" + key + "\"";
    auto pos = json.find(needle);
    if (pos == std::string::npos) return default_val;
    pos = json.find(':', pos + needle.size());
    if (pos == std::string::npos) return default_val;
    pos++;
    while (pos < json.size() && (json[pos] == ' ' || json[pos] == '\t')) pos++;
    return (uint32_t)strtoul(json.c_str() + pos, nullptr, 10);
}

// Parse a JSON array of strings: ["stun:...", "turn:..."]
// Returns count, fills pointers array
int parse_ice_servers(const std::string& json, const char** out, int max_count) {
    int count = 0;
    // Find the array
    auto pos = json.find('[');
    if (pos == std::string::npos) return 0;
    pos++;
    while (pos < json.size() && count < max_count) {
        pos = json.find('"', pos);
        if (pos == std::string::npos) break;
        pos++; // skip quote
        auto end = json.find('"', pos);
        if (end == std::string::npos) break;
        // We need persistent storage - use strdup
        std::string server = json.substr(pos, end - pos);
        out[count] = portable_strdup(server.c_str());
        count++;
        pos = end + 1;
    }
    return count;
}

// Callbacks from libdatachannel
void on_local_description(int pc, const char* sdp, const char* type, void* ptr) {
    (void)ptr;
    std::string sdp_copy(sdp ? sdp : "");
    std::string type_copy(type ? type : "");
    std::ostringstream json;
    json << "{\"event\":\"onLocalDescription\",\"pcId\":" << pc
         << ",\"sdp\":\"" << escape_json_string(sdp_copy)
         << "\",\"type\":\"" << escape_json_string(type_copy) << "\"}";
    fire_event(json.str());
}

void on_local_candidate(int pc, const char* cand, const char* mid, void* ptr) {
    (void)ptr;
    std::string cand_copy(cand ? cand : "");
    std::string mid_copy(mid ? mid : "");
    std::ostringstream json;
    json << "{\"event\":\"onLocalCandidate\",\"pcId\":" << pc
         << ",\"candidate\":\"" << escape_json_string(cand_copy)
         << "\",\"mid\":\"" << escape_json_string(mid_copy) << "\"}";
    fire_event(json.str());
}

void on_state_change(int pc, rtcState state, void* ptr) {
    (void)ptr;
    static const char* names[] = {"new", "connecting", "connected", "disconnected", "failed", "closed"};
    const char* name = (state >= 0 && state <= 5) ? names[state] : "unknown";
    std::ostringstream json;
    json << "{\"event\":\"onStateChange\",\"pcId\":" << pc
         << ",\"state\":\"" << name << "\"}";
    fire_event(json.str());
}

void on_ice_state_change(int pc, rtcIceState state, void* ptr) {
    (void)ptr;
    static const char* names[] = {"new", "checking", "connected", "completed", "failed", "disconnected", "closed"};
    const char* name = (state >= 0 && state <= 6) ? names[state] : "unknown";
    std::ostringstream json;
    json << "{\"event\":\"onIceStateChange\",\"pcId\":" << pc
         << ",\"state\":\"" << name << "\"}";
    fire_event(json.str());
}

void on_gathering_state_change(int pc, rtcGatheringState state, void* ptr) {
    (void)ptr;
    static const char* names[] = {"new", "inprogress", "complete"};
    const char* name = (state >= 0 && state <= 2) ? names[state] : "unknown";
    std::ostringstream json;
    json << "{\"event\":\"onGatheringStateChange\",\"pcId\":" << pc
         << ",\"state\":\"" << name << "\"}";
    fire_event(json.str());
}

void on_signaling_state_change(int pc, rtcSignalingState state, void* ptr) {
    (void)ptr;
    static const char* names[] = {"stable", "have-local-offer", "have-remote-offer",
                                   "have-local-pranswer", "have-remote-pranswer"};
    const char* name = (state >= 0 && state <= 4) ? names[state] : "unknown";
    std::ostringstream json;
    json << "{\"event\":\"onSignalingStateChange\",\"pcId\":" << pc
         << ",\"state\":\"" << name << "\"}";
    fire_event(json.str());
}

void setup_track_callbacks(int tr) {
    rtcSetOpenCallback(tr, [](int id, void* p) {
        (void)p;
        std::ostringstream json;
        json << "{\"event\":\"onTrackOpen\",\"trId\":" << id << "}";
        fire_event(json.str());
    });
    rtcSetClosedCallback(tr, [](int id, void* p) {
        (void)p;
        std::ostringstream json;
        json << "{\"event\":\"onTrackClosed\",\"trId\":" << id << "}";
        fire_event(json.str());
    });
    rtcSetErrorCallback(tr, [](int id, const char* error, void* p) {
        (void)p;
        std::string err_copy(error ? error : "");
        std::ostringstream json;
        json << "{\"event\":\"onTrackError\",\"trId\":" << id
             << ",\"error\":\"" << escape_json_string(err_copy) << "\"}";
        fire_event(json.str());
    });
    rtcSetMessageCallback(tr, [](int id, const char* message, int size, void* p) {
        (void)p;
        if (size > 0) {
            fire_binary_event(id, reinterpret_cast<const uint8_t*>(message), size);
        }
    });
}

void on_track(int pc, int tr, void* ptr) {
    (void)ptr;
    std::string mid = get_string_from_rtc(rtcGetTrackMid, tr);

    setup_track_callbacks(tr);

    std::ostringstream json;
    json << "{\"event\":\"onTrack\",\"pcId\":" << pc
         << ",\"trId\":" << tr
         << ",\"mid\":\"" << escape_json_string(mid) << "\"}";
    fire_event(json.str());
}

} // anonymous namespace

// Public API implementation

void ldc_init(void) {
    rtcInitLogger(RTC_LOG_WARNING, nullptr);
    rtcPreload();
}

void ldc_cleanup(void) {
    rtcCleanup();
}

void ldc_free(void* ptr) {
    free(ptr);
}

void ldc_set_event_callback(ldc_event_callback cb, void* user_data) {
    std::lock_guard<std::mutex> lock(g_state.mutex);
    g_state.event_cb = cb;
    g_state.user_data = user_data;
}

void ldc_set_binary_event_callback(ldc_binary_event_callback cb, void* user_data) {
    std::lock_guard<std::mutex> lock(g_state.mutex);
    g_state.binary_cb = cb;
    // user_data is shared with event callback
    if (user_data) g_state.user_data = user_data;
}

int ldc_create_peer_connection(const char* ice_servers_json) {
    rtcConfiguration config = {};

    // Parse ice servers from JSON array
    const char* servers[16] = {};
    int server_count = 0;
    if (ice_servers_json && ice_servers_json[0]) {
        server_count = parse_ice_servers(ice_servers_json, servers, 16);
    }
    config.iceServers = servers;
    config.iceServersCount = server_count;
    config.disableAutoNegotiation = true;
    config.forceMediaTransport = true;

    int pc = rtcCreatePeerConnection(&config);

    // Free strdup'd server strings
    for (int i = 0; i < server_count; i++) {
        free((void*)servers[i]);
    }

    if (pc < 0) return pc;

    // Set up callbacks
    rtcSetLocalDescriptionCallback(pc, on_local_description);
    rtcSetLocalCandidateCallback(pc, on_local_candidate);
    rtcSetStateChangeCallback(pc, on_state_change);
    rtcSetIceStateChangeCallback(pc, on_ice_state_change);
    rtcSetGatheringStateChangeCallback(pc, on_gathering_state_change);
    rtcSetSignalingStateChangeCallback(pc, on_signaling_state_change);
    rtcSetTrackCallback(pc, on_track);

    return pc;
}

void ldc_close_peer_connection(int pc_id) {
    rtcClosePeerConnection(pc_id);
}

void ldc_delete_peer_connection(int pc_id) {
    rtcDeletePeerConnection(pc_id);
}

int ldc_set_local_description(int pc_id, const char* type) {
    return rtcSetLocalDescription(pc_id, type);
}

int ldc_set_remote_description(int pc_id, const char* sdp, const char* type) {
    return rtcSetRemoteDescription(pc_id, sdp, type);
}

int ldc_add_remote_candidate(int pc_id, const char* candidate, const char* mid) {
    return rtcAddRemoteCandidate(pc_id, candidate, mid);
}

char* ldc_get_local_description(int pc_id) {
    std::string s = get_string_from_rtc(rtcGetLocalDescription, pc_id);
    return strdup_export(s);
}

char* ldc_get_local_description_type(int pc_id) {
    std::string s = get_string_from_rtc(rtcGetLocalDescriptionType, pc_id);
    return strdup_export(s);
}

char* ldc_get_remote_description(int pc_id) {
    std::string s = get_string_from_rtc(rtcGetRemoteDescription, pc_id);
    return strdup_export(s);
}

char* ldc_get_remote_description_type(int pc_id) {
    std::string s = get_string_from_rtc(rtcGetRemoteDescriptionType, pc_id);
    return strdup_export(s);
}

int ldc_add_track(int pc_id, const char* track_init_json) {
    std::string json(track_init_json ? track_init_json : "");

    rtcTrackInit init = {};

    std::string direction_str = json_get_string(json, "direction");
    if (direction_str == "sendonly") init.direction = RTC_DIRECTION_SENDONLY;
    else if (direction_str == "recvonly") init.direction = RTC_DIRECTION_RECVONLY;
    else if (direction_str == "sendrecv") init.direction = RTC_DIRECTION_SENDRECV;
    else if (direction_str == "inactive") init.direction = RTC_DIRECTION_INACTIVE;

    std::string codec_str = json_get_string(json, "codec");
    if (codec_str == "h264") init.codec = RTC_CODEC_H264;
    else if (codec_str == "vp8") init.codec = RTC_CODEC_VP8;
    else if (codec_str == "vp9") init.codec = RTC_CODEC_VP9;
    else if (codec_str == "h265") init.codec = RTC_CODEC_H265;
    else if (codec_str == "av1") init.codec = RTC_CODEC_AV1;
    else if (codec_str == "opus") init.codec = RTC_CODEC_OPUS;
    else if (codec_str == "pcmu") init.codec = RTC_CODEC_PCMU;
    else if (codec_str == "pcma") init.codec = RTC_CODEC_PCMA;

    init.payloadType = json_get_int(json, "payloadType", 96);
    init.ssrc = json_get_uint32(json, "ssrc", 0);

    std::string mid = json_get_string(json, "mid");
    std::string name = json_get_string(json, "name");
    std::string msid = json_get_string(json, "msid");
    std::string track_id = json_get_string(json, "trackId");
    std::string profile = json_get_string(json, "profile");

    init.mid = mid.empty() ? nullptr : mid.c_str();
    init.name = name.empty() ? nullptr : name.c_str();
    init.msid = msid.empty() ? nullptr : msid.c_str();
    init.trackId = track_id.empty() ? nullptr : track_id.c_str();
    init.profile = profile.empty() ? nullptr : profile.c_str();

    int tr = rtcAddTrackEx(pc_id, &init);
    if (tr < 0) return tr;

    setup_track_callbacks(tr);

    return tr;
}

void ldc_delete_track(int tr_id) {
    rtcDeleteTrack(tr_id);
}

int ldc_send_track_message(int tr_id, const uint8_t* data, int size) {
    return rtcSendMessage(tr_id, reinterpret_cast<const char*>(data), size);
}

static rtcPacketizerInit parse_packetizer_init(const std::string& json) {
    rtcPacketizerInit init = {};
    init.ssrc = json_get_uint32(json, "ssrc", 0);
    init.payloadType = (uint8_t)json_get_int(json, "payloadType", 96);
    init.clockRate = json_get_uint32(json, "clockRate", 90000);
    init.sequenceNumber = (uint16_t)json_get_int(json, "sequenceNumber", 0);
    init.timestamp = json_get_uint32(json, "timestamp", 0);
    init.maxFragmentSize = (uint16_t)json_get_int(json, "maxFragmentSize", 0);

    std::string nal_sep = json_get_string(json, "nalSeparator");
    if (nal_sep == "length") init.nalSeparator = RTC_NAL_SEPARATOR_LENGTH;
    else if (nal_sep == "longStartSequence") init.nalSeparator = RTC_NAL_SEPARATOR_LONG_START_SEQUENCE;
    else if (nal_sep == "shortStartSequence") init.nalSeparator = RTC_NAL_SEPARATOR_SHORT_START_SEQUENCE;
    else if (nal_sep == "startSequence") init.nalSeparator = RTC_NAL_SEPARATOR_START_SEQUENCE;

    return init;
}

int ldc_set_h264_packetizer(int tr_id, const char* init_json) {
    std::string json(init_json ? init_json : "");
    rtcPacketizerInit init = parse_packetizer_init(json);
    std::string cname = json_get_string(json, "cname");
    init.cname = cname.empty() ? "video" : cname.c_str();
    return rtcSetH264Packetizer(tr_id, &init);
}

int ldc_set_opus_packetizer(int tr_id, const char* init_json) {
    std::string json(init_json ? init_json : "");
    rtcPacketizerInit init = parse_packetizer_init(json);
    if (init.clockRate == 90000) init.clockRate = 48000; // Opus default
    std::string cname = json_get_string(json, "cname");
    init.cname = cname.empty() ? "audio" : cname.c_str();
    return rtcSetOpusPacketizer(tr_id, &init);
}

int ldc_chain_rtcp_receiving_session(int tr_id) {
    return rtcChainRtcpReceivingSession(tr_id);
}

int ldc_chain_rtcp_sr_reporter(int tr_id) {
    return rtcChainRtcpSrReporter(tr_id);
}
