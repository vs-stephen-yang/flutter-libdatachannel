#ifndef FLUTTER_PLUGIN_FLUTTER_LIBDATACHANNEL_PLUGIN_H_
#define FLUTTER_PLUGIN_FLUTTER_LIBDATACHANNEL_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>

namespace flutter_libdatachannel {

class FlutterLibdatachannelPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  FlutterLibdatachannelPlugin();

  virtual ~FlutterLibdatachannelPlugin();

  // Disallow copy and assign.
  FlutterLibdatachannelPlugin(const FlutterLibdatachannelPlugin&) = delete;
  FlutterLibdatachannelPlugin& operator=(const FlutterLibdatachannelPlugin&) = delete;

  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
};

}  // namespace flutter_libdatachannel

#endif  // FLUTTER_PLUGIN_FLUTTER_LIBDATACHANNEL_PLUGIN_H_
