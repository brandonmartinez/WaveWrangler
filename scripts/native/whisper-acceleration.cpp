// Bounded research harness, using the production engine and decoding recipe.
#include "../../Packages/WaveWranglerKit/Sources/WWWhisperNative/upstream/whisper.cpp"
#include <atomic>
#include <chrono>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <mutex>
#include <sstream>
#include <thread>
#include <sys/resource.h>

using Clock = std::chrono::steady_clock;
static std::mutex initialization;
static double seconds(Clock::time_point start) {
    return std::chrono::duration<double>(Clock::now() - start).count();
}
static std::string quoted(const char *text) {
    std::ostringstream out;
    out << '"';
    for (const unsigned char *p = (const unsigned char *)text; *p; ++p) {
        if (*p == '"' || *p == '\\') out << '\\' << *p;
        else if (*p < 32) out << "\\u" << std::hex << std::setw(4) << std::setfill('0') << int(*p);
        else out << *p;
    }
    out << '"';
    return out.str();
}
template <typename T> static std::vector<T> read(const char *path) {
    std::ifstream file(path, std::ios::binary | std::ios::ate);
    if (!file) throw std::runtime_error("Cannot open input");
    const auto size = file.tellg();
    if (size <= 0 || size % sizeof(T)) throw std::runtime_error("Invalid input size");
    std::vector<T> data(size / sizeof(T));
    file.seekg(0);
    if (!file.read((char *)data.data(), size)) throw std::runtime_error("Incomplete input");
    return data;
}
static void log_callback(ggml_log_level, const char *text, void *) { std::cerr << text; }
struct Abort {
    Clock::time_point start;
    int milliseconds;
};
static bool abort_callback(void *raw) {
    const auto *abort = (const Abort *)raw;
    return abort->milliseconds > 0 && seconds(abort->start) * 1000 >= abort->milliseconds;
}

int main(int argc, char **argv) {
    try {
        if (argc < 8) throw std::runtime_error("MODEL cpu|metal THREADS WORKERS ROUNDS CANCEL_MS PCM...");
        const bool gpu = std::string(argv[2]) == "metal";
        if (!gpu && std::string(argv[2]) != "cpu") throw std::runtime_error("Invalid backend");
        const int threads = std::stoi(argv[3]), workers = std::stoi(argv[4]);
        const int rounds = std::stoi(argv[5]), cancel_ms = std::stoi(argv[6]);
        if (threads < 1 || threads > 8 || workers < 1 || workers > 4 || rounds < 1 || rounds > 3)
            throw std::runtime_error("Unbounded configuration");
        const auto model_start = Clock::now();
        auto bytes = read<char>(argv[1]);
        const double read_seconds = seconds(model_start);
        std::vector<std::vector<float>> clips;
        for (int i = 7; i < argc; ++i) {
            auto pcm = read<float>(argv[i]);
            if (pcm.size() < 1600 || pcm.size() > 480000) throw std::runtime_error("Unbounded PCM");
            for (float sample : pcm) if (!std::isfinite(sample) || std::abs(sample) > 1)
                throw std::runtime_error("Invalid PCM");
            clips.push_back(std::move(pcm));
        }
        whisper_log_set(log_callback, nullptr);
        std::cout << "{\"model_read_seconds\":" << read_seconds << ",\"rounds\":[";
        for (int round = 0; round < rounds; ++round) {
            const auto started = Clock::now();
            std::atomic<size_t> cursor(0);
            std::vector<std::string> results(clips.size());
            std::atomic<bool> failed(false);
            std::vector<std::thread> tasks;
            for (int worker = 0; worker < workers; ++worker) tasks.emplace_back([&] {
                size_t index;
                while ((index = cursor.fetch_add(1)) < clips.size()) {
                    try {
                        const auto start = Clock::now();
                        whisper_context_params cp = whisper_context_default_params();
                        cp.use_gpu = gpu;
                        cp.flash_attn = false;
                        cp.dtw_token_timestamps = false;
                        whisper_context *ctx;
                        {
                            std::lock_guard<std::mutex> lock(initialization);
                            ctx = whisper_init_from_buffer_with_params_no_state(bytes.data(), bytes.size(), cp);
                            if (!ctx) throw std::runtime_error("Model load failed");
#ifdef WHISPER_USE_COREML
                            ctx->path_model = argv[1];
#endif
                            ctx->state = whisper_init_state(ctx);
                        }
                        if (!ctx->state || (gpu != bool(ggml_backend_is_metal(ctx->backend)))) {
                            whisper_free(ctx);
                            throw std::runtime_error("Requested backend unavailable (no substitution)");
                        }
                        const double load = seconds(start);
                        whisper_full_params p = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH);
                        p.n_threads = threads;
                        p.language = "en";
                        p.duration_ms = (clips[index].size() + 15) / 16;
                        p.no_context = true;
                        p.no_timestamps = false;
                        p.token_timestamps = true;
                        p.single_segment = false;
                        p.max_tokens = 0;
                        p.greedy.best_of = 5;
                        p.beam_search.beam_size = 5;
                        p.max_len = 1;
                        p.split_on_word = true;
                        p.initial_prompt = "Um, uh, well, I, I mean, you know, like, sort of.";
                        p.temperature_inc = 0;
                        p.print_progress = p.print_realtime = p.print_timestamps = p.print_special = false;
                        Abort abort{Clock::now(), cancel_ms};
                        p.abort_callback = abort_callback;
                        p.abort_callback_user_data = &abort;
                        const int status = whisper_full(ctx, p, clips[index].data(), clips[index].size());
                        const double inference = seconds(abort.start);
                        std::ostringstream out;
                        out << "{\"index\":" << index << ",\"load_seconds\":" << load
                            << ",\"inference_seconds\":" << inference << ",\"status\":" << status
                            << ",\"cancel_requested\":" << (abort_callback(&abort) ? "true" : "false")
                            << ",\"segments\":[";
                        for (int j = 0; status == 0 && j < whisper_full_n_segments(ctx); ++j) {
                            if (j) out << ',';
                            out << "{\"text\":" << quoted(whisper_full_get_segment_text(ctx, j))
                                << ",\"start\":" << whisper_full_get_segment_t0(ctx, j) / 100.0
                                << ",\"end\":" << whisper_full_get_segment_t1(ctx, j) / 100.0 << '}';
                        }
                        out << "]}";
                        whisper_free(ctx);
                        results[index] = out.str();
                    } catch (const std::exception &error) {
                        std::cerr << error.what() << '\n';
                        failed = true;
                    }
                }
            });
            for (auto &task : tasks) task.join();
            if (failed) return 2;
            rusage usage;
            getrusage(RUSAGE_SELF, &usage);
            if (round) std::cout << ',';
            std::cout << "{\"wall_seconds\":" << seconds(started) << ",\"peak_rss_bytes\":" << usage.ru_maxrss
                      << ",\"clips\":[";
            for (size_t i = 0; i < results.size(); ++i) {
                if (i) std::cout << ',';
                std::cout << results[i];
            }
            std::cout << "]}" << std::flush;
        }
        std::cout << "]}\n";
        return 0;
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
