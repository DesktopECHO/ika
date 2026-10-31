# spdlog and fmt, header-only from third_party: distributions ship versions
# older than madbfs needs (fmt 11).
if(NOT TARGET spdlog::spdlog)
  add_library(spdlog::spdlog INTERFACE IMPORTED GLOBAL)
  target_include_directories(spdlog::spdlog INTERFACE
    ${CMAKE_CURRENT_LIST_DIR}/../third_party/spdlog/include
    ${CMAKE_CURRENT_LIST_DIR}/../third_party/fmt/include)
  target_compile_definitions(spdlog::spdlog INTERFACE SPDLOG_HEADER_ONLY SPDLOG_FMT_EXTERNAL FMT_HEADER_ONLY)
endif()
