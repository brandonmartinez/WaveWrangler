#include "WWWhisperNative.h"
#include "whisper.h"
#include <ctype.h>
#include <math.h>
#include <time.h>

WWWhisperCPUProbeResult ww_whisper_cpu_probe(void) {
    const float generated[] = { 0.0f, 0.25f, -0.25f, 0.0f };
    float energy = 0.0f;
    for (int i = 0; i < 4; ++i) {
        energy += generated[i] * generated[i];
    }
    return (WWWhisperCPUProbeResult) {
        .linked = whisper_lang_id("en") == 0,
        .synthetic_frame_count = 4,
        .synthetic_energy = energy,
        .recognized_word_count = 0,
        .inference_available = 0,
    };
}

static void discard_probe_log(enum ggml_log_level level, const char *text, void *user_data) {
    (void) level;
    (void) text;
    (void) user_data;
}

static double elapsed_seconds(struct timespec start, struct timespec end) {
    return (double) (end.tv_sec - start.tv_sec) +
           (double) (end.tv_nsec - start.tv_nsec) / 1000000000.0;
}

WWTinyPCMProbeResult ww_whisper_tiny_pcm_probe(void *model_bytes, size_t model_size) {
    WWTinyPCMProbeResult result = { 0 };
    if (!model_bytes || model_size != 77704715) {
        return result;
    }

    // The probe runs in its own executable; suppress upstream model and recognition diagnostics.
    whisper_log_set(discard_probe_log, NULL);
    struct whisper_context_params context_params = whisper_context_default_params();
    context_params.use_gpu = false;
    context_params.flash_attn = false;
    context_params.dtw_token_timestamps = false;
    struct timespec before, after;
    clock_gettime(CLOCK_MONOTONIC, &before);
    struct whisper_context *context = whisper_init_from_buffer_with_params(model_bytes, model_size, context_params);
    clock_gettime(CLOCK_MONOTONIC, &after);
    result.load_seconds = elapsed_seconds(before, after);
    if (!context) {
        return result;
    }
    result.loaded = 1;

    enum { sample_count = 32000, thread_count = 2 };
    float pcm[sample_count];
    for (int i = 0; i < sample_count; ++i) {
        pcm[i] = 0.1f * sinf((float) i * (2.0f * 3.14159265358979323846f * 440.0f / 16000.0f));
    }
    struct whisper_full_params full_params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    full_params.n_threads = thread_count;
    full_params.language = "en";
    full_params.duration_ms = 2000;
    full_params.no_context = true;
    full_params.no_timestamps = false;
    full_params.single_segment = true;
    full_params.max_tokens = 16;
    full_params.greedy.best_of = 1;
    full_params.temperature_inc = 0.0f;
    full_params.print_progress = false;
    full_params.print_realtime = false;
    full_params.print_timestamps = false;
    full_params.print_special = false;
    result.sample_count = sample_count;
    result.threads = thread_count;
    clock_gettime(CLOCK_MONOTONIC, &before);
    const int status = whisper_full(context, full_params, pcm, sample_count);
    clock_gettime(CLOCK_MONOTONIC, &after);
    result.inference_seconds = elapsed_seconds(before, after);
    if (status == 0) {
        result.inferred = 1;
        result.segment_count = whisper_full_n_segments(context);
        result.segment_timing_available = result.segment_count > 0;
        for (int i = 0; i < result.segment_count; ++i) {
            if (whisper_full_get_segment_t1(context, i) <= whisper_full_get_segment_t0(context, i)) {
                result.segment_timing_available = 0;
            }
            const char *text = whisper_full_get_segment_text(context, i);
            int in_word = 0;
            for (const unsigned char *p = (const unsigned char *) text; p && *p; ++p) {
                if (isspace(*p)) {
                    in_word = 0;
                } else if (!in_word) {
                    ++result.word_count;
                    in_word = 1;
                }
            }
        }
    }
    whisper_free(context);
    return result;
}
