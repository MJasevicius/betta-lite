#!/bin/zsh
# Renders the README's pictures into media/, and the demo video into dist/ (for the release), all
# offscreen, from the tools in the app itself.
#
#   tools/make-media.sh

set -e
cd "$(dirname "$0")/.."
swift build -c release
B="$(swift build -c release --show-bin-path)/BettaLite"
W=.build/media
rm -rf $W media
mkdir -p $W media dist

# the fish drawing itself, close up
$B --gif media/drawing.gif --seconds 8 --fps 15 --width 560 --cols 150 --rows 104 --seed 3
# three fish in the tank, and the light at sunrise
$B --snap 1200 --out $W/tank --fish 3 --seabed --surface --company --rays 1 --caustics 0.6 --rows 160 --seed 6
$B --snap 600 --out $W/dawn --seabed --rays 1.8 --dawn 1 --seed 3
sips -Z 1600 $W/tank/swift_01200.png --out media/tank.png >/dev/null
sips -Z 1600 $W/dawn/swift_00600.png --out media/dawn.png >/dev/null
# 40 seconds: it draws itself, swims, is fed (12 s), and the glass is tapped (25 s)
$B --video dist/betta-lite-demo.mp4 --seconds 40 --width 1280 --seabed --surface --rays 1 --caustics 0.6 --feed 360 --tap 750 --seed 3
ls -la media dist/*.mp4
