#ifndef FLUTTER_PLUGIN_FLUTTER_LIBDATACHANNEL_PLUGIN_H_
#define FLUTTER_PLUGIN_FLUTTER_LIBDATACHANNEL_PLUGIN_H_

#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <windows.h>
#include <memory>
#include <mutex>
#include <queue>
#include <set>
#include <vector>

namespace flutter_libdatachannel {

class FlutterLibdatachannelPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  FlutterLibdatachannelPlugin(flutter::PluginRegistrarWindows *registrar);
  virtual ~FlutterLibdatachannelPlugin();

  FlutterLibdatachannelPlugin(const FlutterLibdatachannelPlugin&) = delete;
  FlutterLibdatachannelPlugin& operator=(const FlutterLibdatachannelPlugin&) = delete;

  // Called from libdatachannel worker threads to enqueue events for delivery
  // on the platform thread.
  void EnqueueEvent(flutter::EncodableMap map);

  // Called from OnTrack callback to track remote track IDs for cleanup.
  void TrackRemoteTrack(int tr);

 private:
  static constexpr UINT kDrainMessage = WM_APP + 0x4C44;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void SetupEventChannel(flutter::PluginRegistrarWindows *registrar);
  void DrainEventQueue();

  static LRESULT CALLBACK DrainWndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp);

  flutter::PluginRegistrarWindows *registrar_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> event_channel_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> event_sink_;
  std::mutex sink_mutex_;

  std::queue<flutter::EncodableMap> event_queue_;
  std::mutex queue_mutex_;
  HWND hwnd_ = nullptr;  // hidden message-only window for thread marshalling

  std::set<int> pc_ids_;    // track live PeerConnection IDs
  std::set<int> track_ids_; // track live Track IDs
};

}  // namespace flutter_libdatachannel

#endif  // FLUTTER_PLUGIN_FLUTTER_LIBDATACHANNEL_PLUGIN_H_
