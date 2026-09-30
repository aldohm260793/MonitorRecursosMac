#!/bin/bash
# Empaqueta MonitorRecursos.app en un DMG listo para compartir
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="MonitorRecursos"
VERSION="1.0"
DMG_NAME="$APP_NAME-$VERSION.dmg"

if [ ! -d "$APP_NAME.app" ]; then
    echo "Primero compila la app:  ./build.sh"
    exit 1
fi

echo "==> Preparando contenido del DMG…"
rm -rf dmg-staging "$DMG_NAME"
mkdir dmg-staging
cp -R "$APP_NAME.app" dmg-staging/
ln -s /Applications dmg-staging/Applications

echo "==> Creando $DMG_NAME…"
hdiutil create -volname "Monitor Recursos" -srcfolder dmg-staging -ov -format UDZO "$DMG_NAME"
rm -rf dmg-staging

echo ""
echo "✅ Listo: $DMG_NAME"
echo "   Pásalo a otra Mac por AirDrop, USB o red. Allí basta abrir el DMG"
echo "   y arrastrar la app a la carpeta Aplicaciones."
