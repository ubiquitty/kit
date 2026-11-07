# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# ubiquitty-kit's Apple products, compiled in the including project's build: the
# Swift modules both Apple arms compile from the lists in AppleSharedSwift.cmake,
# the shader library they load, and the embeddable framework.
#
# A project includes this file at its top directory after project(), with
# UBIQUITTY_CORE_SOURCE_DIR set and UBIQUITTY_KIT_SOURCE_DIR set before
# UbiquittyOptimize.cmake is read (Scripts/cmake/UbiquittyCoreRoot.cmake lays
# out the order), and Swift enabled before it calls a function here. It reads
# Core's UbiquittyOptimize.cmake and UbiquittyCoreSources.cmake first. Every
# function creates its targets in the directory that calls it, under the names
# the Kit's consumers link and its gates read, and holds the Kit's own targets
# to the Swift 6 language mode and, for C++, to C++23 without exceptions or RTTI,
# whatever the calling directory sets.
#
#   UBIQUITTY_APPLE_SHARED_RENDERKIT_SOURCES, UBIQUITTY_APPLE_SHARED_KIT_SOURCES,
#   UBIQUITTY_MACOS_RENDERKIT_SOURCES, UBIQUITTY_MACOS_KIT_SOURCES
#   ubiquitty_kit_swift_flags(PLATFORM macOS|iOS [SOURCE_ROOTS <directories...>])
#   ubiquitty_kit_swift_whole_module(<target>)
#   ubiquitty_kit_add_swift_conditions(<target> <conditions...>)
#   ubiquitty_kit_add_swift_modules(PLATFORM macOS|iOS [MODULE_MAPS <maps...>]
#                                   [LINK_LIBRARIES <libraries...>]
#                                   [CONDITIONS <names...>]
#                                   [SHELL_SOURCES <sources...>]
#                                   [HEADER_PASS_OPTIONS <flags...>])
#   ubiquitty_kit_add_metal_library(<target> PLATFORM macOS|iOS ...)
#   ubiquitty_kit_add_framework(CORE_SOURCES <sources...> [METAL_LIBRARY <target>])
#
# Read from the calling scope, which declares each one: UBIQUITTY_QUIC,
# UBIQUITTY_QUIC_PLATFORM_PREFIX or else UBIQUITTY_QUIC_PREFIX,
# UBIQUITTY_HARFBUZZ_PROBE, UBIQUITTY_SWIFT_PGO_FLAGS (the Swift codegen profile
# flags, empty for none), UBIQUITTY_MACOS_APP_MIN and UBIQUITTY_WERROR. The
# calling project's own build switches reach the modules as CONDITIONS.
include_guard(GLOBAL)

if(NOT DEFINED UBIQUITTY_CORE_SOURCE_DIR)
    message(FATAL_ERROR
        "UbiquittyKit.cmake compiles against ubiquitty-core, and UBIQUITTY_CORE_SOURCE_DIR is not set. "
        "Include <core>/Scripts/cmake/UbiquittyCoreRoot.cmake and Core's modules first, in the order "
        "that file lays out.")
endif()
# UbiquittyOptimize.cmake path-maps the Kit root when it is first read, which is
# below unless the project read it earlier, in the order UbiquittyCoreRoot.cmake
# lays out, with the root set before it. A root defaulted here would be one that
# earlier read left out of the map.
if(NOT DEFINED UBIQUITTY_KIT_SOURCE_DIR)
    message(FATAL_ERROR
        "UbiquittyKit.cmake compiles ubiquitty-kit from UBIQUITTY_KIT_SOURCE_DIR, which is not set. "
        "Set it to the Kit's checkout before including <core>/Scripts/cmake/UbiquittyOptimize.cmake, "
        "in the order <core>/Scripts/cmake/UbiquittyCoreRoot.cmake lays out.")
endif()
# The Kit's targets compile under Core's link-time optimization, profile and
# path map, and over Core's sources.
include("${UBIQUITTY_CORE_SOURCE_DIR}/Scripts/cmake/UbiquittyOptimize.cmake")
include("${UBIQUITTY_CORE_SOURCE_DIR}/Scripts/cmake/UbiquittyCoreSources.cmake")
ubiquitty_require_top_directory(UbiquittyKit.cmake)

# This file's directory as it was read: the functions name the scripts beside it
# from here, whatever roots the calling scope spells.
set(_ubiquitty_kit_modules_directory "${CMAKE_CURRENT_LIST_DIR}")

include("${_ubiquitty_kit_modules_directory}/AppleSharedSwift.cmake")
include("${UBIQUITTY_KIT_SOURCE_DIR}/cmake/SwiftInteropStamp.cmake")

# A directory every source root holds part of, once per root in owner order:
# Core, the Kit, then the caller's SOURCE_ROOTS. Equal roots name it once, so one
# checkout keeps one path.
#
# - Parameters:
#   - outputVariable: Receives the directories.
#   - directory: The directory, relative to each root.
function(ubiquitty_kit_root_directories outputVariable directory)
    set(directories "")
    foreach(root IN LISTS UBIQUITTY_KIT_SOURCE_ROOTS)
        list(APPEND directories "${root}/${directory}")
    endforeach()
    list(REMOVE_DUPLICATES directories)
    set(${outputVariable} "${directories}" PARENT_SCOPE)
endfunction()

