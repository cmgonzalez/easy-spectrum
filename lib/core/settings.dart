import 'package:shared_preferences/shared_preferences.dart';
import 'emulator/zx_types.dart';

/// Ajustes persistentes de la app.
class AppSettings {
  ZxModel model = ZxModel.k128;
  JoyMapping joyMapping = JoyMapping.kempston;
  bool quickLoad = true;
  bool vibration = true;
  bool keepScreenOn = true;
  bool startWithKeyboard = false;

  static Future<AppSettings> load() async {
    final p = await SharedPreferences.getInstance();
    final s = AppSettings();
    s.model = ZxModel.values[(p.getInt('model') ?? ZxModel.k128.index)
        .clamp(0, ZxModel.values.length - 1)];
    s.joyMapping = JoyMapping.values[(p.getInt('joy_mapping') ?? 0)
        .clamp(0, JoyMapping.values.length - 1)];
    s.quickLoad = p.getBool('quick_load') ?? true;
    s.vibration = p.getBool('vibration') ?? true;
    s.keepScreenOn = p.getBool('keep_screen_on') ?? true;
    s.startWithKeyboard = p.getBool('start_keyboard') ?? false;
    return s;
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt('model', model.index);
    await p.setInt('joy_mapping', joyMapping.index);
    await p.setBool('quick_load', quickLoad);
    await p.setBool('vibration', vibration);
    await p.setBool('keep_screen_on', keepScreenOn);
    await p.setBool('start_keyboard', startWithKeyboard);
  }
}
