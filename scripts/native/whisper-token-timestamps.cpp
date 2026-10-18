// Include the actual private routine without adding a diagnostic API to the app.
#include "../../Packages/WaveWranglerKit/Sources/WWWhisperNative/upstream/whisper.cpp"

#include <iostream>

static bool check_case(int count, bool end_special, bool active, bool begin_timestamp) {
    whisper_context context {};
    whisper_state state {};
    context.vocab.id_to_token[0] = " um";
    context.vocab.id_to_token[context.vocab.token_eot] = "[end]";
    context.vocab.id_to_token[context.vocab.token_beg] = "[begin]";
    state.energy.assign(WHISPER_SAMPLE_RATE, active ? 1.0f : 0.0f);
    state.tid_last = context.vocab.token_beg;
    whisper_segment segment { 0, 50, " um", {}, false };
    for (int index = 0; index < count; ++index) {
        whisper_token_data token {};
        token.id = end_special && index == count - 1 ? context.vocab.token_eot : 0;
        if (begin_timestamp && index == 0) token.id = context.vocab.token_beg;
        token.tid = context.vocab.token_beg;
        token.t0 = -1;
        token.t1 = -1;
        segment.tokens.push_back(token);
    }
    state.result_all.push_back(segment);
    whisper_exp_compute_token_level_timestamps(context, state, 0, 0.01f, 0.01f);
    const auto & tokens = state.result_all[0].tokens;
    if (tokens.size() != static_cast<size_t>(count)) return false;
    for (size_t index = 0; index < tokens.size(); ++index) {
        const auto & token = tokens[index];
        if (token.t0 < 0 || token.t1 < token.t0 || token.t1 > 100) return false;
        if (index + 1 < tokens.size() && token.t1 > tokens[index + 1].t0) return false;
    }
    return true;
}

int main() {
    int cases = 0;
    for (int count = 0; count < 10; ++count) {
        for (bool end_special : { false, true }) {
            for (bool active : { false, true }) {
                for (bool begin_timestamp : { false, true }) {
                    if (!check_case(count, end_special, active, begin_timestamp)) {
                        std::cerr << "Invalid timestamps: tokens=" << count << " end_special=" << end_special
                                  << " active=" << active << " begin_timestamp=" << begin_timestamp << "\n";
                        return 1;
                    }
                    ++cases;
                }
            }
        }
    }
    std::cout << cases << " generated token-timestamp cases passed (no model or recording)\n";
}
