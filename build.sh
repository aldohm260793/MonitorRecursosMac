#!/bin/bash
# Compila MonitorRecursos.app para macOS (Apple Silicon, arm64)
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="MonitorRecursos"
APP_DIR="$APP_NAME.app"

echo "==> Compilando código Swift…"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

swiftc -O \
    -swift-version 5 \
    -target arm64-apple-macos14.0 \
    -module-name "$APP_NAME" \
    -o "$APP_DIR/Contents/MacOS/$APP_NAME" \
    Sources/*.swift

echo "==> Copiando Info.plist…"
cp Info.plist "$APP_DIR/Contents/Info.plist"

echo "==> Firmando (firma ad-hoc local)…"
codesign --force --deep --sign - "$APP_DIR"

echo ""
echo "✅ Listo: $APP_DIR"
echo "   Ábrelo con:  open \"$APP_DIR\""
echo "   Instálalo con:  ./install.sh"
