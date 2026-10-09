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
    int32_t loaded;
    int32_t inferred;
    int32_t sample_count;
    int32_t threads;
    int32_t segment_count;
    int32_t word_count;
    int32_t segment_timing_available;
    double load_seconds;
    double inference_seconds;
} WWTinyPCMProbeResult;

// Only the separate headless probe invokes this. The caller validates the complete model bytes first.
WWTinyPCMProbeResult ww_whisper_tiny_pcm_probe(void *model_bytes, size_t model_size);

#endif
