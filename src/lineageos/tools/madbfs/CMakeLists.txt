# Builds the madbfs client for ika-base: the distribution's Boost (1.88 or
# later) and libfuse 3, with everything else from third_party. The server,
# madbfs-server, is built by Android.bp into the ROM.
cmake_minimum_required(VERSION 3.22)
# upstream's find_package(Boost) calls use module mode; this makes them use
# Boost's own config files, as CMake 3.30 and later does by default for new
# projects. A default, because upstream's cmake_minimum_required resets policies.
set(CMAKE_POLICY_DEFAULT_CMP0167 NEW)
include(upstream/madbfs-common/cmake/version.cmake)
project(madbfs-ika VERSION ${MADBFS_PROJECT_VERSION} LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(MADBFS_THIRD_PARTY ${CMAKE_CURRENT_SOURCE_DIR}/third_party)
set(libfuse_DIR ${CMAKE_CURRENT_SOURCE_DIR}/cmake)
set(rapidhash_DIR ${CMAKE_CURRENT_SOURCE_DIR}/cmake)
set(spdlog_DIR ${CMAKE_CURRENT_SOURCE_DIR}/cmake)

# Boost.Process is compiled in from third_party: Debian does not package the
# library, and its headers come first so every distribution builds the same
# version.
find_package(Boost 1.88 CONFIG REQUIRED COMPONENTS json filesystem program_options)
file(GLOB_RECURSE MADBFS_BOOST_PROCESS_SOURCES CONFIGURE_DEPENDS ${MADBFS_THIRD_PARTY}/boost-process/src/*.cpp)
add_library(madbfs-boost-process STATIC ${MADBFS_BOOST_PROCESS_SOURCES})
target_include_directories(madbfs-boost-process BEFORE PUBLIC ${MADBFS_THIRD_PARTY}/boost-process/include)
target_link_libraries(madbfs-boost-process PUBLIC Boost::headers Boost::filesystem)

# madbfs links Boost::boost and boost::boost, as Conan names them.
add_library(madbfs-boost INTERFACE)
target_link_libraries(madbfs-boost INTERFACE madbfs-boost-process Boost::headers Boost::json Boost::filesystem
  Boost::program_options)
set_property(TARGET Boost::boost APPEND PROPERTY INTERFACE_LINK_LIBRARIES madbfs-boost)
add_library(boost::boost ALIAS madbfs-boost)

set(MADBFS_ENABLE_TESTS OFF CACHE BOOL "" FORCE)
add_subdirectory(upstream)
