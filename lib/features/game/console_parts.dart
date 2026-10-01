import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../core/emulator/zx_types.dart';
import '../../core/haptics.dart';

/// Acciones de los botones de colores, en orden: rojo, amarillo, verde, azul.
enum PadAction {
  config(Icons.tune_rounded), // configuración (juego + general)
  sound(Icons.volume_up_rounded), // sonido sí/no
  keyboard(Icons.keyboard_rounded), // cambiar mando ↔ teclado
  exit(Icons.format_list_bulleted_rounded); // volver a la lista

  const PadAction(this.icon);
  final IconData icon;
}

const padActionColours = [Color(0xFFE8322B), Color(0xFFF5C400), Color(0xFF1FBF3A), Color(0xFF12B5E8)];

/// Texto centrado en [center]; si es más ancho que [maxWidth] se encoge.
void paintCenteredText(Canvas canvas, String text, Offset center, TextStyle style, {double? maxWidth}) {
  final tp = TextPainter(text: TextSpan(text: text, style: style), textDirection: TextDirection.ltr)..layout();
  final k = maxWidth != null && tp.width > maxWidth ? maxWidth / tp.width : 1.0;
  canvas.save();
  canvas.translate(center.dx, center.dy);
  canvas.scale(k);
  tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
  canvas.restore();
}

void paintIcon(Canvas canvas, IconData icon, Offset center, double size, Color color) => paintCenteredText(
      canvas,
      String.fromCharCode(icon.codePoint),
      center,
      TextStyle(fontSize: size, color: color, fontFamily: icon.fontFamily, package: icon.fontPackage, height: 1),
    );

/// Fila de los 4 botones de acción (mismo lugar con mando y con teclado). La acción
/// se dispara al soltar (puede abrir un panel o cambiar de pantalla).
class ActionButtons extends StatefulWidget {
  final void Function(PadAction action) onAction;
  /// Con el teclado a la vista, el verde vuelve al mando (ícono de mando).
  final bool keyboardMode;
  final bool soundOn;
  final bool haptics;
  const ActionButtons(
      {super.key, required this.onAction, this.keyboardMode = false, this.soundOn = true, this.haptics = true});

  @override
  State<ActionButtons> createState() => _ActionButtonsState();
}

class _ActionButtonsState extends State<ActionButtons> {
  final Map<int, int> _pointers = {}; // puntero → botón

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final h = box.maxHeight;
      final w = h * 1.6, gap = h * 0.22;
      final rects = [
        for (var i = 0; i < 4; i++) Rect.fromLTWH(box.maxWidth - (4 - i) * w - (3 - i) * gap, 0, w, h),
      ];
      int? hit(Offset p) {
        for (var i = 0; i < 4; i++) {
          if (rects[i].inflate(gap / 2).contains(p)) return i;
        }
        return null;
      }

      return Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (e) {
          final i = hit(e.localPosition);
          if (i == null) return;
          if (widget.haptics) Haptics.press();
          setState(() => _pointers[e.pointer] = i);
        },
        onPointerUp: (e) {
          final i = _pointers.remove(e.pointer);
          if (i == null) return;
          setState(() {});
          widget.onAction(PadAction.values[i]);
        },
        onPointerCancel: (e) => setState(() => _pointers.remove(e.pointer)),
        child: CustomPaint(
          size: Size(box.maxWidth, h),
          painter: _ActionsPainter(rects, {..._pointers.values}, widget.keyboardMode, widget.soundOn),
        ),
      );
    });
  }
}

