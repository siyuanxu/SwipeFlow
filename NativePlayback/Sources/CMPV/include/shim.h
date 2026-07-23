#ifndef SWIPEFLOW_CMPV_SHIM_H
#define SWIPEFLOW_CMPV_SHIM_H

#include <dlfcn.h>
#include <mpv/client.h>
#include <mpv/render.h>
#include <mpv/render_gl.h>

static inline unsigned long swipeflow_mpv_compiled_client_api_version(void) {
    return MPV_CLIENT_API_VERSION;
}

static inline void *swipeflow_mpv_opengl_get_proc_address(
    void *context,
    const char *name
) {
    (void)context;
    return dlsym(RTLD_DEFAULT, name);
}

static inline int swipeflow_mpv_create_opengl_render_context(
    mpv_render_context **result,
    mpv_handle *handle
) {
    mpv_opengl_init_params open_gl = {
        .get_proc_address = swipeflow_mpv_opengl_get_proc_address,
        .get_proc_address_ctx = NULL,
    };
    const char *api_type = MPV_RENDER_API_TYPE_OPENGL;
    mpv_render_param parameters[] = {
        { MPV_RENDER_PARAM_API_TYPE, (void *)api_type },
        { MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &open_gl },
        { MPV_RENDER_PARAM_INVALID, NULL },
    };
    return mpv_render_context_create(result, handle, parameters);
}

static inline int swipeflow_mpv_render_opengl_frame(
    mpv_render_context *context,
    int framebuffer,
    int width,
    int height
) {
    mpv_opengl_fbo frame_buffer = {
        .fbo = framebuffer,
        .w = width,
        .h = height,
        .internal_format = 0,
    };
    int flip_y = 1;
    int block_for_target_time = 0;
    mpv_render_param parameters[] = {
        { MPV_RENDER_PARAM_OPENGL_FBO, &frame_buffer },
        { MPV_RENDER_PARAM_FLIP_Y, &flip_y },
        { MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, &block_for_target_time },
        { MPV_RENDER_PARAM_INVALID, NULL },
    };
    return mpv_render_context_render(context, parameters);
}

#endif
