// Pantalla CRT para el framebuffer del Spectrum (320×256 con borde).
// Técnica del shader "CRT" de Timothy Lottes (dominio público), reescrita para
// los shaders de Flutter: curvatura, haz gaussiano por línea (más ancho en los
// píxeles brillantes), máscara de fósforo RGB, resplandor, viñeta y esquinas
// redondeadas. Todo el filtrado se hace en espacio lineal.
#version 460 core
#include <flutter/runtime_effect.glsl>

precision mediump float;

uniform vec2 uSize;      // tamaño de salida (px lógicos)
uniform vec2 uSrc;       // tamaño de la imagen (320, 256)
uniform float uDpr;      // px físicos por px lógico (máscara al tamaño del fósforo)
uniform float uCurve;    // curvatura (0 = plana)
uniform float uScan;     // intensidad de las líneas (0-1)
uniform float uMask;     // intensidad de la máscara RGB (0-1)
uniform float uVignette; // oscurecimiento de los bordes (0-1)
uniform float uCorner;   // radio de las esquinas, fracción del alto
uniform float uGlow;     // resplandor (0-1)
uniform sampler2D uTex;

out vec4 fragColor;

vec3 toLinear(vec3 c) { return c * c; }       // gamma 2 (barato y suficiente)
vec3 toGamma(vec3 c) { return sqrt(max(c, 0.0)); }

vec3 texel(vec2 p) {
  p = clamp(p, vec2(0.0), uSrc - 1.0);
  return toLinear(texture(uTex, (floor(p) + 0.5) / uSrc).rgb);
}

// Fila horizontal filtrada con 4 muestras gaussianas alrededor de x.
vec3 row(vec2 pos, float y, float sharp) {
  float x = floor(pos.x);
  float f = pos.x - x;
  float w0 = exp2(-sharp * (f + 1.0) * (f + 1.0));
  float w1 = exp2(-sharp * f * f);
  float w2 = exp2(-sharp * (1.0 - f) * (1.0 - f));
  float w3 = exp2(-sharp * (2.0 - f) * (2.0 - f));
  vec3 c = texel(vec2(x - 1.0, y)) * w0 + texel(vec2(x, y)) * w1 +
           texel(vec2(x + 1.0, y)) * w2 + texel(vec2(x + 2.0, y)) * w3;
  return c / (w0 + w1 + w2 + w3);
}

// Peso de una línea a distancia d (en líneas) según su brillo.
float scanWeight(float d, vec3 c) {
  float lum = dot(c, vec3(0.3, 0.6, 0.1));
  float sigma = mix(0.26, 0.42, sqrt(lum));
  return exp(-d * d / (2.0 * sigma * sigma));
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec2 uv = frag / uSize;

  // Curvatura de tubo: cada eje se abomba según el otro.
  vec2 c = uv * 2.0 - 1.0;
  c *= vec2(1.0 + c.y * c.y * uCurve * 0.6, 1.0 + c.x * c.x * uCurve);
  uv = c * 0.5 + 0.5;

  // Esquinas redondeadas (antialias de ~1 px).
  float aspect = uSize.x / uSize.y;
  vec2 q = abs(uv - 0.5) * vec2(aspect, 1.0);
  vec2 half_ = vec2(aspect, 1.0) * 0.5 - uCorner;
  float dist = length(max(q - half_, 0.0)) - uCorner;
  float edge = 1.0 - smoothstep(-1.0 / uSize.y, 1.0 / uSize.y, dist);
  if (edge <= 0.0) {
    fragColor = vec4(0.0, 0.0, 0.0, 1.0);
    return;
  }

  vec2 pos = uv * uSrc - 0.5;
  float y = floor(pos.y);
  float fy = pos.y - y;

  // Haz: la línea actual y la siguiente, cada una con su peso.
  vec3 a = row(pos, y, 2.5);
  vec3 b = row(pos, y + 1.0, 2.5);
  vec3 beam = a * scanWeight(fy, a) + b * scanWeight(1.0 - fy, b);
  vec3 flat_ = mix(a, b, fy);
  vec3 col = mix(flat_, beam * 1.35, uScan);

  // Resplandor: la misma zona muy desenfocada, sumada suave.
  vec3 glow = (row(pos, y - 1.0, 0.25) + row(pos, y, 0.25) + row(pos, y + 1.0, 0.25) +
               row(pos, y + 2.0, 0.25)) * 0.25;
  col += glow * uGlow * 0.35;

  // Máscara de fósforo (rejilla de apertura) en px físicos.
  float k = mod(floor(frag.x * uDpr), 3.0);
  vec3 mask = vec3(k < 0.5 ? 1.0 : 0.55, (k > 0.5 && k < 1.5) ? 1.0 : 0.55, k > 1.5 ? 1.0 : 0.55);
  col *= mix(vec3(1.0), mask * 1.3, uMask);

  // Viñeta.
  float v = 16.0 * uv.x * uv.y * (1.0 - uv.x) * (1.0 - uv.y);
  col *= mix(1.0, pow(clamp(v, 0.0, 1.0), 0.3), uVignette);

  fragColor = vec4(toGamma(col) * edge, 1.0);
}
