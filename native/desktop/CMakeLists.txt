cmake_minimum_required(VERSION 3.25)
project(cornice_desktop VERSION 0.1.0 LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_AUTOMOC ON)
find_package(Qt6 REQUIRED COMPONENTS Core Gui Network Quick Qml)
qt_policy(SET QTP0001 NEW)
find_package(PkgConfig REQUIRED)
pkg_check_modules(WAYLAND REQUIRED IMPORTED_TARGET wayland-client)
pkg_check_modules(XKB REQUIRED IMPORTED_TARGET xkbcommon)
find_program(WAYLAND_SCANNER wayland-scanner REQUIRED)
foreach(name virtual-keyboard-unstable-v1 wlr-virtual-pointer-unstable-v1)
  add_custom_command(OUTPUT ${name}.h ${name}.c
    COMMAND ${WAYLAND_SCANNER} client-header ${CMAKE_CURRENT_SOURCE_DIR}/protocols/${name}.xml ${name}.h
    COMMAND ${WAYLAND_SCANNER} private-code ${CMAKE_CURRENT_SOURCE_DIR}/protocols/${name}.xml ${name}.c
    DEPENDS protocols/${name}.xml VERBATIM)
  list(APPEND PROTOCOL_SOURCES ${name}.c ${name}.h)
endforeach()
add_executable(cornice-desktop-runtime main.cpp Broker.cpp SeatDriver.cpp ${PROTOCOL_SOURCES})
target_include_directories(cornice-desktop-runtime PRIVATE ${CMAKE_CURRENT_BINARY_DIR})
target_link_libraries(cornice-desktop-runtime PRIVATE Qt6::Core Qt6::Gui Qt6::Network PkgConfig::WAYLAND PkgConfig::XKB)
qt_add_qml_module(cornice_desktop_qml URI Cornice.Desktop VERSION 1.0
  OUTPUT_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/qml/Cornice/Desktop
  SOURCES WorkspaceView.hpp WorkspaceView.cpp)
target_link_libraries(cornice_desktop_qml PRIVATE Qt6::Quick Qt6::Network)
set_target_properties(cornice_desktop_qml cornice_desktop_qmlplugin PROPERTIES INSTALL_RPATH "$ORIGIN")
install(TARGETS cornice-desktop-runtime RUNTIME DESTINATION native/bin)
install(TARGETS cornice_desktop_qml cornice_desktop_qmlplugin LIBRARY DESTINATION native/qml/Cornice/Desktop)
install(FILES ${CMAKE_CURRENT_BINARY_DIR}/qml/Cornice/Desktop/qmldir
  ${CMAKE_CURRENT_BINARY_DIR}/qml/Cornice/Desktop/cornice_desktop_qml.qmltypes
  DESTINATION native/qml/Cornice/Desktop)

install(FILES ${CMAKE_CURRENT_SOURCE_DIR}/../../LICENSE
  protocols/virtual-keyboard-unstable-v1.xml protocols/wlr-virtual-pointer-unstable-v1.xml
  DESTINATION native/licenses)
