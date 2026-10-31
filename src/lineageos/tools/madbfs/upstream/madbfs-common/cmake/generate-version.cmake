set(MADBFS_VERSION_FULL "${CMAKE_PROJECT_VERSION}")

configure_file(
  ${CMAKE_CURRENT_LIST_DIR}/version.hpp.in
  ${CMAKE_BINARY_DIR}/generated/madbfs-gen/version.hpp
  @ONLY
)
configure_file(
  ${CMAKE_CURRENT_LIST_DIR}/version.cpp.in
  ${CMAKE_BINARY_DIR}/generated/madbfs-gen/version.cpp
  @ONLY
)

add_library(madbfs-version STATIC)
target_sources(
  madbfs-version
  PRIVATE ${CMAKE_BINARY_DIR}/generated/madbfs-gen/version.cpp
)
target_include_directories(madbfs-version PUBLIC ${CMAKE_BINARY_DIR}/generated/)
