#include "../Tools/AudioInput.h"
#include <cassert>
#include <iostream>
int main(int argc,char**argv) {
    if(argc!=3)return 2;
    const auto full=recognition_audio(argv[1],0);
    const auto skipped=recognition_audio(argv[1],24000);
    const auto clean=recognition_audio(argv[2],0);
    assert(full.size()==skipped.size()+24000);
    assert(skipped==clean);
    assert(std::vector<float>(full.begin()+24000,full.end())==skipped);
    assert(recognition_audio(argv[1],(int)full.size()).empty());
    bool negative=false,large=false;
    try{recognition_audio(argv[1],-1);}catch(...){negative=true;}
    try{recognition_audio(argv[1],(int)full.size()+1);}catch(...){large=true;}
    assert(negative&&large);
    std::cout<<"PASS: both engines share exact PCM cropping; 1.5-second prefix removed without changing new samples"<<std::endl;
}
