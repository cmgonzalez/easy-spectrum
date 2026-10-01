import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'emulator/zx_types.dart';
import 'screen_border.dart';
import 'storage/media_db.dart';
import 'video_mode.dart';

/// Ajustes persistentes de la app.
class AppSettings {
  ZxModel model = ZxModel.k128;
  JoyMapping joyMapping = JoyMapping.kempston;
  bool quickLoad = true;
  bool vibration = true;
  bool soundOn = true;
  bool keepScreenOn = true;
  bool startWithKeyboard = false;
  bool onlineInfo = true;
  VideoMode videoMode = VideoMode.sharp;
  bool gigascreen = false;
  bool fitWidth = true; // vertical: la imagen de borde a borde, sin marco
  ScreenBorder screenBorder = ScreenBorder.half;

  /// Juego al que pertenecen estos ajustes (null = valores por defecto, que usan
  /// los juegos nuevos). Los ajustes por juego se guardan en [MediaDb].
  String? gamePath;

  /// Ajustes de un juego: los por defecto con lo que ese juego haya cambiado encima.
  /// Por juego: modelo, carga rápida, sonido, vibración, video, borde y Gigascreen.
  static Future<AppSettings> loadForGame(String gamePath) async {
    final s = await load();
    s.gamePath = gamePath;
    try {
      final raw = (await MediaDb.get(gamePath, ['cfg']))?['cfg'] as String?;
      if (raw == null) return s;
      final j = jsonDecode(raw) as Map<String, Object?>;
      final m = j['model'] as int?;
      if (m != null) s.model = ZxModel.values[m.clamp(0, ZxModel.values.length - 1)];
      s.quickLoad = j['quick_load'] as bool? ?? s.quickLoad;
      s.soundOn = j['sound_on'] as bool? ?? s.soundOn;
      s.vibration = j['vibration'] as bool? ?? s.vibration;
      if (j['video_mode'] != null) s.videoMode = VideoMode.byName(j['video_mode'] as String?);
      if (j['screen_border'] != null) s.screenBorder = ScreenBorder.byName(j['screen_border'] as String?);
      s.gigascreen = j['gigascreen'] as bool? ?? s.gigascreen;
      s.fitWidth = j['fit_width'] as bool? ?? s.fitWidth;
    } catch (_) {}
    return s;
  }

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
    s.soundOn = p.getBool('sound_on') ?? true;
    s.keepScreenOn = p.getBool('keep_screen_on') ?? true;
    s.startWithKeyboard = p.getBool('start_keyboard') ?? false;
    s.onlineInfo = p.getBool('online_info') ?? true;
    s.videoMode = VideoMode.byName(p.getString('video_mode'));
    s.gigascreen = p.getBool('gigascreen') ?? false;
    s.fitWidth = p.getBool('fit_width') ?? true;
    s.screenBorder = ScreenBorder.byName(p.getString('screen_border'));
    return s;
  }

  Future<void> save() async {
    final g = gamePath;
    if (g != null) {
      // Solo lo que difiere de los valores por defecto: lo demás sigue al menú principal.
      final d = await AppSettings.load();
      final all = <String, Object>{
        'model': model.index,
        'quick_load': quickLoad,
        'sound_on': soundOn,
        'vibration': vibration,
        'video_mode': videoMode.name,
        'screen_border': screenBorder.name,
        'gigascreen': gigascreen,
        'fit_width': fitWidth,
      };
      final base = <String, Object>{
        'model': d.model.index,
        'quick_load': d.quickLoad,
        'sound_on': d.soundOn,
        'vibration': d.vibration,
        'video_mode': d.videoMode.name,
        'screen_border': d.screenBorder.name,
        'gigascreen': d.gigascreen,
        'fit_width': d.fitWidth,
      };
      final diff = {for (final e in all.entries) if (base[e.key] != e.value) e.key: e.value};
      await MediaDb.put(g, {'cfg': diff.isEmpty ? null : jsonEncode(diff)});
      return;
    }
    final p = await SharedPreferences.getInstance();
    await p.setInt('model', model.index);
    await p.setString('joy_type', joyMapping.name);
    await p.setBool('quick_load', quickLoad);
    await p.setBool('vibration', vibration);
    await p.setBool('sound_on', soundOn);
    await p.setBool('keep_screen_on', keepScreenOn);
    await p.setBool('start_keyboard', startWithKeyboard);
    await p.setBool('online_info', onlineInfo);
    await p.setString('video_mode', videoMode.name);
    await p.setBool('gigascreen', gigascreen);
    await p.setBool('fit_width', fitWidth);
    await p.setString('screen_border', screenBorder.name);
  }
}
