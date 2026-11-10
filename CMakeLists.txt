# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

#
# ubiquitty-kit: the renderers and the drop-in terminal views.
#
# One tree, selected at configure time by -DUBIQUITTY_FRONTEND=<name>:
#
#   macOS   UbiquittyKit.framework, the embeddable Metal terminal view
#           (TerminalSurface), with the Swift modules it is made of:
#           UbiquittyRenderKit, UbiquittyKitModule and the typed pasteboard.
#           The default on macOS. (Scripts/check-ubiquittykit.sh)
#   iOS     The same Swift modules for iphoneos or iphonesimulator, over the
#           Core library cut for iOS, and a link probe over the whole of it.
#           A library arm: it carries no UIKit and no entry point.
#   Linux   The Vulkan, FreeType and software renderers and the GTK platform
#           layer, as static libraries, with the Vulkan shaders and a link
#           check. The default on Linux. -DUBIQUITTY_BUILD_TESTS=ON adds the
#           kit's tests that need no app.
#
# ubiquitty-core is read from Libraries/ubiquitty-core, a submodule, unless
# -DUBIQUITTY_CORE_SOURCE_DIR names another checkout. Its build modules are
# included at this top directory in the order
# Libraries/ubiquitty-core/Scripts/cmake/UbiquittyCoreRoot.cmake lays out, and
# compiled into this build, so link-time optimization and the training profile
# cover the whole program. A project that embeds the kit includes
# Scripts/cmake/UbiquittyKit.cmake the same way and never adds this tree as a
# subdirectory.

cmake_minimum_required(VERSION 3.13)

if(NOT DEFINED UBIQUITTY_CORE_SOURCE_DIR)
    set(UBIQUITTY_CORE_SOURCE_DIR "${CMAKE_CURRENT_LIST_DIR}/Libraries/ubiquitty-core")
endif()
get_filename_component(UBIQUITTY_CORE_SOURCE_DIR "${UBIQUITTY_CORE_SOURCE_DIR}" ABSOLUTE)
if(NOT EXISTS "${UBIQUITTY_CORE_SOURCE_DIR}/Scripts/cmake/UbiquittyCoreRoot.cmake")
    message(FATAL_ERROR
        "ubiquitty-core is not at ${UBIQUITTY_CORE_SOURCE_DIR}. Run "
        "`git submodule update --init`, or pass -DUBIQUITTY_CORE_SOURCE_DIR=<checkout>.")
endif()
include("${UBIQUITTY_CORE_SOURCE_DIR}/Scripts/cmake/UbiquittyCoreRoot.cmake")

# This tree is the Kit's checkout, ABSOLUTE rather than REALPATH so a compile
# line spells the root the way its caller did. The version is this tree's: its
# commit and its VERSION file, not Core's.
set(UBIQUITTY_KIT_SOURCE_DIR "${CMAKE_SOURCE_DIR}")
get_filename_component(UBIQUITTY_KIT_SOURCE_DIR "${UBIQUITTY_KIT_SOURCE_DIR}" ABSOLUTE)
if(NOT DEFINED UBIQUITTY_VERSION_SOURCE_DIR)
    set(UBIQUITTY_VERSION_SOURCE_DIR "${UBIQUITTY_KIT_SOURCE_DIR}")
endif()
# The header root, once per distinct checkout, Core's first.
set(UBIQUITTY_SOURCE_INCLUDE_DIRECTORIES
    "${UBIQUITTY_CORE_SOURCE_DIR}/Source" "${UBIQUITTY_KIT_SOURCE_DIR}/Source")
list(REMOVE_DUPLICATES UBIQUITTY_SOURCE_INCLUDE_DIRECTORIES)

# The Swift 6 language mode, for every Swift target of the Apple arms: its
# data-race checking keeps the tree at zero concurrency diagnostics, as a build
# failure rather than a warning. The Xcode generator turns
# CMAKE_Swift_LANGUAGE_VERSION into a `-swift-version` word that Xcode reports
# as overriding the language mode; there the mode is the SWIFT_VERSION build
# setting instead.
if(CMAKE_GENERATOR MATCHES "Xcode")
    set(CMAKE_XCODE_ATTRIBUTE_SWIFT_VERSION 6)
else()
    set(CMAKE_Swift_LANGUAGE_VERSION 6)
endif()

# The compiler launcher, the deployment floors, the SDK and the version, which
# project() reads.
include("${UBIQUITTY_CORE_SOURCE_DIR}/Scripts/cmake/UbiquittyPreProject.cmake")
project(UbiquittyKit VERSION "${UBIQUITTY_VERSION_NAMED}" LANGUAGES C CXX)

