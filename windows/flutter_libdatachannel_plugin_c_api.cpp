#include "include/flutter_libdatachannel/flutter_libdatachannel_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "flutter_libdatachannel_plugin.h"

void FlutterLibdatachannelPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  flutter_libdatachannel::FlutterLibdatachannelPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
