"""Genera las pieles del teclado y del mando (assets/skin/) desde las ilustraciones de art/.

Uso: python tools/make_skins.py   (desde la raíz del proyecto; requiere Pillow y numpy)

- Teclado: la fuente viene en HDR (ICC Rec.2020 PQ) → se convierte a sRGB con su perfil
  (Flutter ignora el ICC y se vería apagada). Se quita la cabecera "sinclair" y arriba se pone
  el reflejo de la franja metálica inferior (solo la mitad izquierda, sin arcoíris, espejada),
  seguida del canto real de la placa. Origen del recorte en la imagen original: (0, 268).
- Mando: contenido (145,170)-(1490,921) de la original, sin el relleno entre marco y controles,
  y un marco nuevo dibujado con el perfil de relieve real de cada lado (mezclado por dirección en
  las esquinas). Pegar trozos del marco original dejaba escalones en las curvas.
  Origen en la imagen original: (121, 146).
- Botonera: sobre el pozo del botón de fuego se pega el arte de art/circles-optimized con 1-4
  botones (rojo = fuego; amarillo, verde, azul = extra) → assets/skin/joystick_<n>.jpg. El anillo
  (centro (627,627), radio 525 en el arte) queda centrado en (1163,542) con radio CLUSTER_R.
  Imprime el centro y radio de cada botón en coordenadas de la original para joystick_pad.dart.
- Select/Start: arte de 1 o 2 botones → assets/skin/select_<n>.png, que la app dibuja encima del
  LCD (centrado en x=761, cuerpo de SELECT_H de alto con la base en y=SELECT_BOTTOM). Imprime el
  rectángulo del PNG y de cada tecla en coordenadas de la original.
Si cambian los orígenes, actualizar SkinImage(origin:) en zx_keyboard.dart / joystick_pad.dart.
"""
import io

import numpy as np
from PIL import Image, ImageCms, ImageOps

KEYBOARD_SRC = 'art/Imagen de ChatGPT 28 sept 2026, 11_32_04.png'
PAD_SRC = 'art/Imagen de ChatGPT 28 sept 2026, 11_23_12.png'
CLUSTER_SRC = 'art/circles-optimized/circle-{n}-buttons-optimized.png'
PAD_ORIGIN = (121, 170)          # mando abierto arriba (sin marco superior)
FIRE_CENTER = (1163, 542)      # centro del pozo del fuego en la original
CLUSTER_R = 230                # radio del anillo de la botonera en la original
ART_CENTER, ART_R = (627, 627), 525
SELECT_SRC = {1: 'art/Imagen de ChatGPT 28 sept 2026, 19_44_24.png',
              2: 'art/Imagen de ChatGPT 28 sept 2026, 19_42_20.png'}
SELECT_CX, SELECT_BOTTOM, SELECT_H = 761, 738, 118


KB_HEADER_END, KB_PLATE_FROM = 175, 235   # se quitan 60 filas de plástico liso de la cabecera


def keyboard():
    """Teclado con su cabecera ("sinclair ZX Spectrum" + hueco a la derecha para los 4
    botones de acción), acortada quitando plástico liso: filas 0-175 + 235-959 de la
    original. Origen (0, 60): desde y=235 el asset coincide con la original - 60."""
    src = Image.open(KEYBOARD_SRC)
    prof = ImageCms.ImageCmsProfile(io.BytesIO(src.info['icc_profile']))
    full = ImageCms.profileToProfile(src.convert('RGB'), prof, ImageCms.createProfile('sRGB'),
                                     renderingIntent=ImageCms.Intent.PERCEPTUAL)
    w, h = full.size
    head = full.crop((0, 0, w, KB_HEADER_END))
    rest = full.crop((0, KB_PLATE_FROM, w, h))
    kb = Image.new('RGB', (w, head.height + rest.height))
    kb.paste(head, (0, 0))
    kb.paste(rest, (0, head.height))
    kb.save('assets/skin/keyboard.jpg', quality=88, optimize=True)
    print('teclado', kb.size, 'origen', (0, KB_PLATE_FROM - KB_HEADER_END))


T = 24                                              # grosor del marco
FRAME_R = 56.0                                      # radio de las esquinas


def profiles(o):
    """Perfiles de relieve del marco (de afuera hacia adentro) y color de fondo."""
    return {
        'top': o[80:80 + T, 600:900].mean(axis=1),
        'bottom': o[944:944 - T:-1, 600:900].mean(axis=1),
        'left': o[400:700, 22:22 + T].mean(axis=0),
        'right': o[300:500, 1514:1514 - T:-1].mean(axis=0),
        'bg': o[5:20, 600:900].reshape(-1, 3).mean(axis=0),
    }


