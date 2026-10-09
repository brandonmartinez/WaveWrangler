#include "WWWhisperNative.h"
#include "whisper.h"

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
