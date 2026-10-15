cmake_minimum_required(VERSION 3.25)
project(cornice_platform VERSION 0.1.0 LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_AUTOMOC ON)
find_package(Qt6 REQUIRED COMPONENTS Core Gui Quick Qml Concurrent Network DBus)
qt_policy(SET QTP0001 NEW)
qt_add_qml_module(cornice_platform URI Cornice.Platform VERSION 1.0
  OUTPUT_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/qml/Cornice/Platform
  SOURCES ScreenshotController.hpp ScreenshotController.cpp LocalIpcServer.hpp LocalIpcServer.cpp
    DesktopActionRouter.hpp DesktopActionRouter.cpp)
target_link_libraries(cornice_platform PRIVATE Qt6::Core Qt6::Gui Qt6::Quick Qt6::Concurrent Qt6::Network Qt6::DBus)
set_target_properties(cornice_platform cornice_platformplugin PROPERTIES INSTALL_RPATH "$ORIGIN")
install(TARGETS cornice_platform cornice_platformplugin LIBRARY DESTINATION native/qml/Cornice/Platform)
install(FILES ${CMAKE_CURRENT_BINARY_DIR}/qml/Cornice/Platform/qmldir
  ${CMAKE_CURRENT_BINARY_DIR}/qml/Cornice/Platform/cornice_platform.qmltypes
  DESTINATION native/qml/Cornice/Platform)

# Real local sockets and the exported QML type; never installed.
add_executable(cornice-local-ipc-verify EXCLUDE_FROM_ALL ../../test/local-ipc-server-verify.cpp)
add_dependencies(cornice-local-ipc-verify cornice_platformplugin)
target_include_directories(cornice-local-ipc-verify PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(cornice-local-ipc-verify PRIVATE cornice_platform Qt6::Gui Qt6::Qml Qt6::Network)
target_compile_definitions(cornice-local-ipc-verify PRIVATE
  CORNICE_TEST_QML_IMPORT_PATH="${CMAKE_CURRENT_BINARY_DIR}/qml")

add_executable(cornice-desktop-action-verify EXCLUDE_FROM_ALL ../../test/desktop-action-router-verify.cpp)
target_include_directories(cornice-desktop-action-verify PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(cornice-desktop-action-verify PRIVATE cornice_platform Qt6::Core Qt6::DBus)
