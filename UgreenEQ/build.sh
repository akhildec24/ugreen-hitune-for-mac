#!/bin/zsh
set -e
cd "$(dirname "$0")"
rm -rf UgreenEQ.app
mkdir -p UgreenEQ.app/Contents/MacOS
swiftc -O main.swift -o UgreenEQ.app/Contents/MacOS/UgreenEQ
cp Info.plist UgreenEQ.app/Contents/Info.plist
mkdir -p UgreenEQ.app/Contents/Resources
[ -f AppIcon.icns ] || { swiftc -O make-icon.swift -o make-icon && ./make-icon AppIcon.iconset >/dev/null && iconutil -c icns AppIcon.iconset -o AppIcon.icns; }
cp AppIcon.icns UgreenEQ.app/Contents/Resources/AppIcon.icns
codesign --force --sign - UgreenEQ.app
echo "Built UgreenEQ.app"
if [ "$1" = "--install" ]; then
  pkill -x UgreenEQ; sleep 1
  rm -rf /Applications/UgreenEQ.app && cp -R UgreenEQ.app /Applications/UgreenEQ.app
  touch /Applications/UgreenEQ.app
  open /Applications/UgreenEQ.app
  echo "Installed to /Applications and launched"
fi
