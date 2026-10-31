# libfuse 3 from the distribution, under the target name madbfs expects.
find_package(PkgConfig REQUIRED)
pkg_check_modules(FUSE3 REQUIRED IMPORTED_TARGET GLOBAL fuse3)
if(NOT TARGET libfuse::libfuse)
  add_library(libfuse::libfuse INTERFACE IMPORTED GLOBAL)
  target_link_libraries(libfuse::libfuse INTERFACE PkgConfig::FUSE3)
endif()
