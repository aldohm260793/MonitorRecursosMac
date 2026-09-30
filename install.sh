#!/bin/bash
# Instala MonitorRecursos.app en /Applications y lo abre
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="MonitorRecursos"

if [ ! -d "$APP_NAME.app" ]; then
    echo "Primero compila la app:  ./build.sh"
    exit 1
fi

echo "==> Instalando en /Applications…"
rm -rf "/Applications/$APP_NAME.app"
cp -R "$APP_NAME.app" "/Applications/$APP_NAME.app"

# Quitar la cuarentena para que macOS no la bloquee (app local sin certificado de desarrollador)
xattr -dr com.apple.quarantine "/Applications/$APP_NAME.app" 2>/dev/null || true

echo "==> Abriendo la app…"
open "/Applications/$APP_NAME.app"

echo ""
echo "✅ Instalada. Verás el widget flotante en la esquina superior derecha del escritorio."
echo "   Consejo: activa «Abrir al iniciar sesión» dentro del widget para que arranque solo."
