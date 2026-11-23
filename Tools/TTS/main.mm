#import <Foundation/Foundation.h>
#include <algorithm>
#include <cmath>
#include <iostream>
#include <string>
#include <vector>
#include "sherpa-c-api.h"
#include "Korean.h"

static void send(NSDictionary *message) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:message options:0 error:nullptr];
    std::cout.write(static_cast<const char *>(data.bytes), data.length);
    std::cout << std::endl;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 3 && argc != 4) return 2;
        const std::string root = argv[2];
        const bool korean = std::string(argv[1]) == "meloKO";
        std::unique_ptr<KoreanTTS> koreanModel;
        if (korean) {
            try { koreanModel = std::make_unique<KoreanTTS>(root); }
            catch (...) { send(@{@"type": @"fatal"}); return 1; }
        }
        const bool kokoro = std::string(argv[1]) == "kokoro";
        const std::string model = root + (kokoro ? "/model.int8.onnx" : "/model.onnx");
        const std::string tokens = root + "/tokens.txt";
        const std::string voices = root + "/voices.bin";
        const std::string espeak = root + "/espeak-ng-data";
        const std::string lexicon = kokoro
            ? root + "/lexicon-us-en.txt," + root + "/lexicon-zh.txt"
            : root + "/lexicon.txt";
        const std::string rules = kokoro
            ? root + "/phone-zh.fst," + root + "/date-zh.fst," + root + "/number-zh.fst"
            : root + "/phone.fst," + root + "/date.fst," + root + "/number.fst";
        SherpaOnnxOfflineTtsConfig config{};
        config.model.provider = "cpu";
        config.model.num_threads = argc == 4 ? std::clamp(std::atoi(argv[3]), 1, 4) : 2;
        config.rule_fsts = rules.c_str();
        config.max_num_sentences = 1;
        config.silence_scale = 0.7f;
        if (kokoro) {
            config.model.kokoro.model = model.c_str();
            config.model.kokoro.tokens = tokens.c_str();
            config.model.kokoro.voices = voices.c_str();
            config.model.kokoro.lexicon = lexicon.c_str();
            config.model.kokoro.data_dir = espeak.c_str();
            config.model.kokoro.length_scale = 1.0f;
        } else {
            config.model.vits.model = model.c_str();
            config.model.vits.tokens = tokens.c_str();
            config.model.vits.lexicon = lexicon.c_str();
            config.model.vits.noise_scale = 0.667f;
            config.model.vits.noise_scale_w = 0.8f;
            config.model.vits.length_scale = 1.0f;
        }

        auto *tts = korean ? nullptr : SherpaOnnxCreateOfflineTts(&config);
        if (!tts && !koreanModel) {
            send(@{@"type": @"fatal"});
            return 1;
        }
        send(@{@"type": @"ready", @"model": @{@"sample_rate": @(korean ? 44100 : SherpaOnnxOfflineTtsSampleRate(tts))}});
        std::string line;
        while (std::getline(std::cin, line)) {
            @autoreleasepool {
                NSData *data = [NSData dataWithBytes:line.data() length:line.size()];
                NSDictionary *request = [NSJSONSerialization JSONObjectWithData:data options:0 error:nullptr];
                NSString *identifier = request[@"id"] ?: @"";
                NSString *text = request[@"text"];
                if (text.length == 0) {
                    send(@{@"type": @"error", @"id": identifier});
                    continue;
                }
                SherpaOnnxGenerationConfig options{};
                options.speed = 1.0f;
                options.silence_scale = 0.7f;
                options.sid = [request[@"voice"] intValue];
                std::vector<float> koreanAudio;
                SherpaOnnxGeneratedAudio koreanGenerated{};
                if (koreanModel) {
                    try {
                        koreanAudio = koreanModel->generate(text);
                        koreanGenerated.samples = koreanAudio.data();
                        koreanGenerated.n = (int)koreanAudio.size();
                        koreanGenerated.sample_rate = 44100;
                    } catch (const std::exception &error) {
                        std::cerr << error.what() << std::endl;
                        send(@{@"type": @"error", @"id": identifier});
                        continue;
                    }
                }
                auto *generated = koreanModel ? &koreanGenerated : SherpaOnnxOfflineTtsGenerateWithConfig(tts, text.UTF8String, &options, nullptr, nullptr);
                if (!generated || generated->n <= 0) {
                    if (generated && !koreanModel) SherpaOnnxDestroyOfflineTtsGeneratedAudio(generated);
                    send(@{@"type": @"error", @"id": identifier});
                    continue;
                }
                const int chunkSize = 8192;
                int sequence = 0;
                for (int start = 0; start < generated->n; start += chunkSize) {
                    const int count = std::min(chunkSize, generated->n - start);
                    std::vector<int16_t> pcm(count);
                    for (int i = 0; i < count; ++i) {
                        const float sample = generated->samples[start + i];
                        pcm[i] = std::isfinite(sample) ? std::lround(std::clamp(sample, -1.0f, 1.0f) * 32767) : 0;
                    }
                    NSData *payload = [NSData dataWithBytes:pcm.data() length:pcm.size() * sizeof(int16_t)];
                    send(@{@"type": @"chunk", @"id": identifier, @"seq": @(sequence++),
                           @"pcm": [payload base64EncodedStringWithOptions:0]});
                }
                send(@{@"type": @"end", @"id": identifier, @"samples": @(generated->n), @"stop": @"complete"});
                if (!koreanModel) SherpaOnnxDestroyOfflineTtsGeneratedAudio(generated);
            }
        }
        if (tts) SherpaOnnxDestroyOfflineTts(tts);
    }
}
