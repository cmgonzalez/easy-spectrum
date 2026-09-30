#!/bin/bash
# build-app.sh — Easy Spectrum (dos ediciones: free con anuncios, pro sin anuncios)
# Uso:
#   bash build-app.sh [modo] [edición] [push]
#     modo:    release (defecto) | aab | debug | windows | installer
#     edición: all (defecto) | free | pro
#   Ejemplos:
#     bash build-app.sh                  → APK release de las dos ediciones
#     bash build-app.sh aab              → AAB de las dos (Play Store)
#     bash build-app.sh release pro      → solo la Pro
#     bash build-app.sh release all push → APKs + git add + commit + push
#     bash build-app.sh windows          → EasySpectrum-win-<ver>-<code>.zip (carpeta con el .exe)
#     bash build-app.sh installer        → EasySpectrum-Setup-<ver>-<code>.exe (Inno Setup)
#
# Salida en la raíz: EasySpectrum-<ver>-<code>.apk / EasySpectrumPro-<ver>-<code>.apk (o .aab).
# El versionCode está en pubspec.yaml Y en android/app/build.gradle.kts: subir ambos.

set -e

FLUTTER="/c/Users/cmgon/dev-tools/flutter/bin/flutter"
export JAVA_HOME="/c/Users/cmgon/dev-tools/jdk17/jdk-17.0.18+8"
export ANDROID_HOME="/c/Users/cmgon/dev-tools/android-sdk"

MODE=${1:-release}
EDITION=${2:-all}
PUSH=${3:-}

RAW=$(grep "^version:" pubspec.yaml | sed 's/version: //' | tr -d '\r')
VERSION=${RAW%%+*}
CODE=${RAW##*+}

# Windows: una sola edición (sin anuncios), sin flavors. Requiere Visual Studio 2022
# con C++ y "Clang para Windows" (el core se compila con clang-cl).
if [ "$MODE" = "windows" ] || [ "$MODE" = "installer" ]; then
  echo "→ Windows release..."
  "$FLUTTER" build windows --release --no-pub
  RELEASE_DIR="build/windows/x64/runner/Release"
  if [ "$MODE" = "windows" ]; then
    DEST="EasySpectrum-win-${VERSION}-${CODE}.zip"
    rm -f "$DEST"
    powershell -NoProfile -Command "Compress-Archive -Path '$RELEASE_DIR/*' -DestinationPath '$DEST'"
    echo "✓ $DEST  (ejecutable: $RELEASE_DIR/EasySpectrum.exe)"
    exit 0
  fi
  # Instalador: Inno Setup (el de PRISMA si no está en el PATH) + runtime de VC++ local.
  ISCC=$(command -v iscc || true)
  for c in "/c/prisma/bin/Inno Setup 6/ISCC.exe" "/c/Program Files (x86)/Inno Setup 6/ISCC.exe" "/c/Program Files/Inno Setup 6/ISCC.exe"; do
    [ -z "$ISCC" ] && [ -f "$c" ] && ISCC="$c"
  done
  [ -z "$ISCC" ] && { echo "No se encontró ISCC.exe (Inno Setup 6)"; exit 1; }
  REDIST=$(ls -d "/c/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/VC/Redist/MSVC/"*/x64/Microsoft.VC143.CRT 2>/dev/null | sort | tail -1)
  [ -z "$REDIST" ] && { echo "No se encontró el runtime de VC++ (Microsoft.VC143.CRT)"; exit 1; }
  DEST="EasySpectrum-Setup-${VERSION}-${CODE}.exe"
  rm -f "$DEST"
  echo "→ Instalador (Inno Setup)..."
  MSYS_NO_PATHCONV=1 "$ISCC" /Q "/DAppVersion=$VERSION" "/DAppCode=$CODE"     "/DSourceDir=$(cygpath -w "$PWD/$RELEASE_DIR")" "/DRedistDir=$(cygpath -w "$REDIST")"     "/DOutputDir=$(cygpath -w "$PWD")" installer/easy_spectrum.iss
  echo "✓ $DEST"
  exit 0
fi

case "$EDITION" in
  all)  FLAVORS="free pro" ;;
  free|pro) FLAVORS="$EDITION" ;;
  *) echo "Edición desconocida: $EDITION (usar all, free o pro)"; exit 1 ;;
esac

OUTPUTS=()
for FLAVOR in $FLAVORS; do
  if [ "$FLAVOR" = "pro" ]; then APP="EasySpectrumPro"; else APP="EasySpectrum"; fi

  case "$MODE" in
    aab)
      echo "→ AAB release ($FLAVOR)..."
      "$FLUTTER" build appbundle --release --flavor "$FLAVOR" --no-pub
      DEST="${APP}-${VERSION}-${CODE}.aab"
      rm -f "$DEST"
      cp "build/app/outputs/bundle/${FLAVOR}Release/app-${FLAVOR}-release.aab" "$DEST"
      ;;
    debug)
      echo "→ APK debug ($FLAVOR)..."
      "$FLUTTER" build apk --debug --flavor "$FLAVOR" --no-pub
      DEST="${APP}-${VERSION}-${CODE}-debug.apk"
      cp "build/app/outputs/flutter-apk/app-${FLAVOR}-debug.apk" "$DEST"
      ;;
    *)
      echo "→ APK release ($FLAVOR)..."
      "$FLUTTER" build apk --release --flavor "$FLAVOR" --no-pub
      DEST="${APP}-${VERSION}-${CODE}.apk"
      cp "build/app/outputs/flutter-apk/app-${FLAVOR}-release.apk" "$DEST"
      ;;
  esac
  echo "✓ $DEST"
  OUTPUTS+=("$DEST")
done

if [ "$PUSH" = "push" ]; then
  git add -f "${OUTPUTS[@]}"
  git commit -m "release: v${VERSION} (${CODE}) — ${OUTPUTS[*]}"
  git push
fi

for DEST in "${OUTPUTS[@]}"; do
  echo "   https://github.com/cmgonzalez/easy-spectrum/raw/main/${DEST}"
done
