/// Tipos compartidos con native/zx_bridge.h.
library;

const int zxFbWidth = 320; // ZX_FB_WIDTH: 256 px de pantalla + 32 de borde por lado
const int zxFbHeight = 256; // ZX_FB_HEIGHT: 192 + 32 + 32

/// Modelos — mismo orden que ZX_MODEL_* / Target::Model de CLK.
enum ZxModel {
  k16('16K'),
  k48('48K'),
  k128('128K'),
  plus2('+2'),
  plus2a('+2A'),
  plus3('+3');

  const ZxModel(this.label);
  final String label;
}

/// Bits de zx_set_joystick.
class ZxJoy {
  static const up = 1 << 0;
  static const down = 1 << 1;
  static const left = 1 << 2;
  static const right = 1 << 3;
  static const fire = 1 << 4;
}

/// Teclas de la matriz: (fila << 8) | bit — igual que Sinclair::ZX::Keyboard::Key.
class ZxKey {
  static const caps = 0x0001, z = 0x0002, x = 0x0004, c = 0x0008, v = 0x0010;
  static const a = 0x0101, s = 0x0102, d = 0x0104, f = 0x0108, g = 0x0110;
  static const q = 0x0201, w = 0x0202, e = 0x0204, r = 0x0208, t = 0x0210;
  static const k1 = 0x0301, k2 = 0x0302, k3 = 0x0304, k4 = 0x0308, k5 = 0x0310;
  static const k0 = 0x0401, k9 = 0x0402, k8 = 0x0404, k7 = 0x0408, k6 = 0x0410;
  static const p = 0x0501, o = 0x0502, i = 0x0504, u = 0x0508, y = 0x0510;
  static const enter = 0x0601, l = 0x0602, k = 0x0604, j = 0x0608, h = 0x0610;
  static const space = 0x0701, sym = 0x0702, m = 0x0704, n = 0x0708, b = 0x0710;
}

/// Cómo se traduce el joystick en pantalla a la máquina.
enum JoyMapping {
  kempston('Kempston'),
  sinclair('Sinclair (6-7-8-9-0)'),
  cursor('Cursor (5-6-7-8-0)'),
  qaop('Q-A-O-P + Space'); // la UI usa AppLocalizations.joyQaop

  const JoyMapping(this.label);
  final String label;

  /// Teclas para cada dirección [up, down, left, right, fire]; null = usar joystick.
  List<int>? get keys => switch (this) {
        JoyMapping.kempston => null,
        JoyMapping.sinclair => const [ZxKey.k9, ZxKey.k8, ZxKey.k6, ZxKey.k7, ZxKey.k0],
        JoyMapping.cursor => const [ZxKey.k7, ZxKey.k6, ZxKey.k5, ZxKey.k8, ZxKey.k0],
        JoyMapping.qaop => const [ZxKey.q, ZxKey.a, ZxKey.o, ZxKey.p, ZxKey.space],
      };
}

/// Extensiones que acepta el emulador.
const zxMediaExtensions = ['tap', 'tzx', 'csw', 'z80', 'sna', 'szx', 'dsk'];
