#include "WWWhisperNative.h"
#include "whisper.h"
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

static double elapsed_seconds(struct timespec start, struct timespec end) {
    return (double) (end.tv_sec - start.tv_sec) +
           (double) (end.tv_nsec - start.tv_nsec) / 1000000000.0;
}

int32_t ww_whisper_classify_token_timing(int32_t enabled, int64_t t0, int64_t t1) {
    return enabled == 1 && t0 >= 0 && t1 > t0 ? 1 : 0;
}

static WWTokenTimingObservation observe_tokens(struct whisper_context *context, int32_t enabled) {
    WWTokenTimingObservation observation = { 0 };
    const int segments = whisper_full_n_segments(context);
    for (int i = 0; i < segments; ++i) {
        int previous_text_token = 0;
        int previous_ended_in_whitespace = 0;
        const int tokens = whisper_full_n_tokens(context, i);
        observation.token_count += tokens;
        for (int j = 0; j < tokens; ++j) {
            if (whisper_full_get_token_id(context, i, j) >= whisper_token_eot(context)) {
                previous_text_token = 0;
                continue;
            }
            const unsigned char *text =
                (const unsigned char *) whisper_full_get_token_text(context, i, j);
            if (!text || !*text) {
                previous_text_token = 0;
                continue;
            }
            int has_non_whitespace = 0;
            int internal_whitespace = 0;
            int whitespace_after_content = 0;
            int ended_in_whitespace = 0;
            for (const unsigned char *p = text; *p; ++p) {
                ended_in_whitespace = isspace(*p) != 0;
                internal_whitespace |= whitespace_after_content && !ended_in_whitespace;
                whitespace_after_content |= has_non_whitespace && ended_in_whitespace;
                has_non_whitespace |= !ended_in_whitespace;
            }
            if (!has_non_whitespace) {
                previous_text_token = 0;
                continue;
            }
            ++observation.text_token_count;
            observation.leading_whitespace_token_count += isspace(*text) != 0;
            observation.internal_whitespace_token_count += internal_whitespace;
            observation.unseparated_adjacent_token_count +=
                previous_text_token && !previous_ended_in_whitespace && !isspace(*text);
            previous_text_token = 1;
            previous_ended_in_whitespace = ended_in_whitespace;
            if (enabled == 1) {
                const whisper_token_data token = whisper_full_get_token_data(context, i, j);
                if (ww_whisper_classify_token_timing(enabled, token.t0, token.t1)) {
                    ++observation.experimental_text_token_count;
                } else {
                    ++observation.absent_text_token_count;
                }
            } else {
                ++observation.absent_text_token_count;
            }
        }
    }
    return observation;
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
    full_params.token_timestamps = false;
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
        result.disabled_token_timing = observe_tokens(context, 0);
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
        full_params.token_timestamps = true;
        clock_gettime(CLOCK_MONOTONIC, &before);
        const int enabled_status = whisper_full(context, full_params, pcm, sample_count);
        clock_gettime(CLOCK_MONOTONIC, &after);
        result.enabled_inference_seconds = elapsed_seconds(before, after);
        if (enabled_status == 0) {
            result.enabled_token_timing = observe_tokens(context, 1);
        } else {
            result.inferred = 0;
        }
    }
    whisper_free(context);
    return result;
}

static pthread_mutex_t inference_lock = PTHREAD_MUTEX_INITIALIZER;

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
    for (int32_t i = 0; i < transcript->segment_count; ++i) {
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

WWNativeTranscript ww_whisper_infer_pcm(
    void *model_bytes, size_t model_size, const float *pcm, int32_t sample_count,
    int32_t (*cancelled)(void *), void *cancel_context
) {
    WWNativeTranscript result = { .status = WW_INFERENCE_INVALID_INPUT };
    if (!cancelled) return result;
    if (cancelled(cancel_context)) {
        result.status = WW_INFERENCE_CANCELLED;
        return result;
    }
    if (!model_bytes || model_size != 77704715 || !pcm || sample_count != 32000) return result;
    for (int32_t i = 0; i < sample_count; ++i) {
        if (!isfinite(pcm[i]) || fabsf(pcm[i]) > 1.0f) return result;
    }
    if (pthread_mutex_lock(&inference_lock) != 0) {
        result.status = WW_INFERENCE_FAILED;
        return result;
    }
    if (cancelled(cancel_context)) {
        result.status = WW_INFERENCE_CANCELLED;
        goto unlock;
    }

    whisper_log_set(discard_probe_log, NULL);
    struct whisper_context_params context_params = whisper_context_default_params();
    context_params.use_gpu = false;
    context_params.flash_attn = false;
    context_params.dtw_token_timestamps = false;
    struct whisper_context *context = whisper_init_from_buffer_with_params(model_bytes, model_size, context_params);
    if (!context) {
        result.status = cancelled(cancel_context) ? WW_INFERENCE_CANCELLED : WW_INFERENCE_LOAD_FAILED;
        goto unlock;
    }
    if (cancelled(cancel_context)) {
        result.status = WW_INFERENCE_CANCELLED;
        goto release_context;
    }

    struct cancel_state cancel_state = { cancelled, cancel_context };
    struct whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.n_threads = 2;
    params.language = "en";
    params.duration_ms = 2000;
    params.no_context = true;
    params.no_timestamps = false;
    params.token_timestamps = false;
    params.single_segment = true;
    params.max_tokens = 16;
    params.greedy.best_of = 1;
    params.temperature_inc = 0.0f;
    params.print_progress = false;
    params.print_realtime = false;
    params.print_timestamps = false;
    params.print_special = false;
    params.abort_callback = abort_inference;
    params.abort_callback_user_data = &cancel_state;
    const int status = whisper_full(context, params, pcm, sample_count);
    if (cancelled(cancel_context)) {
        result.status = WW_INFERENCE_CANCELLED;
        goto release_context;
    }
    if (status != 0) {
        result.status = WW_INFERENCE_FAILED;
        goto release_context;
    }
    const int count = whisper_full_n_segments(context);
    if (count < 0 || count > 16) {
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
    result.status = cancelled(cancel_context) ? WW_INFERENCE_CANCELLED : WW_INFERENCE_OK;

release_context:
    whisper_free(context);
    if (result.status != WW_INFERENCE_OK) ww_whisper_free_transcript(&result);
unlock:
    pthread_mutex_unlock(&inference_lock);
    return result;
}
