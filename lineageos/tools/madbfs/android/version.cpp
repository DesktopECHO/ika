// What upstream's CMake generates from madbfs-common/cmake/version.cpp.in;
// keep the version in step with madbfs-common/cmake/version.cmake.
#include "madbfs-gen/version.hpp"

namespace madbfs::version
{
    const char* get_version_full()
    {
        return "0.12.0.1";
    }

    const char* get_version_base()
    {
        return "0.12.0.1";
    }

    const char* get_git_hash()
    {
        return "";
    }
}
