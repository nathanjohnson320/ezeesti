#include "ezeesti_llama.h"

#include "llama.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static struct llama_model *g_model = NULL;
static struct llama_context *g_ctx = NULL;
static int g_backend_ready = 0;

static void set_err(char *err, int err_len, const char *msg) {
    if (!err || err_len <= 0) return;
    snprintf(err, (size_t)err_len, "%s", msg ? msg : "unknown error");
}

static void unload_unlocked(void) {
    if (g_ctx) {
        llama_free(g_ctx);
        g_ctx = NULL;
    }
    if (g_model) {
        llama_model_free(g_model);
        g_model = NULL;
    }
}

int ezeesti_llama_is_loaded(void) {
    pthread_mutex_lock(&g_lock);
    int loaded = g_ctx != NULL && g_model != NULL;
    pthread_mutex_unlock(&g_lock);
    return loaded;
}

void ezeesti_llama_unload(void) {
    pthread_mutex_lock(&g_lock);
    unload_unlocked();
    if (g_backend_ready) {
        llama_backend_free();
        g_backend_ready = 0;
    }
    pthread_mutex_unlock(&g_lock);
}

int ezeesti_llama_load(
    const char *lib_dir,
    const char *model_path,
    int n_ctx,
    char *err,
    int err_len
) {
    (void)lib_dir;
    if (!model_path) {
        set_err(err, err_len, "model_path required");
        return -1;
    }
    if (n_ctx <= 0) n_ctx = 2048;

    pthread_mutex_lock(&g_lock);
    if (g_ctx && g_model) {
        pthread_mutex_unlock(&g_lock);
        return 0;
    }
    unload_unlocked();

    if (!g_backend_ready) {
        llama_backend_init();
        g_backend_ready = 1;
    }

    struct llama_model_params mparams = llama_model_default_params();
    mparams.n_gpu_layers = 99;

    struct llama_model *model = llama_model_load_from_file(model_path, mparams);
    if (!model) {
        set_err(err, err_len, "llama_model_load_from_file failed");
        pthread_mutex_unlock(&g_lock);
        return -1;
    }

    struct llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx = (uint32_t)n_ctx;
    cparams.n_batch = 512;
    cparams.n_threads = 4;
    cparams.n_threads_batch = 4;

    struct llama_context *ctx = llama_init_from_model(model, cparams);
    if (!ctx) {
        llama_model_free(model);
        set_err(err, err_len, "llama_init_from_model failed");
        pthread_mutex_unlock(&g_lock);
        return -1;
    }

    g_model = model;
    g_ctx = ctx;
    pthread_mutex_unlock(&g_lock);
    return 0;
}

int ezeesti_llama_complete(
    const char *prompt,
    int n_predict,
    float temperature,
    char *out,
    int out_len,
    char *err,
    int err_len
) {
    if (!prompt || !out || out_len <= 0) {
        set_err(err, err_len, "invalid complete args");
        return -1;
    }
    out[0] = '\0';
    if (n_predict <= 0) n_predict = 128;

    pthread_mutex_lock(&g_lock);
    if (!g_ctx || !g_model) {
        set_err(err, err_len, "llama not loaded");
        pthread_mutex_unlock(&g_lock);
        return -1;
    }

    const struct llama_vocab *vocab = llama_model_get_vocab(g_model);
    if (!vocab) {
        set_err(err, err_len, "llama_model_get_vocab failed");
        pthread_mutex_unlock(&g_lock);
        return -1;
    }

    const int prompt_len = (int)strlen(prompt);
    const int n_tokens_max = (int)llama_n_ctx(g_ctx);
    llama_token *tokens = (llama_token *)malloc((size_t)n_tokens_max * sizeof(llama_token));
    if (!tokens) {
        set_err(err, err_len, "OOM tokenizing");
        pthread_mutex_unlock(&g_lock);
        return -1;
    }

    // Prompts already include Llama-3.1 `<|begin_of_text|>` (BOS). Asking
    // tokenize to add_special would double-BOS and spam check_double_bos_eos.
    int n_tokens = llama_tokenize(vocab, prompt, prompt_len, tokens, n_tokens_max, false, true);
    if (n_tokens < 0) {
        free(tokens);
        set_err(err, err_len, "llama_tokenize failed (prompt too long?)");
        pthread_mutex_unlock(&g_lock);
        return -1;
    }

    llama_memory_clear(llama_get_memory(g_ctx), true);

    for (int i = 0; i < n_tokens; i++) {
        llama_token tok = tokens[i];
        struct llama_batch batch = llama_batch_get_one(&tok, 1);
        if (llama_decode(g_ctx, batch) != 0) {
            free(tokens);
            set_err(err, err_len, "llama_decode failed on prompt");
            pthread_mutex_unlock(&g_lock);
            return -1;
        }
    }
    free(tokens);

    struct llama_sampler_chain_params sparams = llama_sampler_chain_default_params();
    struct llama_sampler *smpl = llama_sampler_chain_init(sparams);
    if (temperature <= 0.0f) {
        llama_sampler_chain_add(smpl, llama_sampler_init_greedy());
    } else {
        llama_sampler_chain_add(smpl, llama_sampler_init_temp(temperature));
        llama_sampler_chain_add(smpl, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));
    }

    size_t used = 0;
    for (int i = 0; i < n_predict; i++) {
        llama_token id = llama_sampler_sample(smpl, g_ctx, -1);
        llama_sampler_accept(smpl, id);
        if (llama_vocab_is_eog(vocab, id)) break;

        char piece[256];
        int n = llama_token_to_piece(vocab, id, piece, (int)sizeof(piece), 0, true);
        if (n < 0) {
            int need = -n;
            if (need < (int)sizeof(piece)) {
                n = llama_token_to_piece(vocab, id, piece, need, 0, true);
            } else {
                n = 0;
            }
        }
        if (n > 0) {
            if (used + (size_t)n + 1 >= (size_t)out_len) break;
            memcpy(out + used, piece, (size_t)n);
            used += (size_t)n;
            out[used] = '\0';
        }

        struct llama_batch batch = llama_batch_get_one(&id, 1);
        if (llama_decode(g_ctx, batch) != 0) {
            llama_sampler_free(smpl);
            set_err(err, err_len, "llama_decode failed during generation");
            pthread_mutex_unlock(&g_lock);
            return -1;
        }
    }

    llama_sampler_free(smpl);
    pthread_mutex_unlock(&g_lock);
    return 0;
}
