# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

include_guard(GLOBAL)

# The distribution's licence notices, staged into an application or framework bundle. Which
# notices there are and the checkout each is read from are Core's
# cmake/LicenseNotices.cmake, included before this file; the staging is
# cmake/BundleResources.cmake.
if(NOT COMMAND ubiquitty_license_notice_paths)
    message(FATAL_ERROR
        "BundleLicenseNotices.cmake needs Core's cmake/LicenseNotices.cmake included first")
endif()
include("${CMAKE_CURRENT_LIST_DIR}/BundleResources.cmake")

# Stages every distribution notice into the bundle and checks the staged set
# against the inventory after every build.
#
# - Parameter target: The bundle target.
function(ubiquitty_bundle_license_notices target)
    ubiquitty_license_notice_paths(notices)
    foreach(notice IN LISTS notices)
        get_filename_component(directory "${notice}" DIRECTORY)
        if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
            # A top-level Resources directory makes codesign interpret a shallow
            # iOS bundle as a different layout. Keep the entire linked notice
            # hierarchy under one ordinary resource directory instead.
            set(directory "Licenses/${directory}")
        endif()
        ubiquitty_license_notice_file("${notice}" noticeFile)
        ubiquitty_bundle_resources(${target} "${directory}" "${noticeFile}")
    endforeach()

    # The staged set is checked against the inventory after every build, on
    # every generator: a resource rule that silently builds nothing ships an
    # app without its licences, and only the finished bundle can show that.
    ubiquitty_bundle_resource_root(${target} noticeRoot)
    if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
        string(APPEND noticeRoot "/Licenses")
    endif()
    # FindPython's executable variable is scoped to the function that found
    # it, so the check finds the interpreter for itself.
    find_package(Python3 COMPONENTS Interpreter REQUIRED)
    get_property(script GLOBAL PROPERTY UBIQUITTY_LICENSE_NOTICE_SCRIPT)
    set(coreArguments)
    if(DEFINED UBIQUITTY_CORE_SOURCE_DIR)
        set(coreArguments --core "${UBIQUITTY_CORE_SOURCE_DIR}")
    endif()
    # Not VERBATIM: under Xcode the bundle directory is spelled with a build
    # setting the phase's shell has to expand.
    add_custom_command(TARGET ${target} POST_BUILD
        COMMAND "${Python3_EXECUTABLE}" "${script}"
            --source "${CMAKE_SOURCE_DIR}" ${coreArguments} --verify "${noticeRoot}"
        COMMENT "Checking ${target}'s bundled licence notices")
endfunction()
