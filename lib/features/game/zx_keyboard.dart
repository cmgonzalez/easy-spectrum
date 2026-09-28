import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/emulator/zx_types.dart';
import '../../core/theme/easy_theme.dart';

/// Definición de una tecla: etiqueta, palabra clave (modo K) y símbolo (Symbol Shift).
class _K {
  final String label;
  final int code;
  final String keyword;
  final String symbol;
  final int flex;
  const _K(this.label, this.code, [this.keyword = '', this.symbol = '', this.flex = 2]);
}

const _rows = <List<_K>>[
  [
    _K('1', ZxKey.k1, '', '!'), _K('2', ZxKey.k2, '', '@'), _K('3', ZxKey.k3, '', '#'),
    _K('4', ZxKey.k4, '', '\$'), _K('5', ZxKey.k5, '', '%'), _K('6', ZxKey.k6, '', '&'),
    _K('7', ZxKey.k7, '', "'"), _K('8', ZxKey.k8, '', '('), _K('9', ZxKey.k9, '', ')'),
    _K('0', ZxKey.k0, '', '_'),
  ],
  [
    _K('Q', ZxKey.q, 'PLOT', '<='), _K('W', ZxKey.w, 'DRAW', '<>'), _K('E', ZxKey.e, 'REM', '>='),
    _K('R', ZxKey.r, 'RUN', '<'), _K('T', ZxKey.t, 'RAND', '>'), _K('Y', ZxKey.y, 'RETURN', 'AND'),
    _K('U', ZxKey.u, 'IF', 'OR'), _K('I', ZxKey.i, 'INPUT', 'AT'), _K('O', ZxKey.o, 'POKE', ';'),
    _K('P', ZxKey.p, 'PRINT', '"'),
  ],
  [
    _K('A', ZxKey.a, 'NEW', 'STOP'), _K('S', ZxKey.s, 'SAVE', 'NOT'), _K('D', ZxKey.d, 'DIM', 'STEP'),
    _K('F', ZxKey.f, 'FOR', 'TO'), _K('G', ZxKey.g, 'GOTO', 'THEN'), _K('H', ZxKey.h, 'GOSUB', '↑'),
    _K('J', ZxKey.j, 'LOAD', '-'), _K('K', ZxKey.k, 'LIST', '+'), _K('L', ZxKey.l, 'LET', '='),
    _K('ENTER', ZxKey.enter),
  ],
  [
    _K('CAPS', ZxKey.caps, '', '', 3), _K('Z', ZxKey.z, 'COPY', ':'), _K('X', ZxKey.x, 'CLEAR', '£'),
    _K('C', ZxKey.c, 'CONT', '?'), _K('V', ZxKey.v, 'CLS', '/'), _K('B', ZxKey.b, 'BORDER', '*'),
    _K('N', ZxKey.n, 'NEXT', ','), _K('M', ZxKey.m, 'PAUSE', '.'), _K('SYM', ZxKey.sym, '', '', 3),
    _K('SPACE', ZxKey.space, '', '', 3),
  ],
];

/// Teclado completo del Spectrum 48K. Multitáctil: cada tecla escucha sus
/// propios punteros. CAPS SHIFT y SYMBOL SHIFT se fijan con un toque y se
/// sueltan solos tras la siguiente tecla (o se mantienen pulsados a la vez).
class ZxKeyboard extends StatefulWidget {
  final void Function(int code, bool pressed) onKey;
  final bool haptics;
  const ZxKeyboard({super.key, required this.onKey, this.haptics = true});

  @override
  State<ZxKeyboard> createState() => _ZxKeyboardState();
}

class _ZxKeyboardState extends State<ZxKeyboard> {
  final Set<int> _down = {};
  final Set<int> _latched = {};
  final Set<int> _modifierHeld = {};
  bool _usedWhileHeld = false;

  bool _isModifier(int code) => code == ZxKey.caps || code == ZxKey.sym;

  void _press(int code) {
    if (widget.haptics) HapticFeedback.selectionClick();
    setState(() => _down.add(code));
    if (_isModifier(code)) {
      _modifierHeld.add(code);
      _usedWhileHeld = false;
      if (!_latched.contains(code)) widget.onKey(code, true);
      return;
    }
    if (_modifierHeld.isNotEmpty) _usedWhileHeld = true;
    for (final m in _latched) {
      widget.onKey(m, true);
    }
    widget.onKey(code, true);
  }

  void _release(int code) {
    setState(() => _down.remove(code));
    if (_isModifier(code)) {
      _modifierHeld.remove(code);
      if (_usedWhileHeld) {
        widget.onKey(code, false);
      } else if (_latched.contains(code)) {
        // Segundo toque: desbloquear.
        _latched.remove(code);
        widget.onKey(code, false);
      } else {
        // Toque simple: queda fijada hasta la próxima tecla.
        _latched.add(code);
      }
      setState(() {});
      return;
    }
    widget.onKey(code, false);
    if (_latched.isNotEmpty) {
      for (final m in _latched) {
        widget.onKey(m, false);
      }
      setState(_latched.clear);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: ZxColors.body,
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
      child: Column(
        children: [
          for (final row in _rows)
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final k in row)
                    Expanded(
                      flex: k.flex,
                      child: _KeyCap(
                        k: k,
                        down: _down.contains(k.code),
                        latched: _latched.contains(k.code),
                        onDown: () => _press(k.code),
                        onUp: () => _release(k.code),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _KeyCap extends StatelessWidget {
  final _K k;
  final bool down;
  final bool latched;
  final VoidCallback onDown;
  final VoidCallback onUp;

  const _KeyCap({
    required this.k,
    required this.down,
    required this.latched,
    required this.onDown,
    required this.onUp,
  });

  @override
  Widget build(BuildContext context) {
    final isWide = k.label.length > 1;
    final bg = latched
        ? ZxColors.cyan.withValues(alpha: 0.55)
        : (down ? ZxColors.keyPressed : ZxColors.key);
    return Listener(
      onPointerDown: (_) => onDown(),
      onPointerUp: (_) => onUp(),
      onPointerCancel: (_) => onUp(),
      child: Container(
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.black, width: 1),
        ),
        child: Stack(
          children: [
            if (k.keyword.isNotEmpty)
              Positioned(
                top: 1,
                left: 0,
                right: 0,
                child: Text(k.keyword,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    style: const TextStyle(fontSize: 7.5, color: ZxColors.textDim)),
              ),
            Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Text(k.label,
                      style: TextStyle(
                        fontSize: isWide ? 13 : 20,
                        fontWeight: FontWeight.bold,
                        color: ZxColors.keyText,
                      )),
                ),
              ),
            ),
            if (k.symbol.isNotEmpty)
              Positioned(
                bottom: 1,
                right: 3,
                child: Text(k.symbol,
                    style: const TextStyle(
                        fontSize: 9, color: ZxColors.keyRed, fontWeight: FontWeight.bold)),
              ),
          ],
        ),
      ),
    );
  }
}
