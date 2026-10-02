import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../core/haptics.dart';
import '../../core/tape/tape_controller.dart';
import '../../core/theme/easy_theme.dart';
import '../game/console_parts.dart' show paintIcon;

/// Grabadora de cassette (Android): tercer modo del área de controles, junto a mando y
/// teclado. Ventanilla con la cinta y dos carretes que giran mientras corre (más rápido al
/// avanzar/rebobinar, parados en pausa), contador mecánico = bloque actual, y las teclas
/// ● REC · ▶ PLAY · ⏪ REW · ⏩ FF · ■ STOP (mantener = expulsar). Todo dibujado por código
/// con la estética de la consola; la vista de la lista (y el editor) es una hoja aparte
/// que se abre tocando la ventanilla. Ver doc/TAPE_MANAGER.md.
class TapeDeck extends StatefulWidget {
  final TapeController controller;
  final VoidCallback onRecord;
  final VoidCallback onShowList;
  final bool haptics;

  /// Nombre del juego (a bolígrafo en la etiqueta) y modelo (placa bajo el arcoíris).
  final String title;
  final String machine;
  const TapeDeck({
    super.key,
    required this.controller,
    required this.onRecord,
    required this.onShowList,
    this.haptics = true,
    this.title = '',
    this.machine = 'ZX SPECTRUM',
  });

  @override
  State<TapeDeck> createState() => _TapeDeckState();
}

enum _Key { rec, play, rew, ff, stop }

class _TapeDeckState extends State<TapeDeck> with SingleTickerProviderStateMixin {
  // Ángulo de cada carrete (dx izquierdo, dy derecho): un Ticker propio que solo repinta.
  // El carrete con menos cinta gira más rápido, así que cada uno integra el suyo.
  final _angle = ValueNotifier<Offset>(Offset.zero);
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  double _spinFast = 0; // s que quedan girando rápido (tras REW/FF)
  int _spinDir = 1;
  final Map<int, _Key> _pointers = {};
  DateTime? _stopDown;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick)..start();
    widget.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(TapeDeck old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _ticker.dispose();
    _angle.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _tick(Duration now) {
    final dt = ((now - _last).inMicroseconds / 1e6).clamp(0.0, 0.1);
    _last = now;
    final c = widget.controller;
    double speed = 0; // vueltas por segundo
    if (_spinFast > 0) {
      _spinFast -= dt;
      speed = 4.0 * _spinDir;
    } else if (c.info.isPlaying || c.recording) {
      speed = c.info.isPlaying && !c.recording ? 0.6 : 0.5;
    }
    if (speed != 0) {
      final prog = c.total == 0 ? 0.0 : (c.info.block / c.total).clamp(0.0, 1.0);
      final (rl, rr) = _reelRadii(prog);
      final k = speed * dt * 2 * math.pi;
      _angle.value = _angle.value + Offset(k * _maxR / rl, k * _maxR / rr);
    }
  }

  // --- Geometría (fracciones del área) ---------------------------------------

  static Rect _bodyRect(Size s) {
    final w = math.min(s.width * 0.92, s.height * 1.55);
    final h = math.min(s.height * 0.62, w * 0.62);
    return Rect.fromLTWH((s.width - w) / 2, s.height * 0.04, w, h);
  }

  static List<Rect> _keyRects(Size s) {
    final body = _bodyRect(s);
    final top = body.bottom + s.height * 0.06;
    final h = math.max(64.0, s.height - top - s.height * 0.04);
    const n = 5;
    final gap = body.width * 0.02;
    final w = (body.width - gap * (n - 1)) / n;
    return [for (var i = 0; i < n; i++) Rect.fromLTWH(body.left + i * (w + gap), top, w, math.min(h, s.height - top))];
  }

  // --- Toques ----------------------------------------------------------------

  _Key? _hitKey(Size s, Offset p) {
    final keys = _keyRects(s);
    for (var i = 0; i < keys.length; i++) {
      if (keys[i].inflate(4).contains(p)) return _Key.values[i];
    }
    return null;
  }

  void _down(Size s, PointerDownEvent e) {
    final k = _hitKey(s, e.localPosition);
    if (k == null) {
      if (_bodyRect(s).contains(e.localPosition)) widget.onShowList();
      return;
    }
    if (widget.haptics) Haptics.press();
    if (k == _Key.stop) _stopDown = DateTime.now();
    setState(() => _pointers[e.pointer] = k);
  }

  void _up(PointerUpEvent e) {
    final k = _pointers.remove(e.pointer);
    if (k == null) return;
    setState(() {});
    final c = widget.controller;
    switch (k) {
      case _Key.rec:
        widget.onRecord();
      case _Key.play:
        c.togglePlay();
      case _Key.rew:
        _spin(-1);
        c.previous();
      case _Key.ff:
        _spin(1);
        c.next();
      case _Key.stop:
        // Mantener ≥ 0,6 s = expulsar; si no, detener (vuelve al inicio del bloque).
        final held = _stopDown == null ? Duration.zero : DateTime.now().difference(_stopDown!);
        if (held >= const Duration(milliseconds: 600)) {
          c.eject();
        } else {
          c.stop();
        }
    }
  }

  void _spin(int dir) {
    _spinDir = dir;
    _spinFast = 0.6;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final size = Size(box.maxWidth, box.maxHeight);
      final c = widget.controller;
      final latched = <_Key>{
        if (c.recording) _Key.rec,
        if (c.info.isPlaying) _Key.play,
      };
      return Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (e) => _down(size, e),
        onPointerUp: _up,
        onPointerCancel: (e) => setState(() => _pointers.remove(e.pointer)),
        child: CustomPaint(
          size: size,
          painter: _DeckPainter(
            angle: _angle,
            hasTape: c.hasTape,
            counter: c.hasList ? (c.info.block + 1).clamp(0, 999) : 0,
            progress: c.total == 0 ? 0 : (c.info.block / c.total).clamp(0.0, 1.0),
            down: {..._pointers.values, ...latched},
            recording: c.recording,
            playing: c.info.isPlaying,
            title: widget.title,
            machine: widget.machine,
          ),
        ),
      );
    });
  }
}

