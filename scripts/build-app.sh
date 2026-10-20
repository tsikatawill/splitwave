#!/bin/zsh
# Builds build/Splitwave.app (menu-bar app with the CLI inside) and signs it.
#   scripts/build-app.sh            release build for this Mac
#   scripts/build-app.sh --install  ...and copy it to /Applications, linking the CLI to /usr/local/bin
#   UNIVERSAL=1 scripts/build-app.sh   Apple Silicon + Intel (what releases ship)
set -euo pipefail
cd "${0:A:h}/.."

ARCH_FLAGS=()
[[ "${UNIVERSAL:-}" == 1 ]] && ARCH_FLAGS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCH_FLAGS[@]}" --product SplitwaveApp
swift build -c release "${ARCH_FLAGS[@]}" --product splitwave
BIN=$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)

APP=build/Splitwave.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [[ -n "${SPLITWAVE_VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SPLITWAVE_VERSION" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${SPLITWAVE_BUILD:-1}" "$APP/Contents/Info.plist"
fi
cp "$BIN/SplitwaveApp" "$APP/Contents/MacOS/SplitwaveApp"
cp "$BIN/splitwave" "$APP/Contents/MacOS/splitwave"

# macOS ties the audio-capture grant to the signature. Ad-hoc signatures change with every build,
# so it asks again; a real identity (SPLITWAVE_SIGN_IDENTITY, or "Splitwave Local") keeps the grant.
IDENTITY="${SPLITWAVE_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  # The identity scripts/make-signing-cert.sh creates, if it exists; else ad hoc.
  if security find-identity -v -p codesigning 2>/dev/null | grep -q '"Splitwave Local"'; then
    IDENTITY="Splitwave Local"
  else
    IDENTITY="-"
    echo "Signing ad hoc: macOS will ask for audio permission again. Run scripts/make-signing-cert.sh once to stop that."
  fi
fi
codesign --force --sign "$IDENTITY" --identifier app.splitwave.cli "$APP/Contents/MacOS/splitwave"
codesign --force --sign "$IDENTITY" --identifier app.splitwave.Splitwave "$APP"
codesign --verify --strict "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  osascript -e 'quit app id "app.splitwave.Splitwave"' 2>/dev/null || true
  rm -rf /Applications/Splitwave.app
  cp -R "$APP" /Applications/Splitwave.app
  if [[ -w /usr/local/bin ]]; then
    ln -sf /Applications/Splitwave.app/Contents/MacOS/splitwave /usr/local/bin/splitwave
    echo "Linked /usr/local/bin/splitwave"
  else
    echo "To use the CLI from anywhere: sudo ln -sf /Applications/Splitwave.app/Contents/MacOS/splitwave /usr/local/bin/splitwave"
  fi
  echo "Installed /Applications/Splitwave.app"
fi
