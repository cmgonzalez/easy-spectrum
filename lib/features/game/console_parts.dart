import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../core/emulator/zx_types.dart';
import '../../core/haptics.dart';
import '../../core/theme/easy_theme.dart';

/// Acciones de los botones de la fila bajo el LCD, de izquierda a derecha.
enum PadAction {
  keyboard(Icons.keyboard_rounded), // cambiar mando ↔ teclado ↔ ratón
  pause(Icons.pause_rounded), // pausa / continuar el Spectrum
  sound(Icons.volume_up_rounded), // sonido sí/no
  config(Icons.tune_rounded), // configuración (juego + general)
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
  /// Ícono del verde = el modo de controles que viene (mando → teclado → cassette).
  /// null = el de siempre según [keyboardMode].
  final IconData? inputIcon;
  final bool soundOn;
  final bool paused;
  final bool haptics;
  /// Luz gamer en los bordes; apagada = borde negro simple.
  final bool light;
  const ActionButtons(
      {super.key,
      this.light = true,
      required this.onAction,
      this.keyboardMode = false,
      this.inputIcon,
      this.soundOn = true,
      this.paused = false,
      this.haptics = true});

  @override
  State<ActionButtons> createState() => _ActionButtonsState();
}

class _ActionButtonsState extends State<ActionButtons> with SingleTickerProviderStateMixin {
  final Map<int, int> _pointers = {}; // puntero → botón
  // Luz "gamer": los 4 colores del Spectrum giran por el borde de cada botón. Un Ticker
  // propio que solo repinta los botones (segundos transcurridos).
  final _time = ValueNotifier<double>(0);
  late final Ticker _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((d) => _time.value = d.inMicroseconds / 1e6);
    if (widget.light) _ticker.start();
  }

  @override
  void didUpdateWidget(ActionButtons old) {
    super.didUpdateWidget(old);
    if (widget.light && !_ticker.isActive) {
      _ticker.start();
    } else if (!widget.light && _ticker.isActive) {
      _ticker.stop();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _time.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final h = box.maxHeight;
      final n = PadAction.values.length;
      final w = h * 1.6, gap = h * 0.22;
      final rects = [
        for (var i = 0; i < n; i++) Rect.fromLTWH(box.maxWidth - (n - i) * w - (n - 1 - i) * gap, 0, w, h),
      ];
      int? hit(Offset p) {
        for (var i = 0; i < n; i++) {
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
          painter: _ActionsPainter(rects, {..._pointers.values}, widget.keyboardMode, widget.soundOn, widget.paused, widget.inputIcon, _time, widget.light),
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
  final bool paused;
  final IconData? inputIcon;
  final ValueNotifier<double> time;
  final bool light;
  _ActionsPainter(this.rects, this.down, this.keyboardMode, this.soundOn, this.paused, this.inputIcon, this.time, this.light)
      : super(repaint: time);

  /// Una banda continua que recorre los 4 botones: negro, los 4 colores del Spectrum y negro
  /// otra vez (los tramos negros son los huecos entre una pasada y la siguiente).
  static final _band = [
    const Color(0xFF000000),
    const Color(0xFF000000),
    ...ZxColors.rainbow,
    const Color(0xFF000000),
    const Color(0xFF000000),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    // Un solo degradado lineal sobre toda la fila, desplazado con el tiempo: la luz pasa de un
    // botón al siguiente en vez de girar dentro de cada uno.
    final row = Rect.fromLTRB(rects.first.left, rects.first.top, rects.last.right, rects.last.bottom);
    final period = row.width * 1.2;
    final shift = (time.value / 4 % 1) * period;
    final sweep = LinearGradient(colors: _band, tileMode: TileMode.repeated)
        .createShader(Rect.fromLTWH(row.left + shift - period, row.top, period, row.height));
    for (var i = 0; i < rects.length; i++) {
      final r = rects[i];
      final rr = RRect.fromRectAndRadius(r, Radius.circular(r.height * 0.22));
      canvas.drawRRect(
          rr.inflate(r.height * 0.03).shift(Offset(0, r.height * 0.05)),
          light
              ? (Paint()
                ..shader = sweep
                ..color = Colors.white.withValues(alpha: 0.85))
              : (Paint()..color = Colors.black.withValues(alpha: 0.6)));
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
      final border = rr.deflate(r.height * 0.03);
      if (light) {
        // Luz gamer: halo difuso + borde con la banda que recorre los 4 botones.
        // Pulsado, el halo brilla más.
        final pressed = down.contains(i);
        canvas.drawRRect(
            border,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = r.height * (pressed ? 0.30 : 0.20)
              ..maskFilter = MaskFilter.blur(BlurStyle.normal, r.height * 0.14)
              ..shader = sweep
              ..color = Colors.white.withValues(alpha: pressed ? 0.95 : 0.55));
        canvas.drawRRect(
            border,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = r.height * 0.07
              ..shader = sweep);
      } else {
        canvas.drawRRect(
            border,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = r.height * 0.07
              ..color = Colors.black);
      }
      final action = PadAction.values[i];
      final icon = action == PadAction.pause
          ? (paused ? Icons.play_arrow_rounded : Icons.pause_rounded)
          : inputIcon != null && action == PadAction.keyboard
          ? inputIcon!
          : keyboardMode && action == PadAction.keyboard
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
      old.inputIcon != inputIcon ||
      old.soundOn != soundOn ||
      old.light != light ||
      old.paused != paused ||
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