# The Swift compile options of an arm's Swift targets, the Kit's and the
# caller's own, which import Core and the Kit through C++ interop.
#
# Sets in the calling scope UBIQUITTY_KIT_SOURCE_ROOTS and, for macOS,
# UBIQUITTY_SWIFT_FLAGS (argv, for a pass that runs swiftc by hand),
# UBIQUITTY_SWIFT_FLAGS_GROUPED (one string, for a target's SHELL: group),
# UBIQUITTY_SWIFT_HEADER_PASS_FLAGS, UBIQUITTY_SWIFT_PGO_GENEX,
# UBIQUITTY_SWIFT_DEBUG_WHOLE_MODULE and UBIQUITTY_KIT_SWIFT_LINK_LIBRARIES (what
# a target linking the modules links besides them); for iOS,
# UBIQUITTY_IOS_SWIFT_FLAGS.
#
# - Parameters:
#   - PLATFORM: macOS or iOS.
#   - SOURCE_ROOTS: Further checkouts whose Source directories, and on macOS
#     whose Source/Platform/Apple and Source/Platform/macOS, the importer
#     searches after Core's and the Kit's.
#
# Under UBIQUITTY_QUIC the importer reads the QUIC dependencies' headers from
# UBIQUITTY_QUIC_PLATFORM_PREFIX, the prefix completed for the platform being
# built (ubiquitty_ensure_quic_deps()), or from UBIQUITTY_QUIC_PREFIX, which is
# the same prefix on the host.
function(ubiquitty_kit_swift_flags)
    cmake_parse_arguments(PARSE_ARGV 0 _ubq_swift "" "PLATFORM" "SOURCE_ROOTS")
    set(quicPrefix "${UBIQUITTY_QUIC_PREFIX}")
    if(DEFINED UBIQUITTY_QUIC_PLATFORM_PREFIX)
        set(quicPrefix "${UBIQUITTY_QUIC_PLATFORM_PREFIX}")
    endif()
    set(UBIQUITTY_KIT_SOURCE_ROOTS
        "${UBIQUITTY_CORE_SOURCE_DIR}" "${UBIQUITTY_KIT_SOURCE_DIR}" ${_ubq_swift_SOURCE_ROOTS})
    list(REMOVE_DUPLICATES UBIQUITTY_KIT_SOURCE_ROOTS)
    set(UBIQUITTY_KIT_SOURCE_ROOTS "${UBIQUITTY_KIT_SOURCE_ROOTS}" PARENT_SCOPE)
    ubiquitty_kit_root_directories(sourceDirectories Source)
    list(TRANSFORM sourceDirectories PREPEND "-I" OUTPUT_VARIABLE sourceIncludes)

    if(_ubq_swift_PLATFORM STREQUAL "iOS")
        set(UBIQUITTY_IOS_SWIFT_FLAGS
            -package-name ubiquitty
            -cxx-interoperability-mode=default
            -Xcc -std=c++23
            ${sourceIncludes}
            # Core's interop map shared by both Apple arms, and the directory of
            # Core's virtual-key table, which that map reaches. A shell's own
            # bridges are in its own map, which only the shell's module searches.
            "-I${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/Apple"
            "-I${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/macOS")
        if(UBIQUITTY_QUIC)
            list(APPEND UBIQUITTY_IOS_SWIFT_FLAGS "SHELL:-Xcc -DUBIQUITTY_QUIC=1"
                "-I${quicPrefix}/include")
        endif()
        set(UBIQUITTY_IOS_SWIFT_FLAGS "${UBIQUITTY_IOS_SWIFT_FLAGS}" PARENT_SCOPE)
        return()
    elseif(NOT _ubq_swift_PLATFORM STREQUAL "macOS")
        message(FATAL_ERROR "ubiquitty_kit_swift_flags: PLATFORM is '${_ubq_swift_PLATFORM}'; it takes macOS or iOS")
    endif()

    # Each include is a single -I<path> token (no space), so the SHELL: space-join
    # below keeps one path bound to each flag.
    ubiquitty_kit_root_directories(appleDirectories Source/Platform/Apple)
    ubiquitty_kit_root_directories(macosDirectories Source/Platform/macOS)
    list(TRANSFORM appleDirectories PREPEND "-I" OUTPUT_VARIABLE appleIncludes)
    list(TRANSFORM macosDirectories PREPEND "-I" OUTPUT_VARIABLE macosIncludes)
    # Swift modules and header-emission passes share the application's API floor.
    # An omitted target inherits the build machine's OS and can produce modules
    # that the application cannot import.
    set(UBIQUITTY_SWIFT_FLAGS
        -target "${CMAKE_SYSTEM_PROCESSOR}-apple-macos${UBIQUITTY_MACOS_APP_MIN}"
        -package-name ubiquitty
        -cxx-interoperability-mode=default
        # The clang importer must compile the interop C++ modules at the same C++23
        # standard as the Core build — the modulemap'd terminal-model headers reach
        # Terminal.h → Encodings.h, which uses std::span (C++20). The importer's default
        # standard is pre-C++20, so raise it to match Core or the module won't build.
        -Xcc -std=c++23
        ${sourceIncludes}
        # The shared Apple map ahead of every other, because a map is searched in
        # include order and the shared one owns Core's headers. Behind, another map
        # is reached first, parses a Core header the shared one owns, and defines
        # its types a second time — which surfaces as a redefinition inside Core
        # rather than as anything about module maps.
        ${appleIncludes}
        ${macosIncludes}
        # Where the bridging header's precompiled form lands.
        #
        # swiftc precompiles -import-objc-header into a temporary directory and
        # records that path in every object's debug info. The directory is reaped
        # when the compile ends, so dsymutil later reports
        #
        #   warning: /var/folders/.../TemporaryDirectory.XXXX/Ubiquitty-Bridging-Header.pch:
        #            No such file or directory
        #
        # on every build -- a warning nobody can act on, about a file that was
        # correct when it was written. Naming a directory under the build tree makes
        # the recorded path outlive the compile, and shares one PCH between the
        # in-target compile and the header-emit pass instead of building it twice.
        "-pch-output-dir" "${CMAKE_CURRENT_BINARY_DIR}/swift-pch"
    )
    # Inline C++ factories imported by Swift must see the same transport feature
    # as the linked C++ objects, including every generated-header emission pass.
    if(UBIQUITTY_QUIC)
        list(APPEND UBIQUITTY_SWIFT_FLAGS -Xcc -DUBIQUITTY_QUIC=1
            "-I${quicPrefix}/include")
    endif()

    set(linkLibraries "")
    if(UBIQUITTY_HARFBUZZ_PROBE)
        find_package(PkgConfig REQUIRED)
        pkg_check_modules(HARFBUZZ_PROBE REQUIRED IMPORTED_TARGET harfbuzz>=14.0)
        find_path(HARFBUZZ_PROBE_HEADERS hb.h HINTS ${HARFBUZZ_PROBE_INCLUDE_DIRS} REQUIRED)
        set(HARFBUZZ_PROBE_MODULE "${CMAKE_CURRENT_BINARY_DIR}/HarfBuzzProbe")
        file(MAKE_DIRECTORY "${HARFBUZZ_PROBE_MODULE}")
        file(WRITE "${HARFBUZZ_PROBE_MODULE}/module.modulemap"
            "module HarfBuzzProbe [system] {\n header \"${HARFBUZZ_PROBE_HEADERS}/hb.h\"\n header \"${HARFBUZZ_PROBE_HEADERS}/hb-ot.h\"\n header \"${HARFBUZZ_PROBE_HEADERS}/hb-coretext.h\"\n export *\n}\n")
        list(APPEND UBIQUITTY_SWIFT_FLAGS "-I${HARFBUZZ_PROBE_MODULE}" "-I${HARFBUZZ_PROBE_HEADERS}")
        list(APPEND linkLibraries PkgConfig::HARFBUZZ_PROBE)
    endif()

    # What the header-emit swiftc passes add to UBIQUITTY_SWIFT_FLAGS. They run
    # swiftc by hand, so neither the language mode CMake gives a Swift target (the
    # Xcode generator carries it as a build setting instead) nor the directory-wide
    # -warnings-as-errors reaches them. Both are stated here once, so a diagnostic
    # that exists in a target's compile exists in its header pass and fails the same
    # build: the Swift 6 mode, and -warnings-as-errors under UBIQUITTY_WERROR.
    set(headerPassFlags -swift-version 6)
    if(UBIQUITTY_WERROR)
        list(APPEND headerPassFlags -warnings-as-errors)
    endif()

    # Swift PGO, from the caller's UBIQUITTY_SWIFT_PGO_FLAGS rather than through
    # UBIQUITTY_SWIFT_FLAGS: that list also feeds the -typecheck header-emit
    # passes, whose command lines must not change on a retrain (codegen never
    # runs there, and a changed line would rebuild the generated headers and
    # everything behind them for nothing). Only the codegen targets consume this.
    set(pgoGenex "")
    if(UBIQUITTY_SWIFT_PGO_FLAGS)
        set(pgoGenex "$<$<COMPILE_LANGUAGE:Swift>:SHELL:${UBIQUITTY_SWIFT_PGO_FLAGS}>")
    endif()

    # CMake deduplicates option lists before expanding a SHELL group. Keep repeated
    # -Xcc forwarding pairs in one group while raw custom commands keep list argv.
    set(grouped "")
    foreach(flag IN LISTS UBIQUITTY_SWIFT_FLAGS)
        string(APPEND grouped " '${flag}'")
    endforeach()

    # How Debug is made whole-module, per generator. The reason is spelled on
    # UbiquittyRenderKit below; this is only the spelling. Ninja takes the mode as
    # a flag. Xcode plans a target's outputs from its own build setting, and a
    # `-wmo` among the other flags contradicts that plan, so there the mode is the
    # setting — on every Swift target, the caller's included, because an
    # incremental importer loses the same members an incremental emitter does.
    set(debugWholeModule "")
    if(NOT CMAKE_GENERATOR MATCHES "Xcode")
        set(debugWholeModule "$<$<AND:$<COMPILE_LANGUAGE:Swift>,$<CONFIG:Debug>>:SHELL:-wmo>")
    endif()

    set(UBIQUITTY_SWIFT_FLAGS "${UBIQUITTY_SWIFT_FLAGS}" PARENT_SCOPE)
    set(UBIQUITTY_SWIFT_FLAGS_GROUPED "${grouped}" PARENT_SCOPE)
    set(UBIQUITTY_SWIFT_HEADER_PASS_FLAGS "${headerPassFlags}" PARENT_SCOPE)
    set(UBIQUITTY_SWIFT_PGO_GENEX "${pgoGenex}" PARENT_SCOPE)
    set(UBIQUITTY_SWIFT_DEBUG_WHOLE_MODULE "${debugWholeModule}" PARENT_SCOPE)
    set(UBIQUITTY_KIT_SWIFT_LINK_LIBRARIES "${linkLibraries}" PARENT_SCOPE)
