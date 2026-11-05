#include "whisper.h"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <vector>

// Keep the existing whisper.cpp version and its public API. v1.8.2 resets
// recurrent state on every detect call, so replay a bounded history rather than
// mistakenly treating independent 32 ms calls as stateful streaming inference.
struct Detector {
    whisper_vad_context * context = nullptr;
    std::vector<float> history;
    ~Detector() { if (context) whisper_vad_free(context); }
};

extern "C" void * tq_vad_create(const char * path) {
    try {
        whisper_log_set([](enum ggml_log_level level, const char * text, void *) {
            if (level >= GGML_LOG_LEVEL_WARN) std::fputs(text, stderr);
        }, nullptr);
        auto params = whisper_vad_default_context_params();
        params.use_gpu = false;
        params.n_threads = 1;
        auto context = whisper_vad_init_from_file_with_params(path, params);
        if (!context) return nullptr;
        auto detector = new Detector;
        detector->context = context;
        return detector;
    } catch (...) { return nullptr; }
}

extern "C" void tq_vad_destroy(void * handle) { delete static_cast<Detector *>(handle); }
extern "C" void tq_vad_reset(void * handle) {
    if (handle) static_cast<Detector *>(handle)->history.clear();
}

// One probability for each 512 samples, in chronological order. No audio is
// filtered or returned: the Swift segmenter retains the original PCM.
extern "C" int tq_vad_process(void * handle, const float * samples, int count, float * output) {
    if (!handle || !samples || !output || count <= 0 || count > 4096 || count % 512) return -1;
    try {
        auto & d = *static_cast<Detector *>(handle);
        std::vector<float> audio = d.history;
        audio.insert(audio.end(), samples, samples + count);
        if (!whisper_vad_detect_speech(d.context, audio.data(), int(audio.size()))) return -1;
        const int n = whisper_vad_n_probs(d.context), wanted = count / 512;
        const auto probs = whisper_vad_probs(d.context);
        if (!probs || n != int(audio.size() / 512)) return -1;
        for (int i = 0; i < wanted; ++i) {
            const float p = probs[n - wanted + i];
            if (!std::isfinite(p) || p < 0 || p > 1) return -1;
            output[i] = p;
        }
        // 896 ms of left context + 128 ms of new audio at normal call size.
        const size_t keep = std::min(size_t(14336), audio.size());
        d.history.assign(audio.end() - keep, audio.end());
        return wanted;
    } catch (...) { return -1; }
}
