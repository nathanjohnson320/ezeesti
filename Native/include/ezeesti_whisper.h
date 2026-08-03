#ifndef EZEESTI_WHISPER_H
#define EZEESTI_WHISPER_H

#ifdef __cplusplus
extern "C" {
#endif

/// `lib_dir` is unused when linked into the umbrella dylib; kept for a stable API.
int ezeesti_whisper_load(const char *lib_dir, const char *model_path, char *err, int err_len);
void ezeesti_whisper_unload(void);
int ezeesti_whisper_is_loaded(void);
int ezeesti_whisper_transcribe(
    const float *samples,
    int n_samples,
    const char *language,
    const char *initial_prompt,
    char *out,
    int out_len,
    char *err,
    int err_len
);

#ifdef __cplusplus
}
#endif

#endif