endfunction()

# Whole-module in every configuration, spelled the way each generator honours,
# for a Swift target of the iOS arm.
#
# `Swift_COMPILATION_MODE` is inert under the including tree's policy level:
# CMake compiles the optimised configurations whole-module and Debug
# incrementally whatever the property says. Ninja takes the mode as a flag.
# Xcode does not — `-wmo` among the other flags contradicts the mode Xcode
# itself planned the target's outputs for — so there it is the build setting,
# on the target, which holds in all four configurations.
#
# Debug is the configuration a person presses Run on, and incremental there is
# not merely slower to link. A member whose signature names an imported C++ type
# does not survive an incremental compile on either side of an import: the
# importer fails with "value of type 'RuntimeDrive' has no member
# 'readSnapshot'" on a member that is public in the source, and nothing is
# diagnosed where it was lost. Making the two kits whole-module moves the
# failure from the Kit to the shell, which imports them the same way — so the
# mode belongs to every Swift target of the arm, the shell's included.
#
# - Parameter target: A Swift target of the iOS arm.
function(ubiquitty_kit_swift_whole_module target)
    if(CMAKE_GENERATOR MATCHES "Xcode")
        set_target_properties(${target} PROPERTIES
            XCODE_ATTRIBUTE_SWIFT_COMPILATION_MODE "wholemodule")
    else()
        target_compile_options(${target} PRIVATE
            "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-wmo>")
    endif()
endfunction()

# Compiles a Swift target under each compilation condition, each also defined as
# 1 for its C++ importer. A module imports Core's headers through that importer,
# so without the second half it lays out a type with a member under the
# condition one member short of the C++ translation units built under it, and
# the first call across the seam faults. One SHELL: group per flag, because
# CMake de-duplicates an option list and would take a second bare `-Xcc` from
# its argument. Every Swift module of an arm takes the conditions its C++ is
# built under: the Kit's (ubiquitty_kit_add_swift_modules(CONDITIONS)) and the
# caller's own.
#
# - Parameters:
#   - target: A Swift target.
#   - ARGN: The conditions' names.
function(ubiquitty_kit_add_swift_conditions target)
    foreach(condition IN LISTS ARGN)
        target_compile_options(${target} PRIVATE
            "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-D${condition}>"
            "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-Xcc -D${condition}=1>")
    endforeach()
endfunction()

# Holds a Kit Swift target to the Swift 6 language mode, whose data-race
# checking keeps the Kit at zero concurrency diagnostics, whatever the calling
# directory's default mode. Xcode takes the mode from SWIFT_VERSION, and a
# -swift-version word in OTHER_SWIFT_FLAGS is reported as overriding it.
#
# - Parameter target: A Swift target the Kit creates.
function(ubiquitty_kit_swift_language_mode target)
    if(CMAKE_GENERATOR MATCHES "Xcode")
        set_target_properties(${target} PROPERTIES XCODE_ATTRIBUTE_SWIFT_VERSION 6)
    else()
        set_target_properties(${target} PROPERTIES Swift_LANGUAGE_VERSION 6)
    endif()
endfunction()

