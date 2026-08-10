#include "ezeesti_whisper.h"

#include "whisper.h"

#include <pthread.h>
#include <stdio.h>
#include <string.h>

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static struct whisper_context *g_ctx = NULL;

static void set_err(char *err, int err_len, const char *msg) {
    if (!err || err_len <= 0) return;
    snprintf(err, (size_t)err_len, "%s", msg ? msg : "unknown error");
}

int ezeesti_whisper_is_loaded(void) {
    pthread_mutex_lock(&g_lock);
    int loaded = g_ctx != NULL;
    pthread_mutex_unlock(&g_lock);
    return loaded;
}

void ezeesti_whisper_unload(void) {
    pthread_mutex_lock(&g_lock);
    if (g_ctx) {
        whisper_free(g_ctx);
        g_ctx = NULL;
    }
    pthread_mutex_unlock(&g_lock);
}

int ezeesti_whisper_load(const char *lib_dir, const char *model_path, char *err, int err_len) {
    (void)lib_dir;
    if (!model_path) {
        set_err(err, err_len, "model_path required");
        return -1;
    }

    pthread_mutex_lock(&g_lock);
    if (g_ctx) {
        pthread_mutex_unlock(&g_lock);
        return 0;
    }

    struct whisper_context_params cparams = whisper_context_default_params();
    cparams.use_gpu = true;
    struct whisper_context *ctx = whisper_init_from_file_with_params(model_path, cparams);
    if (!ctx) {
        set_err(err, err_len, "whisper_init_from_file_with_params failed");
        pthread_mutex_unlock(&g_lock);
        return -1;
    }
    g_ctx = ctx;
    pthread_mutex_unlock(&g_lock);
    return 0;
}

int ezeesti_whisper_transcribe(
    const float *samples,
    int n_samples,
    const char *language,
    const char *initial_prompt,
    char *out,
    int out_len,
    char *err,
    int err_len
) {
    if (!samples || n_samples <= 0 || !out || out_len <= 0) {
        set_err(err, err_len, "invalid transcribe args");
        return -1;
    }
    out[0] = '\0';

    pthread_mutex_lock(&g_lock);
    if (!g_ctx) {
        set_err(err, err_len, "whisper not loaded");
        pthread_mutex_unlock(&g_lock);
        return -1;
    }

    struct whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.print_progress = false;
    params.print_realtime = false;
    params.print_special = false;
    params.print_timestamps = false;
    params.no_timestamps = true;
    params.suppress_nst = true;
    params.temperature = 0.0f;
    params.temperature_inc = 0.0f;
    // Lower than stock 0.6 so quiet mic / short Estonian clips are less often dropped as silence.
    params.no_speech_thold = 0.45f;
    params.entropy_thold = 2.4f;
    params.max_len = 0;
    params.language = language ? language : "et";
    params.detect_language = false;
    params.initial_prompt = initial_prompt;
    params.n_threads = 4;
    // Prefer multi-segment for longer spoken summaries.
    params.single_segment = false;

    int rc = whisper_full(g_ctx, params, samples, n_samples);
    if (rc != 0) {
        set_err(err, err_len, "whisper_full failed");
        pthread_mutex_unlock(&g_lock);
        return -1;
    }

    int n = whisper_full_n_segments(g_ctx);
    size_t used = 0;
    for (int i = 0; i < n; i++) {
        const char *seg = whisper_full_get_segment_text(g_ctx, i);
        if (!seg) continue;
        size_t len = strlen(seg);
        if (used + len + 1 >= (size_t)out_len) break;
        memcpy(out + used, seg, len);
        used += len;
    }
    out[used] = '\0';
    pthread_mutex_unlock(&g_lock);
    return 0;
}
