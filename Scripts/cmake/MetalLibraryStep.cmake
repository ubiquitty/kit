# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

#
# MetalLibraryStep.cmake — the render kit's shader library, compiled for one
# iOS SDK.
#
# The metallib comes out different for a device and for the simulator (a
# minimum-version flag), and which one a build wants is not known at configure
# time in an Xcode project: the destination picked in the toolbar chooses the
# SDK when the build starts. So the platform is read when the step runs, handed
# in by a tree that serves one SDK and taken from Xcode's PLATFORM_NAME
# otherwise, and the output path is derived here from that one answer.
#
#   cmake -DCORE_SOURCE_DIR=<ubiquitty-core checkout>
#         -DKIT_SOURCE_DIR=<ubiquitty-kit checkout>
#         -DBINARY_DIR=<build tree> -DIOS_MIN=<deployment target>
#         [-DPLATFORM=<iphoneos|iphonesimulator>] [-DPER_PLATFORM=ON]
#         -P MetalLibraryStep.cmake
#
# Writes <build tree>/default.metallib, or <build tree>/<platform>/default.metallib
# under PER_PLATFORM, which a tree serving both SDKs needs: one shared library
# would be whichever SDK built last, with a timestamp that says it is current.
# It is the default step of ubiquitty_kit_add_metal_library(PLATFORM iOS) in
# Scripts/cmake/UbiquittyKit.cmake, whose library depends on this file.
#

foreach(_required CORE_SOURCE_DIR KIT_SOURCE_DIR BINARY_DIR IOS_MIN)
    if(NOT DEFINED ${_required} OR "${${_required}}" STREQUAL "")
        message(FATAL_ERROR "MetalLibraryStep.cmake needs -D${_required}=...")
    endif()
endforeach()

if(NOT DEFINED PLATFORM OR PLATFORM STREQUAL "")
    set(PLATFORM "$ENV{PLATFORM_NAME}")
endif()
# Refused rather than defaulted. A step that guessed "device" for an unset
# platform would produce a well-formed library for the wrong SDK.
if(NOT PLATFORM STREQUAL "iphoneos" AND NOT PLATFORM STREQUAL "iphonesimulator")
    message(FATAL_ERROR
        "MetalLibraryStep.cmake: the platform is '${PLATFORM}', and the shaders build for "
        "iphoneos or iphonesimulator. Pass -DPLATFORM=..., or run under Xcode, which "
        "exports PLATFORM_NAME for the destination being built.")
endif()

if(PER_PLATFORM)
    set(_metalDirectory "${BINARY_DIR}/${PLATFORM}")
else()
    set(_metalDirectory "${BINARY_DIR}")
endif()
file(MAKE_DIRECTORY "${_metalDirectory}")

if(PLATFORM STREQUAL "iphonesimulator")
    set(_metalVersionFlag "-mios-simulator-version-min=${IOS_MIN}")
else()
    set(_metalVersionFlag "-miphoneos-version-min=${IOS_MIN}")
endif()

# Runs one tool and stops the build on a failure, with the tool named.
#
# - Parameter what: What the command was doing, for the failure line.
function(ubiquitty_kit_metal_run what)
    execute_process(COMMAND ${ARGN} RESULT_VARIABLE _status)
    if(NOT _status EQUAL 0)
        message(FATAL_ERROR "MetalLibraryStep.cmake (${PLATFORM}): ${what} failed (${_status})")
    endif()
endfunction()

# Same source as the macOS arm: a shader is not platform code, and a second copy
# would be a second renderer by another route. It includes Core's Tek raster by
# its path under Core's Source root.
set(_metalAir "${_metalDirectory}/UBShaders.air")
ubiquitty_kit_metal_run("metal"
    xcrun -sdk "${PLATFORM}" metal ${_metalVersionFlag}
    -I "${CORE_SOURCE_DIR}/Source"
    -c "${KIT_SOURCE_DIR}/Source/UbiquittyRenderKit/UBShaders.metal"
    -o "${_metalAir}")
ubiquitty_kit_metal_run("metallib"
    xcrun -sdk "${PLATFORM}" metallib "${_metalAir}" -o "${_metalDirectory}/default.metallib")