# The two Swift modules of an Apple arm, and on macOS the typed pasteboard
# beneath them: UbiquittyRenderKit, the Swift renderer, and UbiquittyKitModule,
# the UbiquittyKit module a shell hosts, with UbiquittyPasteboard and the
# UbiquittyRenderKitHeader step that emits the render kit's generated interface.
# Reads the flags ubiquitty_kit_swift_flags() set for the same PLATFORM.
#
# Sets in the calling scope UBIQUITTY_SWIFT_INTEROP_STAMP, the source every Swift
# module that inlines Core carries (the caller's own included), and on macOS
# UBIQUITTY_KIT_SOURCES, the UbiquittyKit module's sources, which the framework
# compiles too.
#
# - Parameters:
#   - PLATFORM: macOS or iOS.
#   - MODULE_MAPS: The caller's own module maps, which the interop stamp follows
#     besides Core's and the Kit's.
#   - LINK_LIBRARIES: What the render kit links: the Core library, where the
#     caller does not compile Core into its own target.
#   - CONDITIONS: Compilation conditions every module compiles under, each also
#     defined as 1 for its C++ importer, so a module lays out Core's types as the
#     caller's C++ translation units do.
#   - SHELL_SOURCES: macOS: the caller's window shell, compiled into the
#     UbiquittyKit module after the Kit's own sources. A Kit source the list
#     names is compiled at the list's position instead.
#   - HEADER_PASS_OPTIONS: macOS: further swiftc flags of the generated-header
#     pass, after the conditions.
function(ubiquitty_kit_add_swift_modules)
    cmake_parse_arguments(PARSE_ARGV 0 _ubq_modules "" "PLATFORM"
        "MODULE_MAPS;LINK_LIBRARIES;CONDITIONS;SHELL_SOURCES;HEADER_PASS_OPTIONS")
    set(platform "${_ubq_modules_PLATFORM}")
    if(platform STREQUAL "macOS")
        if(NOT DEFINED UBIQUITTY_SWIFT_FLAGS_GROUPED)
            message(FATAL_ERROR "ubiquitty_kit_add_swift_modules(PLATFORM macOS) reads ubiquitty_kit_swift_flags(PLATFORM macOS); call it first")
        endif()
        set(renderKitLists UBIQUITTY_APPLE_SHARED_RENDERKIT_SOURCES UBIQUITTY_MACOS_RENDERKIT_SOURCES)
        set(kitLists UBIQUITTY_APPLE_SHARED_KIT_SOURCES UBIQUITTY_MACOS_KIT_SOURCES)
        # The typed pasteboard the Kit's clipboard seam and the C++ side call,
        # unless the caller created it by including TypedPasteboard.cmake.
        include("${_ubiquitty_kit_modules_directory}/TypedPasteboard.cmake")
    elseif(platform STREQUAL "iOS")
        if(NOT DEFINED UBIQUITTY_IOS_SWIFT_FLAGS)
            message(FATAL_ERROR "ubiquitty_kit_add_swift_modules(PLATFORM iOS) reads ubiquitty_kit_swift_flags(PLATFORM iOS); call it first")
        endif()
        set(renderKitLists UBIQUITTY_APPLE_SHARED_RENDERKIT_SOURCES)
        set(kitLists UBIQUITTY_APPLE_SHARED_KIT_SOURCES)
    else()
        message(FATAL_ERROR "ubiquitty_kit_add_swift_modules: PLATFORM is '${platform}'; it takes macOS or iOS")
    endif()

    # The Swift modules inline header-only Core through interop, and CMake does
    # not scan an interop include: the stamp is the source that makes them
    # recompile when a header moves (cmake/SwiftInteropStamp.cmake).
    ubiquitty_swift_interop_stamp(UBIQUITTY_SWIFT_INTEROP_STAMP ${_ubq_modules_MODULE_MAPS})
    set(UBIQUITTY_SWIFT_INTEROP_STAMP "${UBIQUITTY_SWIFT_INTEROP_STAMP}" PARENT_SCOPE)

    # The conditions as the generated-header pass's argv, which takes both
    # halves ubiquitty_kit_add_swift_conditions() gives a target.
    set(conditionFlags "")
    foreach(condition IN LISTS _ubq_modules_CONDITIONS)
        list(APPEND conditionFlags "-D${condition}" "-Xcc" "-D${condition}=1")
    endforeach()

    # ------------------------------------------------------------------
    # UbiquittyRenderKit: the Swift renderer, as its own module. What holds it
    # apart is the export wall: UbiquittyKit imports it internally, so the Kit's
    # public interface can name no renderer type and carries no C++, and a file
    # in the wrong one of the two lists fails to compile instead of leaking the
    # renderer into the consumer's API. Both arms compile it from the same
    # shared list, macOS adding its shell's chrome.
    #
    # Speed does not separate it. On macOS the module compiles with dynamic
    # exclusivity checking off. Core imports the slot cache as a foreign
    # reference type, so a probe is a method call through a reference the
    # renderer only reads, and neither Swift arm's loop carries
    # swift_beginAccess: Tools/seam-bench reads 2.72 ns a crossing with the
    # checks and 2.78 without, against 2.84 for inline C++ and 3.37 for a
    # virtual call. Whether the flag buys anything on the renderer's other
    # per-frame paths is unmeasured. Dynamic exclusivity stays on in every
    # other Swift module, where it is a safety property and no per-frame seam
    # runs: -wmo compiles a module as a unit, so the flag cannot be scoped to a
    # file.
    #
    # This is also the boundary that makes the renderer extractable: it reaches
    # Core through the module maps and Metal/CoreText through the SDK, and
    # nothing in it names an app. No bridging header: the six check-*.sh
    # drivers compile these same files with neither a bridging header nor an
    # app module, which is the standing proof the list stays self-contained.
    # ------------------------------------------------------------------
    set(renderKitSources "")
    foreach(source IN LISTS ${renderKitLists})
        list(APPEND renderKitSources "${UBIQUITTY_KIT_SOURCE_DIR}/${source}")
    endforeach()
    list(APPEND renderKitSources "${UBIQUITTY_SWIFT_INTEROP_STAMP}")
    add_library(UbiquittyRenderKit STATIC ${renderKitSources})
    # Whole-module, because Swift optimises a file at a time otherwise and no call
    # inlines across a file boundary — Tools/seam-bench records that source
    # annotations (@inline(__always), final) are no-ops without it, so a hot
    # function called from another file stays outlined whatever it is marked.
    #
    # This property is honoured in the optimised configurations and not in Debug,
    # where CMake drives swiftc `-incremental`. The per-config spelling does not
    # bind it either — measured, by building Debug from scratch with each and
    # comparing. The mode is therefore forced as a flag too, and the difference it
    # makes reaches the module interface rather than only the object code: an
    # incrementally merged module is built from per-file partials, and a member
    # whose signature names an imported C++ type is dropped from the serialized
    # interface instead of being diagnosed. The consumer then fails at the call
    # with "has no member" while the member is public on the same tree, so nothing
    # points at the cause. Naming the mode in every configuration is what makes
    # each arm buildable in the mode it is debugged in.
    set_target_properties(UbiquittyRenderKit PROPERTIES
        Swift_MODULE_NAME "UbiquittyRenderKit"
        Swift_COMPILATION_MODE "wholemodule")
    ubiquitty_kit_swift_language_mode(UbiquittyRenderKit)
    if(platform STREQUAL "macOS")
        if(CMAKE_GENERATOR MATCHES "Xcode")
            # The app's floor, as the setting. UBIQUITTY_SWIFT_FLAGS names it with
            # `-target`, which Xcode replaces with one built from this setting; left
            # at the C++ floor, the module is compiled for an OS older than the API
            # it is written against.
            set_target_properties(UbiquittyRenderKit PROPERTIES
                XCODE_ATTRIBUTE_SWIFT_COMPILATION_MODE "wholemodule"
                XCODE_ATTRIBUTE_MACOSX_DEPLOYMENT_TARGET "${UBIQUITTY_MACOS_APP_MIN}")
        endif()
        target_compile_options(UbiquittyRenderKit PRIVATE
            "$<$<COMPILE_LANGUAGE:Swift>:SHELL:${UBIQUITTY_SWIFT_FLAGS_GROUPED}>"
            "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-enforce-exclusivity=unchecked>"
            ${UBIQUITTY_SWIFT_DEBUG_WHOLE_MODULE}
            ${UBIQUITTY_SWIFT_PGO_GENEX})
    else()
        ubiquitty_kit_swift_whole_module(UbiquittyRenderKit)
        target_compile_options(UbiquittyRenderKit PRIVATE
            "$<$<COMPILE_LANGUAGE:Swift>:SHELL:${UBIQUITTY_IOS_SWIFT_FLAGS}>")
    endif()
    if(_ubq_modules_LINK_LIBRARIES)
        target_link_libraries(UbiquittyRenderKit PRIVATE ${_ubq_modules_LINK_LIBRARIES})
    endif()
    ubiquitty_kit_add_swift_conditions(UbiquittyRenderKit ${_ubq_modules_CONDITIONS})

    if(platform STREQUAL "macOS")
        # The render kit's generated interface, which
        # Scripts/check-swift-cxx-exports.py reads for what the module exports
        # across the seam. Emitted by its own pass so Ninja orders it after the
        # module it describes.
        set(generatedHeader "${CMAKE_CURRENT_BINARY_DIR}/UbiquittyRenderKit-Swift.h")
        add_custom_command(
            OUTPUT  "${generatedHeader}"
            COMMAND xcrun swiftc
                    -module-name UbiquittyRenderKit
                    -emit-objc-header-path "${generatedHeader}"
                    -typecheck
                    -wmo
                    ${UBIQUITTY_SWIFT_FLAGS}
                    ${UBIQUITTY_SWIFT_HEADER_PASS_FLAGS}
                    ${conditionFlags}
                    ${_ubq_modules_HEADER_PASS_OPTIONS}
                    ${renderKitSources}
            DEPENDS ${renderKitSources}
                    "${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/Apple/module.modulemap"
            COMMENT "Emitting UbiquittyRenderKit-Swift.h"
            VERBATIM)
        add_custom_target(UbiquittyRenderKitHeader
            DEPENDS "${generatedHeader}")
        # The header target waits for the library, and that is what makes the
        # Xcode generator accept the directory at all.
        #
        # The interop stamp is generated by one custom command and is a source
        # of both UbiquittyRenderKit and the emit above. Xcode's "new build
        # system" refuses a generating command attached to two targets unless one
        # is a dependency of the other; Ninja does not.
        #
        # Ordering it this way rather than the other: the emit reads the same
        # sources the library compiles, so running it after the library is the
        # direction that was already true in practice.
        add_dependencies(UbiquittyRenderKitHeader UbiquittyRenderKit)
    endif()

    # ------------------------------------------------------------------
    # UbiquittyKitModule: the UbiquittyKit module, the pure-Swift surface over
    # the machinery.
    #
    # Its files import the render kit and every Core interop module INTERNALLY,
    # which is what keeps C++ out of the module's interface: a consumer of the
    # UbiquittyKit module needs no interoperability flags and no module maps.
    # The machinery it constructs is reached through package visibility — both
    # modules compile under -package-name ubiquitty.
    # ------------------------------------------------------------------
    set(shellSources "${_ubq_modules_SHELL_SOURCES}")
    set(UBIQUITTY_KIT_SOURCES "")
    foreach(source IN LISTS ${kitLists})
        if(NOT "${UBIQUITTY_KIT_SOURCE_DIR}/${source}" IN_LIST shellSources)
            list(APPEND UBIQUITTY_KIT_SOURCES "${UBIQUITTY_KIT_SOURCE_DIR}/${source}")
        endif()
    endforeach()
    list(APPEND UBIQUITTY_KIT_SOURCES ${shellSources})
    list(APPEND UBIQUITTY_KIT_SOURCES "${UBIQUITTY_SWIFT_INTEROP_STAMP}")
    add_library(UbiquittyKitModule STATIC ${UBIQUITTY_KIT_SOURCES})
    ubiquitty_kit_swift_language_mode(UbiquittyKitModule)
    # Whole-module for the reason spelled on UbiquittyRenderKit. This target
    # reads the other's interface, so it is where a dropped member is observed —
    # but both need it, since either one built incrementally can serialize a
    # module the next reader finds short.
    #
    # The module's name, as the setting Xcode reads too: it names a module for
    # its product, which here is the target's name and not the name the shell
    # imports.
    if(platform STREQUAL "macOS")
        set_target_properties(UbiquittyKitModule PROPERTIES
            Swift_MODULE_NAME "UbiquittyKit"
            Swift_COMPILATION_MODE "wholemodule")
        if(CMAKE_GENERATOR MATCHES "Xcode")
            set_target_properties(UbiquittyKitModule PROPERTIES
                XCODE_ATTRIBUTE_SWIFT_COMPILATION_MODE "wholemodule"
                XCODE_ATTRIBUTE_PRODUCT_MODULE_NAME "UbiquittyKit"
                XCODE_ATTRIBUTE_MACOSX_DEPLOYMENT_TARGET "${UBIQUITTY_MACOS_APP_MIN}")
        endif()
        target_compile_options(UbiquittyKitModule PRIVATE
            "$<$<COMPILE_LANGUAGE:Swift>:SHELL:${UBIQUITTY_SWIFT_FLAGS_GROUPED}>"
            ${UBIQUITTY_SWIFT_DEBUG_WHOLE_MODULE}
            "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-I ${CMAKE_CURRENT_BINARY_DIR}>"
            ${UBIQUITTY_SWIFT_PGO_GENEX})
        add_dependencies(UbiquittyKitModule UbiquittyRenderKit)
        target_link_libraries(UbiquittyKitModule PRIVATE UbiquittyRenderKit PUBLIC UbiquittyPasteboard)
        set(UBIQUITTY_KIT_SOURCES "${UBIQUITTY_KIT_SOURCES}" PARENT_SCOPE)
    else()
        set_target_properties(UbiquittyKitModule PROPERTIES
            Swift_MODULE_NAME "UbiquittyKit"
            Swift_COMPILATION_MODE "wholemodule"
            XCODE_ATTRIBUTE_PRODUCT_MODULE_NAME "UbiquittyKit")
        ubiquitty_kit_swift_whole_module(UbiquittyKitModule)
        target_compile_options(UbiquittyKitModule PRIVATE
            "$<$<COMPILE_LANGUAGE:Swift>:SHELL:${UBIQUITTY_IOS_SWIFT_FLAGS}>"
            "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-I ${CMAKE_CURRENT_BINARY_DIR}>")
        add_dependencies(UbiquittyKitModule UbiquittyRenderKit)
        target_link_libraries(UbiquittyKitModule PRIVATE UbiquittyRenderKit)
    endif()
    ubiquitty_kit_add_swift_conditions(UbiquittyKitModule ${_ubq_modules_CONDITIONS})
