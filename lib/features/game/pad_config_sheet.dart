import 'package:flutter/material.dart';

import '../../core/emulator/zx_types.dart';
import '../../core/l10n.dart';
import '../../core/pad_config.dart';
import '../../core/theme/easy_theme.dart';

/// Nombre de tecla para mostrar (SPACE traducido).
String zxKeyName(BuildContext context, int key) =>
    key == ZxKey.space ? context.l10n.space.toUpperCase() : zxKeyLabel(key);

/// Panel del botón rojo del mando: tipo de control, teclas del modo Teclado y
/// botones extra. Devuelve la configuración nueva, o null si se cierra sin tocar "Listo".
Future<PadConfig?> showPadConfig(BuildContext context, PadConfig current, JoyMapping fallback) {
  return showModalBottomSheet<PadConfig>(
    context: context,
    isScrollControlled: true,
    backgroundColor: ZxColors.bodyLight,
    builder: (_) => _PadConfigSheet(initial: current, fallback: fallback),
  );
}

class _PadConfigSheet extends StatefulWidget {
  final PadConfig initial;
  final JoyMapping fallback;
  const _PadConfigSheet({required this.initial, required this.fallback});

  @override
  State<_PadConfigSheet> createState() => _PadConfigSheetState();
}

class _PadConfigSheetState extends State<_PadConfigSheet> {
  late PadConfig _c = widget.initial.copy();

  Future<void> _pickDirection(int i) async {
    final k = await showZxKeyPicker(context, _c.keys[i]);
    if (k != null) setState(() => _c.keys[i] = k);
  }

  Future<void> _pickSystem(int i) async {
    final k = await showZxKeyPicker(context, _c.systemKeys[i]);
    if (k != null) setState(() => _c.systemKeys[i] = k);
  }

