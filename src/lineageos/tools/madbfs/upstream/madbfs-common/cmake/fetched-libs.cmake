# Ika: saf is vendored in third_party/saf rather than downloaded.
add_library(saf INTERFACE)
target_include_directories(saf INTERFACE ${CMAKE_CURRENT_LIST_DIR}/../../../third_party/saf/include)
add_library(fetch::saf ALIAS saf)
