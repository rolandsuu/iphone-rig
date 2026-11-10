#!/bin/sh
# Builds UxPlay (open-source AirPlay mirroring receiver) into vendor/UxPlay/build/uxplay.
# iPhone Rig.app runs it as a hidden child process named "Claude Rig".
# Needs: brew install cmake pkgconf libplist gstreamer
set -e
cd "$(dirname "$0")/.."
if [ ! -d vendor/UxPlay ]; then
  mkdir -p vendor
  git clone --depth 1 https://github.com/FDH2/UxPlay.git vendor/UxPlay
fi
cd vendor/UxPlay
mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release -DNO_MARCH_NATIVE=ON
make -j"$(sysctl -n hw.ncpu)"
echo "built $(pwd)/uxplay"
