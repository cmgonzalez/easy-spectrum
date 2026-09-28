import 'package:flutter/material.dart';

import '../../core/emulator/zx_types.dart';
import '../../core/settings.dart';
import '../../core/theme/easy_theme.dart';
import '../about/about_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  AppSettings? _s;

  @override
  void initState() {
    super.initState();
    AppSettings.load().then((s) => setState(() => _s = s));
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
    return Scaffold(
      appBar: AppBar(title: const Text('Ajustes')),
      body: s == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                const _Header('Máquina'),
                ListTile(
                  leading: const Icon(Icons.memory_rounded, size: 32),
                  title: const Text('Modelo de Spectrum'),
                  subtitle: Text('${s.model.label} — los snapshots (.z80, .sna) usan su propio modelo'),
                  onTap: () async {
                    final v = await _choose('Modelo', ZxModel.values, (m) => m.label, s.model);
                    if (v != null) _update((s) => s.model = v);
                  },
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.fast_forward_rounded, size: 32),
                  title: const Text('Carga rápida de cintas'),
                  subtitle: const Text('Los juegos .tap/.tzx cargan al instante'),
                  value: s.quickLoad,
                  onChanged: (v) => _update((s) => s.quickLoad = v),
                ),
                const _Header('Controles'),
                ListTile(
                  leading: const Icon(Icons.sports_esports_rounded, size: 32),
                  title: const Text('Tipo de joystick'),
                  subtitle: Text(s.joyMapping.label),
                  onTap: () async {
                    final v = await _choose(
                        'Joystick', JoyMapping.values, (m) => m.label, s.joyMapping);
                    if (v != null) _update((s) => s.joyMapping = v);
                  },
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.keyboard_rounded, size: 32),
                  title: const Text('Empezar con el teclado'),
                  subtitle: const Text('Si no, se muestra el mando'),
                  value: s.startWithKeyboard,
                  onChanged: (v) => _update((s) => s.startWithKeyboard = v),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.vibration_rounded, size: 32),
                  title: const Text('Vibrar al pulsar'),
                  value: s.vibration,
                  onChanged: (v) => _update((s) => s.vibration = v),
                ),
                const _Header('Pantalla'),
                SwitchListTile(
                  secondary: const Icon(Icons.light_mode_rounded, size: 32),
                  title: const Text('Mantener pantalla encendida'),
                  value: s.keepScreenOn,
                  onChanged: (v) => _update((s) => s.keepScreenOn = v),
                ),
                const Divider(height: 32),
                ListTile(
                  leading: const Icon(Icons.info_outline_rounded, size: 32),
                  title: const Text('Acerca de'),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const AboutScreen()),
                  ),
                ),
              ],
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
