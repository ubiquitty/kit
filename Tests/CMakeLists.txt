# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

#
# Tests/CMakeLists.txt — finds the kit's host tests, builds them, and registers
# them with CTest.
#
# A test is added by adding its file. Any `test_*.cpp` under Tests/<Subsystem>/
# is found by the glob further down, compiled into an executable of its own and
# run by `ctest`; no list names it, because a source list kept by hand falls
# out of step with the files on disk and nothing reports the drift.
#
# ubiquitty-core's Scripts/cmake/UbiquittyTests.cmake compiles and registers
# them, each linked against Core's `ubiquitty-core` aggregate. This file says
# what each test needs: its extra sources, definitions and libraries, and which
# tests this host leaves out. The Linux tests run on a Linux host and the macOS
# ones on a Mac; a test named for a platform is left out elsewhere.
#

include(${UBIQUITTY_CORE_SOURCE_DIR}/Scripts/cmake/UbiquittyTests.cmake)

# The typed pasteboard's C++ half, over the Swift module beneath it.
set(test_typed_pasteboard_EXTRA_SOURCES ${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/macOS/TypedPasteboard.cpp)
if(APPLE AND NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
    include(${UBIQUITTY_KIT_SOURCE_DIR}/Scripts/cmake/TypedPasteboard.cmake)
endif()
set(test_typed_pasteboard_EXTRA_LIBS UbiquittyPasteboard)
# The three macOS PAL backends that need no window: the diagnostics sink, the
# bell and the clipboard's C++ half. None is Objective-C, so the target needs no
# .mm compiler. The test-hook define below reaches the bell, which counts each
# alert and silences its playback — the suite runs on a desk with speakers —
# and it keeps this target off the shared precompiled header, which is built
# without it.
set(test_macos_pal_EXTRA_SOURCES ${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/macOS/Diag.cpp
                                 ${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/macOS/Bell.cpp
                                 ${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/macOS/Clipboard.cpp)
set(test_macos_pal_EXTRA_DEFINES UBIQUITTY_ENABLE_TEST_HOOKS=1)
set(test_macos_pal_EXTRA_LIBS "-framework AudioToolbox")
set(test_linux_accessibility_EXTRA_SOURCES ${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/Linux/Accessibility.cpp)
set(test_linux_raster_context_EXTRA_SOURCES ${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/Linux/Raster.cpp)

# The tests that link GLib, GTK, Pango, FreeType or fontconfig are the Linux
# libraries' own, so they run on a Linux host: a Mac that has these through
# Homebrew links dylibs built for a newer macOS than this tree's floor, which
# the linker reports as a warning on every such test. Found rather than
# hardcoded — a library's path would rot at the next upgrade — and an absent
# library leaves the test out with a reason instead of failing on a header error
# that names a path nobody set.
find_package(PkgConfig QUIET)
if(PkgConfig_FOUND AND CMAKE_SYSTEM_NAME STREQUAL "Linux")
    pkg_check_modules(UBQ_FONTCONFIG QUIET fontconfig freetype2 harfbuzz)
    pkg_check_modules(UBQ_GIO QUIET IMPORTED_TARGET gio-2.0)
    pkg_check_modules(UBQ_PANGOCAIRO QUIET IMPORTED_TARGET pangocairo)
    pkg_check_modules(UBQ_GTK_ACCESSIBILITY QUIET IMPORTED_TARGET gtk4>=4.16)
endif()
if(UBQ_PANGOCAIRO_FOUND)
    set(test_linux_rich_text_EXTRA_SOURCES ${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/Linux/PangoRichText.cpp)
    set(test_linux_rich_text_EXTRA_LIBS PkgConfig::UBQ_PANGOCAIRO)
endif()
find_program(UBQ_XVFB_RUN xvfb-run)
if(UBQ_GTK_ACCESSIBILITY_FOUND AND UBQ_XVFB_RUN)
    set(test_linux_accessible_terminal_EXTRA_SOURCES ${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/Linux/AccessibleTerminal.cpp
                                                    ${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/Linux/Accessibility.cpp)
    set(test_linux_accessible_terminal_EXTRA_LIBS PkgConfig::UBQ_GTK_ACCESSIBILITY)
    set(test_linux_accessible_terminal_LAUNCHER ${CMAKE_COMMAND} -E env GDK_BACKEND=x11 ${UBQ_XVFB_RUN} -a)
endif()
if(UBQ_GIO_FOUND)
    set(test_linux_pty_watch_EXTRA_LIBS PkgConfig::UBQ_GIO)
endif()
if(UBQ_FONTCONFIG_FOUND)
    set(test_linux_fontinventory_EXTRA_SOURCES    ${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/Linux/FontInventory.cpp
                                                  ${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/Linux/ColorGlyphPainter.cpp
                                                  ${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/Linux/BundledFontDirectory.cpp)
    set(test_linux_fontinventory_EXTRA_INCLUDES   ${UBQ_FONTCONFIG_INCLUDE_DIRS})
    set(test_linux_fontinventory_EXTRA_LIBS       ${UBQ_FONTCONFIG_LINK_LIBRARIES})
    # The bundled fonts by absolute path: the inventory derives its directory
    # from the executable, and a test binary has no staged fonts beside it.
    set(test_linux_fontinventory_EXTRA_DEFINES
        UBQ_BUNDLED_FONTS_DIR="${UBIQUITTY_CORE_SOURCE_DIR}/Resources/fonts")
    # Font routing belongs to the Kit and uses the inventory's shipped-face
    # fixture, so both renderer routes are checked without an application.
    set(test_linux_route_parity_EXTRA_SOURCES ${test_linux_fontinventory_EXTRA_SOURCES}
                                            ${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/Linux/FontRouting.cpp)
    set(test_linux_route_parity_EXTRA_INCLUDES ${test_linux_fontinventory_EXTRA_INCLUDES})
    set(test_linux_route_parity_EXTRA_LIBS ${test_linux_fontinventory_EXTRA_LIBS})
    set(test_linux_route_parity_EXTRA_DEFINES ${test_linux_fontinventory_EXTRA_DEFINES})
    # The colour-emoji rasterizer needs the same two libraries: FreeType to read
    # a CBDT/sbix strike and fontconfig to find the font at all.
    set(test_linux_color_emoji_EXTRA_SOURCES  ${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/Linux/FreeTypeRasterizer.cpp
                                              ${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/Linux/FontInventory.cpp
                                              ${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/Linux/BundledFontDirectory.cpp
                                              ${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/Linux/ColorGlyphPainter.cpp
                                              Source/Core/Rendering/UnifontRasterizer.cpp
                                              Source/Core/Rendering/UnifontFaceMetrics.cpp
                                              Source/Core/Rendering/Unifont.cpp)
    set(test_linux_color_emoji_EXTRA_INCLUDES ${UBQ_FONTCONFIG_INCLUDE_DIRS})
    set(test_linux_color_emoji_EXTRA_LIBS     ${UBQ_FONTCONFIG_LINK_LIBRARIES})
    # The bundled fonts by absolute path, for the source-root reason above: a
    # rasteriser handed a relative fallback path derives the bundled emoji
    # face's path beside it, and a relative path resolves against nothing at
    # run time, so the host's own colour face was kept in the bundled one's place.
    set(test_linux_color_emoji_EXTRA_DEFINES
        UBQ_BUNDLED_FONTS_DIR="${UBIQUITTY_CORE_SOURCE_DIR}/Resources/fonts")
    # Which file the fallback face opens: the same rasteriser, the same two
    # libraries, and the bundled directory by absolute path for the reason above
    # — the table lookup is derived beside the fallback path it is handed.
    set(test_linux_fallback_face_EXTRA_SOURCES  ${test_linux_color_emoji_EXTRA_SOURCES})
    set(test_linux_fallback_face_EXTRA_INCLUDES ${UBQ_FONTCONFIG_INCLUDE_DIRS})
    set(test_linux_fallback_face_EXTRA_LIBS     ${UBQ_FONTCONFIG_LINK_LIBRARIES})
    set(test_linux_fallback_face_EXTRA_DEFINES
        UBQ_BUNDLED_FONTS_DIR="${UBIQUITTY_CORE_SOURCE_DIR}/Resources/fonts")
    # A doubled row drawn by the software renderer over the same rasteriser,
    # from the bundled faces by absolute path for the reason above.
    set(test_linux_sized_master_EXTRA_SOURCES  ${test_linux_fallback_face_EXTRA_SOURCES})
    set(test_linux_sized_master_EXTRA_INCLUDES ${UBQ_FONTCONFIG_INCLUDE_DIRS})
    set(test_linux_sized_master_EXTRA_LIBS     ${UBQ_FONTCONFIG_LINK_LIBRARIES})
    set(test_linux_sized_master_EXTRA_DEFINES
        UBQ_BUNDLED_FONTS_DIR="${UBIQUITTY_CORE_SOURCE_DIR}/Resources/fonts")
    # A proportional run past its size held to FreeType's raster at that size,
    # over the same rasteriser and the bundled faces by absolute path.
    set(test_linux_proportional_at_size_EXTRA_SOURCES  ${test_linux_fallback_face_EXTRA_SOURCES})
    set(test_linux_proportional_at_size_EXTRA_INCLUDES ${UBQ_FONTCONFIG_INCLUDE_DIRS})
    set(test_linux_proportional_at_size_EXTRA_LIBS     ${UBQ_FONTCONFIG_LINK_LIBRARIES})
    set(test_linux_proportional_at_size_EXTRA_DEFINES
        UBQ_BUNDLED_FONTS_DIR="${UBIQUITTY_CORE_SOURCE_DIR}/Resources/fonts")
    # The COLRv1 painter walks a paint graph FreeType exposes and finds its
    # face through fontconfig, so it needs the same pair.
    set(test_linux_color_glyph_painter_EXTRA_SOURCES  ${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/Linux/ColorGlyphPainter.cpp)
    set(test_linux_color_glyph_painter_EXTRA_INCLUDES ${UBQ_FONTCONFIG_INCLUDE_DIRS})
    set(test_linux_color_glyph_painter_EXTRA_LIBS     ${UBQ_FONTCONFIG_LINK_LIBRARIES})
else()
    list(APPEND UBIQUITTY_UNAVAILABLE_TESTS test_linux_fontinventory test_linux_color_emoji test_linux_color_glyph_painter test_linux_fallback_face test_linux_sized_master test_linux_proportional_at_size test_linux_route_parity)
    list(APPEND UBIQUITTY_DEFERRED_TESTS ${UBIQUITTY_UNAVAILABLE_TESTS})
    foreach(_ubq_unavailable_test IN LISTS UBIQUITTY_UNAVAILABLE_TESTS)
        message(STATUS "Ubiquitty tests: ${_ubq_unavailable_test} unavailable (a Linux host with fontconfig, freetype2, and harfbuzz is required)")
    endforeach()
endif()

# Both this directory and every directory under it. `*/test_*.cpp` requires a
# subdirectory, so a test written beside this file would be picked up by no one.
file(GLOB_RECURSE _ubq_kit_tests RELATIVE ${UBIQUITTY_KIT_SOURCE_DIR}/Tests
    CONFIGURE_DEPENDS
    "${UBIQUITTY_KIT_SOURCE_DIR}/Tests/test_*.cpp"
    "${UBIQUITTY_KIT_SOURCE_DIR}/Tests/*/test_*.cpp")
# Leaves every test whose path under Tests/ matches <pattern> out of the list.
function(ubq_leave_out_tests pattern)
    list(FILTER _ubq_kit_tests EXCLUDE REGEX "${pattern}")
    set(_ubq_kit_tests ${_ubq_kit_tests} PARENT_SCOPE)
endfunction()
# The iOS protected-file suite links Swift (the creator and its protection
# probe) and runs inside a simulator; Scripts/run-ios-protected-file-tests.sh
# builds it, and no host can.
ubq_leave_out_tests("(^|/)test_ios_protected_file\\.cpp$")
if(NOT UBQ_PANGOCAIRO_FOUND)
    ubq_leave_out_tests("(^|/)test_linux_rich_text\\.cpp$")
    message(STATUS "Linux rich text test requires PangoCairo on Linux")
endif()
if(NOT UBQ_GIO_FOUND)
    ubq_leave_out_tests("(^|/)test_linux_pty_watch\\.cpp$")
endif()
if(NOT UBQ_GTK_ACCESSIBILITY_FOUND OR NOT UBQ_XVFB_RUN)
    ubq_leave_out_tests("(^|/)test_linux_accessible_terminal\\.cpp$")
    message(STATUS "Linux accessible widget test requires GTK 4.16 and xvfb-run on Linux")
endif()

# GIO enables POSIX thread support; its consumers cannot reuse a PCH built
# without the dependency's compiler options.
set(UBIQUITTY_NO_PCH_TESTS test_linux_pty_watch test_linux_accessible_terminal test_linux_rich_text)

# What every test and the precompiled header read: Source/ of the core and kit
# checkouts in that order, and the core's Tests/.
set(_ubq_test_include_directories
    ${UBIQUITTY_CORE_SOURCE_DIR}/Source
    ${UBIQUITTY_KIT_SOURCE_DIR}/Source)
list(REMOVE_DUPLICATES _ubq_test_include_directories)
list(APPEND _ubq_test_include_directories ${UBIQUITTY_CORE_SOURCE_DIR}/Tests)

ubiquitty_add_host_tests(
    ROOT ${UBIQUITTY_KIT_SOURCE_DIR} SOURCES ${_ubq_kit_tests}
    INCLUDE_DIRECTORIES ${_ubq_test_include_directories}
    NO_PCH ${UBIQUITTY_NO_PCH_TESTS}
    DEFERRED ${UBIQUITTY_DEFERRED_TESTS}
    UNAVAILABLE ${UBIQUITTY_UNAVAILABLE_TESTS})

# The test links the Swift module beneath the typed pasteboard, so CMake drives
# its link through swiftc, and in Debug adds -incremental, which the driver
# warns it ignores for a link with no output file map. Naming the whole-module
# mode the Kit's modules compile in answers it with a remark instead.
if(TARGET test_typed_pasteboard)
    target_link_options(test_typed_pasteboard PRIVATE "$<$<LINK_LANGUAGE:Swift>:SHELL:-wmo>")
    # This C++-only test uses the Swift linker for its pasteboard module.
    target_link_options(test_typed_pasteboard PRIVATE "$<$<LINK_LANGUAGE:Swift>:-cxx-interoperability-mode=default>")
endif()

if(CMAKE_SYSTEM_NAME STREQUAL "Linux" AND TARGET test_linux_rich_text)
    # The native family-selection test must have real fonts even in a minimal
    # image. Add the shipped files as application startup does; keep the native
    # system inventory so enumeration still exercises its actual family map.
    set(UBQ_RICH_TEXT_FONT_DIRECTORY "${UBIQUITTY_CORE_SOURCE_DIR}/Resources/fonts")
    string(REPLACE "&" "&amp;" UBQ_RICH_TEXT_FONT_DIRECTORY "${UBQ_RICH_TEXT_FONT_DIRECTORY}")
    string(REPLACE "<" "&lt;" UBQ_RICH_TEXT_FONT_DIRECTORY "${UBQ_RICH_TEXT_FONT_DIRECTORY}")
    file(CONFIGURE OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/rich-text-fonts.conf" CONTENT [=[
<?xml version="1.0"?>
<!-- Copyright (C) 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
    <include ignore_missing="yes">/etc/fonts/fonts.conf</include>
    <dir>@UBQ_RICH_TEXT_FONT_DIRECTORY@</dir>
</fontconfig>
]=] @ONLY)
    set_property(TEST test_linux_rich_text APPEND PROPERTY
        ENVIRONMENT "FONTCONFIG_FILE=${CMAKE_CURRENT_BINARY_DIR}/rich-text-fonts.conf")
endif()

if(APPLE AND NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
    # Actual CryptoKit AEAD with task-owned in-memory keys: no user's keychain
    # or app process participates. Production keychain availability is a
    # separate platform acceptance check, not inferred from this test.
    enable_language(Swift)
    # Every Swift target here compiles whole-module, as the kit does. CMake
    # drives Debug with swiftc -incremental whatever Swift_COMPILATION_MODE
    # says, and the incremental driver fails a relink whose inputs it all skips
    # with cannotResolveTempPath(<target>-1.swiftmodule): a version bump alone
    # breaks the test build. Whole-module keeps no incremental state to go
    # stale.
    add_compile_options("$<$<COMPILE_LANGUAGE:Swift>:-wmo>")
    # These executables compile kit sources directly, and a kit declaration
    # with package access needs the package name the kit builds under.
    add_compile_options("$<$<COMPILE_LANGUAGE:Swift>:SHELL:-package-name ubiquitty>")
    add_executable(test_rich_text_native_geometry
        ${UBIQUITTY_KIT_SOURCE_DIR}/Source/UbiquittyRenderKit/RichTextGeometry.swift
        ${UBIQUITTY_KIT_SOURCE_DIR}/Tests/Platform/test_rich_text_native_geometry.swift)
    set_target_properties(test_rich_text_native_geometry PROPERTIES Swift_LANGUAGE_VERSION 6)
    add_test(NAME test_rich_text_native_geometry COMMAND test_rich_text_native_geometry)
    add_executable(test_rich_text_font_catalog
        ${UBIQUITTY_KIT_SOURCE_DIR}/Source/UbiquittyRenderKit/RichTextFontCatalog.swift
        ${UBIQUITTY_KIT_SOURCE_DIR}/Tests/Platform/test_rich_text_font_catalog.swift)
    set_target_properties(test_rich_text_font_catalog PROPERTIES Swift_LANGUAGE_VERSION 6)
    add_test(NAME test_rich_text_font_catalog COMMAND test_rich_text_font_catalog)

    add_executable(test_resume_sealer
        ${UBIQUITTY_KIT_SOURCE_DIR}/Source/UbiquittyKit/Swift/SealedStore.swift
        ${UBIQUITTY_KIT_SOURCE_DIR}/Tests/Platform/test_resume_sealer.swift)
    set_target_properties(test_resume_sealer PROPERTIES Swift_LANGUAGE_VERSION 6)
    add_test(NAME test_resume_sealer COMMAND test_resume_sealer)

    # Keep the production source first: the native Kit uses whole-module
    # compilation, where an earlier Foundation String overload lookup can hide
    # the C++ string initializer even from a later explicit CxxStdlib import.
    add_executable(test_resume_sealer_cxx
        ${UBIQUITTY_KIT_SOURCE_DIR}/Source/UbiquittyKit/Swift/SealedStore.swift
        ${UBIQUITTY_KIT_SOURCE_DIR}/Tests/Platform/test_resume_sealer_cxx.swift)
    set_target_properties(test_resume_sealer_cxx PROPERTIES
        Swift_LANGUAGE_VERSION 6
        Swift_COMPILATION_MODE wholemodule)
    target_compile_options(test_resume_sealer_cxx PRIVATE
        -cxx-interoperability-mode=default)
    add_test(NAME test_resume_sealer_cxx COMMAND test_resume_sealer_cxx)
    ubiquitty_set_test_entry_properties(
        test_rich_text_native_geometry
        test_rich_text_font_catalog
        test_resume_sealer
        test_resume_sealer_cxx)
endif()

# The kit's shell stanzas, one ctest entry each, so the tests a push reaches
# include the stanzas whose subject it changed. The driver runs a named stanza
# without CTest, and ctest-covered.txt names the entries ctest has run so a full
# driver run does not repeat them.
ubiquitty_schedule_shell_stanzas(DRIVER ${UBIQUITTY_KIT_SOURCE_DIR}/Scripts/run-tests.sh)
ubiquitty_finish_host_tests(DRIVER ${UBIQUITTY_KIT_SOURCE_DIR}/Scripts/run-tests.sh)
