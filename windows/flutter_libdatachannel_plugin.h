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
#include <string>
#include <variant>
#include <vector>

namespace flutter_libdatachannel {

class FlutterLibdatachannelPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  FlutterLibdatachannelPlugin(flutter::PluginRegistrarWindows *registrar);
  virtual ~FlutterLibdatachannelPlugin();

  FlutterLibdatachannelPlugin(const FlutterLibdatachannelPlugin&) = delete;
  FlutterLibdatachannelPlugin& operator=(const FlutterLibdatachannelPlugin&) = delete;

 private:
  struct PendingEvent {
    enum class Kind { Json, Binary };
    Kind kind;
    // Json variant
    std::string json;
    // Binary variant
    int tr_id = 0;
    std::vector<uint8_t> data;
  };

  static constexpr UINT kDrainMessage = WM_APP + 0x4C44;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void SetupEventChannel(flutter::PluginRegistrarWindows *registrar);
  void DrainEventQueue();

  flutter::PluginRegistrarWindows *registrar_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> event_channel_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> event_sink_;
  std::mutex sink_mutex_;

  std::queue<PendingEvent> event_queue_;
  std::mutex queue_mutex_;
  HWND hwnd_ = nullptr;
  int window_proc_delegate_id_ = 0;
};

}  // namespace flutter_libdatachannel

#endif  // FLUTTER_PLUGIN_FLUTTER_LIBDATACHANNEL_PLUGIN_H_