if(NOT DEFINED UBIQUITTY_FRONTEND)
    if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
        set(UBIQUITTY_FRONTEND "Linux")
    else()
        set(UBIQUITTY_FRONTEND "macOS")
    endif()
endif()
set(UBIQUITTY_FRONTEND "${UBIQUITTY_FRONTEND}" CACHE STRING "Arm to build (macOS, iOS, Linux)")
message(STATUS "Ubiquitty frontend: ${UBIQUITTY_FRONTEND}")

# Core's toolchain, optimisation, sources and libraries, which every arm below
# builds on.
include("${UBIQUITTY_CORE_SOURCE_DIR}/Scripts/cmake/UbiquittyToolchain.cmake")
include("${UBIQUITTY_CORE_SOURCE_DIR}/Scripts/cmake/UbiquittyOptimize.cmake")
include("${UBIQUITTY_CORE_SOURCE_DIR}/Scripts/cmake/UbiquittyCoreSources.cmake")
include("${UBIQUITTY_CORE_SOURCE_DIR}/Scripts/cmake/UbiquittyCoreLibrary.cmake")

if(UBIQUITTY_FRONTEND STREQUAL "macOS" OR UBIQUITTY_FRONTEND STREQUAL "iOS")
    include("${UBIQUITTY_KIT_SOURCE_DIR}/Scripts/cmake/UbiquittyKit.cmake")
endif()

if(UBIQUITTY_BUILD_TESTS AND UBIQUITTY_FRONTEND STREQUAL "iOS")
    message(FATAL_ERROR
        "The kit's host tests run on the host: configure with -DUBIQUITTY_FRONTEND=macOS or Linux.")
endif()

# ----------------------------------------------------------------------
# macOS — UbiquittyKit.framework.
#
# The Swift modules the framework is made of, the shader library it carries and
# the framework itself. The framework compiles the portable Core the way an
# app embedding the modules does, so one configure produces the product.
# Scripts/check-ubiquittykit.sh builds it and draws a frame through it from a
# consumer of its own.
# ----------------------------------------------------------------------
if(UBIQUITTY_FRONTEND STREQUAL "macOS")

    enable_language(Swift)

    # The portable Core the framework links: the canonical list less what a
    # terminal view never reaches.
    ubiquitty_core_subset(UBIQUITTY_MACOS_CORE EXCLUDE
        Source/Core/Protocol/Sync/QUICBootstrap.cpp
        Source/Core/Session/Surface.cpp)
    set(UBIQUITTY_MACOS_CORE_EXTRAS
        Source/Core/Input/PasteNormalize.cpp
        Source/PAL/OutputQueue.cpp
        # The control socket's JSON-RPC value and parser, and the vendored
        # parser they wrap.
        Source/Core/Codec/JSON.cpp
        Source/ThirdParty/yyjson/yyjson.c)
    set(UBIQUITTY_PORTABLE_CORE ${UBIQUITTY_MACOS_CORE} ${UBIQUITTY_MACOS_CORE_EXTRAS})
    set(UBIQUITTY_PORTABLE_CORE_ABS "")
    foreach(_src IN LISTS UBIQUITTY_PORTABLE_CORE)
        list(APPEND UBIQUITTY_PORTABLE_CORE_ABS "${UBIQUITTY_CORE_SOURCE_DIR}/${_src}")
    endforeach()
    # The WebKit-style strict ABI the host and agent targets also use, per file
    # because the framework mixes in Swift. The vendored C parser is the one C
    # translation unit; it takes Core's ThirdParty policy and is set last, since
    # setting a property replaces it.
    set_source_files_properties(${UBIQUITTY_PORTABLE_CORE_ABS} PROPERTIES
        COMPILE_FLAGS "-std=c++23 -fno-exceptions -fno-rtti")
    set_source_files_properties("${UBIQUITTY_CORE_SOURCE_DIR}/Source/ThirdParty/yyjson/yyjson.c"
        PROPERTIES COMPILE_FLAGS "-std=c99 -Wno-error -w")

    if(UBIQUITTY_QUIC)
        ubiquitty_ensure_quic_deps() # fetch the pinned QUIC TLS deps if absent
        message(STATUS "Ubiquitty: QUIC transport enabled (ngtcp2 + AWS-LC)")
    endif()

    option(UBIQUITTY_HARFBUZZ_PROBE "Build the experimental uniform-face shaping comparison" OFF)
    set(UBIQUITTY_SWIFT_PGO_FLAGS "" CACHE STRING "Swift codegen profile flags (empty = no PGO)")
    ubiquitty_kit_swift_flags(PLATFORM macOS)
    ubiquitty_kit_add_swift_modules(PLATFORM macOS CXX_TARGETS UbiquittyKit)
    # The framework compiles the Kit's sources itself; the static module is what
    # an app links, and it is built when a target asks for it.
    set_target_properties(UbiquittyKitModule PROPERTIES EXCLUDE_FROM_ALL ON)

    ubiquitty_kit_add_metal_library(UbiquittyMetalLib PLATFORM macOS)
    ubiquitty_kit_add_framework(
        CORE_SOURCES ${UBIQUITTY_PORTABLE_CORE_ABS}
        METAL_LIBRARY UbiquittyMetalLib)
    ubiquitty_kit_add_layout_probe(PLATFORM macOS CXX_TARGETS UbiquittyKit)
    add_dependencies(UbiquittyKit ubiquitty-kit-layout-probe)

    # The host tests link Core's aggregate, which this arm does not otherwise
    # build.
    if(UBIQUITTY_BUILD_TESTS)
        ubiquitty_add_core_layer_libraries()
    endif()

