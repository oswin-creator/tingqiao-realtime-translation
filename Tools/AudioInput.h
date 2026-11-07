#pragma once
#include <fstream>
#include <vector>
#include <string>
#include <cstring>
#include <stdexcept>
#include <cstdint>
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

static std::vector<float> recognition_audio(const std::string& path, int skip) {
    auto samples = audio(path);
    if (skip < 0 || skip > (int)samples.size()) throw std::runtime_error("invalid audio offset");
    if (skip > 0) samples.erase(samples.begin(), samples.begin() + skip);
    return samples;
}
