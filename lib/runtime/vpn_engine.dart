import '../models/config_entry.dart';
import '../models/runtime_settings.dart';
import '../models/vpn_runtime_models.dart';

abstract class VpnEngine {
  Future<VpnEngineResult> validate(ConfigEntry entry, RuntimeSettings runtimeSettings);
  Future<VpnEngineResult> connect(ConfigEntry entry, RuntimeSettings runtimeSettings);
  Future<VpnEngineResult> disconnect(ConfigEntry entry);
}
