# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# The stamp's writer, beside this file: the function below runs in its caller's
# scope, where CMAKE_CURRENT_LIST_DIR names the caller's list.
set(_ubiquitty_interop_stamp_writer "${CMAKE_CURRENT_LIST_DIR}/WriteInteropStamp.cmake")

# What the Swift modules INLINE, so Ninja knows to rebuild them when it moves.
#
# The Swift sources reach Core through C++ interop and inline header-only code
# — TerminalSession.h's attach and apply paths, the render helpers, the
# preference folds. CMake lists only the .swift files as a Swift target's
# sources and does not scan an interop include, so without this there is no
# edge from Source/Core/**.h to any Swift module: editing a Core header
# rebuilds the C++ TUs, relinks, and leaves the Swift libraries holding the
# code from before the edit.
#
# The app then RUNS the old Core on the Swift arm. Measured on macOS, one edit:
# without this, 9 targets rebuild and a probe shows the removed line still
# executing; touch any .swift in the module and 62 rebuild and it stops. Which
# behaviour you get is decided by whether an unrelated Swift file happens to be
# newer than the library, and nothing says which you got.
#
# Worse than a stale binary, because it silently inverts the tool used to prove
# a test can fail: an ablation that never reaches the arm reports "cannot fail"
# for a healthy test. That cost a correct scenario a wrong verdict before this
# was found.
#
# ONE definition for every arm, and that is the point rather than tidiness. The
# fix shipped for macOS alone and the iOS modules kept the defect for as long as
# the two arms each owned a copy — the reasoning above lived in one file and the
# other frontend did not have it. A second copy is how they diverge again.
#
# How the dependency is carried, and why it is not OBJECT_DEPENDS.
#
# OBJECT_DEPENDS is a C/C++/ObjC source property; CMake's Swift support ignores
# it. Setting it on these modules' .swift sources was tried and MEASURED: after
# it, touching Source/Core/Runtime/TerminalSession.h still rebuilt 10 targets
# with neither Swift library among them. It reads like a fix and is not one.
#
# What a Swift target does honour is its own sources, so the header set is
# carried as one: a generated .swift whose only content is a hash of every
# header below. A header change moves the hash, the file changes, and the module
# recompiles — wholemodule, so all of it, which is the point. The hash rather
# than a timestamp so an untouched tree regenerates nothing and a configure does
# not churn the build.
#
# - Parameters:
#   - outputVariable: set to the generated .swift's path; the caller adds it to
#     every Swift target that inlines Core through interop.
#   - ARGN: the caller's own module maps. Core's and the kit's are named here.
function(ubiquitty_swift_interop_stamp outputVariable)
    # The WHOLE tree rather than the module map's own list: the map names 89
    # headers and Core has 343, and the rest arrive transitively —
    # TerminalSession.h includes Terminal.h, which includes the preference
    # folds. A partial list would restore exactly the silence this removes for
    # whatever it omitted. It costs nothing to be blunt here: these modules
    # compile wholemodule, so a partial rebuild was never on offer.
    #
    # CONFIGURE_DEPENDS so a header added tomorrow joins the set without anyone
    # remembering to add it.
    file(GLOB_RECURSE interopHeaders CONFIGURE_DEPENDS
        "${UBIQUITTY_CORE_SOURCE_DIR}/Source/Core/*.h"
        "${UBIQUITTY_CORE_SOURCE_DIR}/Source/PAL/*.h"
        "${UBIQUITTY_CORE_SOURCE_DIR}/Source/Base/*.h")

    # Every module map and every header one names. A map edit moves a header
    # between modules, which changes what a Swift module imports as surely as a
    # header edit does, and a named header outside the trees above (a seam
    # under Source/Platform, a shell's bridge) is inlined as Core's own are. The
    # maps are configure inputs, so a header a map names tomorrow joins the set
    # at the next build.
    set(moduleMaps
        "${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/Apple/module.modulemap"
        "${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/macOS/module.modulemap"
        ${ARGN})
    set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS ${moduleMaps})
    foreach(moduleMap IN LISTS moduleMaps)
        list(APPEND interopHeaders "${moduleMap}")
        cmake_path(GET moduleMap PARENT_PATH mapDirectory)
        file(STRINGS "${moduleMap}" headerDeclarations
            REGEX "^[ \t]*([a-z]+[ \t]+)*header[ \t]+\"")
        foreach(headerDeclaration IN LISTS headerDeclarations)
            string(REGEX REPLACE "^[^\"]*\"([^\"]+)\".*$" "\\1" header "${headerDeclaration}")
            cmake_path(ABSOLUTE_PATH header BASE_DIRECTORY "${mapDirectory}" NORMALIZE)
            list(APPEND interopHeaders "${header}")
        endforeach()
    endforeach()
    list(REMOVE_DUPLICATES interopHeaders)

    # In the CALLER's binary directory, so the macOS and iOS builds each get
    # their own and a shared source path cannot make one arm's stamp satisfy the
    # other's target.
    set(stampPath "${CMAKE_CURRENT_BINARY_DIR}/UbiquittyInteropStamp.swift")
    add_custom_command(
        OUTPUT  "${stampPath}"
        COMMAND ${CMAKE_COMMAND}
                "-DOUT=${stampPath}"
                "-DHEADERS=${interopHeaders}"
                -P "${_ubiquitty_interop_stamp_writer}"
        DEPENDS ${interopHeaders}
                "${_ubiquitty_interop_stamp_writer}"
        COMMENT "Hashing the C++ headers the Swift modules inline"
        VERBATIM)

    set(${outputVariable} "${stampPath}" PARENT_SCOPE)
endfunction()