endfunction()

# The shader library the renderer loads, UBShaders.metal compiled to a
# default.metallib, behind a target of the caller's name that builds it. The
# target carries the library's path as its UBIQUITTY_KIT_METAL_LIBRARY property.
#
#   ubiquitty_kit_add_metal_library(<target> PLATFORM macOS)
#       Into the calling directory's binary directory, for the deployment floor
#       CMAKE_OSX_DEPLOYMENT_TARGET. Without a usable Metal toolchain the target
#       is not created and the configure warns.
#   ubiquitty_kit_add_metal_library(<target> PLATFORM iOS
#       OUTPUT_DIRECTORY <directory> PLATFORM_LABEL <text>
#       STEP <command...> [STEP_SCRIPT <script>])
#       For the SDK being built, by a script run as `<STEP...> -P <STEP_SCRIPT>`
#       when the build runs: Scripts/cmake/MetalLibraryStep.cmake by default, whose
#       header names the -D arguments STEP passes, or a step script of the
#       caller's own. The library depends on that script alone, so the script
#       holds the commands it runs rather than including them from another
#       file. The library lands in OUTPUT_DIRECTORY, which is where the step's
#       arguments put it.
function(ubiquitty_kit_add_metal_library target)
    cmake_parse_arguments(PARSE_ARGV 1 _ubq_metal ""
        "PLATFORM;OUTPUT_DIRECTORY;PLATFORM_LABEL;STEP_SCRIPT" "STEP")
    set(metalSource "${UBIQUITTY_KIT_SOURCE_DIR}/Source/UbiquittyRenderKit/UBShaders.metal")
    # The shader includes Core's Tek raster by its path under Core's Source root.
    set(rasterHeader "${UBIQUITTY_CORE_SOURCE_DIR}/Source/Core/Tek/BeamRaster.h")

    if(_ubq_metal_PLATFORM STREQUAL "iOS")
        if(NOT DEFINED _ubq_metal_OUTPUT_DIRECTORY OR NOT _ubq_metal_STEP)
            message(FATAL_ERROR "ubiquitty_kit_add_metal_library(${target} PLATFORM iOS) needs OUTPUT_DIRECTORY and STEP")
        endif()
        if(NOT DEFINED _ubq_metal_STEP_SCRIPT)
            set(_ubq_metal_STEP_SCRIPT "${_ubiquitty_kit_modules_directory}/MetalLibraryStep.cmake")
        endif()
        # Same source as the macOS arm: a shader is not platform code, and a
        # second copy would be a second renderer by another route.
        set(metalLibrary "${_ubq_metal_OUTPUT_DIRECTORY}/default.metallib")
        add_custom_command(
            OUTPUT "${metalLibrary}"
            COMMAND ${_ubq_metal_STEP} -P "${_ubq_metal_STEP_SCRIPT}"
            DEPENDS "${metalSource}"
                    "${rasterHeader}"
                    "${_ubq_metal_STEP_SCRIPT}"
            COMMENT "Compiling UBShaders.metal for ${_ubq_metal_PLATFORM_LABEL}"
            VERBATIM)
        add_custom_target(${target} DEPENDS "${metalLibrary}")
        set_target_properties(${target} PROPERTIES UBIQUITTY_KIT_METAL_LIBRARY "${metalLibrary}")
        return()
    elseif(NOT _ubq_metal_PLATFORM STREQUAL "macOS")
        message(FATAL_ERROR "ubiquitty_kit_add_metal_library(${target}): PLATFORM is '${_ubq_metal_PLATFORM}'; it takes macOS or iOS")
    endif()

    # The Makefile and Ninja generators do not compile .metal sources natively,
    # so the metal compiler is driven by hand.
    #
    # Compiling .metal requires the Metal Toolchain, which ships with full Xcode
    # (and, on recent macOS, as a separately downloaded component:
    # `xcodebuild -downloadComponent MetalToolchain`). When the toolchain is
    # absent the shader build is skipped so the caller still configures,
    # compiles and links; the runtime detects the missing library and reports it
    # instead of crashing. Building the metallib then only requires a rebuild
    # once the toolchain is installed.
    set(metalAir "${CMAKE_CURRENT_BINARY_DIR}/UBShaders.air")
    set(metalLibrary "${CMAKE_CURRENT_BINARY_DIR}/default.metallib")

    # Without a version-min the metal compiler targets the newest Metal language
    # version, producing a metallib older systems refuse to load. It is pinned to
    # CMAKE_OSX_DEPLOYMENT_TARGET, the C++ floor, which is at or below the app's,
    # so the shaders load everywhere the app installs.
    set(metalFlags "")
    if(CMAKE_OSX_DEPLOYMENT_TARGET)
        set(metalFlags "-mmacosx-version-min=${CMAKE_OSX_DEPLOYMENT_TARGET}")
    endif()
    set(metalIncludes -I "${UBIQUITTY_CORE_SOURCE_DIR}/Source")

    # Probe for a usable metal compiler. The Xcode-bundled metal at
    # Toolchains/XcodeDefault.xctoolchain/usr/bin/metal is a stub that exits with
    # "missing Metal Toolchain"; the real compiler lives in the cryptex-mounted
    # Metal.xctoolchain and is reachable through `xcrun -f metal`. Always resolve
    # via xcrun first.
    execute_process(
        COMMAND xcrun -f metal
        OUTPUT_VARIABLE metalTool
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET)
    execute_process(
        COMMAND xcrun -f metallib
        OUTPUT_VARIABLE metallibTool
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET)

    set(haveMetalTool FALSE)
    if(metalTool AND metallibTool)
        # Confirm the binary can actually compile (the Metal Toolchain component
        # must be downloaded — `xcodebuild -downloadComponent MetalToolchain` on
        # recent macOS).
        execute_process(
            COMMAND "${metalTool}" ${metalIncludes}
                    -c "${metalSource}"
                    -o "${metalAir}.probe"
            RESULT_VARIABLE probeStatus
            OUTPUT_QUIET ERROR_QUIET)
        if(probeStatus EQUAL 0)
            set(haveMetalTool TRUE)
            file(REMOVE "${metalAir}.probe")
        endif()
    endif()

    if(NOT haveMetalTool)
        message(WARNING
            "Metal Toolchain not found; UBShaders.metal will NOT be compiled. "
            "The app links but the renderer reports a missing default library "
            "at launch. Install full Xcode or run "
            "`xcodebuild -downloadComponent MetalToolchain`, then rebuild.")
        return()
    endif()
    add_custom_command(
        OUTPUT  "${metalAir}"
        COMMAND "${metalTool}" ${metalFlags}
                ${metalIncludes}
                -c "${metalSource}"
                -o "${metalAir}"
        DEPENDS "${metalSource}" "${rasterHeader}"
        COMMENT "Compiling UBShaders.metal -> AIR"
        VERBATIM)
    add_custom_command(
        OUTPUT  "${metalLibrary}"
        COMMAND "${metallibTool}" "${metalAir}"
                -o "${metalLibrary}"
        DEPENDS "${metalAir}"
        COMMENT "Linking default.metallib"
        VERBATIM)
    add_custom_target(${target} DEPENDS "${metalLibrary}")
    set_target_properties(${target} PROPERTIES UBIQUITTY_KIT_METAL_LIBRARY "${metalLibrary}")