// Radios de cinta de los carretes como fracción del ancho del cassette: el izquierdo se vacía
// (progress 0 = todo a la izquierda) y el derecho se llena. Sobrepasan la ventanilla y se recortan.
const double _maxR = 0.160;
const double _minR = 0.102;
(double, double) _reelRadii(double progress) => (_maxR - (_maxR - _minR) * progress, _minR + (_maxR - _minR) * progress);

class _DeckPainter extends CustomPainter {
  final ValueNotifier<Offset> angle;
  final bool hasTape;
  final int counter;
  final double progress; // 0 = toda la cinta en el carrete izquierdo
  final Set<_Key> down;
  final bool recording;
  final bool playing;
  final String title;
  final String machine;
  _DeckPainter({
    required this.angle,
    required this.hasTape,
    required this.counter,
    required this.progress,
    required this.down,
    required this.recording,
    required this.playing,
    required this.title,
    required this.machine,
  }) : super(repaint: angle);

  static const _body = Color(0xFF3D4F5F);
  static const _bodyDark = Color(0xFF2C3A47);
  static const _label = Color(0xFFF2E8D5);
  static const _labelLine = Color(0xFFBCAAA4);
  static const _labelRule = Color(0xFFDFD5CC);
  static const _reelWhite = Color(0xFFF5F5F5);
  static const _reelShadow = Color(0xFFD0D0D0);
  static const _tapePack = Color(0xFF5A3A22);
  static const _tapeStrand = Color(0xFF5A5A5A);

  @override
  void paint(Canvas canvas, Size size) {
    final body = _TapeDeckState._bodyRect(size);
    final w = body.width, h = body.height;
    final r = w * 0.018;
    canvas.drawRRect(
        RRect.fromRectAndRadius(body, Radius.circular(r)).shift(Offset(0, h * 0.03)),
        Paint()..color = Colors.black.withValues(alpha: 0.6));
    canvas.save();
    canvas.translate(body.left, body.top);
    if (hasTape) {
      _cassette(canvas, w, h, r);
    } else {
      _emptyDeck(canvas, w, h, r);
    }
    canvas.restore();
    _keys(canvas, size);
  }

