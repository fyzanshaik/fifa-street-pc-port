# fifastreet - ReXGlue Recompiled Project
#
# SDK boilerplate lives in generated/rexglue.cmake.

cmake_minimum_required(VERSION 3.25)
project(fifastreet LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(generated/rexglue.cmake)

# The SDK sets REXGLUE_ROOT in its own subdirectory scope, so the value does not
# reach this consumer scope. The macOS Vulkan staging helper reads it to locate
# cmake/MoltenVK_icd.json; without it the copy source collapses to
# "/cmake/MoltenVK_icd.json" and the host POST_BUILD step fails. Re-derive it
# from REXSDK_DIR (the source tree the SDK was added from). APPLE-guarded, so
# the Windows path is unaffected; the find_package flow uses its own ICD path.
if(APPLE AND NOT REXGLUE_ROOT AND REXSDK_DIR)
    set(REXGLUE_ROOT "${REXSDK_DIR}")
endif()

# Sources
set(FIFASTREET_SOURCES
    src/main.cpp
)

if(WIN32)
    enable_language(RC)
    add_executable(fifastreet WIN32 ${FIFASTREET_SOURCES})
    target_sources(fifastreet PRIVATE src/fifastreet.rc)

    if(CMAKE_CXX_COMPILER_ID MATCHES "Clang")
        set_source_files_properties(src/fifastreet.rc PROPERTIES
            COMPILE_OPTIONS "/nologo"
        )
        target_include_directories(fifastreet PRIVATE
            "${CMAKE_CURRENT_SOURCE_DIR}/src"
        )
    endif()
else()
    add_executable(fifastreet ${FIFASTREET_SOURCES})
endif()

rexglue_setup_target(fifastreet GPU_PLUGINS xenos)
target_include_directories(fifastreet PRIVATE src)

# macOS guest-startup ordering fix. The recompiled entrypoint's sub_820509A8
# spawns its worker before it constructs the events the worker signals on, so on
# a multicore host the worker reads the still-NULL members (guest read of 0x4).
# config/default_overrides.toml [[midasm_hook]]s hoist the two constructions
# ahead of the spawn by calling the helpers in src/guest_start_events.cpp, which
# is linked into the host that carries the entrypoint recompiled module. Only
# the macOS manifest enables those hooks (the Windows manifest keeps
# entrypoint includes empty), so this stays off the Windows build.
if(APPLE)
    target_sources(fifastreet PRIVATE
        src/guest_start_events.cpp
        src/guest_frame_capture.cpp
        src/control_bridge_server.cpp
        src/control_bridge.cpp
    )
endif()

# The source SDK keeps ImGui private to rexruntime; its public UI headers
# still require the include directory when compiling the host application.
# Propagate headers only, keeping the ImGui objects in the shared runtime.
if(TARGET imgui::imgui)
    target_include_directories(fifastreet PRIVATE
        $<TARGET_PROPERTY:imgui::imgui,INTERFACE_INCLUDE_DIRECTORIES>)
endif()

# Guest SIMD code must be optimized even when using the debug runtime. Keep
# debug symbols and checked runtime libraries while avoiding unoptimized SIMD
# wrappers in the game and its separately compiled DLL.
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
    target_compile_options(fifastreet PRIVATE -O2)
    if(TARGET fifastreet_recomp)
        target_compile_options(fifastreet_recomp PRIVATE -O2)
    endif()
endif()

# FIFA Street DLL-specific kernel stubs.
if(TARGET fifastreet_fifadllzf_xex)
    if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
        target_compile_options(fifastreet_fifadllzf_xex PRIVATE -O2)
    endif()
    target_sources(fifastreet_fifadllzf_xex PRIVATE
        src/stubs.cpp
    )
endif()

# World Tour competition engine DLL. Keep it optimized, but do not attach
# fifadllzf-specific stubs to this independent guest module.
if(TARGET fifastreet_FootballCompEngzf_xex)
    if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
        target_compile_options(fifastreet_FootballCompEngzf_xex PRIVATE -O2)
    endif()
endif()

# Generated registration and init tables pack every entry into a single
# translation unit (fifadllzf is ~8 MB, ~159k statements in one function).
# Even -O1 is pathological on that (tens of minutes in the backend), so compile
# these data-only tables at -O0. -O0 changes the __OPTIMIZE__ macro, so the
# module's precompiled header no longer matches; skip the PCH for these units
# too. No hot code lives in them, and the Windows path keeps its own settings.
if(APPLE)
    file(GLOB _rexglue_generated_tables
        "${CMAKE_CURRENT_SOURCE_DIR}/generated/*/fifastreet_register.cpp"
        "${CMAKE_CURRENT_SOURCE_DIR}/generated/*/fifastreet_init.cpp")
    if(_rexglue_generated_tables)
        set_source_files_properties(${_rexglue_generated_tables}
            PROPERTIES
                COMPILE_OPTIONS "-O0"
                SKIP_PRECOMPILE_HEADERS ON)
    endif()
endif()