endfunction()

# UbiquittyKit, the embeddable terminal framework: the UbiquittyKit module's
# sources plus the portable Core they link, packaged as a macOS framework an
# external app consumes with no Ubiquitty app around it. Scripts/check-ubiquittykit.sh
# builds it and draws a frame through it from a consumer of its own.
#
# It recompiles the Core translation units into the framework, the way the
# caller's app builds them, so one configure produces the product. Reads what
# ubiquitty_kit_add_swift_modules(PLATFORM macOS) set. Its C++ compiles as C++23
# without exceptions or RTTI, Core's language policy, beneath whatever
# per-file flags the calling directory adds; the vendored sources take Core's
# ThirdParty policy over it. The built-in themes' generated translation unit is
# the framework's own copy (ubiquitty_embed_builtin_themes), since the Xcode
# generator refuses one generating command attached to two targets.
#
# - Parameters:
#   - CORE_SOURCES: The portable Core the framework compiles into itself.
#   - METAL_LIBRARY: The ubiquitty_kit_add_metal_library() target whose library
#     the framework carries, when there is one.
function(ubiquitty_kit_add_framework)
    cmake_parse_arguments(PARSE_ARGV 0 _ubq_framework "" "METAL_LIBRARY" "CORE_SOURCES")
    if(NOT DEFINED UBIQUITTY_KIT_SOURCES)
        message(FATAL_ERROR "ubiquitty_kit_add_framework() reads ubiquitty_kit_add_swift_modules(PLATFORM macOS); call it first")
    endif()
    # The OS-seam translation units the runtime needs beneath the portable Core:
    # the PTY transport, the clock, the diagnostics sink and the serial/pty facts.
    # App chrome stays out — the framework is the terminal, not the application
    # around it.
    #
    # Every one is C++ over a C API, so the framework links no Objective-C at
    # all. The clipboard's pasteboard half is Swift and rides
    # UBIQUITTY_MACOS_KIT_SOURCES.
    set(seams
        "${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/POSIX/PTYStream.cpp"
        "${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/POSIX/SerialStream.cpp"
        "${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/POSIX/PTYFacts.cpp"
        "${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/POSIX/SessionHandoff.cpp"
        "${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/POSIX/LocalHostInstall.cpp"
        "${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/macOS/RemoteResumeBridge.cpp"
        "${UBIQUITTY_CORE_SOURCE_DIR}/Source/Platform/Apple/Clock.cpp"
        "${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/macOS/Diag.cpp"
        "${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/macOS/Bell.cpp"
        "${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/macOS/Clipboard.cpp"
        "${UBIQUITTY_KIT_SOURCE_DIR}/Source/Platform/macOS/DECPSSound.cpp")
    ubiquitty_embed_builtin_themes(themesSource
        COMMENT "Embedding built-in themes TOML for UbiquittyKit"
        TARGET UbiquittyKit)
    add_library(UbiquittyKit SHARED
        ${UBIQUITTY_KIT_SOURCES}
        "${themesSource}"
        ${seams}
        ${_ubq_framework_CORE_SOURCES})
    add_dependencies(UbiquittyKit UbiquittyRenderKit)
    # The Kit sources import UbiquittyPasteboard, as UbiquittyKitModule's do;
    # the framework compiles the same sources and needs the same module.
    target_link_libraries(UbiquittyKit PRIVATE UbiquittyRenderKit UbiquittyPasteboard)
    # A shell's remote session offers the QUIC carrier, so the framework builds
    # the same sources under the same define as an app beside it, or its sessions
    # would fall back to the subprocess carrier on every connect while the app
    # dialled QUIC. The two must agree, since which one opened a window is a user
    # default rather than a build. The caller has completed the dependencies
    # (ubiquitty_ensure_quic_deps()).
    if(UBIQUITTY_QUIC)
        target_sources(UbiquittyKit PRIVATE ${UBIQUITTY_QUIC_CLIENT_SOURCES})
        target_include_directories(UbiquittyKit PRIVATE "${UBIQUITTY_QUIC_PREFIX}/include")
        target_compile_definitions(UbiquittyKit PRIVATE
            "$<$<OR:$<COMPILE_LANGUAGE:C>,$<COMPILE_LANGUAGE:CXX>>:UBIQUITTY_QUIC=1>")
        ubiquitty_link_quic_archives(UbiquittyKit PRIVATE "${UBIQUITTY_QUIC_PREFIX}")
    endif()
    # The framework's public Swift interface and the C++ session facade share
    # the Kit version. Core owns that version's header.
    set(versionHeader "${UBIQUITTY_CORE_SOURCE_DIR}/Source/UbiquittyKit/Version.h")
    set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${versionHeader}")
    file(READ "${versionHeader}" versionText)
    string(REGEX MATCH "kitVersionString = \"([0-9]+\\.[0-9]+\\.[0-9]+)\"" _ "${versionText}")
    if(NOT CMAKE_MATCH_1)
        message(FATAL_ERROR "no kitVersionString in ${versionHeader}")
    endif()
    set(kitVersion "${CMAKE_MATCH_1}")
    set_target_properties(UbiquittyKit PROPERTIES
        FRAMEWORK TRUE
        FRAMEWORK_VERSION A
        MACOSX_FRAMEWORK_IDENTIFIER "dev.ubiquitty.UbiquittyKit"
        MACOSX_FRAMEWORK_SHORT_VERSION_STRING "${kitVersion}"
        MACOSX_FRAMEWORK_BUNDLE_VERSION "${kitVersion}"
        Swift_MODULE_NAME "UbiquittyKit"
        Swift_COMPILATION_MODE "wholemodule"
        # Its own module directory: UbiquittyKitModule emits the same module
        # name into the default location, and two rules for one output stop the
        # build before either runs.
        Swift_MODULE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/UbiquittyKitFramework"
        CXX_STANDARD 23
        CXX_STANDARD_REQUIRED ON
        CXX_EXTENSIONS OFF)
    ubiquitty_kit_swift_language_mode(UbiquittyKit)
    # Whole-module in Debug too, for the reason spelled on UbiquittyRenderKit:
    # an incremental compile drops a member whose signature names an imported
    # C++ type, and the framework's Swift calls it across files.
    if(CMAKE_GENERATOR MATCHES "Xcode")
        set_target_properties(UbiquittyKit PROPERTIES
            XCODE_ATTRIBUTE_SWIFT_COMPILATION_MODE "wholemodule")
    endif()
    target_compile_options(UbiquittyKit PRIVATE
        "$<$<COMPILE_LANGUAGE:CXX>:-fno-exceptions;-fno-rtti>"
        "$<$<COMPILE_LANGUAGE:Swift>:SHELL:${UBIQUITTY_SWIFT_FLAGS_GROUPED}>"
        ${UBIQUITTY_SWIFT_DEBUG_WHOLE_MODULE}
        # Library evolution is what makes the internal imports invisible to a
        # consumer: the binary swiftmodule records every dependency, but the
        # textual interface names only the public ones, and the framework ships
        # the interface. It is this product's alone; the static modules an app
        # links compile without it.
        "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-enable-library-evolution>"
        "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-emit-module-interface-path ${CMAKE_CURRENT_BINARY_DIR}/UbiquittyKitFramework/UbiquittyKit.swiftinterface>"
        ${UBIQUITTY_SWIFT_PGO_GENEX})
    ubiquitty_kit_root_directories(sourceDirectories Source)
    ubiquitty_kit_root_directories(macosDirectories Source/Platform/macOS)
    target_include_directories(UbiquittyKit PRIVATE
        ${sourceDirectories}
        ${macosDirectories}
        "${CMAKE_CURRENT_BINARY_DIR}")
    # ScrollSearch links the vendored re2 and the ingest path the vendored
    # simdutf, each under Core's ThirdParty policy.
    target_include_directories(UbiquittyKit SYSTEM PRIVATE "${UBIQUITTY_RE2_DIR}" "${UBIQUITTY_SIMDUTF_DIR}")
    target_sources(UbiquittyKit PRIVATE ${UBIQUITTY_RE2_SOURCES} ${UBIQUITTY_SIMDUTF_SOURCES})
    ubiquitty_apply_third_party_policy(${UBIQUITTY_RE2_SOURCES} ${UBIQUITTY_SIMDUTF_SOURCES})
    target_link_libraries(UbiquittyKit PRIVATE
        "-framework AppKit"
        "-framework Metal"
        "-framework QuartzCore"
        "-framework CoreText"
        "-framework CoreGraphics"
        "-framework AudioToolbox"
        "-framework UniformTypeIdentifiers")

    # Every framework resource is staged into its version directory. The
    # renderer resolves that bundle instead of the embedding application's.
    include("${UBIQUITTY_CORE_SOURCE_DIR}/cmake/LicenseNotices.cmake")
    include("${UBIQUITTY_KIT_SOURCE_DIR}/cmake/BundleResources.cmake")
    include("${UBIQUITTY_KIT_SOURCE_DIR}/cmake/BundleLicenseNotices.cmake")
    if(_ubq_framework_METAL_LIBRARY AND TARGET ${_ubq_framework_METAL_LIBRARY})
        get_target_property(metalLibrary ${_ubq_framework_METAL_LIBRARY} UBIQUITTY_KIT_METAL_LIBRARY)
        add_dependencies(UbiquittyKit ${_ubq_framework_METAL_LIBRARY})
        add_custom_command(TARGET UbiquittyKit POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy "${metalLibrary}"
                    "$<TARGET_FILE_DIR:UbiquittyKit>/Resources/default.metallib"
            COMMENT "Copying default.metallib into UbiquittyKit Resources"
            VERBATIM)
    endif()

    file(GLOB UBIQUITTY_BUNDLED_FONT_FILES CONFIGURE_DEPENDS "${UBIQUITTY_CORE_SOURCE_DIR}/Resources/fonts/*")
    file(GLOB phosphorFiles CONFIGURE_DEPENDS "${UBIQUITTY_KIT_SOURCE_DIR}/Resources/phosphor/*")
    file(GLOB processIconFiles CONFIGURE_DEPENDS "${UBIQUITTY_CORE_SOURCE_DIR}/Resources/process-icons/*")
    list(SORT UBIQUITTY_BUNDLED_FONT_FILES)
    list(SORT phosphorFiles)
    list(SORT processIconFiles)
    ubiquitty_bundle_resource_directory(UbiquittyKit "fonts" ${UBIQUITTY_BUNDLED_FONT_FILES})
    ubiquitty_bundle_resource_directory(UbiquittyKit "phosphor" ${phosphorFiles})
    ubiquitty_bundle_resource_directory(UbiquittyKit "process-icons" ${processIconFiles})
    ubiquitty_bundle_license_notices(UbiquittyKit)

    # Only the textual public interface ships: the binary swiftmodule requires
    # Core's private interop modules. Run after every step writing the bundle,
    # so the root contains only the links codesign seals in an embedding app.
    add_custom_command(TARGET UbiquittyKit POST_BUILD
        COMMAND ${CMAKE_COMMAND}
                "-DUBIQUITTY_FRAMEWORK=$<TARGET_BUNDLE_DIR:UbiquittyKit>"
                "-DUBIQUITTY_FRAMEWORK_VERSION=$<TARGET_PROPERTY:UbiquittyKit,FRAMEWORK_VERSION>"
                "-DUBIQUITTY_FRAMEWORK_INTERFACE=${CMAKE_CURRENT_BINARY_DIR}/UbiquittyKitFramework/UbiquittyKit.swiftinterface"
                "-DUBIQUITTY_FRAMEWORK_INTERFACE_NAME=${CMAKE_SYSTEM_PROCESSOR}-apple-macos.swiftinterface"
                -P "${UBIQUITTY_KIT_SOURCE_DIR}/cmake/FrameworkBundleLayout.cmake"
        COMMENT "Laying out UbiquittyKit.framework"
        VERBATIM)
endfunction()