class _ActionsPainter extends CustomPainter {
  final List<Rect> rects;
  final Set<int> down;
  final bool keyboardMode;
  final bool soundOn;
  _ActionsPainter(this.rects, this.down, this.keyboardMode, this.soundOn);

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < rects.length; i++) {
      final r = rects[i];
      final rr = RRect.fromRectAndRadius(r, Radius.circular(r.height * 0.22));
      canvas.drawRRect(rr.shift(Offset(0, r.height * 0.05)), Paint()..color = Colors.black.withValues(alpha: 0.6));
      canvas.drawRRect(
        rr,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: down.contains(i)
                ? const [Color(0xFF1E2023), Color(0xFF2C2F33)]
                : const [Color(0xFF45484D), Color(0xFF26282B)],
          ).createShader(r),
      );
      canvas.drawRRect(
          rr.deflate(r.height * 0.03),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = r.height * 0.07
            ..color = padActionColours[i]);
      final action = PadAction.values[i];
      final icon = keyboardMode && action == PadAction.keyboard
          ? Icons.sports_esports_rounded
          : !soundOn && action == PadAction.sound
              ? Icons.volume_off_rounded
              : action.icon;
      paintIcon(canvas, icon, r.center, r.height * 0.6, Colors.white.withValues(alpha: 0.92));
    }
  }

  @override
  bool shouldRepaint(_ActionsPainter old) =>
      old.rects.length != rects.length ||
      old.rects.first != rects.first ||
      old.keyboardMode != keyboardMode ||
      old.soundOn != soundOn ||
      old.down.length != down.length ||
      !old.down.containsAll(down);
}

/// Pantalla LCD bajo la pantalla del juego: letrero que avanza en bucle (juego,
/// datos, control…) y sus dos mitades son ENTER | ESPACIO (la pulsada, en negativo).
class LcdPanel extends StatefulWidget {
  static const aspect = 582 / 134; // assets/skin/lcd.png
  final String text;
  final String spaceLabel;
  final void Function(int code, bool pressed) onKey;
  final bool haptics;
  /// Franja fija inferior: modelo ("128K", "+2"…), y los indicadores ULA+ y NEXT
  /// (apagados = tenues, como los segmentos de un LCD). [ulaplus] se consulta en cada cuadro.
  final String modelLabel;
  final bool next;
  final bool Function() ulaplus;
  const LcdPanel({
    super.key,
    required this.text,
    required this.spaceLabel,
    required this.onKey,
    this.haptics = true,
    this.modelLabel = '',
    this.next = false,
    this.ulaplus = _never,
  });

  static bool _never() => false;

  @override
  State<LcdPanel> createState() => _LcdPanelState();
}

class _LcdPanelState extends State<LcdPanel> with SingleTickerProviderStateMixin {
  // Reloj del letrero: solo repinta el LCD.
  final _clock = ValueNotifier<double>(0);
  late final Ticker _ticker;
  final Map<int, int> _pointers = {}; // puntero → tecla

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((d) => _clock.value = d.inMicroseconds / 1e6)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth;
      return Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (e) {
          final code = e.localPosition.dx < w / 2 ? ZxKey.enter : ZxKey.space;
          if (_pointers.containsValue(code)) return;
          if (widget.haptics) Haptics.press();
          setState(() => _pointers[e.pointer] = code);
          widget.onKey(code, true);
        },
        onPointerUp: (e) => _release(e.pointer),
        onPointerCancel: (e) => _release(e.pointer),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.asset('assets/skin/lcd.png', fit: BoxFit.fill, gaplessPlayback: true),
            CustomPaint(
              painter: _LcdPainter(
                clock: _clock,
                text: widget.text,
                enter: _pointers.containsValue(ZxKey.enter),
                space: _pointers.containsValue(ZxKey.space),
                spaceLabel: widget.spaceLabel,
                modelLabel: widget.modelLabel,
                next: widget.next,
                ulaplus: widget.ulaplus,
              ),
            ),
          ],
        ),
      );
    });
  }

  void _release(int pointer) {
    final code = _pointers.remove(pointer);
    if (code == null) return;
    setState(() {});
    widget.onKey(code, false);
  }
}

class _LcdPainter extends CustomPainter {
  final ValueNotifier<double> clock;
  final String text;
  final bool enter;
  final bool space;
  final String spaceLabel;
  final String modelLabel;
  final bool next;
  final bool Function() ulaplus;
  _LcdPainter({
    required this.clock,
    required this.text,
    required this.enter,
    required this.space,
    required this.spaceLabel,
    required this.modelLabel,
    required this.next,
    required this.ulaplus,
  }) : super(repaint: clock);

