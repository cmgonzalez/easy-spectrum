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
            _Section(t.extraButtons),
            for (var i = 0; i < PadConfig.maxExtra; i++)
              _Row(
                leading: Switch(
                  value: _c.extra[i] != null,
                  onChanged: (on) {
                    if (on) {
                      _pickExtra(i);
                    } else {
                      setState(() => _c.extra[i] = null);
                    }
                  },
                ),
                title: t.extraButton(i + 1),
                trailing: _c.extra[i] == null
                    ? null
                    : _KeyChip(zxKeyName(context, _c.extra[i]!), onTap: () => _pickExtra(i)),
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