  /// Grabadora sin cinta: carcasa oscura con la ventanilla vacía.
  void _emptyDeck(Canvas canvas, double w, double h, double r) {
    final bodyR = RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, w, h), Radius.circular(r));
    canvas.drawRRect(bodyR, Paint()..color = const Color(0xFF1E2023));
    final win = Rect.fromLTWH(w * 0.20, h * 0.30, w * 0.60, h * 0.40);
    canvas.drawRRect(RRect.fromRectAndRadius(win, Radius.circular(r * 0.5)), Paint()..color = const Color(0xFF0B0C0D));
    paintIcon(canvas, Icons.eject_rounded, win.center, win.height * 0.6, Colors.white24);
  }

  void _cassette(Canvas canvas, double w, double h, double r) {
    // 1. Cuerpo.
    final bodyR = RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, w, h), Radius.circular(r));
    canvas.drawRRect(bodyR, Paint()..color = _body);
    canvas.save();
    canvas.clipRRect(bodyR);
    canvas.drawRRect(bodyR, Paint()
      ..color = _bodyDark
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5);

    // 2. Etiqueta con rayas y el nombre a bolígrafo.
    final labelPad = w * 0.04, labelTop = h * 0.10, labelH = h * 0.66;
    final labelR = RRect.fromRectAndRadius(
        Rect.fromLTWH(labelPad, labelTop, w - labelPad * 2, labelH), Radius.circular(r * 0.6));
    canvas.drawRRect(labelR, Paint()..color = _label);
    canvas.drawRRect(labelR, Paint()
      ..color = _labelLine.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8);
    final rule = Paint()
      ..color = _labelRule
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;
    final lx = labelPad + w * 0.04, lMax = w - labelPad - w * 0.04;
    for (var i = 0; i < 4; i++) {
      final y = labelTop + labelH * 0.05 + i * labelH * 0.048;
      canvas.drawLine(Offset(lx, y), Offset(lx + (lMax - lx) * 0.95, y), rule);
    }
    if (title.isNotEmpty) {
      final tp = TextPainter(
        text: TextSpan(
            text: title,
            style: TextStyle(
              color: const Color(0xFF0D47A1),
              fontSize: w * 0.05,
              fontWeight: FontWeight.w500,
              fontStyle: FontStyle.italic,
              fontFamily: 'serif',
              fontFamilyFallback: const ['monospace'],
              letterSpacing: 0.5,
              height: 1,
            )),
        maxLines: 1,
        ellipsis: '…',
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: w * 0.80);
      tp.paint(canvas, Offset((w - tp.width) / 2, labelTop + labelH * 0.05 + labelH * 0.048 * 1.5 - tp.height / 2 + h * 0.01));
    }

    // 3. Ventanilla, tira de cinta y carretes (se recortan con la ventanilla).
    final winTop = h * 0.30, winH = h * 0.18, winPad = w * 0.20;
    final winRect = Rect.fromLTWH(winPad, winTop, w - winPad * 2, winH);
    final winRR = RRect.fromRectAndRadius(winRect, Radius.circular(r * 0.5));
    canvas.drawRRect(winRR, Paint()..color = const Color(0xFF1A1A1A));
    final cy = winTop + winH * 0.48;
    final hubR = w * 0.052;
    final (rl, rrad) = _reelRadii(progress);
    canvas.save();
    canvas.clipRRect(winRR);
    final tapeY = winTop + winH * 0.88;
    canvas.drawLine(
        Offset(winPad + w * 0.01, tapeY),
        Offset(w - winPad - w * 0.01, tapeY),
        Paint()
          ..color = _tapeStrand
          ..strokeWidth = winH * 0.055
          ..strokeCap = StrokeCap.round);
    _reel(canvas, Offset(w * 0.27, cy), hubR, rl * w, angle.value.dx);
    _reel(canvas, Offset(w * 0.73, cy), hubR, rrad * w, angle.value.dy);
    canvas.restore();
    canvas.drawRRect(winRR, Paint()
      ..color = Colors.black.withValues(alpha: 0.4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2);

    // 4. Franjas arcoíris con la placa del modelo encima.
    final rbTop = h * 0.57, rbH = h * 0.045, rbPad = w * 0.04;
    for (var i = 0; i < ZxColors.rainbow.length; i++) {
      canvas.drawRect(Rect.fromLTWH(rbPad, rbTop + i * rbH, w - rbPad * 2, rbH), Paint()..color = ZxColors.rainbow[i]);
    }
    if (machine.isNotEmpty) {
      final plateH = rbH * 4;
      final tp = TextPainter(
        text: TextSpan(
            text: machine,
            style: TextStyle(
                fontFamily: 'VT323', color: Colors.white, fontSize: plateH * 0.62, letterSpacing: w * 0.004, height: 1)),
        maxLines: 1,
        textDirection: TextDirection.ltr,
      )..layout();
      final plateW = math.min(tp.width + w * 0.06, w * 0.84);
      final plate = RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(w / 2, rbTop + plateH / 2), width: plateW, height: plateH * 0.84),
          Radius.circular(w * 0.008));
      canvas.drawRRect(plate, Paint()..color = const Color(0xFF111111));
      canvas.drawRRect(plate, Paint()
        ..color = Colors.white.withValues(alpha: 0.18)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8);
      final scale = tp.width > plateW - w * 0.04 ? (plateW - w * 0.04) / tp.width : 1.0;
      canvas.save();
      canvas.translate(w / 2, rbTop + plateH / 2);
      canvas.scale(scale);
      tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
      canvas.restore();
    }

    // 5. Trapecio inferior con agujeros y el contador de bloques.
    _trapezoid(canvas, w, h);

    // 6. Tornillos.
    for (final p in const [Offset(0.025, 0.03), Offset(0.975, 0.03), Offset(0.025, 0.96), Offset(0.975, 0.96)]) {
      _screw(canvas, Offset(w * p.dx, h * p.dy), w * 0.012);
    }

    // 7. Indicador de estado.
    final label = recording ? 'REC' : (playing ? 'PLAY' : 'STOP');
    final colour = recording
        ? ZxColors.red
        : playing
            ? const Color(0xFF27AE60)
            : const Color(0xFFC0392B);
    final tp = TextPainter(
      text: TextSpan(
          text: label,
          style: TextStyle(fontFamily: 'VT323', color: colour, fontSize: w * 0.05, letterSpacing: 1, height: 1)),
      textDirection: TextDirection.ltr,
    )..layout();
    final ix = w - tp.width - w * 0.05;
    tp.paint(canvas, Offset(ix, h * 0.025));
    canvas.drawCircle(Offset(ix - w * 0.022, h * 0.025 + tp.height / 2), w * 0.011, Paint()..color = colour);
    canvas.restore();
  }

  void _reel(Canvas c, Offset center, double hubR, double outerR, double rot) {
    c.drawCircle(center, outerR, Paint()..color = _tapePack);
    c.drawCircle(center, outerR, Paint()
      ..color = Colors.black.withValues(alpha: 0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5);
    c.drawCircle(center, hubR, Paint()..color = _reelWhite);
    c.drawCircle(center, hubR, Paint()
      ..color = _reelShadow
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1);
    const teeth = 8;
    final toothPaint = Paint()..color = _reelShadow;
    for (var i = 0; i < teeth; i++) {
      final a = rot + i * 2 * math.pi / teeth;
      final inner = hubR * 0.55, outer = hubR * 0.88, half = math.pi / teeth * 0.35;
      final path = Path()
        ..moveTo(center.dx + math.cos(a - half) * inner, center.dy + math.sin(a - half) * inner)
        ..lineTo(center.dx + math.cos(a - half) * outer, center.dy + math.sin(a - half) * outer)
        ..arcToPoint(Offset(center.dx + math.cos(a + half) * outer, center.dy + math.sin(a + half) * outer),
            radius: Radius.circular((outer - inner) / 2))
        ..lineTo(center.dx + math.cos(a + half) * inner, center.dy + math.sin(a + half) * inner)
        ..close();
      c.drawPath(path, toothPaint);
    }
    c.drawCircle(center, hubR * 0.48, Paint()..color = _reelWhite);
    c.drawCircle(center, hubR * 0.48, Paint()
      ..color = _reelShadow
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8);
    c.drawCircle(center, hubR * 0.28, Paint()..color = _reelShadow);
    c.drawCircle(center, hubR * 0.18, Paint()..color = _reelWhite);
    c.drawCircle(center, hubR * 0.08, Paint()..color = _reelShadow);
  }

  void _trapezoid(Canvas c, double w, double h) {
    final topY = h * 0.77, bottomY = h;
    final indentTop = w * 0.20, indentBot = w * 0.15;
    final path = Path()
      ..moveTo(indentTop, topY)
      ..lineTo(w - indentTop, topY)
      ..lineTo(w - indentBot, bottomY)
      ..lineTo(indentBot, bottomY)
      ..close();
    c.drawPath(
        Path()
          ..moveTo(indentTop, topY + 1)
          ..lineTo(w - indentTop, topY + 1)
          ..lineTo(w - indentBot * 0.9, bottomY * 0.96)
          ..lineTo(indentBot * 0.9, bottomY * 0.96)
          ..close(),
        Paint()
          ..color = Colors.black.withValues(alpha: 0.35)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
    c.drawPath(
        path,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xE62C3A47), _bodyDark, _bodyDark, Color(0xFF1A2530)],
            stops: [0.0, 0.3, 0.7, 1.0],
          ).createShader(Rect.fromLTWH(0, topY, w, bottomY - topY)));
    c.drawLine(Offset(indentTop, topY + 0.5), Offset(w - indentTop, topY + 0.5),
        Paint()
          ..color = Colors.white.withValues(alpha: 0.15)
          ..strokeWidth = 1.2);
    c.drawPath(
        path,
        Paint()
          ..color = Colors.black.withValues(alpha: 0.4)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1);
    final hole = Paint()..color = _body;
    final hy = (topY + bottomY) / 2 + h * 0.01;
    c.drawCircle(Offset(w * 0.22, hy), w * 0.018, hole);
    c.drawCircle(Offset(w * 0.78, hy), w * 0.018, hole);

    // Contador mecánico de 3 dígitos = bloque actual, en el centro del trapecio.
    final cnt = Rect.fromCenter(center: Offset(w / 2, hy), width: w * 0.22, height: (bottomY - topY) * 0.55);
    c.drawRRect(RRect.fromRectAndRadius(cnt, Radius.circular(cnt.height * 0.15)), Paint()..color = Colors.black);
    final digits = counter.toString().padLeft(3, '0');
    final dw = cnt.width / 3;
    for (var i = 0; i < 3; i++) {
      final cell = Rect.fromLTWH(cnt.left + i * dw, cnt.top, dw, cnt.height).deflate(cnt.height * 0.08);
      c.drawRect(cell, Paint()..color = const Color(0xFFEDEDED));
      _text(c, digits[i], cell.center, cell.height * 0.85, Colors.black);
    }
  }

  void _screw(Canvas c, Offset p, double r) {
    c.drawCircle(p, r, Paint()..color = _bodyDark);
    final s = r * 0.55;
    final line = Paint()
      ..color = _body.withValues(alpha: 0.7)
      ..strokeWidth = 1.2;
    c.drawLine(p + Offset(-s, 0), p + Offset(s, 0), line);
    c.drawLine(p + Offset(0, -s), p + Offset(0, s), line);
  }

  void _keys(Canvas canvas, Size size) {
    final keys = _TapeDeckState._keyRects(size);
    const icons = [
      Icons.fiber_manual_record_rounded,
      Icons.play_arrow_rounded,
      Icons.fast_rewind_rounded,
      Icons.fast_forward_rounded,
      Icons.stop_rounded,
    ];
    for (var i = 0; i < keys.length; i++) {
      final k = keys[i];
      final pressed = down.contains(_Key.values[i]);
      final sink = pressed ? k.height * 0.08 : 0.0;
      final face = k.translate(0, sink).deflate(k.height * 0.02);
      final kr = RRect.fromRectAndRadius(k, Radius.circular(k.height * 0.14));
      canvas.drawRRect(kr.shift(Offset(0, k.height * 0.1)), Paint()..color = Colors.black.withValues(alpha: 0.7));
      final fr = RRect.fromRectAndRadius(face, Radius.circular(k.height * 0.14));
      canvas.drawRRect(
        fr,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: pressed
                ? const [Color(0xFF1E2023), Color(0xFF2C2F33)]
                : const [Color(0xFF55585E), Color(0xFF2A2C30)],
          ).createShader(face),
      );
      final colour = i == 0 ? ZxColors.red : Colors.white.withValues(alpha: 0.92);
      paintIcon(canvas, icons[i], face.center, math.min(face.height, face.width) * 0.55, colour);
      if (i == 4) {
        paintIcon(canvas, Icons.eject_rounded, Offset(face.right - face.width * 0.18, face.top + face.height * 0.22),
            math.min(face.height, face.width) * 0.22, Colors.white54);
      }
    }
  }

  void _text(Canvas canvas, String s, Offset center, double size, Color color) {
    final tp = TextPainter(
      text: TextSpan(
          text: s, style: TextStyle(fontSize: size, color: color, fontWeight: FontWeight.bold, height: 1)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(_DeckPainter old) =>
      old.hasTape != hasTape ||
      old.counter != counter ||
      old.progress != progress ||
      old.recording != recording ||
      old.playing != playing ||
      old.title != title ||
      old.machine != machine ||
      old.down.length != down.length ||
      !old.down.containsAll(down);
}
