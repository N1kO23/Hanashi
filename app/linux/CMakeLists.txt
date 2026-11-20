# Project-level configuration.
cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# The name of the executable created for the application. Not "hanashi": the
# packages' launcher, which starts it, has that name (packaging/linux/package.sh).
set(BINARY_NAME "hanashi_app")
# The unique GTK application identifier for this application. See:
# https://wiki.gnome.org/HowDoI/ChooseApplicationID
set(APPLICATION_ID "app.nullpointr.hanashi")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(SET CMP0063 NEW)

# Load bundled libraries from the lib/ directory relative to the binary.
set(CMAKE_INSTALL_RPATH "$ORIGIN/lib")

# Root filesystem for cross-building.
if(FLUTTER_TARGET_PLATFORM_SYSROOT)
  set(CMAKE_SYSROOT ${FLUTTER_TARGET_PLATFORM_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH ${CMAKE_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
  set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
endif()

# Define build configuration options.
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE "Debug" CACHE
    STRING "Flutter build mode" FORCE)
  set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
    "Debug" "Profile" "Release")
endif()

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_14)
  target_compile_options(${TARGET} PRIVATE -Wall -Werror)
  target_compile_options(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:-O3>")
  target_compile_definitions(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:NDEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# System-level dependencies.
find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK REQUIRED IMPORTED_TARGET gtk+-3.0)

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# Only the install-generated bundle's copy of the executable will launch
# correctly, since the resources must in the right relative locations. To avoid
# people trying to run the unbundled copy, put it in a subdirectory instead of
# the default top-level location.
set_target_properties(${BINARY_NAME}
  PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/intermediates_do_not_run"
)


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)

# The WebRTC plugins for calls have warnings of their own, which the standard
# settings' -Werror makes errors; they stay warnings.
foreach(plugin flutter_webrtc livekit_client)
  if(TARGET ${plugin}_plugin)
    target_compile_options(${plugin}_plugin PRIVATE -Wno-error)
  endif()
endforeach()

# flutter_webrtc's screen capture is built from our copy
# (webrtc/flutter_screen_capture.cc), but only for the version it was copied
# from; otherwise flutter_webrtc's own is built. The copy attaches the
# microphone's voice gate (webrtc/voice_gate.h). Where PipeWire's headers are
# (PipeWire itself is loaded at run time), it also shares a screen or a
# window on Wayland through one desktop portal session of our own
# (webrtc/portal_screen_cast.h), and a share's sound without the call's
# (webrtc/pipewire_app_sound.h).
set(WEBRTC_CAPTURE_SHA256 "5fd92ad57ea1b0464b8adcc2585b7b5fa044140bac4b905217b425c023b015d2")
set(WEBRTC_CAPTURE_ORIGINAL
  "${CMAKE_CURRENT_SOURCE_DIR}/flutter/ephemeral/.plugin_symlinks/flutter_webrtc/common/cpp/src/flutter_screen_capture.cc")
find_package(PkgConfig REQUIRED)
pkg_check_modules(HANASHI_PIPEWIRE libpipewire-0.3)
if(TARGET flutter_webrtc_plugin AND EXISTS "${WEBRTC_CAPTURE_ORIGINAL}")
  file(SHA256 "${WEBRTC_CAPTURE_ORIGINAL}" WEBRTC_CAPTURE_FOUND)
  if(NOT WEBRTC_CAPTURE_FOUND STREQUAL WEBRTC_CAPTURE_SHA256)
    message(WARNING "flutter_webrtc's flutter_screen_capture.cc is not the one linux/webrtc copies: "
      "no voice gate, and screen sharing on Wayland falls back to flutter_webrtc's own, until the copy is brought up to date.")
  else()
    get_target_property(WEBRTC_SOURCES flutter_webrtc_plugin SOURCES)
    list(FILTER WEBRTC_SOURCES EXCLUDE REGEX "flutter_screen_capture\\.cc$")
    list(APPEND WEBRTC_SOURCES
      "${CMAKE_CURRENT_SOURCE_DIR}/webrtc/flutter_screen_capture.cc"
      "${CMAKE_CURRENT_SOURCE_DIR}/webrtc/voice_gate.cc")
    target_include_directories(flutter_webrtc_plugin PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/webrtc")
    target_compile_definitions(flutter_webrtc_plugin PRIVATE HANASHI_VOICE_GATE=1)
    # It runs on every 10 ms of the microphone: optimized also in debug builds.
    set_source_files_properties("${CMAKE_CURRENT_SOURCE_DIR}/webrtc/voice_gate.cc"
      PROPERTIES COMPILE_OPTIONS "-O2")
    if(NOT HANASHI_PIPEWIRE_FOUND)
      message(WARNING "No PipeWire headers (libpipewire-0.3): screen sharing on Wayland falls back to flutter_webrtc's own.")
    else()
      list(APPEND WEBRTC_SOURCES
        "${CMAKE_CURRENT_SOURCE_DIR}/webrtc/pipewire_app_sound.cc"
        "${CMAKE_CURRENT_SOURCE_DIR}/webrtc/portal_screen_cast.cc")
      target_include_directories(flutter_webrtc_plugin PRIVATE ${HANASHI_PIPEWIRE_INCLUDE_DIRS})
      target_compile_definitions(flutter_webrtc_plugin PRIVATE HANASHI_PORTAL_SCREENCAST=1)
      target_link_libraries(flutter_webrtc_plugin PRIVATE ${CMAKE_DL_LIBS})
      # Frames are converted pixel by pixel: fast enough also in debug builds.
      set_source_files_properties("${CMAKE_CURRENT_SOURCE_DIR}/webrtc/portal_screen_cast.cc"
        PROPERTIES COMPILE_OPTIONS "-O2")
    endif()
    set_target_properties(flutter_webrtc_plugin PROPERTIES SOURCES "${WEBRTC_SOURCES}")
  endif()
endif()

# === Installation ===
# By default, "installing" just makes a relocatable bundle in the build
# directory.
set(BUILD_BUNDLE_DIR "${PROJECT_BINARY_DIR}/bundle")
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

# Start with a clean build bundle directory every time.
install(CODE "
  file(REMOVE_RECURSE \"${BUILD_BUNDLE_DIR}/\")
  " COMPONENT Runtime)

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}/lib")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

foreach(bundled_library ${PLUGIN_BUNDLED_LIBRARIES})
  install(FILES "${bundled_library}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endforeach(bundled_library)

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/linux/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
if(NOT CMAKE_BUILD_TYPE MATCHES "Debug")
  install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()
