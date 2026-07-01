cmake_minimum_required(VERSION 3.20)
project(RestApiToText VERSION 1.0.0 LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_OSX_DEPLOYMENT_TARGET "11.0")
set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64")
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

# Host plugin interface + Scintilla (read-only; NO host changes)
set(NPP_MACOS_DIR      "${CMAKE_SOURCE_DIR}/../../notepad-plus-plus-macos")
set(NPP_PLUGIN_INCLUDE "${NPP_MACOS_DIR}/src")
set(SCINTILLA_INCLUDE  "${NPP_MACOS_DIR}/scintilla/include")

add_library(RestApiToText SHARED src/RestApiToText.mm)
target_include_directories(RestApiToText PRIVATE ${NPP_PLUGIN_INCLUDE} ${SCINTILLA_INCLUDE})
# NSURLSession transport lives in Foundation; AppKit dialogs need Cocoa.
target_link_libraries(RestApiToText PRIVATE "-framework Foundation" "-framework Cocoa")
target_compile_options(RestApiToText PRIVATE
    -Wall -Wno-unused-parameter -fvisibility=hidden
    $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
set_target_properties(RestApiToText PROPERTIES PREFIX "" SUFFIX ".dylib")
target_link_options(RestApiToText PRIVATE "-Wl,-current_version,${PROJECT_VERSION}")

# Install (real plugins dir). This plugin has no toolbar icon and ships no
# bundled resources — just the dylib.
set(PLUGIN_INSTALL_DIR "$ENV{HOME}/Library/Application Support/Nextpad++/plugins/RestApiToText")
install(TARGETS RestApiToText DESTINATION "${PLUGIN_INSTALL_DIR}")
