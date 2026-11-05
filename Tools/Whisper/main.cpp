#include "whisper.h"
#include "json.hpp"
#include <fstream>
#include <iostream>
#include <vector>
#include <cstring>
#include <algorithm>
using json=nlohmann::json;
static unsigned u16(const unsigned char* p){return p[0]|(p[1]<<8);}
static unsigned u32(const unsigned char* p){return u16(p)|(u16(p+2)<<16);}
static std::vector<float> audio(const std::string& path){
    std::ifstream f(path,std::ios::binary);unsigned char h[12];if(!f.read((char*)h,12)||memcmp(h,"RIFF",4)||memcmp(h+8,"WAVE",4))throw std::runtime_error("invalid wav");
    unsigned rate=0,bits=0,channels=0,format=0;
    while(f.read((char*)h,8)){
        unsigned size=u32(h+4);if(size>100000000)throw std::runtime_error("wav too large");
        if(!memcmp(h,"fmt ",4)){std::vector<unsigned char> b(size);if(size<16||!f.read((char*)b.data(),size))throw std::runtime_error("invalid fmt");format=u16(b.data());channels=u16(b.data()+2);rate=u32(b.data()+4);bits=u16(b.data()+14);}
        else if(!memcmp(h,"data",4)){
            if(format!=1||channels!=1||rate!=16000||bits!=16||size%2)throw std::runtime_error("expected mono pcm16 16kHz");
            std::vector<unsigned char> b(size);if(!f.read((char*)b.data(),size))throw std::runtime_error("truncated wav");std::vector<float> v(size/2);for(size_t i=0;i<v.size();i++)v[i]=(int16_t)u16(b.data()+2*i)/32768.f;return v;
        }else f.seekg(size,std::ios::cur);
        if(size%2)f.seekg(1,std::ios::cur);
    }throw std::runtime_error("no audio");
}
int main(int argc,char** argv){
    if(argc!=2)return 2;
    auto cp=whisper_context_default_params();cp.use_gpu=true;
    whisper_context* ctx=whisper_init_from_file_with_params(argv[1],cp);
    if(!ctx){std::cout<<"{\"ready\":false}"<<std::endl;return 3;}
    std::cout<<"{\"ready\":true}"<<std::endl;
    std::string line;
    while(std::getline(std::cin,line)){
        try{
            auto request = json::parse(line);
            auto samples = audio(request.at("file"));
            const bool retry = request.value("retry", false);
            auto p = whisper_full_default_params(retry ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY);
            if (retry) p.beam_search.beam_size = 3;
            const auto language = request.value("language", std::string("en"));
            p.language = language.c_str();
            p.n_threads = 4;
            p.translate = false;
            p.no_context = true;
            p.print_realtime = false;
            p.print_progress = false;
            p.print_timestamps = false;
            p.print_special = false;
            p.suppress_blank = true;
            p.suppress_nst = true;
            p.temperature_inc = 0;
            if(whisper_full(ctx,p,samples.data(),(int)samples.size())!=0)throw std::runtime_error("decode failed");
            std::string text;json segments=json::array();
            for(int i=0;i<whisper_full_n_segments(ctx);i++){
                if(whisper_full_get_segment_no_speech_prob(ctx,i)>0.85f)continue;
                std::string t=whisper_full_get_segment_text(ctx,i);text+=t;segments.push_back({{"text",t},{"end",whisper_full_get_segment_t1(ctx,i)/100.0}});
            }
            std::cout<<json({{"text",text},{"segments",segments}}).dump()<<std::endl;
        }catch(...){std::cout<<"{\"error\":\"local transcription failed\"}"<<std::endl;}
    }
    whisper_free(ctx);return 0;
}
