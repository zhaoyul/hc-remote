cmake_minimum_required(VERSION 3.24)
project(hc_remote VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

include(FetchContent)

option(HCR_LINK_STATIC "Statically link libdatachannel/OpenSSL and the C++ runtime" OFF)

set(NO_MEDIA ON CACHE BOOL "" FORCE)
set(NO_EXAMPLES ON CACHE BOOL "" FORCE)
set(NO_TESTS ON CACHE BOOL "" FORCE)
set(NO_WEBSOCKET OFF CACHE BOOL "" FORCE)
if(WIN32 OR HCR_LINK_STATIC)
  # DLL builds of libdatachannel export std::vector<std::byte> template
  # instantiations which collide with consumer objects (LNK2005); static
  # linking also makes the binaries portable across distros.
  set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
else()
  set(BUILD_SHARED_LIBS ON CACHE BOOL "" FORCE)
endif()

FetchContent_Declare(
  libdatachannel
  GIT_REPOSITORY https://github.com/paullouisageneau/libdatachannel.git
  GIT_TAG v0.24.6
  GIT_SHALLOW TRUE
  GIT_SUBMODULES_RECURSE TRUE
)

find_package(nlohmann_json 3.11.3 QUIET)
if(NOT nlohmann_json_FOUND)
  message(STATUS "nlohmann_json not found on system, fetching via FetchContent")
  FetchContent_Declare(
    nlohmann_json
    GIT_REPOSITORY https://github.com/nlohmann/json.git
    GIT_TAG v3.12.0
    GIT_SHALLOW TRUE
  )
  FetchContent_MakeAvailable(nlohmann_json)
endif()
FetchContent_MakeAvailable(libdatachannel)

set(HCR_NATIVE_SOURCES
  native/src/c_api.cpp
  native/src/event_queue.cpp
  native/src/file_transfer.cpp
  native/src/frame_codec.cpp
  native/src/peer.cpp
  native/src/session.cpp
  native/src/signaling.cpp
)
if(WIN32 OR HCR_LINK_STATIC)
  add_library(hcr_native STATIC ${HCR_NATIVE_SOURCES})
else()
  add_library(hcr_native SHARED ${HCR_NATIVE_SOURCES})
endif()
target_include_directories(hcr_native PUBLIC native/include)
target_link_libraries(hcr_native PUBLIC
  LibDataChannel::LibDataChannel
  nlohmann_json::nlohmann_json
)
if(MSVC)
  target_compile_options(hcr_native PRIVATE /W4)
else()
  target_compile_options(hcr_native PRIVATE -Wall -Wextra -Wpedantic)
endif()

add_executable(hc-remote-signal native/src/signal_server.cpp)
target_link_libraries(hc-remote-signal PRIVATE
  LibDataChannel::LibDataChannel
  nlohmann_json::nlohmann_json
)

add_executable(hc-remote-peer native/src/peer_main.cpp)
target_link_libraries(hc-remote-peer PRIVATE hcr_native)

if(HCR_LINK_STATIC AND NOT APPLE AND NOT WIN32)
  target_link_options(hc-remote-signal PRIVATE -static-libstdc++ -static-libgcc)
  target_link_options(hc-remote-peer PRIVATE -static-libstdc++ -static-libgcc)
endif()
