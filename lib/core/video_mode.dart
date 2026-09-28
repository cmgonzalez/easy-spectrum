import 'l10n.dart';

/// Parámetros del shader CRT (shaders/crt.frag).
class CrtParams {
  final double curve, scan, mask, vignette, corner, glow;
  const CrtParams({
    this.curve = 0,
    this.scan = 0,
    this.mask = 0,
    this.vignette = 0,
    this.corner = 0,
    this.glow = 0,
  });
}

/// Presets de video de la pantalla del juego. Se guarda por nombre en Ajustes.
enum VideoMode {
  sharp, // píxeles perfectos
  smooth, // filtrado bilineal
  rounded, // nítido con esquinas redondeadas
  monitor, // monitor: líneas suaves y esquinas redondeadas
  tv; // televisor CRT: curvatura, líneas, fósforo, viñeta

  /// Parámetros del shader, o null si se pinta sin shader.
  CrtParams? get crt => switch (this) {
        VideoMode.monitor =>
          const CrtParams(scan: 0.45, mask: 0.2, vignette: 0.15, corner: 0.035, glow: 0.15),
        VideoMode.tv => const CrtParams(
            curve: 0.035, scan: 0.75, mask: 0.45, vignette: 0.4, corner: 0.05, glow: 0.35),
        _ => null,
      };

  String label(AppLocalizations t) => switch (this) {
        VideoMode.sharp => t.videoSharp,
        VideoMode.smooth => t.videoSmooth,
        VideoMode.rounded => t.videoRounded,
        VideoMode.monitor => t.videoMonitor,
        VideoMode.tv => t.videoTv,
      };

  static VideoMode byName(String? name) =>
      VideoMode.values.firstWhere((m) => m.name == name, orElse: () => VideoMode.sharp);
}
