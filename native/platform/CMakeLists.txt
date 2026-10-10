cmake_minimum_required(VERSION 3.25)
project(cornice_platform VERSION 0.1.0 LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_AUTOMOC ON)
find_package(Qt6 REQUIRED COMPONENTS Core Gui Quick Qml)
qt_policy(SET QTP0001 NEW)
qt_add_qml_module(cornice_platform URI Cornice.Platform VERSION 1.0
  OUTPUT_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/qml/Cornice/Platform
  SOURCES ScreenshotController.hpp ScreenshotController.cpp)
target_link_libraries(cornice_platform PRIVATE Qt6::Core Qt6::Gui Qt6::Quick)
set_target_properties(cornice_platform cornice_platformplugin PROPERTIES INSTALL_RPATH "$ORIGIN")
install(TARGETS cornice_platform cornice_platformplugin LIBRARY DESTINATION native/qml/Cornice/Platform)
install(FILES ${CMAKE_CURRENT_BINARY_DIR}/qml/Cornice/Platform/qmldir
  ${CMAKE_CURRENT_BINARY_DIR}/qml/Cornice/Platform/cornice_platform.qmltypes
  DESTINATION native/qml/Cornice/Platform)
