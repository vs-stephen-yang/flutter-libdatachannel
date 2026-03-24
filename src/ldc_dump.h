#ifndef LDC_DUMP_H
#define LDC_DUMP_H

#include <cstdint>
#include <functional>

namespace ldc_dump {

// Recording
int start_recording(int tr_id, const char* file_path, int codec);
int stop_recording(int tr_id);
bool is_recording(int tr_id);
// Called from message callback — writes packet if recording active
void on_rtp_packet(int tr_id, const uint8_t* data, int size);

// Playback
using CompletionCallback = std::function<void(int tr_id)>;
int start_playback(int tr_id, const char* file_path, double speed,
                   CompletionCallback on_complete);
int pause_playback(int tr_id);
int resume_playback(int tr_id);
int stop_playback(int tr_id);

void cleanup();

} // namespace ldc_dump

#endif // LDC_DUMP_H
