cmake_minimum_required(VERSION 3.25)
project(cornice_screenshot_controller_verify LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_AUTOMOC ON)
find_package(Qt6 REQUIRED COMPONENTS Core Gui Quick Qml Concurrent Test)
qt_add_executable(screenshot-controller-verify main.cpp
  ../../native/platform/ScreenshotController.cpp ../../native/platform/ScreenshotController.hpp)
target_link_libraries(screenshot-controller-verify PRIVATE Qt6::Core Qt6::Gui Qt6::Quick Qt6::Qml Qt6::Concurrent Qt6::Test)
