//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <flutter_libdatachannel/flutter_libdatachannel_plugin_c_api.h>
#include <flutter_webrtc/flutter_web_r_t_c_plugin.h>

void RegisterPlugins(flutter::PluginRegistry* registry) {
  FlutterLibdatachannelPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FlutterLibdatachannelPluginCApi"));
  FlutterWebRTCPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FlutterWebRTCPlugin"));
}