def framed(c, prof, open_top=False, open_bottom=False):
    """Contenido [c] con el marco redibujado (SDF de rectángulo redondeado, perfil
    mezclado por dirección). Un lado abierto no lleva marco ni esquinas: las piezas
    se apilan sin costura (cuerpo de la pantalla + mando)."""
    ext = int(FRAME_R + T) + 8
    top_pad = ext if open_top else 0
    bot_pad = ext if open_bottom else 0
    c = np.concatenate([np.repeat(c[:1], top_pad, 0), c, np.repeat(c[-1:], bot_pad, 0)])
    t, r = T, FRAME_R
    h, w = c.shape[0] + 2 * t, c.shape[1] + 2 * t
    yy, xx = np.mgrid[0:h, 0:w].astype(float) + 0.5
    cx, cy = w / 2, h / 2
    qx = np.abs(xx - cx) - (w / 2 - r)
    qy = np.abs(yy - cy) - (h / 2 - r)
    mx, my = np.maximum(qx, 0), np.maximum(qy, 0)
    d = -(np.hypot(mx, my) + np.minimum(np.maximum(qx, qy), 0) - r)   # distancia hacia adentro
    corner = (qx > 0) & (qy > 0)
    norm = np.maximum(np.hypot(mx, my), 1e-6)
    nx = np.where(corner, mx / norm, (qx >= qy).astype(float)) * np.sign(xx - cx)
    ny = np.where(corner, my / norm, (qy > qx).astype(float)) * np.sign(yy - cy)
    weights = [(prof['top'], np.maximum(0, -ny) ** 2), (prof['bottom'], np.maximum(0, ny) ** 2),
               (prof['left'], np.maximum(0, -nx) ** 2), (prof['right'], np.maximum(0, nx) ** 2)]

    def sample(pr, dist):
        i = np.clip(dist, 0, t - 1.001)
        i0 = np.floor(i).astype(int)
        f = (i - i0)[..., None]
        return pr[i0] * (1 - f) + pr[np.minimum(i0 + 1, t - 1)] * f

    frame = sum(sample(pr, d) * wgt[..., None] for pr, wgt in weights)
    bg = prof['bg']
    out = np.empty((h, w, 3))
    out[:] = bg
    out[t:t + c.shape[0], t:t + c.shape[1]] = c
    band = (d >= 0) & (d < t)
    out[band] = frame[band]
    edge = (d > -1) & (d < 0)                        # antialias del borde exterior
    a = (d[edge] + 1)[..., None]
    out[edge] = frame[edge] * a + bg * (1 - a)
    out = out[(top_pad + t if open_top else 0):h - (bot_pad + t if open_bottom else 0)]
    return Image.fromarray(np.clip(out, 0, 255).astype(np.uint8))


PAD_FOOT = 110                     # plástico extra bajo los controles (los sube)


