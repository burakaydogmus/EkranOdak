#!/bin/bash
# Derler ve build/EkranOdak.app oluşturur.
# --install: ~/Applications'a kopyalar ve başlatır.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/EkranOdak.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
  main.swift -o "$APP/Contents/MacOS/EkranOdak"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - --identifier com.local.EkranOdak "$APP"
echo "Hazır: $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x EkranOdak 2>/dev/null || true
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/EkranOdak.app"
  cp -R "$APP" "$HOME/Applications/"
  open "$HOME/Applications/EkranOdak.app"
  echo "Kuruldu ve başlatıldı: ~/Applications/EkranOdak.app"
fi
