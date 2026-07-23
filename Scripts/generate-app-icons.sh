#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
source_icon="$project_root/App/IconSource/SwipeFlowIcon-Designed.png"
balanced_icon="$project_root/App/IconSource/SwipeFlowIcon-DockBalanced.png"
iconset_dir="$project_root/App/Assets.xcassets/AppIcon.appiconset"

if ! command -v magick >/dev/null 2>&1; then
    echo "ImageMagick is required to regenerate the app icons." >&2
    exit 1
fi

# Modern macOS app icons use a 1024 px canvas with an approximately 824 px
# visual body. The transparent safety area keeps the icon optically aligned
# with Apple and other third-party Dock icons.
magick "$source_icon" \
    -resize 824x824 \
    -background none \
    -gravity center \
    -extent 1024x1024 \
    "$balanced_icon"

typeset -A sizes=(
    AppIcon-16.png 16
    AppIcon-16@2x.png 32
    AppIcon-32.png 32
    AppIcon-32@2x.png 64
    AppIcon-128.png 128
    AppIcon-128@2x.png 256
    AppIcon-256.png 256
    AppIcon-256@2x.png 512
    AppIcon-512.png 512
    AppIcon-512@2x.png 1024
)

for filename size in ${(kv)sizes}; do
    magick "$balanced_icon" -resize "${size}x${size}" "$iconset_dir/$filename"
done

echo "Generated Dock-balanced app icons from $source_icon"
