import 'package:flutter/material.dart';

import '../../core/emulator/zx_types.dart';
import '../../core/l10n.dart';
import '../../core/settings.dart';
import '../../core/screen_border.dart';
import '../../core/video_mode.dart';
import '../../core/theme/easy_theme.dart';
import '../../core/pad_config.dart';
import '../about/about_screen.dart';
import '../game/pad_config_sheet.dart';

class SettingsScreen extends StatefulWidget {
  /// Con juego abierto: control del juego (pestaña "Juego") y aviso de cada cambio.
  final PadConfig? pad;
  final JoyMapping padFallback;
  final ValueChanged<PadConfig>? onPadChanged;
  /// Juego en curso (null = desde el menú principal: valores por defecto).
  final String? gamePath;
  final String? gameName;
  const SettingsScreen(
      {super.key, this.pad, this.padFallback = JoyMapping.kempston, this.onPadChanged, this.gamePath, this.gameName});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  AppSettings? _s;

  @override
  void initState() {
    super.initState();
    (widget.gamePath == null ? AppSettings.load() : AppSettings.loadForGame(widget.gamePath!)).then((s) => setState(() => _s = s));
  }

  void _update(void Function(AppSettings s) change) {
    setState(() => change(_s!));
    _s!.save();
  }

  Future<T?> _choose<T>(String title, List<T> values, String Function(T) label, T current) {
    return showDialog<T>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(title),
        children: [
          for (final v in values)
            ListTile(
              minTileHeight: 60,
              leading: Icon(
                v == current ? Icons.radio_button_checked : Icons.radio_button_off,
                color: ZxColors.cyan,
              ),
              title: Text(label(v)),
              onTap: () => Navigator.pop(ctx, v),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    final t = context.l10n;
    String joyLabel(JoyMapping m) => m == JoyMapping.keyboard ? t.joyQaop : m.label;
    final inGame = widget.gamePath != null;
    final general = s == null
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              _Header(t.machine),
              ListTile(
                leading: const Icon(Icons.memory_rounded, size: 32),
                title: Text(t.spectrumModel),
                subtitle: Text(t.spectrumModelSubtitle(s.model.label)),
                onTap: () async {
                  final v = await _choose(t.model, ZxModel.values, (m) => m.label, s.model);
                  if (v != null) _update((s) => s.model = v);
                },
              ),
              SwitchListTile(
                secondary: const Icon(Icons.fast_forward_rounded, size: 32),
                title: Text(t.quickLoad),
                subtitle: Text(t.quickLoadSubtitle),
                value: s.quickLoad,
                onChanged: (v) => _update((s) => s.quickLoad = v),
              ),
              _Header(t.screen),
              ListTile(
                leading: const Icon(Icons.tv_rounded, size: 32),
                title: Text(t.videoMode),
                subtitle: Text(s.videoMode.label(t)),
                onTap: () async {
                  final v = await _choose(t.videoMode, VideoMode.values, (m) => m.label(t), s.videoMode);
                  if (v != null) _update((s) => s.videoMode = v);
                },
              ),
              ListTile(
                leading: const Icon(Icons.crop_free_rounded, size: 32),
                title: Text(t.screenBorder),
                subtitle: Text(s.screenBorder.label(t)),
                onTap: () async {
                  final v = await _choose(t.screenBorder, ScreenBorder.values, (b) => b.label(t), s.screenBorder);
                  if (v != null) _update((s) => s.screenBorder = v);
                },
              ),
              SwitchListTile(
                secondary: const Icon(Icons.fit_screen_rounded, size: 32),
                title: Text(t.fitWidth),
                subtitle: Text(t.fitWidthSubtitle),
                value: s.fitWidth,
                onChanged: (v) => _update((s) => s.fitWidth = v),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.layers_rounded, size: 32),
                title: const Text('Gigascreen'),
                subtitle: Text(t.gigascreenSubtitle),
                value: s.gigascreen,
                onChanged: (v) => _update((s) => s.gigascreen = v),
              ),
              _Header(t.sound),
              SwitchListTile(
                secondary: const Icon(Icons.volume_up_rounded, size: 32),
                title: Text(t.sound),
                value: s.soundOn,
                onChanged: (v) => _update((s) => s.soundOn = v),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.vibration_rounded, size: 32),
                title: Text(t.vibration),
                value: s.vibration,
                onChanged: (v) => _update((s) => s.vibration = v),
              ),
              // Lo que sigue es de la app entera, no de un juego.
              if (!inGame) ...[
                _Header(t.controls),
                ListTile(
                  leading: const Icon(Icons.sports_esports_rounded, size: 32),
                  title: Text(t.joystickType),
                  subtitle: Text('${joyLabel(s.joyMapping)}\n${t.joystickTypeNote}'),
                  isThreeLine: true,
                  onTap: () async {
                    final v = await _choose(t.joystick, JoyMapping.values, joyLabel, s.joyMapping);
                    if (v != null) _update((s) => s.joyMapping = v);
                  },
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.keyboard_rounded, size: 32),
                  title: Text(t.startWithKeyboard),
                  subtitle: Text(t.startWithKeyboardSubtitle),
                  value: s.startWithKeyboard,
                  onChanged: (v) => _update((s) => s.startWithKeyboard = v),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.light_mode_rounded, size: 32),
                  title: Text(t.keepScreenOn),
                  value: s.keepScreenOn,
                  onChanged: (v) => _update((s) => s.keepScreenOn = v),
                ),
                _Header(t.library),
                SwitchListTile(
                  secondary: const Icon(Icons.travel_explore_rounded, size: 32),
                  title: Text(t.onlineInfo),
                  subtitle: Text(t.onlineInfoSubtitle),
                  value: s.onlineInfo,
                  onChanged: (v) => _update((s) => s.onlineInfo = v),
                ),
                const Divider(height: 32),
                ListTile(
                  leading: const Icon(Icons.info_outline_rounded, size: 32),
                  title: Text(t.about),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const AboutScreen()),
                  ),
                ),
              ],
            ],
          );
    // El título dice qué configuración se está editando: la de este juego o la
    // por defecto (la que heredan los juegos nuevos).
    final titleWidget = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(inGame ? widget.gameName ?? t.settings : t.settings, maxLines: 1, overflow: TextOverflow.ellipsis),
        Text(inGame ? t.configThisGame : t.configDefaults,
            style: const TextStyle(fontSize: 14, color: ZxColors.cyan, fontWeight: FontWeight.normal)),
      ],
    );
    final pad = widget.pad;
    if (pad == null) {
      return Scaffold(appBar: AppBar(title: titleWidget), body: general);
    }
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: titleWidget,
          bottom: TabBar(
            indicatorColor: ZxColors.cyan,
            labelStyle: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            tabs: [
              Tab(height: 64, icon: const Icon(Icons.settings_rounded), text: t.tabGeneral),
              Tab(height: 64, icon: const Icon(Icons.sports_esports_rounded), text: t.tabGame),
            ],
          ),
        ),
        body: TabBarView(
          physics: const NeverScrollableScrollPhysics(),
          children: [
            general,
            PadConfigEditor(
              initial: pad,
              fallback: widget.padFallback,
              onChanged: (c) => widget.onPadChanged?.call(c),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String text;
  const _Header(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 6),
      child: Text(text,
          style: const TextStyle(
              fontSize: 16, fontWeight: FontWeight.bold, color: ZxColors.cyan)),
    );
  }
}
