import 'dart:io';

import '../services/app_logger.dart';
import 'desktop_xray_vpn_engine.dart';
import 'mock_vpn_engine.dart';
import 'vpn_engine.dart';
import 'xray_core_vpn_engine.dart';

VpnEngine createVpnEngine({AppLogger? logger}) {
  if (Platform.isAndroid) {
    return XrayCoreVpnEngine(logger: logger);
  }
  if (Platform.isWindows || Platform.isLinux) {
    return DesktopXrayVpnEngine(logger: logger);
  }
  return MockVpnEngine(logger: logger);
}
