import 'l10n.dart';

/// Cuánto del borde del Spectrum se muestra alrededor de la pantalla (256×192).
/// El framebuffer trae 32 px de borde por lado. Se guarda por nombre en Ajustes.
enum ScreenBorder {
  full(32),
  half(16),
  none(0);

  const ScreenBorder(this.px);

  /// Píxeles de borde por lado que se dibujan.
  final int px;

  String label(AppLocalizations t) => switch (this) {
        ScreenBorder.full => t.borderFull,
        ScreenBorder.half => t.borderHalf,
        ScreenBorder.none => t.borderNone,
      };

  static ScreenBorder byName(String? name) =>
      ScreenBorder.values.firstWhere((b) => b.name == name, orElse: () => ScreenBorder.half);
}
