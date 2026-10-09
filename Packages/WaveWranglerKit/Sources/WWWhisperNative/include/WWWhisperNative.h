#ifndef WW_WHISPER_NATIVE_H
#define WW_WHISPER_NATIVE_H

#include <stdint.h>
#include <stddef.h>

typedef struct {
    int32_t linked;
    int32_t synthetic_frame_count;
    float synthetic_energy;
    int32_t recognized_word_count;
    int32_t inference_available;
} WWWhisperCPUProbeResult;

// No arguments, source paths, media, models or inference are accepted by this diagnostic.
WWWhisperCPUProbeResult ww_whisper_cpu_probe(void);

typedef struct {
    int32_t token_count;
    int32_t text_token_count;
    int32_t absent_text_token_count;
    int32_t experimental_text_token_count;
    int32_t leading_whitespace_token_count;
    int32_t internal_whitespace_token_count;
    int32_t unseparated_adjacent_token_count;
} WWTokenTimingObservation;

// 0 = absent/invalid, 1 = experimental/unsupported. Neither is a word boundary.
// Enabled token times may have been interpolated or adjusted by upstream code.
int32_t ww_whisper_classify_token_timing(int32_t enabled, int64_t t0, int64_t t1);

// DTW reports a token point in 10 ms ticks, NOT an interval or word boundary.
// 0 = absent/invalid/out of the generated two-second window, 1 = experimental/unsupported.
int32_t ww_whisper_classify_dtw_point(int32_t enabled, int64_t point);

typedef struct {
    int32_t loaded;
    int32_t inferred;
    int32_t sample_count;
    int32_t threads;
    int32_t segment_count;
    int32_t word_count;
    int32_t segment_timing_available;
    double load_seconds;
    double inference_seconds;
    double enabled_inference_seconds;
    double dtw_load_seconds;
    double dtw_inference_seconds;
    int32_t dtw_inferred;
    WWTokenTimingObservation disabled_token_timing;
    WWTokenTimingObservation enabled_token_timing;
    WWTokenTimingObservation dtw_token_timing;
} WWTinyPCMProbeResult;

// Only the separate headless probe invokes this on generated PCM after model validation.
// Both modes have DTW disabled; observations are never source-frame word timings.
WWTinyPCMProbeResult ww_whisper_tiny_pcm_probe(void *model_bytes, size_t model_size);

// Third pass is opt-in and refuses any preset other than the pinned tiny.en heads.
// The caller must verify the tiny.en model descriptor before invoking this ABI.
WWTinyPCMProbeResult ww_whisper_tiny_pcm_probe_with_dtw(
    void *model_bytes, size_t model_size, const char *alignment_head_preset
);

// This lower-level ABI has no source reader. Call only after verifying the pinned
// model and validating exactly two seconds of caller-owned 16 kHz mono PCM.
typedef enum {
    WW_INFERENCE_OK = 0,
    WW_INFERENCE_INVALID_INPUT = 1,
    WW_INFERENCE_LOAD_FAILED = 2,
    WW_INFERENCE_CANCELLED = 3,
    WW_INFERENCE_FAILED = 4,
} WWInferenceStatus;

typedef struct {
    char *text;
    int64_t t0;
    int64_t t1;
} WWNativeSegment;

typedef struct {
    WWInferenceStatus status;
    int32_t segment_count;
    WWNativeSegment *segments;
} WWNativeTranscript;

WWNativeTranscript ww_whisper_infer_pcm(
    void *model_bytes, size_t model_size, const float *pcm, int32_t sample_count,
    int32_t (*cancelled)(void *), void *cancel_context
);
void ww_whisper_free_transcript(WWNativeTranscript *transcript);

#endif
