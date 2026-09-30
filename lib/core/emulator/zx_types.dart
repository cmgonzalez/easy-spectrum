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

/// Teclado del Spectrum por filas, como en la máquina (para elegir teclas).
const zxKeyRows = <List<int>>[
  [ZxKey.k1, ZxKey.k2, ZxKey.k3, ZxKey.k4, ZxKey.k5, ZxKey.k6, ZxKey.k7, ZxKey.k8, ZxKey.k9, ZxKey.k0],
  [ZxKey.q, ZxKey.w, ZxKey.e, ZxKey.r, ZxKey.t, ZxKey.y, ZxKey.u, ZxKey.i, ZxKey.o, ZxKey.p],
  [ZxKey.a, ZxKey.s, ZxKey.d, ZxKey.f, ZxKey.g, ZxKey.h, ZxKey.j, ZxKey.k, ZxKey.l, ZxKey.enter],
  [ZxKey.caps, ZxKey.z, ZxKey.x, ZxKey.c, ZxKey.v, ZxKey.b, ZxKey.n, ZxKey.m, ZxKey.sym, ZxKey.space],
];

const _zxKeyLabels = <String>[
  '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', //
  'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P',
  'A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', 'ENTER',
  'CAPS', 'Z', 'X', 'C', 'V', 'B', 'N', 'M', 'SYM', 'SPACE',
];

/// Nombre corto de una tecla ('Q', 'ENTER', 'CAPS', 'SYM', 'SPACE').
String zxKeyLabel(int key) {
  var i = 0;
  for (final row in zxKeyRows) {
    for (final k in row) {
      if (k == key) return _zxKeyLabels[i];
      i++;
    }
  }
  return '?';
}

/// Teclas por defecto del control "Teclado": [arriba, abajo, izquierda, derecha, fuego].
const defaultPadKeys = [ZxKey.q, ZxKey.a, ZxKey.o, ZxKey.p, ZxKey.m];

/// Cómo se traduce el joystick en pantalla a la máquina. Se guarda por nombre.
enum JoyMapping {
  kempston('Kempston'),
  sinclair1('Sinclair 1 (6-7-8-9-0)'),
  sinclair2('Sinclair 2 (1-2-3-4-5)'),
  cursor('Cursor (5-6-7-8-0)'),
  keyboard('Q-A-O-P-M'); // la UI usa AppLocalizations.joyKeyboard

  const JoyMapping(this.label);
  final String label;

  /// Teclas para [arriba, abajo, izquierda, derecha, fuego]; null = joystick Kempston.
  /// Para [keyboard] son las de por defecto (la configuración de cada juego manda).
  List<int>? get keys => switch (this) {
        JoyMapping.kempston => null,
        JoyMapping.sinclair1 => const [ZxKey.k9, ZxKey.k8, ZxKey.k6, ZxKey.k7, ZxKey.k0],
        JoyMapping.sinclair2 => const [ZxKey.k4, ZxKey.k3, ZxKey.k1, ZxKey.k2, ZxKey.k5],
        JoyMapping.cursor => const [ZxKey.k7, ZxKey.k6, ZxKey.k5, ZxKey.k8, ZxKey.k0],
        JoyMapping.keyboard => defaultPadKeys,
      };

  static JoyMapping? byName(String? name) {
    for (final m in values) {
      if (m.name == name) return m;
    }
    return null;
  }
}

/// Extensiones que acepta el emulador.
const zxMediaExtensions = ['tap', 'tzx', 'csw', 'z80', 'sna', 'szx', 'dsk', 'nex'];