def pad():
    """Mando abierto arriba (se une sin costura con el cuerpo de la pantalla) y
    alargado por abajo [PAD_FOOT] filas: los controles no quedan pegados al borde
    del teléfono. Las rayas del arcoíris siguen su diagonal (1 px a la izquierda
    por fila) sobre plástico liso."""
    o = np.asarray(Image.open(PAD_SRC).convert('RGB')).astype(float)
    x0, y0, x1, y1 = 145, 170, 1490, 921
    c = o[y0:y1, x0:x1]
    # Plástico del pie: reflejo de las últimas filas del mando (continúa la textura),
    # con la zona de las rayas cambiada por su espejo desde la izquierda (lisa).
    below = c[-30:]                                   # plástico bajo el LCD
    strip = np.concatenate([below[::-1], below])      # vaivén: continuo en las uniones
    plain = np.concatenate([strip] * (PAD_FOOT // len(strip) + 1))[:PAD_FOOT].copy()
    cut = 850
    cols = np.arange(cut, c.shape[1])
    plain[:, cols] = plain[:, 2 * cut - cols]
    last = c[-1]
    sat = last.max(axis=1) - last.min(axis=1)
    alpha = np.clip((sat - 40) / 80, 0, 1)            # rayas (bordes suaves)
    foot = np.empty((PAD_FOOT, c.shape[1], 3))
    for k in range(PAD_FOOT):
        base = plain[k]
        shifted = np.roll(last, -(k + 1), axis=0)
        a = np.roll(alpha, -(k + 1))[:, None]
        foot[k] = shifted * a + base * (1 - a)
    img = framed(np.concatenate([c, foot]), profiles(o), open_top=True)
    print('mando', img.size, 'origen', (x0 - T, y0))
    return img


def body():
    """Cuerpo de la consola sobre el mando (pantalla del juego): tapa superior con
    esquinas, tramo central que se repite en vertical y tapa inferior (cuando abajo
    va el teclado en vez del mando). Mismo plástico y cantos que el mando."""
    o = np.asarray(Image.open(PAD_SRC).convert('RGB')).astype(float)
    prof = profiles(o)
    w = 1490 - 145
    src = o[176:301, 160:760]                          # plástico liso
    half = np.concatenate([src, src[:, ::-1]], axis=1)
    row = np.concatenate([half] * (w // half.shape[1] + 1), axis=1)[:, :w]
    tile = np.concatenate([row, row[::-1]])            # periódico en vertical (250 filas)
    framed(tile[:40], prof, open_bottom=True).save('assets/skin/body_top.jpg', quality=88)
    framed(tile, prof, open_top=True, open_bottom=True).save('assets/skin/body_mid.jpg', quality=88)
    framed(tile[-40:], prof, open_top=True).save('assets/skin/body_bottom.jpg', quality=88)
    print('cuerpo', Image.open('assets/skin/body_mid.jpg').size)


def pad_buttons(base):
    s = CLUSTER_R / ART_R
    colours = {
        'rojo': lambda r, g, b: (r > 180) & (g < 90) & (b < 90),
        'amarillo': lambda r, g, b: (r > 200) & (g > 170) & (b < 80),
        'verde': lambda r, g, b: (g > 150) & (r < 100) & (b < 130),
        'azul': lambda r, g, b: (b > 200) & (g > 150) & (r < 80),
    }
    for n in range(1, 5):
        art = Image.open(CLUSTER_SRC.format(n=n)).convert('RGBA')
        a = np.asarray(art).astype(int)
        size = round(art.width * s)
        small = art.resize((size, size), Image.LANCZOS)
        # Esquina del arte en la original → en el asset.
        ox = FIRE_CENTER[0] - ART_CENTER[0] * s - PAD_ORIGIN[0]
        oy = FIRE_CENTER[1] - ART_CENTER[1] * s - PAD_ORIGIN[1]
        out = base.convert('RGBA')
        out.alpha_composite(small, (round(ox), round(oy)))
        out.convert('RGB').save(f'assets/skin/joystick_{n}.jpg', quality=88, optimize=True)
        # Miniatura para elegir la botonera en la configuración del control.
        box = art.getbbox()
        art.crop(box).resize((200, 200), Image.LANCZOS).save(f'assets/skin/buttons_{n}.png', optimize=True)
        found = []
        for name, f in colours.items():
            m = f(a[..., 0], a[..., 1], a[..., 2]) & (a[..., 3] > 250)
            if m.sum() < 500:
                continue
            ys, xs = np.nonzero(m)
            cx = FIRE_CENTER[0] + (xs.mean() - ART_CENTER[0]) * s
            cy = FIRE_CENTER[1] + (ys.mean() - ART_CENTER[1]) * s
            found.append(f'{name} ({cx:.0f}, {cy:.0f}) r{(m.sum() / np.pi) ** 0.5 * s:.0f}')
        print(f'botonera {n}:', ', '.join(found))


def select_buttons():
    for n, src in SELECT_SRC.items():
        art = Image.open(src).convert('RGBA')
        a = np.asarray(art).astype(int)
        body = a[..., 3] > 250
        ys, xs = np.nonzero(body)
        bx0, by0, bx1, by1 = xs.min(), ys.min(), xs.max() + 1, ys.max() + 1
        s = SELECT_H / (by1 - by0)
        crop = art.getbbox()                                # con la sombra
        out = art.crop(crop)
        out = out.resize((round(out.width * s), round(out.height * s)), Image.LANCZOS)
        out.save(f'assets/skin/select_{n}.png', optimize=True)
        # Esquina del cuerpo en la original → esquina del PNG.
        left = SELECT_CX - (bx1 - bx0) * s / 2 - (bx0 - crop[0]) * s
        top = SELECT_BOTTOM - SELECT_H - (by0 - crop[1]) * s
        # Teclas grises: componentes claros y poco saturados.
        from scipy import ndimage
        r, g, b = a[..., 0], a[..., 1], a[..., 2]
        caps = body & (r > 110) & (b > 110) & (np.abs(r - b) < 40)
        lab, _ = ndimage.label(caps)
        rects = []
        for sl in ndimage.find_objects(lab):
            w, h = sl[1].stop - sl[1].start, sl[0].stop - sl[0].start
            if w * h < 20000 or w < 300:
                continue                                    # brillos del marco
            rects.append(tuple(round(v) for v in (
                left + (sl[1].start - crop[0]) * s, top + (sl[0].start - crop[1]) * s,
                left + (sl[1].stop - crop[0]) * s, top + (sl[0].stop - crop[1]) * s)))
        rects.sort()
        print(f'select {n}: png ({left:.0f}, {top:.0f}) {out.size}, teclas {rects}')


if __name__ == '__main__':
    keyboard()
    pad_buttons(pad())
    body()
    select_buttons()