# ----------------------------------------------------------------------
# iOS — the Swift modules over the Core library cut for iOS.
#
# A library arm for iphoneos or iphonesimulator: the Core without the
# translation units that start a child process, the Kit's two Swift modules,
# their shader library for the SDK being built, and a link probe that
# force-loads the whole of it. An application's own shell, its bridge and its
# Xcode project are the application's.
# ----------------------------------------------------------------------
elseif(UBIQUITTY_FRONTEND STREQUAL "iOS")

    if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
        message(FATAL_ERROR
            "UBIQUITTY_FRONTEND=iOS needs an iOS toolchain. Configure with "
            "-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos (or "
            "iphonesimulator) -DCMAKE_OSX_ARCHITECTURES=arm64.")
    endif()
    if(CMAKE_GENERATOR MATCHES "Xcode")
        message(FATAL_ERROR
            "The kit's iOS arm builds one SDK per tree with Ninja or Make. The application "
            "that embeds the kit generates the Xcode project.")
    endif()

    # The SDK this arm builds against, which is not the deployment target: the
    # shell above the Kit asks for the layout the newest SDK declares.
    set(UBIQUITTY_IOS_SDK_MIN "27.1")
    if(CMAKE_OSX_SYSROOT MATCHES "[Ss]imulator")
        set(UBIQUITTY_IOS_SDK iphonesimulator)
    else()
        set(UBIQUITTY_IOS_SDK iphoneos)
    endif()
    execute_process(
        COMMAND xcrun --sdk "${UBIQUITTY_IOS_SDK}" --show-sdk-version
        OUTPUT_VARIABLE _ubq_ios_sdk_version
        OUTPUT_STRIP_TRAILING_WHITESPACE
        RESULT_VARIABLE _ubq_ios_sdk_result
        ERROR_QUIET)
    if(NOT _ubq_ios_sdk_result EQUAL 0 OR _ubq_ios_sdk_version STREQUAL "")
        message(FATAL_ERROR
            "Ubiquitty: could not read the version of the ${UBIQUITTY_IOS_SDK} SDK; "
            "the iOS arm needs the iOS ${UBIQUITTY_IOS_SDK_MIN} SDK or newer.")
    elseif(_ubq_ios_sdk_version VERSION_LESS "${UBIQUITTY_IOS_SDK_MIN}")
        message(FATAL_ERROR
            "Ubiquitty: the ${UBIQUITTY_IOS_SDK} SDK is ${_ubq_ios_sdk_version}; the iOS arm "
            "needs ${UBIQUITTY_IOS_SDK_MIN} or newer. Select that Xcode with xcode-select or DEVELOPER_DIR.")
    endif()
    message(STATUS "Ubiquitty iOS: ${UBIQUITTY_IOS_SDK} ${_ubq_ios_sdk_version}, deployment target ${UBIQUITTY_IOS_MIN}")

    # The iOS Core link set: the canonical portable-Core list minus the
    # translation units that start a child process and the ones whose only
    # purpose is to talk to one. A cut made by policy, not by portability: the
    # SDK still declares posix_spawn and fork, so a unit left in would link and
    # ship. check-core-subset-symbols.py refuses a kept unit that references a
    # symbol only a trimmed one defines.
    ubiquitty_add_core_ios_library(ubiquitty-core-ios EXCLUDE
        # Control-mode tmux: a tmux over the carrier is a session type nothing
        # here constructs, and a local `tmux -CC` needs the child process this
        # list rules out.
        Source/Core/Protocol/Tmux/Session.cpp
        Source/Core/Runtime/TmuxControlHost.cpp
        # Runs the receive/send agent (`sz`/`rz`) on the session's terminal.
        Source/Core/Network/FileTransferLaunch.cpp
        # Compiles a terminfo entry by running `tic`.
        Source/Core/Terminfo/UbiquittyTerminfo.cpp
        # The subtree-membership arithmetic behind "which process is in the
        # foreground", whose only caller is the POSIX PTYFacts backend.
        Source/Core/Session/ProcessSubtree.cpp
        INCLUDE_DIRECTORIES ${UBIQUITTY_SOURCE_INCLUDE_DIRECTORIES})

    # QUIC (ngtcp2 + AWS-LC), the client half the apps link, cross-built for the
    # SDK being built.
    if(UBIQUITTY_QUIC)
        ubiquitty_ensure_quic_deps("${UBIQUITTY_IOS_SDK}")
        set(UBIQUITTY_QUIC_PLATFORM_PREFIX "${UBIQUITTY_QUIC_PREFIX}/${UBIQUITTY_IOS_SDK}")
        target_sources(ubiquitty-core-ios PRIVATE ${UBIQUITTY_QUIC_CLIENT_SOURCES})
        target_include_directories(ubiquitty-core-ios PRIVATE "${UBIQUITTY_QUIC_PLATFORM_PREFIX}/include")
        target_compile_definitions(ubiquitty-core-ios PRIVATE UBIQUITTY_QUIC=1)
        ubiquitty_link_quic_archives(ubiquitty-core-ios PUBLIC "${UBIQUITTY_QUIC_PLATFORM_PREFIX}")
        message(STATUS "ubiquitty-core-ios: QUIC transport enabled (ngtcp2 + AWS-LC)")
    endif()

    # The session facade (UbiquittyKit::Session) over the iOS library.
    ubiquitty_add_session_facade(ubiquitty-kit CORE_TARGET ubiquitty-core-ios)
    target_compile_features(ubiquitty-kit PRIVATE cxx_std_23)
    set_target_properties(ubiquitty-kit PROPERTIES
        CXX_STANDARD 23 CXX_STANDARD_REQUIRED ON CXX_EXTENSIONS OFF)
    target_compile_options(ubiquitty-kit PRIVATE
        -fno-exceptions -fno-rtti -Wall -Wextra
        ${UBIQUITTY_NARROWING_WARNING}
        "$<$<BOOL:${UBIQUITTY_WERROR}>:-Werror>")

    # The compiler target is a separate variable from the sysroot, and it has
    # to be set before the language is enabled, because that is when the probe
    # runs: CMake otherwise drives swiftc with -sdk alone and targets the host.
    set(_ubq_ios_triple "arm64-apple-ios${UBIQUITTY_IOS_MIN}")
    if(UBIQUITTY_IOS_SDK STREQUAL "iphonesimulator")
        set(_ubq_ios_triple "${_ubq_ios_triple}-simulator")
    endif()
    set(CMAKE_Swift_COMPILER_TARGET "${_ubq_ios_triple}")
    enable_language(Swift)

    ubiquitty_kit_swift_flags(PLATFORM iOS)
    ubiquitty_kit_add_swift_modules(PLATFORM iOS CXX_TARGETS ubiquitty-core-ios ubiquitty-kit
        LINK_LIBRARIES ubiquitty-core-ios)
    ubiquitty_kit_add_layout_probe(PLATFORM iOS CXX_TARGETS ubiquitty-core-ios ubiquitty-kit)

    # The shaders, compiled for the SDK being built by a script run when the
    # build runs.
    ubiquitty_kit_add_metal_library(ubiquitty-kit-ios-shaders PLATFORM iOS
        OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}"
        PLATFORM_LABEL "${UBIQUITTY_IOS_SDK}"
        STEP ${CMAKE_COMMAND}
            "-DCORE_SOURCE_DIR=${UBIQUITTY_CORE_SOURCE_DIR}"
            "-DKIT_SOURCE_DIR=${UBIQUITTY_KIT_SOURCE_DIR}"
            "-DBINARY_DIR=${CMAKE_CURRENT_BINARY_DIR}"
            "-DIOS_MIN=${UBIQUITTY_IOS_MIN}"
            "-DPLATFORM=${UBIQUITTY_IOS_SDK}")

    # The archive's link check. An archive that builds is not a library that
    # links: ar resolves nothing, so a cut that dropped a definition a kept
    # translation unit still calls packages cleanly and fails in whatever links
    # it next. The probe force-loads each C++ archive, so the whole cut is
    # answered by the linker and not only the reachable objects, and links the
    # Swift modules normally, as an application does.
    add_library(ubiquitty-kit-ios-check SHARED ${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/iOS/KitLinkCheck.cpp)
    target_include_directories(ubiquitty-kit-ios-check PRIVATE ${UBIQUITTY_SOURCE_INCLUDE_DIRECTORIES})
    foreach(_archive ubiquitty-core-ios ubiquitty-kit)
        target_link_options(ubiquitty-kit-ios-check PRIVATE
            "LINKER:-force_load,$<TARGET_FILE:${_archive}>")
    endforeach()
    target_compile_features(ubiquitty-kit-ios-check PRIVATE cxx_std_23)
    set_target_properties(ubiquitty-kit-ios-check PROPERTIES
        CXX_STANDARD 23 CXX_STANDARD_REQUIRED ON CXX_EXTENSIONS OFF)
    target_compile_options(ubiquitty-kit-ios-check PRIVATE
        "$<$<COMPILE_LANGUAGE:CXX>:-fno-exceptions;-fno-rtti;-Wall;-Wextra>"
        ${UBIQUITTY_NARROWING_WARNING}
        "$<$<AND:$<COMPILE_LANGUAGE:CXX>,$<BOOL:${UBIQUITTY_WERROR}>>:-Werror>")
    target_link_libraries(ubiquitty-kit-ios-check PRIVATE UbiquittyKitModule ubiquitty-kit)
    set_property(TARGET ubiquitty-kit-ios-check PROPERTY LINKER_LANGUAGE Swift)
    # This C++-only probe uses the Swift linker for the static Swift modules.
    # Enable interoperability there too, so swiftc supplies its C++ runtime.
    target_link_options(ubiquitty-kit-ios-check PRIVATE -cxx-interoperability-mode=default)
    add_dependencies(ubiquitty-kit-ios-check ubiquitty-kit-ios-shaders)

# ----------------------------------------------------------------------
# Linux — the Vulkan, FreeType and software renderers and the GTK platform
# layer, as static libraries.
#
#   UbiquittyKitFreeType   the FreeType, HarfBuzz and fontconfig glyph
#                          rasterizer, the font inventory and routing, the
#                          bundled-font lookup and the COLRv1 painter
#   UbiquittyKitSoftware   RasterContext, the CPU surface that renders a
#                          Terminal to RGBA8, with the bitmap face and the
#                          size arithmetic it shares with the GPU path
#   UbiquittyKitVulkan     the Vulkan renderer, its atlases and image textures
#   UbiquittyKitGTK        the GDK clipboard, pointer lock, the AT-SPI element
#                          and the Pango rich-text shaper
#   UbiquittyKitGTKPAL     the GTK PAL backend. PAL functions are defined once
#                          per executable, so it is its own opt-in target and
#                          never part of the widget library.
#
# A consumer links the libraries it draws with, Core's `ubiquitty-core` beside
# them, and a PAL backend. ubiquitty-kit-linux-check proves the set links.
# ----------------------------------------------------------------------
elseif(UBIQUITTY_FRONTEND STREQUAL "Linux")

    find_package(PkgConfig REQUIRED)
    pkg_check_modules(GTK4 REQUIRED IMPORTED_TARGET gtk4>=4.16)
    pkg_check_modules(PANGOCAIRO REQUIRED IMPORTED_TARGET pangocairo)
    pkg_check_modules(FREETYPE REQUIRED IMPORTED_TARGET freetype2)
    pkg_check_modules(FONTCONFIG REQUIRED IMPORTED_TARGET fontconfig)
    pkg_check_modules(HARFBUZZ REQUIRED IMPORTED_TARGET harfbuzz)
    find_package(Vulkan REQUIRED)

    # Relative pointer lock (DECSET 7403): the OS-level grab behind
    # PointerLock.cpp, split across two mechanisms neither of which is
    # REQUIRED — a build missing one library's dev headers still gets a working
    # lock through the other, guarded by the UBIQUITTY_LINUX_HAS_* definitions.
    # X11's XWarpPointer/XFixesHideCursor need x11 and xfixes. Wayland's true
    # relative deltas need wayland-client and wayland-protocols together with
    # wayland-scanner; partial Wayland support is not support.
    pkg_check_modules(UBIQUITTY_X11 IMPORTED_TARGET x11 xfixes)
    pkg_check_modules(UBIQUITTY_WAYLAND_CLIENT IMPORTED_TARGET wayland-client)
    pkg_check_modules(UBIQUITTY_WAYLAND_PROTOCOLS wayland-protocols)
    find_program(UBIQUITTY_WAYLAND_SCANNER wayland-scanner)
    set(UBIQUITTY_LINUX_POINTER_LOCK_DEFS "")
    if(UBIQUITTY_X11_FOUND)
        list(APPEND UBIQUITTY_LINUX_POINTER_LOCK_DEFS UBIQUITTY_LINUX_HAS_X11=1)
    else()
        message(STATUS "Linux pointer lock: x11/xfixes dev headers not found — the X11 backend is compiled out")
    endif()
    set(UBIQUITTY_LINUX_HAS_WAYLAND_DEPS FALSE)
    if(UBIQUITTY_WAYLAND_CLIENT_FOUND AND UBIQUITTY_WAYLAND_PROTOCOLS_FOUND AND UBIQUITTY_WAYLAND_SCANNER)
        set(UBIQUITTY_LINUX_HAS_WAYLAND_DEPS TRUE)
        list(APPEND UBIQUITTY_LINUX_POINTER_LOCK_DEFS UBIQUITTY_LINUX_HAS_WAYLAND=1)
    else()
        message(STATUS "Linux pointer lock: wayland-client/wayland-protocols/wayland-scanner not all found — the Wayland backend is compiled out")
    endif()

    # What every library of this arm compiles with: Core's language policy, the
    # header roots, and the warnings that fail the build.
    function(ubiquitty_kit_linux_library target)
        target_include_directories(${target} PUBLIC ${UBIQUITTY_SOURCE_INCLUDE_DIRECTORIES})
        target_compile_features(${target} PUBLIC cxx_std_23)
        set_target_properties(${target} PROPERTIES
            CXX_STANDARD 23 CXX_STANDARD_REQUIRED ON CXX_EXTENSIONS OFF)
        target_compile_options(${target} PRIVATE
            -fno-exceptions -fno-rtti -Wall -Wextra
            ${UBIQUITTY_NARROWING_WARNING}
            "$<$<BOOL:${UBIQUITTY_WERROR}>:-Werror>")
    endfunction()

    set(UBIQUITTY_KIT_LINUX ${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/Linux)

    add_library(UbiquittyKitFreeType STATIC
        ${UBIQUITTY_KIT_LINUX}/FreeTypeRasterizer.cpp
        ${UBIQUITTY_KIT_LINUX}/FontInventory.cpp
        ${UBIQUITTY_KIT_LINUX}/FontRouting.cpp
        ${UBIQUITTY_KIT_LINUX}/BundledFontDirectory.cpp
        ${UBIQUITTY_KIT_LINUX}/ColorGlyphPainter.cpp)
    ubiquitty_kit_linux_library(UbiquittyKitFreeType)
    target_link_libraries(UbiquittyKitFreeType PUBLIC
        PkgConfig::FREETYPE PkgConfig::FONTCONFIG PkgConfig::HARFBUZZ)

    add_library(UbiquittyKitSoftware STATIC ${UBIQUITTY_KIT_LINUX}/Raster.cpp)
    ubiquitty_kit_linux_library(UbiquittyKitSoftware)
    target_link_libraries(UbiquittyKitSoftware PUBLIC UbiquittyKitFreeType)

    add_library(UbiquittyKitVulkan STATIC
        ${UBIQUITTY_KIT_LINUX}/VulkanRenderer.cpp
        ${UBIQUITTY_KIT_LINUX}/VulkanColorGlyphAtlas.cpp
        ${UBIQUITTY_KIT_LINUX}/VulkanGlyphAtlas.cpp
        ${UBIQUITTY_KIT_LINUX}/VulkanImageTextures.cpp
        ${UBIQUITTY_KIT_LINUX}/VulkanCoverageSheet.cpp)
    ubiquitty_kit_linux_library(UbiquittyKitVulkan)
    target_link_libraries(UbiquittyKitVulkan PUBLIC UbiquittyKitFreeType Vulkan::Vulkan)

    add_library(UbiquittyKitGTK STATIC
        ${UBIQUITTY_KIT_LINUX}/Accessibility.cpp
        ${UBIQUITTY_KIT_LINUX}/AccessibleTerminal.cpp
        ${UBIQUITTY_KIT_LINUX}/Clipboard.cpp
        ${UBIQUITTY_KIT_LINUX}/PangoRichText.cpp
        ${UBIQUITTY_KIT_LINUX}/PointerLock.cpp)
    ubiquitty_kit_linux_library(UbiquittyKitGTK)
    target_compile_definitions(UbiquittyKitGTK PRIVATE ${UBIQUITTY_LINUX_POINTER_LOCK_DEFS})
    target_link_libraries(UbiquittyKitGTK PUBLIC PkgConfig::GTK4 PkgConfig::PANGOCAIRO)
    if(UBIQUITTY_X11_FOUND)
        # gdk_x11_display_get_xdisplay / gdk_x11_surface_get_xid are GDK4's only
        # route to the raw Xlib handles XWarpPointer/XFixesHideCursor need, and
        # this GTK build marks them deprecated with no in-GTK4 replacement — so
        # only this warning, and only in the one file that calls them, is
        # downgraded from -Werror.
        set_source_files_properties(${UBIQUITTY_KIT_LINUX}/PointerLock.cpp PROPERTIES
            COMPILE_FLAGS "-Wno-error=deprecated-declarations")
        target_link_libraries(UbiquittyKitGTK PUBLIC PkgConfig::UBIQUITTY_X11)
    endif()
    if(UBIQUITTY_LINUX_HAS_WAYLAND_DEPS)
        # wayland-scanner generates the client-side marshaling code for
        # zwp_pointer_constraints_v1 and zwp_relative_pointer_v1 from the XML
        # wayland-protocols ships; there is no distributed header for either.
        pkg_get_variable(UBIQUITTY_WAYLAND_PROTOCOLS_DIR wayland-protocols pkgdatadir)
        set(UBIQUITTY_WAYLAND_GEN_DIR ${CMAKE_CURRENT_BINARY_DIR}/linux-wayland-protocols)
        file(MAKE_DIRECTORY ${UBIQUITTY_WAYLAND_GEN_DIR})
        set(UBIQUITTY_WAYLAND_PROTOCOL_SOURCES "")
        foreach(_protocol IN ITEMS
                "unstable/pointer-constraints/pointer-constraints-unstable-v1"
                "unstable/relative-pointer/relative-pointer-unstable-v1")
            get_filename_component(_protocol_name "${_protocol}" NAME)
            set(_protocol_xml "${UBIQUITTY_WAYLAND_PROTOCOLS_DIR}/${_protocol}.xml")
            set(_protocol_header "${UBIQUITTY_WAYLAND_GEN_DIR}/${_protocol_name}-client-protocol.h")
            set(_protocol_source "${UBIQUITTY_WAYLAND_GEN_DIR}/${_protocol_name}-protocol.c")
            add_custom_command(OUTPUT ${_protocol_header}
                COMMAND ${UBIQUITTY_WAYLAND_SCANNER} client-header ${_protocol_xml} ${_protocol_header}
                DEPENDS ${_protocol_xml}
                COMMENT "wayland-scanner client-header ${_protocol_name}" VERBATIM)
            add_custom_command(OUTPUT ${_protocol_source}
                COMMAND ${UBIQUITTY_WAYLAND_SCANNER} private-code ${_protocol_xml} ${_protocol_source}
                DEPENDS ${_protocol_xml} ${_protocol_header}
                COMMENT "wayland-scanner private-code ${_protocol_name}" VERBATIM)
            # Generated C, not this target's own: silenced the way yyjson.c is, so
            # a compiler bump's new warning in wayland-scanner's output does not
            # fail a build this tree does not control the source of.
            set_source_files_properties(${_protocol_source} PROPERTIES COMPILE_FLAGS "-Wno-error -w")
            list(APPEND UBIQUITTY_WAYLAND_PROTOCOL_SOURCES ${_protocol_header} ${_protocol_source})
        endforeach()
        target_sources(UbiquittyKitGTK PRIVATE ${UBIQUITTY_WAYLAND_PROTOCOL_SOURCES})
        target_include_directories(UbiquittyKitGTK PRIVATE ${UBIQUITTY_WAYLAND_GEN_DIR})
        target_link_libraries(UbiquittyKitGTK PUBLIC PkgConfig::UBIQUITTY_WAYLAND_CLIENT)
    endif()

    add_library(UbiquittyKitGTKPAL STATIC ${UBIQUITTY_KIT_LINUX}/PAL.cpp)
    ubiquitty_kit_linux_library(UbiquittyKitGTKPAL)
    target_link_libraries(UbiquittyKitGTKPAL PUBLIC UbiquittyKitGTK)

    # The Vulkan renderer's cell shaders, compiled to SPIR-V next to the
    # libraries. A renderer without them cannot load a shader on its first GPU
    # frame, so a configure that cannot find glslc stops here unless it was
    # asked for a CPU-only build.
    option(UBIQUITTY_LINUX_GPU_SHADERS "Compile the Vulkan renderer's SPIR-V shaders (needs glslc)" ON)
    if(UBIQUITTY_LINUX_GPU_SHADERS)
        find_program(UBIQUITTY_GLSLC glslc)
        if(NOT UBIQUITTY_GLSLC)
            message(FATAL_ERROR
                "glslc not found, so the Vulkan renderer's shaders cannot be compiled. "
                "Install it (Debian, Ubuntu and Fedora: glslc; Arch: shaderc), or configure with "
                "-DUBIQUITTY_LINUX_GPU_SHADERS=OFF for a build that renders on the CPU only.")
        endif()
        set(_ubiquitty_spv "")
        foreach(shader IN ITEMS cell.vert cell.frag glyph.vert glyph.frag color.vert color.frag decoration.vert decoration.frag overlay.vert overlay.frag image.vert image.frag backdrop.vert backdrop.frag boxfill.vert boxfill.frag)
            add_custom_command(
                OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/${shader}.spv
                COMMAND ${UBIQUITTY_GLSLC}
                        ${UBIQUITTY_KIT_LINUX}/shaders/${shader}
                        -o ${CMAKE_CURRENT_BINARY_DIR}/${shader}.spv
                DEPENDS ${UBIQUITTY_KIT_LINUX}/shaders/${shader}
                COMMENT "glslc ${shader} -> SPIR-V" VERBATIM)
            list(APPEND _ubiquitty_spv ${CMAKE_CURRENT_BINARY_DIR}/${shader}.spv)
        endforeach()
        add_custom_target(UbiquittyKitVulkanShaders ALL DEPENDS ${_ubiquitty_spv})
        add_dependencies(UbiquittyKitVulkan UbiquittyKitVulkanShaders)
    else()
        message(STATUS "Linux GPU shaders: OFF (UBIQUITTY_LINUX_GPU_SHADERS), so the Vulkan renderer's shaders are not compiled")
    endif()

    # The link check, over Core and every library above. An archive that builds
    # is not a library that links: each archive is loaded whole, so an undefined
    # symbol one expects its consumer to supply is named by the linker here.
    # Core's layer libraries are what a consumer links beside them.
    ubiquitty_add_core_layer_libraries()
    add_executable(ubiquitty-kit-linux-check ${UBIQUITTY_KIT_LINUX}/Check/main.cpp)
    foreach(_archive UbiquittyKitSoftware UbiquittyKitVulkan UbiquittyKitGTK UbiquittyKitGTKPAL)
        target_link_options(ubiquitty-kit-linux-check PRIVATE
            "LINKER:--whole-archive,$<TARGET_FILE:${_archive}>,--no-whole-archive")
    endforeach()
    target_link_libraries(ubiquitty-kit-linux-check PRIVATE
        UbiquittyKitSoftware UbiquittyKitVulkan UbiquittyKitGTK UbiquittyKitGTKPAL ubiquitty-core)
    target_compile_features(ubiquitty-kit-linux-check PRIVATE cxx_std_23)
    set_target_properties(ubiquitty-kit-linux-check PROPERTIES
        CXX_STANDARD 23 CXX_STANDARD_REQUIRED ON CXX_EXTENSIONS OFF)
    target_compile_options(ubiquitty-kit-linux-check PRIVATE
        -fno-exceptions -fno-rtti -Wall -Wextra
        ${UBIQUITTY_NARROWING_WARNING}
        "$<$<BOOL:${UBIQUITTY_WERROR}>:-Werror>")
    # forkpty lives in libutil on Linux/glibc.
    target_link_libraries(ubiquitty-kit-linux-check PRIVATE util)

else()

    message(FATAL_ERROR
        "UBIQUITTY_FRONTEND='${UBIQUITTY_FRONTEND}' is not recognised. Valid values: macOS, iOS, Linux.")

endif()

# ----------------------------------------------------------------------
# The kit's host tests. Tests/CMakeLists.txt finds them on disk; nothing here or
# there keeps a list of them.
# ----------------------------------------------------------------------
if(UBIQUITTY_BUILD_TESTS)
    enable_testing()
    add_subdirectory("${UBIQUITTY_KIT_SOURCE_DIR}/Tests" "${CMAKE_CURRENT_BINARY_DIR}/Tests")
endif()

# Last, once every target of every arm exists.
ubiquitty_order_after_build_version("${CMAKE_CURRENT_SOURCE_DIR}")
