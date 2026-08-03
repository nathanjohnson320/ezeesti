#ifndef EZEESTI_LLAMA_H
#define EZEESTI_LLAMA_H

#ifdef __cplusplus
extern "C" {
#endif

int ezeesti_llama_load(
    const char *lib_dir,
    const char *model_path,
    int n_ctx,
    char *err,
    int err_len
);
void ezeesti_llama_unload(void);
int ezeesti_llama_is_loaded(void);
int ezeesti_llama_complete(
    const char *prompt,
    int n_predict,
    float temperature,
    char *out,
    int out_len,
    char *err,
    int err_len
);

#ifdef __cplusplus
}
#endif

#endif
