import 'package:shared_preferences/shared_preferences.dart';
import 'emulator/zx_types.dart';
import 'video_mode.dart';

/// Ajustes persistentes de la app.
class AppSettings {
  ZxModel model = ZxModel.k128;
  JoyMapping joyMapping = JoyMapping.kempston;
  bool quickLoad = true;
  bool vibration = true;
  bool keepScreenOn = true;
  bool startWithKeyboard = false;
  bool onlineInfo = true;
  VideoMode videoMode = VideoMode.sharp;
  bool gigascreen = false;

  static Future<AppSettings> load() async {
    final p = await SharedPreferences.getInstance();
    final s = AppSettings();
    s.model = ZxModel.values[(p.getInt('model') ?? ZxModel.k128.index)
        .clamp(0, ZxModel.values.length - 1)];
    // 'joy_mapping' (índice) era el formato antiguo: Kempston, Sinclair, Cursor, QAOP.
    const legacy = [JoyMapping.kempston, JoyMapping.sinclair1, JoyMapping.cursor, JoyMapping.keyboard];
    s.joyMapping = JoyMapping.byName(p.getString('joy_type')) ??
        legacy[(p.getInt('joy_mapping') ?? 0).clamp(0, legacy.length - 1)];
    s.quickLoad = p.getBool('quick_load') ?? true;
    s.vibration = p.getBool('vibration') ?? true;
    s.keepScreenOn = p.getBool('keep_screen_on') ?? true;
    s.startWithKeyboard = p.getBool('start_keyboard') ?? false;
    s.onlineInfo = p.getBool('online_info') ?? true;
    s.videoMode = VideoMode.byName(p.getString('video_mode'));
    s.gigascreen = p.getBool('gigascreen') ?? false;
    return s;
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt('model', model.index);
    await p.setString('joy_type', joyMapping.name);
    await p.setBool('quick_load', quickLoad);
    await p.setBool('vibration', vibration);
    await p.setBool('keep_screen_on', keepScreenOn);
    await p.setBool('start_keyboard', startWithKeyboard);
    await p.setBool('online_info', onlineInfo);
    await p.setString('video_mode', videoMode.name);
    await p.setBool('gigascreen', gigascreen);
  }
}
