if(NOT TARGET rapidhash::rapidhash)
  add_library(rapidhash::rapidhash INTERFACE IMPORTED GLOBAL)
  target_include_directories(rapidhash::rapidhash INTERFACE ${CMAKE_CURRENT_LIST_DIR}/../third_party/rapidhash)
endif()
