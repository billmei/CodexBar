#!/bin/bash
set -euo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
  echo "CodexBar Floating Widget requires macOS." >&2
  exit 1
fi

if ! command -v node >/dev/null || ! xcrun --find swiftc >/dev/null; then
  echo "Install Node.js and Xcode Command Line Tools before building the widget." >&2
  exit 1
fi

widget_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd -- "$widget_dir/../.." && pwd)"
install_dir="$HOME/Applications"
app_name="CodexBar Floating Widget.app"
destination="$install_dir/$app_name"
mkdir -p "$install_dir"
stage="$(mktemp -d "$install_dir/.codexbar-widget.XXXXXX")"
app="$stage/$app_name"
backup="$stage/previous/$app_name"

cleanup() {
  if [[ -d "$backup" && ! -e "$destination" && ! -L "$destination" ]]; then
    if ! mv "$backup" "$install_dir"; then
      printf 'The previous app is still at %s\n' "$backup" >&2
      return
    fi
  fi
  rm -rf -- "$stage"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

resources="$app/Contents/Resources"
executable="$app/Contents/MacOS/CodexBarFloatingWidget"
mkdir -p "$resources" "$(dirname "$executable")"
cp "$widget_dir/Info.plist" "$app/Contents/Info.plist"
cp "$widget_dir/index.html" "$widget_dir/widget.css" "$resources/"

sucrase="$root_dir/Sources/CodexBarCore/Resources/Plugins/sucrase-3.35.1.min.js"
for script in usage widget; do
  node "$root_dir/Scripts/transpile-plugin-ts.mjs" "$widget_dir/$script.ts" "$sucrase" > "$resources/$script.js"
done

xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library -O \
  -target "$(uname -m)-apple-macosx14.0" \
  "$widget_dir/DashboardFeed.swift" "$widget_dir/FloatingWidget.swift" -o "$executable"
/usr/bin/codesign --sign - "$app"
/usr/bin/codesign --verify --strict "$app"

if [[ -e "$destination" || -L "$destination" ]]; then
  if [[ -L "$destination" ]] ||
    [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$destination/Contents/Info.plist" 2>/dev/null || true)" != com.billmei.codexbar.floatingwidget ]]; then
    echo "A different app already exists at $destination." >&2
    exit 1
  fi
  mkdir "$stage/previous"
  mv "$destination" "$stage/previous"
fi

mv "$app" "$install_dir"
printf 'Installed %s\n' "$destination"
