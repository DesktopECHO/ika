#include "madbfs/args.hpp"
#include "madbfs/cmd.hpp"
#include "madbfs/operations.hpp"

#include <madbfs-common/log.hpp>
#include <madbfs-gen/version.hpp>

#include <exception>

using namespace madbfs;

void termination()
{
    if (auto e = std::current_exception(); e != nullptr) {
        try {
            std::rethrow_exception(e);
        } catch (const std::exception& e) {
            log_c(__func__, "> Uncaught exception:\n{}", e.what());
        } catch (...) {
            log_c(__func__, "> Uncaught exception (unknown type)");
        }
    }
    log_c(__func__, "> Terminating");
    log::shutdown();
    std::abort();
}

Await<int> push(const args::PushOpt&)
{
    fmt::println(stderr, "error: the Ika ROM ships madbfs-server at /system_ext/bin; there is nothing to push");
    co_return 1;
}

int mount(const args::MountOpt& opt)
{
    if (not log::init(opt.log_level, opt.log_file)) {
        return 1;
    }

    fmt::println("[madbfs] version is {}", version::get_version_full());
    if (opt.caching) {
        fmt::println(
            "[madbfs] mount '{}@{}' [cache={} MiB, page={} KiB]",
            opt.serial,
            opt.root,
            opt.caching->cachesize,
            opt.caching->pagesize
        );
    } else {
        fmt::println("[madbfs] mount '{}@{}' [no cache]", opt.serial, opt.root);
    }

    if (opt.log_file != "-") {
        log_i(__func__, "[madbfs] version is {}", version::get_version_full());
        if (opt.caching) {
            log_i(
                __func__,
                "[madbfs] mount '{}@{}' at '{}' with cache size {} MiB and page size {} KiB",
                opt.serial,
                opt.root,
                opt.mount,
                opt.caching->cachesize,
                opt.caching->pagesize
            );
        } else {
            log_i(
                __func__,
                "[madbfs] mount '{}@{}' at '{}' with cache disabled",
                opt.serial,
                opt.root,
                opt.mount
            );
        }
    }

    fmt::println("[madbfs] unmount with 'fusermount -u {:?}'", opt.mount);

    if (::setenv("ANDROID_SERIAL", opt.serial.c_str(), 1) < 0) {
        fmt::println(stderr, "error: failed to set env variable 'ANDROID_SERIAL' ({})", strerror(errno));
        return 1;
    }

    const auto args = opt.args.inner();
    return fuse_main(args.argc, args.argv, &operations::operations, (void*)&opt);
}

int main(int argc, char** argv)
try {
    std::set_terminate(termination);

    auto context = async::Context{};
    auto parsed  = async::once(context, args::parse(argc, argv));

    context.restart();

    return parsed.visit(Overload{
        [&](const args::MountOpt& opt) { return mount(opt); },
        [&](const args::PushOpt& opt) { return async::once(context, push(opt)); },
        [](int ret) { return ret; },
    });
} catch (const std::exception& e) {
    fmt::println(stderr, "error: exception occurred: {}", e.what());
    return 1;
} catch (...) {
    fmt::println(stderr, "error: exception occurred (unknown exception)");
    return 1;
}
