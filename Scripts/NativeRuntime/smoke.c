#include <mpv/client.h>

#include <stdio.h>

static int set_option(mpv_handle *handle, const char *name, const char *value) {
    const int result = mpv_set_option_string(handle, name, value);
    if (result < 0) {
        fprintf(stderr, "libmpv rejected option %s (%d)\n", name, result);
    }
    return result;
}

int main(void) {
    const unsigned long version = mpv_client_api_version();
    if ((version >> 16) != (MPV_CLIENT_API_VERSION >> 16)) {
        fputs("libmpv client API major version mismatch\n", stderr);
        return 1;
    }

    mpv_handle *handle = mpv_create();
    if (!handle) {
        fputs("libmpv client creation failed\n", stderr);
        return 1;
    }

    const char *options[][2] = {
        {"config", "no"},
        {"terminal", "no"},
        {"vo", "null"},
        {"ao", "null"},
        {"sid", "no"},
        {"secondary-sid", "no"},
        {"sub-auto", "no"},
        {"sub-visibility", "no"},
        {"idle", "yes"},
    };

    for (unsigned long index = 0; index < sizeof(options) / sizeof(options[0]); ++index) {
        if (set_option(handle, options[index][0], options[index][1]) < 0) {
            mpv_terminate_destroy(handle);
            return 1;
        }
    }

    const int result = mpv_initialize(handle);
    mpv_terminate_destroy(handle);
    if (result < 0) {
        fprintf(stderr, "libmpv initialization failed (%d)\n", result);
        return 1;
    }

    puts("Packaged libmpv smoke test passed.");
    return 0;
}
