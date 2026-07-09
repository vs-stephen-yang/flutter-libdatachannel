#ifndef FLUTTER_LIBDATACHANNEL_H
#define FLUTTER_LIBDATACHANNEL_H

#include <stdint.h>

#ifdef _WIN32
#ifdef FLUTTER_LIBDATACHANNEL_BUILDING
#define LDC_EXPORT __declspec(dllexport)
#else
#define LDC_EXPORT
#endif
#else
#define LDC_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

// Lifecycle
LDC_EXPORT int ldc_create_peer_connection(const char* ice_servers_json, int disable_auto_negotiation);
LDC_EXPORT void ldc_close_peer_connection(int pc_id);
LDC_EXPORT void ldc_delete_peer_connection(int pc_id);

// SDP/ICE
LDC_EXPORT int ldc_set_local_description(int pc_id, const char* type);
LDC_EXPORT int ldc_set_remote_description(int pc_id, const char* sdp, const char* type);
LDC_EXPORT int ldc_add_remote_candidate(int pc_id, const char* candidate, const char* mid);
LDC_EXPORT char* ldc_get_local_description(int pc_id);       // caller frees with ldc_free
LDC_EXPORT char* ldc_get_local_description_type(int pc_id);  // caller frees with ldc_free
LDC_EXPORT char* ldc_get_remote_description(int pc_id);      // caller frees with ldc_free
LDC_EXPORT char* ldc_get_remote_description_type(int pc_id); // caller frees with ldc_free

// Tracks
LDC_EXPORT int ldc_add_track(int pc_id, const char* track_init_json);
LDC_EXPORT void ldc_delete_track(int tr_id);
LDC_EXPORT int ldc_send_track_message(int tr_id, const uint8_t* data, int size);

// Packetizers
LDC_EXPORT int ldc_set_h264_packetizer(int tr_id, const char* init_json);
LDC_EXPORT int ldc_set_opus_packetizer(int tr_id, const char* init_json);

// RTCP
LDC_EXPORT int ldc_chain_rtcp_receiving_session(int tr_id);
LDC_EXPORT int ldc_chain_rtcp_sr_reporter(int tr_id);

// Recording (RTP bitstream dump). Thin C wrappers over ldc_dump:: so the
// method-channel / FFI bindings can record without calling C++ directly
// (Android uses ldc_dump:: via JNI). Packet capture itself is already wired on
// the track-message path (ldc_dump::on_rtp_packet), so only start/stop needed.
LDC_EXPORT int ldc_start_recording(int tr_id, const char* file_path, int codec);
LDC_EXPORT int ldc_stop_recording(int tr_id);

// Selected ICE candidate pair as "local || remote" (caller frees with ldc_free);
// empty string if none selected yet. Diagnostic for connectivity issues.
LDC_EXPORT char* ldc_get_selected_candidate_pair(int pc_id);

// Callback for events sent to platform layer
typedef void (*ldc_event_callback)(const char* event_json, void* user_data);
typedef void (*ldc_binary_event_callback)(int tr_id, const uint8_t* data, int size, void* user_data);
LDC_EXPORT void ldc_set_event_callback(ldc_event_callback cb, void* user_data);
LDC_EXPORT void ldc_set_binary_event_callback(ldc_binary_event_callback cb, void* user_data);

// Init/Cleanup
LDC_EXPORT void ldc_init(void);
LDC_EXPORT void ldc_cleanup(void);
LDC_EXPORT void ldc_free(void* ptr);

#ifdef __cplusplus
}
#endif

#endif // FLUTTER_LIBDATACHANNEL_H
