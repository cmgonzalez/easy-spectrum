import 'package:flutter/material.dart';

/// Paleta inspirada en el ZX Spectrum 48K: carcasa negra, teclas gris goma
/// y el arcoíris de la esquina (rojo, amarillo, verde, cian).
class ZxColors {
  static const body = Color(0xFF151515);
  static const bodyLight = Color(0xFF2A2A2A);
  static const key = Color(0xFF3C3C40);
  static const keyPressed = Color(0xFF6A6A70);
  static const keyText = Color(0xFFF0F0F0);
  static const keyRed = Color(0xFFE04040); // leyendas rojas de las teclas
  static const red = Color(0xFFD80000);
  static const yellow = Color(0xFFD8D800);
  static const green = Color(0xFF00C000);
  static const cyan = Color(0xFF00C8C8);
  static const blue = Color(0xFF0000D8);
  static const textLight = Color(0xFFF5F5F0);
  static const textDim = Color(0xFFB0B0B0);

  static const rainbow = [red, yellow, green, cyan];
}

/// Franjas diagonales del logo Spectrum.
class RainbowStripes extends StatelessWidget {
  final double height;
  const RainbowStripes({super.key, this.height = 36});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: height * 2,
      height: height,
      child: CustomPaint(painter: _StripesPainter()),
    );
  }
}

class _StripesPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width / 5;
    for (var i = 0; i < 4; i++) {
      final x = i * w;
      final path = Path()
        ..moveTo(x + size.height * 0.6, 0)
        ..lineTo(x + size.height * 0.6 + w, 0)
        ..lineTo(x + w, size.height)
        ..lineTo(x, size.height)
        ..close();
      canvas.drawPath(path, Paint()..color = ZxColors.rainbow[i]);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class EasyTheme {
  static const double minTouchTarget = 64.0;
  static const double bodyFontSize = 20.0;
  static const double headingFontSize = 24.0;

  static ThemeData get theme {
    const scheme = ColorScheme(
      brightness: Brightness.dark,
      primary: ZxColors.cyan,
      onPrimary: Colors.black,
      secondary: ZxColors.yellow,
      onSecondary: Colors.black,
      surface: ZxColors.body,
      onSurface: ZxColors.textLight,
      error: ZxColors.red,
      onError: Colors.white,
    );

    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: ZxColors.body,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.black,
        foregroundColor: ZxColors.textLight,
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontSize: headingFontSize,
          fontWeight: FontWeight.bold,
          color: ZxColors.textLight,
        ),
      ),
      textTheme: const TextTheme(
        bodyMedium: TextStyle(fontSize: bodyFontSize, color: ZxColors.textLight),
        bodyLarge: TextStyle(fontSize: bodyFontSize + 2, color: ZxColors.textLight),
        titleLarge: TextStyle(
          fontSize: headingFontSize,
          fontWeight: FontWeight.bold,
          color: ZxColors.textLight,
        ),
      ),
      listTileTheme: const ListTileThemeData(
        minVerticalPadding: 12,
        titleTextStyle: TextStyle(fontSize: bodyFontSize, color: ZxColors.textLight),
        subtitleTextStyle: TextStyle(fontSize: 15, color: ZxColors.textDim),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          minimumSize: const Size(double.infinity, minTouchTarget),
          textStyle: const TextStyle(fontSize: bodyFontSize, fontWeight: FontWeight.bold),
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
    );
  }
}