  static const _ink = Color(0xFF263022);
  static const _light = Color(0xFF9DAA8C);
  // Vidrio dentro de lcd.png (582×134): (14, 14)-(568, 120).
  static const _glass = Rect.fromLTRB(14 / 582, 14 / 134, 568 / 582, 120 / 134);

  double _lastLeft = 0;
  static String? _cachedText;
  static double? _cachedSize;
  static TextPainter? _cached;

  static TextPainter _paintText(String text, double size, Color color) => TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            fontSize: size,
            fontWeight: FontWeight.w900,
            color: color,
            letterSpacing: size * 0.08,
            fontFamily: 'monospace',
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

  @override
  void paint(Canvas canvas, Size size) {
    final screen = Rect.fromLTRB(_glass.left * size.width, _glass.top * size.height,
            _glass.right * size.width, _glass.bottom * size.height)
        .deflate(size.height * 0.04);
    final fontSize = screen.height * 0.46;
    // Franja fija inferior (modelo, ULA+, NEXT); el letrero ocupa lo de arriba.
    final stripH = screen.height * 0.27;
    final main = Rect.fromLTRB(screen.left, screen.top, screen.right, screen.bottom - stripH);
    canvas.save();
    canvas.clipRect(screen);
    if (text.isNotEmpty) {
      final tp = _cachedText == text && _cachedSize == fontSize && _cached != null
          ? _cached!
          : (_cached = _paintText(text, fontSize, _ink.withValues(alpha: 0.9)));
      _cachedText = text;
      _cachedSize = fontSize;
      final y = main.center.dy - tp.height / 2;
      if (tp.width <= screen.width) {
        tp.paint(canvas, Offset(screen.center.dx - tp.width / 2, y));
      } else {
        final speed = screen.height * 1.0; // px por segundo
        final period = tp.width + screen.height * 1.5;
        var x = screen.left + screen.width * 0.25 - (clock.value * speed) % period;
        for (; x < screen.right; x += period) {
          tp.paint(canvas, Offset(x, y));
        }
      }
    }
    // Franja: modelo a la izquierda; ULA+ y NEXT a la derecha (tenues si están apagados).
    final strip = Rect.fromLTRB(screen.left, screen.bottom - stripH, screen.right, screen.bottom);
    canvas.drawLine(strip.topLeft + const Offset(4, 0), strip.topRight - const Offset(4, 0),
        Paint()..color = _ink.withValues(alpha: 0.18)..strokeWidth = 1);
    final sf = stripH * 0.74;
    final pad = screen.width * 0.025;
    void stripText(String s, double alpha, {bool right = false, double? edge}) {
      final tp = _paintText(s, sf, _ink.withValues(alpha: alpha));
      final x = right ? (edge ?? strip.right - pad) - tp.width : strip.left + pad;
      tp.paint(canvas, Offset(x, strip.center.dy - tp.height / 2 + 1));
      _lastLeft = x;
    }
    if (modelLabel.isNotEmpty) stripText(modelLabel, 0.9);
    stripText('NEXT', next ? 0.9 : 0.14, right: true);
    stripText('ULA+', ulaplus() ? 0.9 : 0.14, right: true, edge: _lastLeft - sf * 1.0);
    final halves = [
      (enter, Rect.fromLTRB(screen.left, screen.top, screen.center.dx, screen.bottom), 'ENTER'),
      (space, Rect.fromLTRB(screen.center.dx, screen.top, screen.right, screen.bottom), spaceLabel),
    ];
    for (final (on, r, label) in halves) {
      if (!on) continue;
      canvas.drawRect(r, Paint()..color = _ink.withValues(alpha: 0.92));
      final tp = _paintText(label.toUpperCase(), fontSize * 1.05, _light);
      tp.paint(canvas, r.center - Offset(tp.width / 2, tp.height / 2));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_LcdPainter old) =>
      old.text != text ||
      old.enter != enter ||
      old.space != space ||
      old.modelLabel != modelLabel ||
      old.next != next;
}
