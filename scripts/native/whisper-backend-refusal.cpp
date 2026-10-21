#include <cmath>
#include <fstream>
#include <iostream>
#include <vector>
extern "C" {
#include "../../Packages/WaveWranglerKit/Sources/WWWhisperNative/include/WWWhisperNative.h"
}

static int32_t not_canceled(void *) { return 0; }

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    std::ifstream input(argv[1], std::ios::binary | std::ios::ate);
    if (!input || input.tellg() != 147964211) return 2;
    std::vector<char> model(147964211);
    input.seekg(0);
    if (!input.read(model.data(), model.size())) return 2;
    std::vector<float> pcm(32000);
    for (size_t i = 0; i < pcm.size(); ++i) pcm[i] = .01f * std::sin(i * 440.0 * 6.28318530718 / 16000);
    auto invalid = ww_whisper_infer_window_configured(nullptr, 0, nullptr, 0, {1, 0}, not_canceled, nullptr);
    auto metal = ww_whisper_infer_window_configured(model.data(), model.size(), pcm.data(), pcm.size(),
                                                   {1, 4}, not_canceled, nullptr);
    auto cpu = ww_whisper_infer_window_configured(model.data(), model.size(), pcm.data(), pcm.size(),
                                                 {0, 4}, not_canceled, nullptr);
    const bool passed = invalid.status == WW_INFERENCE_INVALID_INPUT
        && metal.status == WW_INFERENCE_BACKEND_UNAVAILABLE && metal.segment_count == 0
        && cpu.status == WW_INFERENCE_OK;
    std::cout << "No-bundle Metal refusal=" << metal.status << "; explicit CPU retry=" << cpu.status << '\n';
    ww_whisper_free_transcript(&invalid);
    ww_whisper_free_transcript(&metal);
    ww_whisper_free_transcript(&cpu);
    return passed ? 0 : 1;
}
