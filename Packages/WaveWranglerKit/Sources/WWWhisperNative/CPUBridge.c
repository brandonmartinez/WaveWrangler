#include "WWWhisperNative.h"
#include "whisper.h"
#ifdef GGML_USE_METAL
#include "ggml-metal.h"
#endif
#include <ctype.h>
#include <math.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
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

static pthread_once_t logging_once = PTHREAD_ONCE_INIT;
static pthread_mutex_t context_init_lock = PTHREAD_MUTEX_INITIALIZER;

static void configure_logging(void) {
    whisper_log_set(discard_probe_log, NULL);
#ifdef GGML_USE_METAL
    ggml_backend_metal_log_set_callback(discard_probe_log, NULL);
#endif
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
    if (pthread_once(&logging_once, configure_logging) != 0) return result;
    struct whisper_context_params context_params = whisper_context_default_params();
    context_params.use_gpu = false;
    context_params.flash_attn = false;
    context_params.dtw_token_timestamps = false;
    struct timespec before, after;
    clock_gettime(CLOCK_MONOTONIC, &before);
    if (pthread_mutex_lock(&context_init_lock) != 0) return result;
    struct whisper_context *context = whisper_init_from_buffer_with_params(model_bytes, model_size, context_params);
    pthread_mutex_unlock(&context_init_lock);
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

struct cancel_state {
    int32_t (*check)(void *);
    void *user_data;
};

static bool abort_inference(void *context) {
    struct cancel_state *state = context;
    return state->check && state->check(state->user_data) != 0;
}

void ww_whisper_free_transcript(WWNativeTranscript *transcript) {
    if (!transcript) return;
    for (int32_t i = 0; transcript->segments && i < transcript->segment_count; ++i) {
        if (transcript->segments[i].text) {
            const size_t length = strlen(transcript->segments[i].text);
            memset(transcript->segments[i].text, 0, length);
            free(transcript->segments[i].text);
        }
    }
    free(transcript->segments);
    transcript->segments = NULL;
    transcript->segment_count = 0;
}

static WWNativeTranscript infer_pcm(
    void *model_bytes, size_t model_size, const float *pcm, int32_t sample_count,
    int32_t (*canceled)(void *), void *cancel_context, int window, WWWhisperConfiguration configuration
) {
    WWNativeTranscript result = { .status = WW_INFERENCE_INVALID_INPUT };
    if (!canceled || configuration.threads < 1 || configuration.threads > 8 ||
        (configuration.use_metal != 0 && configuration.use_metal != 1)) return result;
    if (canceled(cancel_context)) {
        result.status = WW_INFERENCE_CANCELED;
        return result;
    }
    if (!model_bytes || !pcm) return result;
    if (window) {
        if ((model_size != 147964211 && model_size != 487614201 &&
             model_size != 574041195 && model_size != 1081140203) ||
            sample_count < 1600 || sample_count > 480000) return result;
    } else if (model_size != 77704715 || sample_count != 32000) return result;
    for (int32_t i = 0; i < sample_count; ++i) {
        if (!isfinite(pcm[i]) || fabsf(pcm[i]) > 1.0f) return result;
    }
    if (pthread_once(&logging_once, configure_logging) != 0 ||
        pthread_mutex_lock(&context_init_lock) != 0) {
        result.status = WW_INFERENCE_FAILED;
        return result;
    }
    if (canceled(cancel_context)) {
        result.status = WW_INFERENCE_CANCELED;
        pthread_mutex_unlock(&context_init_lock);
        return result;
    }

    struct whisper_context_params context_params = whisper_context_default_params();
    context_params.use_gpu = configuration.use_metal != 0;
    context_params.flash_attn = false;
    context_params.dtw_token_timestamps = false;
    struct whisper_context *context = whisper_init_from_buffer_with_params(model_bytes, model_size, context_params);
    // Upstream initializes shared FFT/backend tables here. Decode uses independent contexts.
    pthread_mutex_unlock(&context_init_lock);
    if (!context) {
        result.status = canceled(cancel_context) ? WW_INFERENCE_CANCELED :
            (configuration.use_metal ? WW_INFERENCE_BACKEND_UNAVAILABLE : WW_INFERENCE_LOAD_FAILED);
        return result;
    }
    if (whisper_uses_metal(context) != configuration.use_metal) {
        result.status = WW_INFERENCE_BACKEND_UNAVAILABLE;
        goto release_context;
    }
    if (canceled(cancel_context)) {
        result.status = WW_INFERENCE_CANCELED;
        goto release_context;
    }

    struct cancel_state cancel_state = { canceled, cancel_context };
    struct whisper_full_params params = whisper_full_default_params(
        window ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY);
    params.n_threads = configuration.threads;
    params.language = "en";
    params.duration_ms = (sample_count + 15) / 16;
    params.no_context = true;
    params.no_timestamps = false;
    params.token_timestamps = window != 0;
    params.single_segment = window == 0;
    params.max_tokens = window ? 0 : 16;
    params.greedy.best_of = window ? 5 : 1;
    params.beam_search.beam_size = window ? 5 : -1;
    params.max_len = window ? 1 : 0;
    params.split_on_word = window != 0;
    params.initial_prompt = window ? "Um, uh, well, I, I mean, you know, like, sort of." : NULL;
    params.temperature_inc = 0.0f;
    params.print_progress = false;
    params.print_realtime = false;
    params.print_timestamps = false;
    params.print_special = false;
    params.abort_callback = abort_inference;
    params.abort_callback_user_data = &cancel_state;
    const int status = whisper_full(context, params, pcm, sample_count);
    if (canceled(cancel_context)) {
        result.status = WW_INFERENCE_CANCELED;
        goto release_context;
    }
    if (status != 0) {
        result.status = WW_INFERENCE_FAILED;
        goto release_context;
    }
    const int count = whisper_full_n_segments(context);
    if (count < 0 || count > (window ? 2048 : 16)) {
        result.status = WW_INFERENCE_FAILED;
        goto release_context;
    }
    if (count) {
        result.segments = calloc((size_t) count, sizeof(WWNativeSegment));
        if (!result.segments) {
            result.status = WW_INFERENCE_FAILED;
            goto release_context;
        }
    }
    result.segment_count = count;
    for (int i = 0; i < count; ++i) {
        const char *text = whisper_full_get_segment_text(context, i);
        if (!text) {
            result.status = WW_INFERENCE_FAILED;
            goto release_context;
        }
        const size_t length = strnlen(text, 4097);
        if (length > 4096) {
            result.status = WW_INFERENCE_FAILED;
            goto release_context;
        }
        result.segments[i].text = malloc(length + 1);
        if (!result.segments[i].text) {
            result.status = WW_INFERENCE_FAILED;
            goto release_context;
        }
        memcpy(result.segments[i].text, text, length + 1);
        result.segments[i].t0 = whisper_full_get_segment_t0(context, i);
        result.segments[i].t1 = whisper_full_get_segment_t1(context, i);
    }
    result.status = canceled(cancel_context) ? WW_INFERENCE_CANCELED : WW_INFERENCE_OK;

release_context:
    whisper_free(context);
    if (result.status != WW_INFERENCE_OK) ww_whisper_free_transcript(&result);
    return result;
}

WWNativeTranscript ww_whisper_infer_pcm(
    void *model_bytes, size_t model_size, const float *pcm, int32_t sample_count,
    int32_t (*canceled)(void *), void *cancel_context
) {
    return infer_pcm(model_bytes, model_size, pcm, sample_count, canceled, cancel_context, 0,
        (WWWhisperConfiguration) { .use_metal = 0, .threads = 2 });
}

WWNativeTranscript ww_whisper_infer_window(
    void *model_bytes, size_t model_size, const float *pcm, int32_t sample_count,
    int32_t (*canceled)(void *), void *cancel_context
) {
    return infer_pcm(model_bytes, model_size, pcm, sample_count, canceled, cancel_context, 1,
        (WWWhisperConfiguration) { .use_metal = 0, .threads = 4 });
}

WWNativeTranscript ww_whisper_infer_window_configured(
    void *model_bytes, size_t model_size, const float *pcm, int32_t sample_count,
    WWWhisperConfiguration configuration, int32_t (*canceled)(void *), void *cancel_context
) {
    return infer_pcm(model_bytes, model_size, pcm, sample_count, canceled, cancel_context, 1, configuration);
}
