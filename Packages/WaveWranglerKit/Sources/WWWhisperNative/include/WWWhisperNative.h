#ifndef WW_WHISPER_NATIVE_H
#define WW_WHISPER_NATIVE_H

#include <stdint.h>

typedef struct {
    int32_t linked;
    int32_t synthetic_frame_count;
    float synthetic_energy;
    int32_t recognized_word_count;
    int32_t inference_available;
} WWWhisperCPUProbeResult;

// No arguments, source paths, media, models or inference are accepted by this diagnostic.
WWWhisperCPUProbeResult ww_whisper_cpu_probe(void);

#endif