  Future<void> _pickExtra(int i) async {
    final k = await showZxKeyPicker(context, _c.extra[i]);
    if (k != null) setState(() => _c.extra[i] = k);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.l10n;
    final dirs = [t.dirUp, t.dirDown, t.dirLeft, t.dirRight, t.fire];
    String typeLabel(JoyMapping m) => m == JoyMapping.keyboard ? t.joyKeyboard : m.label;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.9),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          children: [
            Text(t.padConfig, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            Text(t.padConfigNote, style: const TextStyle(fontSize: 16, color: ZxColors.textDim)),
            const SizedBox(height: 16),
            _Section(t.controlType),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final m in JoyMapping.values)
                  ChoiceChip(
                    label: Text(typeLabel(m), style: const TextStyle(fontSize: 18)),
                    selected: _c.type == m,
                    selectedColor: ZxColors.cyan,
                    labelStyle: TextStyle(color: _c.type == m ? Colors.black : null),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                    onSelected: (_) => setState(() => _c.type = m),
                  ),
              ],
            ),
            if (_c.type == JoyMapping.keyboard) ...[
              const SizedBox(height: 16),
              _Section(t.padKeys),
              for (var i = 0; i < 5; i++)
                _Row(
                  title: dirs[i],
                  trailing: _KeyChip(zxKeyName(context, _c.keys[i]), onTap: () => _pickDirection(i)),
                ),
            ],
            const SizedBox(height: 16),
            _Section(t.actionButtons),
            // Elegir la botonera por su dibujo: 1-4 botones.
            Row(
              children: [
                for (var n = 1; n <= PadConfig.maxButtons; n++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: _ButtonsOption(
                        asset: 'assets/skin/buttons_$n.png',
                        label: '$n',
                        selected: _c.buttons == n,
                        onTap: () => setState(() => _c.buttons = n),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            for (var i = 0; i < _c.buttons; i++)
              _Row(
                leading: Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _buttonColours[i],
                    border: Border.all(color: Colors.black54, width: 2),
                  ),
                ),
                title: i == 0 ? t.fire : t.extraButton(i + 1),
                trailing: i == 0
                    ? null
                    : _KeyChip(zxKeyName(context, _c.extra[i - 1]), onTap: () => _pickExtra(i - 1)),
              ),
            const SizedBox(height: 16),
            _Section(t.systemButtons),
            // Ninguno / 1 / 2 botones Select-Start sobre el LCD.
            Row(
              children: [
                for (var n = 0; n <= PadConfig.maxSystem; n++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: _ButtonsOption(
                        asset: n == 0 ? null : 'assets/skin/select_$n.png',
                        label: n == 0 ? t.none : '$n',
                        selected: _c.system == n,
                        onTap: () => setState(() => _c.system = n),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            for (var i = 0; i < _c.system; i++)
              _Row(
                leading: Container(
                  width: 40,
                  height: 22,
                  decoration: BoxDecoration(
                    color: const Color(0xFF9BA0A8),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.black54, width: 2),
                  ),
                ),
                title: t.extraButton(i + 1),
                trailing: _KeyChip(zxKeyName(context, _c.systemKeys[i]), onTap: () => _pickSystem(i)),
              ),
            const SizedBox(height: 20),
            Row(
              children: [
                TextButton(
                  onPressed: () => setState(() => _c = PadConfig(type: widget.fallback)),
                  child: Text(t.padReset, style: const TextStyle(fontSize: 18)),
                ),
                const Spacer(),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: ZxColors.cyan,
                    foregroundColor: Colors.black,
                    minimumSize: const Size(140, 56),
                  ),
                  onPressed: () => Navigator.pop(context, _c),
                  child: Text(t.padDone, style: const TextStyle(fontSize: 20)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Colores de la botonera (rojo = fuego, amarillo, verde, azul).
const _buttonColours = [Color(0xFFE8322B), Color(0xFFF5C400), Color(0xFF1FBF3A), Color(0xFF12B5E8)];

/// Opción de botonera: su dibujo (o nada) y un rótulo.
class _ButtonsOption extends StatelessWidget {
  final String? asset;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _ButtonsOption({this.asset, required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) => Material(
        color: selected ? ZxColors.cyan.withValues(alpha: 0.18) : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: selected ? ZxColors.cyan : Colors.white24, width: selected ? 3 : 1),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Column(
              children: [
                SizedBox(
                  height: 64,
                  child: Center(child: asset == null ? null : Image.asset(asset!)),
                ),
                const SizedBox(height: 4),
                Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
        ),
      );
}

class _Section extends StatelessWidget {
  final String text;
  const _Section(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text.toUpperCase(),
            style: const TextStyle(
                fontSize: 15, fontWeight: FontWeight.bold, color: ZxColors.cyan, letterSpacing: 1)),
      );
}

class _Row extends StatelessWidget {
  final Widget? leading;
  final String title;
  final Widget? trailing;
  const _Row({this.leading, required this.title, this.trailing});

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 64,
        child: Row(
          children: [
            if (leading != null) ...[leading!, const SizedBox(width: 12)],
            Expanded(child: Text(title, style: const TextStyle(fontSize: 20))),
            if (trailing != null) trailing!,
          ],
        ),
      );
}

class _KeyChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _KeyChip(this.label, {required this.onTap});

  @override
  Widget build(BuildContext context) => OutlinedButton(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(96, 52),
          side: const BorderSide(color: ZxColors.yellow, width: 2),
          foregroundColor: ZxColors.yellow,
        ),
        onPressed: onTap,
        child: Text(label, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
      );
}

/// Teclado del Spectrum en 4 filas para elegir una tecla.
Future<int?> showZxKeyPicker(BuildContext context, int? current) {
  return showDialog<int>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: ZxColors.body,
      insetPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 24),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(ctx.l10n.chooseKey, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            for (final row in zxKeyRows)
              Row(
                children: [
                  for (final k in row)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(2),
                        child: SizedBox(
                          height: 56,
                          child: Material(
                            color: k == current ? ZxColors.cyan : ZxColors.bodyLight,
                            borderRadius: BorderRadius.circular(8),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(8),
                              onTap: () => Navigator.pop(ctx, k),
                              child: Center(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 2),
                                  child: FittedBox(
                                    child: Text(
                                      zxKeyName(ctx, k),
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                        color: k == current ? Colors.black : Colors.white,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    ),
  );
}
