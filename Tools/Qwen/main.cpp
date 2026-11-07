#include "transcribe.h"
#include "json.hpp"
#include "../AudioInput.h"
#include <fstream>
#include <iostream>
#include <vector>
#include <cstring>
#include <cmath>
using json=nlohmann::json;
int main(int argc, char** argv) {
    if (argc != 2) return 2;
    transcribe_model* model = nullptr;
    transcribe_session* session = nullptr;
    bool cpu = false;
    auto release = [&] {
        transcribe_session_free(session); session = nullptr;
        transcribe_model_free(model); model = nullptr;
    };
    auto load = [&](bool useCPU) {
        release(); cpu = useCPU;
        transcribe_model_load_params mp; transcribe_model_load_params_init(&mp);
        mp.backend = useCPU ? TRANSCRIBE_BACKEND_CPU : TRANSCRIBE_BACKEND_METAL;
        if (transcribe_model_load_file(argv[1], &mp, &model) != TRANSCRIBE_OK) return false;
        transcribe_session_params sp; transcribe_session_params_init(&sp);
        sp.n_threads = 4; sp.n_ctx = 2048;
        return transcribe_session_init(model, &sp, &session) == TRANSCRIBE_OK;
    };
    if (!load(false)) { release(); std::cout << "{\"ready\":false}" << std::endl; return 3; }
    std::cout << "{\"ready\":true}" << std::endl;
    std::string line;
    while (std::getline(std::cin, line)) {
        try {
            auto request = json::parse(line);
            const int skip = request.value("skip_samples", 0);
            auto samples = recognition_audio(request.at("file"), skip);
            double mean = 0, power = 0;
            for (float v : samples) mean += v;
            if (!samples.empty()) mean /= samples.size();
            for (float v : samples) power += (v-mean)*(v-mean);
            if (samples.empty() || std::sqrt(power/samples.size()) < 0.000015) {
                std::cout << json({{"text", ""}}).dump() << std::endl; continue;
            }
            bool retry = request.value("retry", false) && skip == 0;
            if (cpu != retry && !load(retry)) throw std::runtime_error("model load failed");
            transcribe_run_params rp; transcribe_run_params_init(&rp);
            const auto language = request.value("language", std::string("ko"));
            rp.language = language.c_str(); rp.timestamps = TRANSCRIBE_TIMESTAMPS_NONE;
            const auto status = transcribe_run(session, samples.data(), (int)samples.size(), &rp);
            if (status != TRANSCRIBE_OK || transcribe_was_truncated(session)) throw std::runtime_error("decode failed");
            std::cout << json({{"text", transcribe_full_text(session)}}).dump() << std::endl;
        } catch (...) { std::cout << "{\"error\":\"local transcription failed\"}" << std::endl; }
    }
    release(); return 0;
}
