#include "ldc_dump.h"

#include <rtc/rtc.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>
#include <thread>
#include <unordered_map>
#include <vector>

#ifdef _WIN32
#include <windows.h>
#endif

namespace ldc_dump {

// ---------------------------------------------------------------------------
// File helpers
// ---------------------------------------------------------------------------

#ifdef _WIN32
static FILE* open_file(const char* path, const char* mode) {
    // Convert UTF-8 path to UTF-16 for _wfopen
    int wlen = MultiByteToWideChar(CP_UTF8, 0, path, -1, nullptr, 0);
    if (wlen <= 0) return nullptr;
    std::vector<wchar_t> wpath(wlen);
    MultiByteToWideChar(CP_UTF8, 0, path, -1, wpath.data(), wlen);

    int wmlen = MultiByteToWideChar(CP_UTF8, 0, mode, -1, nullptr, 0);
    if (wmlen <= 0) return nullptr;
    std::vector<wchar_t> wmode(wmlen);
    MultiByteToWideChar(CP_UTF8, 0, mode, -1, wmode.data(), wmlen);

    return _wfopen(wpath.data(), wmode.data());
}
#else
static FILE* open_file(const char* path, const char* mode) {
    return fopen(path, mode);
}
#endif

// ---------------------------------------------------------------------------
// Dump format — rtptools standard (.rtpdump), interoperable with Wireshark /
// rtpplay / rtpdump. Layout:
//   [text] "#!rtpplay1.0 <ip>/<port>\n"
//   [16B]  RD_hdr_t:  start.tv_sec(u32) start.tv_usec(u32) source(u32)
//                     port(u16) padding(u16)
//   repeat RD_packet_t:
//     [8B] length(u16) plen(u16) offset(u32, ms since start), then packet bytes
// All multi-byte fields are network byte order (big-endian).
// ---------------------------------------------------------------------------

static constexpr int kRtpDumpFileHeaderSize   = 16; // RD_hdr_t
static constexpr int kRtpDumpRecordHeaderSize = 8;  // RD_packet_t
static constexpr int kMaxPreambleLen          = 256;

// Preamble uses 0.0.0.0/0 — the address/port are informational only and not
// used by our replay path.
static const char kRtpDumpPreamble[] = "#!rtpplay1.0 0.0.0.0/0\n";

// ---- big-endian helpers ----------------------------------------------------

static void put_be16(uint8_t* p, uint16_t v) {
    p[0] = static_cast<uint8_t>((v >> 8) & 0xFF);
    p[1] = static_cast<uint8_t>(v & 0xFF);
}
static void put_be32(uint8_t* p, uint32_t v) {
    p[0] = static_cast<uint8_t>((v >> 24) & 0xFF);
    p[1] = static_cast<uint8_t>((v >> 16) & 0xFF);
    p[2] = static_cast<uint8_t>((v >> 8) & 0xFF);
    p[3] = static_cast<uint8_t>(v & 0xFF);
}
static uint16_t get_be16(const uint8_t* p) {
    return static_cast<uint16_t>((p[0] << 8) | p[1]);
}
static uint32_t get_be32(const uint8_t* p) {
    return (static_cast<uint32_t>(p[0]) << 24) |
           (static_cast<uint32_t>(p[1]) << 16) |
           (static_cast<uint32_t>(p[2]) << 8) |
           static_cast<uint32_t>(p[3]);
}

// Read the "#!rtpplay1.0 ...\n" preamble line (bounded). Leaves the file
// positioned at the first RD_hdr_t byte. Returns false on malformed input.
static bool read_preamble(FILE* f) {
    for (int i = 0; i < kMaxPreambleLen; ++i) {
        int c = fgetc(f);
        if (c == EOF) return false;
        if (c == '\n') return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Recording state
// ---------------------------------------------------------------------------

struct RecordingState {
    FILE* file = nullptr;
    std::chrono::steady_clock::time_point start_time;
    std::atomic<bool> active{false};
    std::mutex mutex;
    int flush_counter = 0;
    ErrorCallback on_error;
};

// ---------------------------------------------------------------------------
// Playback state
// ---------------------------------------------------------------------------

struct PlaybackState {
    std::thread thread;
    std::atomic<bool> playing{false};
    std::atomic<bool> paused{false};
    std::atomic<bool> stop_requested{false};
    double speed = 1.0;
    std::mutex pause_mutex;
    std::condition_variable pause_cv;
    CompletionCallback on_complete;
};

// ---------------------------------------------------------------------------
// Global maps
// ---------------------------------------------------------------------------

static std::mutex g_rec_map_mutex;
static std::unordered_map<int, std::shared_ptr<RecordingState>> g_recordings;
static std::atomic<int> g_active_recordings{0};

static std::mutex g_play_map_mutex;
static std::unordered_map<int, std::shared_ptr<PlaybackState>> g_playbacks;

// ---------------------------------------------------------------------------
// H.264 RTP depacketizer helpers
// ---------------------------------------------------------------------------

static int rtp_payload_offset(const uint8_t* pkt, int size) {
    if (size < 12) return size;
    int offset = 12 + (pkt[0] & 0x0F) * 4;
    if ((pkt[0] & 0x10) != 0 && offset + 4 <= size) {
        int ext_len = (pkt[offset + 2] << 8) | pkt[offset + 3];
        offset += 4 + ext_len * 4;
    }
    return offset;
}

// Annex B start code: 00 00 00 01
static void append_start_code(std::vector<uint8_t>& out) {
    out.push_back(0);
    out.push_back(0);
    out.push_back(0);
    out.push_back(1);
}

static void append_nalu_with_start_code(std::vector<uint8_t>& out,
                                         const uint8_t* data, int len) {
    append_start_code(out);
    out.insert(out.end(), data, data + len);
}

struct Depacketizer {
    std::vector<uint8_t> fu_buffer;

    void process(const uint8_t* rtp, int rtp_size,
                 std::vector<uint8_t>& frame_buf) {
        int pay_off = rtp_payload_offset(rtp, rtp_size);
        if (pay_off >= rtp_size) return;

        const uint8_t* payload = rtp + pay_off;
        int payload_len = rtp_size - pay_off;

        // Handle RTP padding
        if ((rtp[0] & 0x20) != 0 && payload_len > 0) {
            int pad_len = rtp[rtp_size - 1];
            payload_len -= pad_len;
            if (payload_len <= 0) return;
        }

        if (payload_len <= 0) return;
        int nal_type = payload[0] & 0x1F;

        if (nal_type >= 1 && nal_type <= 23) {
            // Single NAL unit
            append_nalu_with_start_code(frame_buf, payload, payload_len);
        } else if (nal_type == 24) {
            // STAP-A
            int off = 1;
            while (off + 2 <= payload_len) {
                int len = (payload[off] << 8) | payload[off + 1];
                off += 2;
                if (off + len > payload_len) break;
                append_nalu_with_start_code(frame_buf, payload + off, len);
                off += len;
            }
        } else if (nal_type == 28) {
            // FU-A
            if (payload_len < 2) return;
            uint8_t fu_indicator = payload[0];
            uint8_t fu_header = payload[1];
            bool start = (fu_header & 0x80) != 0;
            bool end   = (fu_header & 0x40) != 0;
            uint8_t frag_nal_type = fu_header & 0x1F;
            uint8_t nri = fu_indicator & 0x60;

            if (start) {
                fu_buffer.clear();
                fu_buffer.push_back(nri | frag_nal_type);
            }
            if (payload_len > 2) {
                fu_buffer.insert(fu_buffer.end(), payload + 2,
                                 payload + payload_len);
            }
            if (end) {
                append_nalu_with_start_code(frame_buf, fu_buffer.data(),
                                            static_cast<int>(fu_buffer.size()));
                fu_buffer.clear();
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Playback worker
// ---------------------------------------------------------------------------

static void playback_thread_func(std::shared_ptr<PlaybackState> state,
                                  int tr_id, std::string file_path) {
    fprintf(stderr, "[LDC-DUMP] playback_thread_func started tr=%d file=%s\n",
            tr_id, file_path.c_str());
    fflush(stderr);

    FILE* f = open_file(file_path.c_str(), "rb");
    if (!f) {
        fprintf(stderr, "[LDC-DUMP] Failed to open file\n");
        fflush(stderr);
        state->playing = false;
        if (state->on_complete) state->on_complete(tr_id);
        return;
    }

    // Read the rtptools preamble + RD_hdr_t (16B, contents unused by replay).
    uint8_t file_hdr[kRtpDumpFileHeaderSize];
    if (!read_preamble(f) ||
        fread(file_hdr, 1, kRtpDumpFileHeaderSize, f) != kRtpDumpFileHeaderSize) {
        fprintf(stderr, "[LDC-DUMP] Invalid rtpdump header\n");
        fflush(stderr);
        fclose(f);
        state->playing = false;
        if (state->on_complete) state->on_complete(tr_id);
        return;
    }
    // The preamble is variable-length, so remember where records begin.
    long first_record_pos = ftell(f);

    // Pass 1: PT detection scan — find primary payload type
    std::unordered_map<int, int> pt_counts;
    uint8_t rec_hdr[kRtpDumpRecordHeaderSize];
    uint8_t pt_peek[2]; // enough to read PT byte from RTP header
    uint8_t scratch[4096];

    while (fread(rec_hdr, 1, kRtpDumpRecordHeaderSize, f) == kRtpDumpRecordHeaderSize) {
        // Bytes stored after this record header = length - 8.
        uint16_t length = get_be16(rec_hdr);
        uint32_t stored_len =
            length >= kRtpDumpRecordHeaderSize
                ? static_cast<uint32_t>(length - kRtpDumpRecordHeaderSize)
                : 0;

        if (stored_len >= 2) {
            if (fread(pt_peek, 1, 2, f) != 2) break;
            int pt = pt_peek[1] & 0x7F;
            pt_counts[pt]++;

            // Read and discard remaining payload bytes
            uint32_t remaining = stored_len - 2;
            while (remaining > 0) {
                uint32_t chunk = remaining > sizeof(scratch)
                                     ? static_cast<uint32_t>(sizeof(scratch))
                                     : remaining;
                if (fread(scratch, 1, chunk, f) != chunk) goto done_scan;
                remaining -= chunk;
            }
        } else {
            // Tiny payload, skip
            uint32_t remaining = stored_len;
            while (remaining > 0) {
                uint32_t chunk = remaining > sizeof(scratch)
                                     ? static_cast<uint32_t>(sizeof(scratch))
                                     : remaining;
                if (fread(scratch, 1, chunk, f) != chunk) goto done_scan;
                remaining -= chunk;
            }
        }
    }
done_scan:

    int primary_pt = -1;
    int max_count = 0;
    for (auto& [pt, count] : pt_counts) {
        if (count > max_count) {
            max_count = count;
            primary_pt = pt;
        }
    }
    fprintf(stderr, "[LDC-DUMP] Primary PT: %d (%d packets)\n", primary_pt, max_count);
    fflush(stderr);

    // Rewind to first record
    fseek(f, first_record_pos, SEEK_SET);

    // Pass 2: streaming playback
    Depacketizer depack;
    int total_records = 0;
    int filtered_records = 0;
    int frames_sent = 0;
    int send_errors = 0;
    std::vector<uint8_t> pkt_buf;
    std::vector<uint8_t> frame_buf;
    uint32_t prev_rtp_ts = 0;
    bool have_prev_ts = false;
    int64_t first_timestamp_us = -1;
    auto wall_start = std::chrono::steady_clock::now();
    bool wall_start_set = false;

    while (!state->stop_requested &&
           fread(rec_hdr, 1, kRtpDumpRecordHeaderSize, f) == kRtpDumpRecordHeaderSize) {

        // RD_packet_t: length (incl. 8B header), plen, offset(ms). The stored
        // packet bytes count is length - 8; offset is converted to us to reuse
        // the timing logic below.
        uint16_t length = get_be16(rec_hdr);
        uint32_t offset_ms = get_be32(rec_hdr + 4);
        uint32_t payload_len =
            length >= kRtpDumpRecordHeaderSize
                ? static_cast<uint32_t>(length - kRtpDumpRecordHeaderSize)
                : 0;
        uint64_t timestamp_us = static_cast<uint64_t>(offset_ms) * 1000ull;

        // Read payload
        pkt_buf.resize(payload_len);
        if (payload_len > 0 &&
            fread(pkt_buf.data(), 1, payload_len, f) != payload_len) break;

        total_records++;
        if (payload_len < 12) continue; // too small for RTP

        // Filter by primary PT
        int pt = pkt_buf[1] & 0x7F;
        if (primary_pt >= 0 && pt != primary_pt) {
            filtered_records++;
            continue;
        }

        // Extract RTP timestamp
        uint32_t rtp_ts = (static_cast<uint32_t>(pkt_buf[4]) << 24) |
                          (static_cast<uint32_t>(pkt_buf[5]) << 16) |
                          (static_cast<uint32_t>(pkt_buf[6]) << 8) |
                          static_cast<uint32_t>(pkt_buf[7]);

        // When RTP timestamp changes, flush accumulated frame
        int64_t delay_us = 0;
        if (have_prev_ts && rtp_ts != prev_rtp_ts && !frame_buf.empty()) {
            // Timing
            if (state->speed > 0 && first_timestamp_us >= 0) {
                if (!wall_start_set) {
                    wall_start = std::chrono::steady_clock::now();
                    wall_start_set = true;
                }
                auto now = std::chrono::steady_clock::now();
                int64_t target_us = static_cast<int64_t>(
                    (static_cast<double>(timestamp_us) -
                     static_cast<double>(first_timestamp_us)) /
                    state->speed);
                auto elapsed = std::chrono::duration_cast<std::chrono::microseconds>(
                                   now - wall_start)
                                   .count();
                delay_us = target_us - elapsed;
                if (delay_us > 0) {
                    std::this_thread::sleep_for(
                        std::chrono::microseconds(delay_us));
                }
            }

            // Check stop/pause after sleep
            if (state->stop_requested) break;
            {
                std::unique_lock<std::mutex> lk(state->pause_mutex);
                state->pause_cv.wait(lk, [&] {
                    return !state->paused || state->stop_requested;
                });
                // Reset wall clock after unpause
                wall_start_set = false;
                first_timestamp_us = static_cast<int64_t>(timestamp_us);
                if (state->stop_requested) break;
            }

            // Set RTP timestamp so the packetizer stamps outgoing packets
            // with proper timing — prevents jitter buffer stalls on the receiver
            rtcSetTrackRtpTimestamp(tr_id, prev_rtp_ts);

            // Send frame
            int send_ret = rtcSendMessage(tr_id,
                           reinterpret_cast<const char*>(frame_buf.data()),
                           static_cast<int>(frame_buf.size()));
            frames_sent++;
            if (send_ret < 0) {
                send_errors++;
                if (send_errors <= 3) {
                    fprintf(stderr, "[LDC-DUMP] rtcSendMessage FAILED ret=%d frame=%d size=%d\n",
                            send_ret, frames_sent, (int)frame_buf.size());
                    fflush(stderr);
                }
            }
            frame_buf.clear();
        }

        if (first_timestamp_us < 0) {
            first_timestamp_us = static_cast<int64_t>(timestamp_us);
        }

        prev_rtp_ts = rtp_ts;
        have_prev_ts = true;

        depack.process(pkt_buf.data(), static_cast<int>(payload_len), frame_buf);
    }

    // Flush last frame
    if (!state->stop_requested && !frame_buf.empty()) {
        rtcSetTrackRtpTimestamp(tr_id, prev_rtp_ts);
        int ret = rtcSendMessage(tr_id,
                       reinterpret_cast<const char*>(frame_buf.data()),
                       static_cast<int>(frame_buf.size()));
        frames_sent++;
        if (ret < 0) send_errors++;
        fprintf(stderr, "[LDC-DUMP] Last frame sent (size=%d, ret=%d)\n",
                (int)frame_buf.size(), ret);
        fflush(stderr);
    }

    fclose(f);

    fprintf(stderr, "[LDC-DUMP] Playback finished: records=%d filtered=%d frames_sent=%d send_errors=%d\n",
            total_records, filtered_records, frames_sent, send_errors);
    fflush(stderr);

    state->playing = false;

    if (state->on_complete) {
        state->on_complete(tr_id);
    }
}

// ---------------------------------------------------------------------------
// Recording API
// ---------------------------------------------------------------------------

int start_recording(int tr_id, const char* file_path, int codec,
                    ErrorCallback on_error) {
    auto state = std::make_shared<RecordingState>();

    // The rtptools format infers codec from the RTP payload type, so the
    // `codec` argument is retained for API compatibility but not written.
    (void)codec;

    state->file = open_file(file_path, "wb");
    if (!state->file) return -1;

    // Write the text preamble.
    if (fwrite(kRtpDumpPreamble, 1, sizeof(kRtpDumpPreamble) - 1, state->file) !=
        sizeof(kRtpDumpPreamble) - 1) {
        fclose(state->file);
        return -1;
    }

    // Write RD_hdr_t (16 bytes, big-endian). start = wall-clock time now;
    // source/port are informational and left zero.
    auto now_sys = std::chrono::system_clock::now();
    auto since_epoch = now_sys.time_since_epoch();
    auto secs = std::chrono::duration_cast<std::chrono::seconds>(since_epoch);
    auto usecs = std::chrono::duration_cast<std::chrono::microseconds>(
                     since_epoch - secs);
    uint8_t hdr[kRtpDumpFileHeaderSize] = {};
    put_be32(hdr + 0, static_cast<uint32_t>(secs.count()));
    put_be32(hdr + 4, static_cast<uint32_t>(usecs.count()));
    put_be32(hdr + 8, 0); // source
    put_be16(hdr + 12, 0); // port
    put_be16(hdr + 14, 0); // padding

    if (fwrite(hdr, 1, kRtpDumpFileHeaderSize, state->file) !=
        kRtpDumpFileHeaderSize) {
        fclose(state->file);
        return -1;
    }
    fflush(state->file);

    state->start_time = std::chrono::steady_clock::now();
    state->on_error = std::move(on_error);
    state->active = true;

    {
        std::lock_guard<std::mutex> lock(g_rec_map_mutex);
        // Stop any existing recording on this track
        auto it = g_recordings.find(tr_id);
        if (it != g_recordings.end()) {
            it->second->active = false;
            g_active_recordings.fetch_sub(1, std::memory_order_relaxed);
            std::lock_guard<std::mutex> sl(it->second->mutex);
            if (it->second->file) {
                fclose(it->second->file);
                it->second->file = nullptr;
            }
        }
        g_recordings[tr_id] = state;
        g_active_recordings.fetch_add(1, std::memory_order_relaxed);
    }

    return 0;
}

int stop_recording(int tr_id) {
    std::shared_ptr<RecordingState> state;
    {
        std::lock_guard<std::mutex> lock(g_rec_map_mutex);
        auto it = g_recordings.find(tr_id);
        if (it == g_recordings.end()) return -1;
        state = it->second;
        g_recordings.erase(it);
        g_active_recordings.fetch_sub(1, std::memory_order_relaxed);
    }

    state->active = false;
    std::lock_guard<std::mutex> sl(state->mutex);
    if (state->file) {
        fflush(state->file);
        fclose(state->file);
        state->file = nullptr;
    }
    return 0;
}

bool is_recording(int tr_id) {
    std::lock_guard<std::mutex> lock(g_rec_map_mutex);
    auto it = g_recordings.find(tr_id);
    return it != g_recordings.end() && it->second->active;
}

void on_rtp_packet(int tr_id, const uint8_t* data, int size) {
    if (g_active_recordings.load(std::memory_order_relaxed) == 0) return;
    if (size <= 0) return;

    std::shared_ptr<RecordingState> state;
    {
        std::lock_guard<std::mutex> lock(g_rec_map_mutex);
        auto it = g_recordings.find(tr_id);
        if (it == g_recordings.end()) return;
        state = it->second;
    }

    if (!state->active) return;

    auto now = std::chrono::steady_clock::now();
    auto elapsed_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                          now - state->start_time)
                          .count();
    // RD_packet_t: length = bytes stored incl. this 8B header; plen = packet
    // length (RTP header+payload); offset = ms since recording start.
    uint16_t plen = static_cast<uint16_t>(size);
    uint16_t length = static_cast<uint16_t>(size + kRtpDumpRecordHeaderSize);
    uint32_t offset_ms = static_cast<uint32_t>(elapsed_ms);

    uint8_t rec_hdr[kRtpDumpRecordHeaderSize];
    put_be16(rec_hdr + 0, length);
    put_be16(rec_hdr + 2, plen);
    put_be32(rec_hdr + 4, offset_ms);

    ErrorCallback error_cb;
    {
        std::lock_guard<std::mutex> sl(state->mutex);
        if (!state->active || !state->file) return;
        if (fwrite(rec_hdr, 1, kRtpDumpRecordHeaderSize, state->file) != kRtpDumpRecordHeaderSize ||
            fwrite(data, 1, size, state->file) != static_cast<size_t>(size)) {
            state->active = false;
            error_cb = state->on_error;
            fprintf(stderr, "[LDC-DUMP] Write error during recording tr=%d, deactivating\n", tr_id);
            fflush(stderr);
        } else if (++state->flush_counter >= 100) {
            fflush(state->file);
            state->flush_counter = 0;
        }
    }

    // Fire error callback outside the state mutex to avoid deadlock
    if (error_cb) error_cb(tr_id);
}

// ---------------------------------------------------------------------------
// Playback API
// ---------------------------------------------------------------------------

int start_playback(int tr_id, const char* file_path, double speed,
                   CompletionCallback on_complete) {
    // Stop any existing playback on this track
    stop_playback(tr_id);

    auto state = std::make_shared<PlaybackState>();
    state->playing = true;
    state->speed = speed;
    state->on_complete = std::move(on_complete);

    std::string path_copy(file_path);

    state->thread = std::thread(playback_thread_func, state, tr_id,
                                std::move(path_copy));

    {
        std::lock_guard<std::mutex> lock(g_play_map_mutex);
        g_playbacks[tr_id] = state;
    }

    return 0;
}

int pause_playback(int tr_id) {
    std::shared_ptr<PlaybackState> state;
    {
        std::lock_guard<std::mutex> lock(g_play_map_mutex);
        auto it = g_playbacks.find(tr_id);
        if (it == g_playbacks.end()) return -1;
        state = it->second;
    }
    {
        std::lock_guard<std::mutex> lk(state->pause_mutex);
        state->paused = true;
    }
    return 0;
}

int resume_playback(int tr_id) {
    std::shared_ptr<PlaybackState> state;
    {
        std::lock_guard<std::mutex> lock(g_play_map_mutex);
        auto it = g_playbacks.find(tr_id);
        if (it == g_playbacks.end()) return -1;
        state = it->second;
    }
    {
        std::lock_guard<std::mutex> lk(state->pause_mutex);
        state->paused = false;
    }
    state->pause_cv.notify_all();
    return 0;
}

int stop_playback(int tr_id) {
    std::shared_ptr<PlaybackState> state;
    {
        std::lock_guard<std::mutex> lock(g_play_map_mutex);
        auto it = g_playbacks.find(tr_id);
        if (it == g_playbacks.end()) return 0; // not an error
        state = it->second;
        g_playbacks.erase(it);
    }

    // Signal stop and unblock pause
    {
        std::lock_guard<std::mutex> lk(state->pause_mutex);
        state->stop_requested = true;
        state->paused = false;
    }
    state->pause_cv.notify_all();

    // Join thread (map lock is NOT held)
    if (state->thread.joinable()) {
        state->thread.join();
    }

    return 0;
}

void cleanup() {
    // Stop all recordings
    {
        std::lock_guard<std::mutex> lock(g_rec_map_mutex);
        for (auto& [id, state] : g_recordings) {
            state->active = false;
            std::lock_guard<std::mutex> sl(state->mutex);
            if (state->file) {
                fclose(state->file);
                state->file = nullptr;
            }
        }
        g_recordings.clear();
        g_active_recordings.store(0, std::memory_order_relaxed);
    }

    // Stop all playbacks — collect first, then join outside lock
    std::vector<std::shared_ptr<PlaybackState>> to_stop;
    {
        std::lock_guard<std::mutex> lock(g_play_map_mutex);
        for (auto& [id, state] : g_playbacks) {
            {
                std::lock_guard<std::mutex> lk(state->pause_mutex);
                state->stop_requested = true;
                state->paused = false;
            }
            state->pause_cv.notify_all();
            to_stop.push_back(state);
        }
        g_playbacks.clear();
    }
    for (auto& state : to_stop) {
        if (state->thread.joinable()) {
            state->thread.join();
        }
    }
}

} // namespace ldc_dump
