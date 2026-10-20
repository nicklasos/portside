#!/usr/bin/env bash
# Regenerates every brand PNG from the SVG masters: the asset catalog's AppIcon and
# menu bar imagesets, the README icons, the GitHub banner, and build/Portside.icns.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ICON="$ROOT/assets/icon"
XCASSETS="$ROOT/Portside/Resources/Assets.xcassets"
ICONSET="$ROOT/build/Portside.iconset"

command -v rsvg-convert >/dev/null || { echo "rsvg-convert not found; brew install librsvg" >&2; exit 1; }

render() { rsvg-convert --width "$2" --height "$2" "$1" --output "$3"; }

rm -rf "$ICONSET"
mkdir -p "$ICONSET" "$XCASSETS"
cat > "$XCASSETS/Contents.json" <<'JSON'
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON

images=""
for size in 16 32 128 256 512; do
  for scale in 1 2; do
    if [ "$scale" = 1 ]; then name="icon_${size}x${size}.png"; else name="icon_${size}x${size}@2x.png"; fi
    render "$ICON/portside.svg" $((size * scale)) "$ICONSET/$name"
    images+="    { \"filename\" : \"$name\", \"idiom\" : \"mac\", \"scale\" : \"${scale}x\", \"size\" : \"${size}x${size}\" },"$'\n'
  done
done

APPICON="$XCASSETS/AppIcon.appiconset"
rm -rf "$APPICON"
mkdir -p "$APPICON"
cp "$ICONSET"/*.png "$APPICON/"
cat > "$APPICON/Contents.json" <<JSON
{
  "images" : [
${images%,$'\n'}
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON

mkdir -p "$ROOT/build"
iconutil --convert icns --output "$ROOT/build/Portside.icns" "$ICONSET"

for state in idle active; do
  set_dir="$XCASSETS/MenuBar$(tr '[:lower:]' '[:upper:]' <<< "${state:0:1}")${state:1}.imageset"
  rm -rf "$set_dir"
  mkdir -p "$set_dir"
  for scale in 1 2 3; do
    render "$ICON/menubar-$state.svg" $((18 * scale)) "$set_dir/menubar-$state@${scale}x.png"
  done
  cat > "$set_dir/Contents.json" <<JSON
{
  "images" : [
    { "filename" : "menubar-$state@1x.png", "idiom" : "universal", "scale" : "1x" },
    { "filename" : "menubar-$state@2x.png", "idiom" : "universal", "scale" : "2x" },
    { "filename" : "menubar-$state@3x.png", "idiom" : "universal", "scale" : "3x" }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "properties" : {
    "template-rendering-intent" : "template"
  }
}
JSON
done

render "$ICON/portside.svg" 1024 "$ICON/portside-1024.png"
render "$ICON/portside.svg" 256 "$ICON/portside-256.png"
# librsvg refuses to load images from outside the SVG's own directory, so inline the icon.
icon_uri="data:image/svg+xml;base64,$(base64 < "$ICON/portside.svg" | tr -d '\n')"
sed "s|href=\"../icon/portside.svg\"|href=\"$icon_uri\"|" "$ROOT/assets/banner/banner.svg" \
  | rsvg-convert --width 1280 --height 640 --output "$ROOT/assets/banner/banner.png"

echo "Regenerated AppIcon, MenuBarIdle, MenuBarActive, README icons, banner and build/Portside.icns"
