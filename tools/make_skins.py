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
PAD_ORIGIN = (121, 146)
FIRE_CENTER = (1163, 542)      # centro del pozo del fuego en la original
CLUSTER_R = 230                # radio del anillo de la botonera en la original
ART_CENTER, ART_R = (627, 627), 525
SELECT_SRC = {1: 'art/Imagen de ChatGPT 28 sept 2026, 19_44_24.png',
              2: 'art/Imagen de ChatGPT 28 sept 2026, 19_42_20.png'}
SELECT_CX, SELECT_BOTTOM, SELECT_H = 761, 738, 118


def keyboard():
    src = Image.open(KEYBOARD_SRC)
    prof = ImageCms.ImageCmsProfile(io.BytesIO(src.info['icc_profile']))
    full = ImageCms.profileToProfile(src.convert('RGB'), prof, ImageCms.createProfile('sRGB'),
                                     renderingIntent=ImageCms.Intent.PERCEPTUAL)
    w, h = full.size
    half = full.crop((0, 944, w // 2, 959))       # 3 px negro + franja metálica + 1 px negro
    edge = Image.new('RGB', (w, 15))
    edge.paste(half, (0, 0))
    edge.paste(ImageOps.mirror(half), (w // 2, 0))
    top = ImageOps.flip(edge)
    body = full.crop((0, 283, w, h))
    kb = Image.new('RGB', (w, top.height + body.height))
    kb.paste(top, (0, 0))
    kb.paste(body, (0, top.height))
    kb.save('assets/skin/keyboard.jpg', quality=88, optimize=True)
    print('teclado', kb.size, 'origen', (0, 283 - top.height))


def pad():
    o = np.asarray(Image.open(PAD_SRC).convert('RGB')).astype(float)
    t = 24                                          # grosor del marco
    top = o[80:80 + t, 600:900].mean(axis=1)        # perfiles de afuera hacia adentro
    bottom = o[944:944 - t:-1, 600:900].mean(axis=1)
    left = o[400:700, 22:22 + t].mean(axis=0)
    right = o[300:500, 1514:1514 - t:-1].mean(axis=0)
    bg = o[5:20, 600:900].reshape(-1, 3).mean(axis=0)
    x0, y0, x1, y1 = 145, 170, 1490, 921
    c = o[y0:y1, x0:x1]
    h, w = c.shape[0] + 2 * t, c.shape[1] + 2 * t
    r = 56.0
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
    weights = [(top, np.maximum(0, -ny) ** 2), (bottom, np.maximum(0, ny) ** 2),
               (left, np.maximum(0, -nx) ** 2), (right, np.maximum(0, nx) ** 2)]

    def sample(prof, dist):
        i = np.clip(dist, 0, t - 1.001)
        i0 = np.floor(i).astype(int)
        f = (i - i0)[..., None]
        return prof[i0] * (1 - f) + prof[np.minimum(i0 + 1, t - 1)] * f

    frame = sum(sample(p, d) * wgt[..., None] for p, wgt in weights)
    out = np.empty((h, w, 3))
    out[:] = bg
    out[t:t + c.shape[0], t:t + c.shape[1]] = c
    band = (d >= 0) & (d < t)
    out[band] = frame[band]
    edge = (d > -1) & (d < 0)                        # antialias del borde exterior
    a = (d[edge] + 1)[..., None]
    out[edge] = frame[edge] * a + bg * (1 - a)
    print('mando', (w, h), 'origen', (x0 - t, y0 - t))
    return Image.fromarray(np.clip(out, 0, 255).astype(np.uint8))


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
    select_buttons()
