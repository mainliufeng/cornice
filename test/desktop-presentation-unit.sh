#!/usr/bin/env bash
# Source-only unit: no QGuiApplication, display, GPU, compositor or host socket.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
build=$(mktemp -d /tmp/cornice-presentation-unit-build.XXXXXX)
trap 'rm -rf "$build"' EXIT
cat > "$build/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.25)
project(cornice_presentation_unit LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_AUTOMOC ON)
find_package(Qt6 REQUIRED COMPONENTS Core Network Quick)
add_executable(cornice-presentation-unit
  ${CORNICE_SOURCE}/test/desktop-presentation-unit.cpp
  ${CORNICE_SOURCE}/native/desktop/DesktopPresentation.cpp
  ${CORNICE_SOURCE}/native/desktop/DesktopPresentation.hpp)
target_include_directories(cornice-presentation-unit PRIVATE ${CORNICE_SOURCE}/native/desktop)
target_link_libraries(cornice-presentation-unit PRIVATE Qt6::Core Qt6::Network Qt6::Quick)
CMAKE
cmake -S "$build" -B "$build/out" -GNinja -DCORNICE_SOURCE="$root" -DCMAKE_BUILD_TYPE=Debug
cmake --build "$build/out" --parallel 2
env -u WAYLAND_DISPLAY -u DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u DBUS_SESSION_BUS_ADDRESS \
  "$build/out/cornice-presentation-unit"
