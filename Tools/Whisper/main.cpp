#include "whisper.h"
#include "convert-komix.h"
#include "json.hpp"
#include "../AudioInput.h"
#include <fstream>
#include <iostream>
#include <vector>
#include <cstring>
#include <algorithm>
#include <cmath>
#include <memory>
#include <cctype>
using json=nlohmann::json;
int main(int argc,char** argv){
    if(argc==5 && std::string(argv[1])=="--convert-komix") {
        try {
            komix::convert(argv[2],argv[3],argv[4]);
            auto cp=whisper_context_default_params(); cp.use_gpu=false;
            auto ctx=whisper_init_from_file_with_params(argv[4],cp);
            if(!ctx) return 5;
            whisper_free(ctx); return 0;
        } catch (...) { std::remove(argv[4]); return 4; }
    }
    if(argc!=2 && argc!=3)return 2;
    std::unique_ptr<whisper_vad_context, decltype(&whisper_vad_free)> vad(nullptr, whisper_vad_free);
    if (argc == 3) { auto vp=whisper_vad_default_context_params(); vp.use_gpu=false; vp.n_threads=1; vad.reset(whisper_vad_init_from_file_with_params(argv[2],vp)); }
    auto cp=whisper_context_default_params();cp.use_gpu=true;
    whisper_context* ctx=whisper_init_from_file_with_params(argv[1],cp);
    if(!ctx){std::cout<<"{\"ready\":false}"<<std::endl;return 3;}
    std::cout<<"{\"ready\":true}"<<std::endl;
    std::string line;
    while(std::getline(std::cin,line)){
        try{
            auto request = json::parse(line);
            const int skip = request.value("skip_samples", 0);
            auto samples = recognition_audio(request.at("file"), skip);
            // Remove only DC bias for the measurement, never modify audio sent to Whisper.
            double mean=0, power=0;
            for(float v:samples) mean+=v;
            if(!samples.empty()) mean/=samples.size();
            for(float v:samples) power+=(v-mean)*(v-mean);
            const double rms=samples.empty()?0:std::sqrt(power/samples.size());
            if(rms<0.000015) { std::cout<<json({{"text",""},{"segments",json::array()},{"no_speech",true}}).dump()<<std::endl; continue; }
            bool vadKnown=false, vadSpeech=false;
            if(vad && whisper_vad_detect_speech(vad.get(),samples.data(),(int)samples.size())) {
                vadKnown=true; int voicedFrames=0;
                auto probs=whisper_vad_probs(vad.get());
                for(int i=0;i<whisper_vad_n_probs(vad.get());i++) if(probs[i]>=0.5f) voicedFrames++;
                vadSpeech=voicedFrames>=3;
            }
            const bool retry = request.value("retry", false);
            auto p = whisper_full_default_params(retry ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY);
            if (retry) p.beam_search.beam_size = 3;
            const auto language = request.value("language", std::string("en"));
            p.language = language.c_str();
            p.n_threads = 4;
            p.translate = false;
            p.no_context = true;
            p.token_timestamps = request.value("with_timestamps", false);
            p.print_realtime = false;
            p.print_progress = false;
            p.print_timestamps = false;
            p.print_special = false;
            p.suppress_blank = true;
            p.suppress_nst = true;
            p.temperature_inc = 0;
            p.no_speech_thold = 0.6f;
            p.logprob_thold = -1.0f;
            if(whisper_full(ctx,p,samples.data(),(int)samples.size())!=0)throw std::runtime_error("decode failed");
            std::string text;json segments=json::array(), words=json::array();
            float maxNoSpeech=0;
            for(int i=0;i<whisper_full_n_segments(ctx);i++){
                const float noSpeech=whisper_full_get_segment_no_speech_prob(ctx,i);
                maxNoSpeech=std::max(maxNoSpeech,noSpeech);
                double logprob=0; int tokens=0;
                for(int j=0;j<whisper_full_n_tokens(ctx,i);j++) {
                    auto token=whisper_full_get_token_data(ctx,i,j);
                    if(token.id<whisper_token_eot(ctx)) { logprob+=token.plog; tokens++; }
                }
                // Combine confidence signals; do not blacklist normal thank-you speech.
                if(noSpeech>0.85f || (noSpeech>0.6f && tokens>0 && logprob/tokens < -1.0))continue;
                std::string t=whisper_full_get_segment_text(ctx,i);text+=t;segments.push_back({{"text",t},{"start",whisper_full_get_segment_t0(ctx,i)/100.0},{"end",whisper_full_get_segment_t1(ctx,i)/100.0}});
                if(p.token_timestamps) {
                    std::string word; double start=-1, end=-1;
                    auto flush=[&] { if(!word.empty()) words.push_back({{"text",word},{"start",start},{"end",end}}); word.clear(); start=-1; end=-1; };
                    for(int j=0;j<whisper_full_n_tokens(ctx,i);j++) {
                        auto token=whisper_full_get_token_data(ctx,i,j);
                        if(token.id>=whisper_token_eot(ctx)) continue;
                        const std::string piece=whisper_full_get_token_text(ctx,i,j);
                        if(!piece.empty() && std::isspace((unsigned char)piece[0]) && !word.empty()) flush();
                        if(word.empty()) start=token.t0/100.0;
                        word+=piece; end=token.t1/100.0;
                    }
                    flush();
                }
            }
            std::string compact;
            for(unsigned char c:text) if(!std::isspace(c) && !(c<128 && std::ispunct(c))) compact+=(char)c;
            const bool canned=compact=="감사합니다" || compact=="고맙습니다" || compact=="시청해주셔서감사합니다";
            if(language=="ko" && canned && vadKnown && !vadSpeech) { text.clear(); segments=json::array(); words=json::array(); }
            std::cout<<json({{"text",text},{"segments",segments},{"words",words}}).dump(-1, ' ', false, json::error_handler_t::replace)<<std::endl;
        }catch(...){std::cout<<"{\"error\":\"local transcription failed\"}"<<std::endl;}
    }
    whisper_free(ctx);return 0;
}
