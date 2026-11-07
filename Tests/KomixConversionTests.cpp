#include "convert-komix.h"
#include <cassert>
#include <iostream>
int main(int argc,char**argv) {
    if(argc!=4) return 2;
    std::ifstream input(argv[1]); auto metadata=nlohmann::json::parse(input);
    std::set<std::string> expected;
    for(auto it=metadata.begin();it!=metadata.end();++it) {
        if(it.key()=="__metadata__") continue;
        expected.insert(komix::tensor_name(it.key()));
    }
    assert(expected.size()==947);
    assert(expected.count("decoder.blocks.23.cross_attn.key.weight"));
    assert(expected.count("encoder.blocks.23.mlp_ln.bias"));
    assert(expected.count("decoder.token_embedding.weight"));
    const std::string source=std::string(argv[3])+".safetensors";
    nlohmann::json fake;
    uint64_t offset=0;
    for(auto it=metadata.begin();it!=metadata.end();++it) {
        if(it.key()=="__metadata__") continue;
        fake[it.key()]={{"dtype","F32"},{"shape",{1,2}},{"data_offsets",{offset,offset+8}}}; offset+=8;
    }
    auto encoded=fake.dump(); uint64_t n=encoded.size();
    std::ofstream fixture(source,std::ios::binary); fixture.write((char*)&n,8);fixture.write(encoded.data(),n);
    const float values[]={1.125f,-0.375f};
    for(size_t i=0;i<expected.size();i++) fixture.write((char*)values,8);
    fixture.close();
    komix::convert(source.c_str(),argv[2],argv[3]);
    std::ifstream prefix(argv[2],std::ios::binary|std::ios::ate);
    std::ifstream result(argv[3],std::ios::binary); result.seekg(prefix.tellg());
    std::set<std::string> actual;
    while(result.peek()!=EOF) {
        int32_t dimensions=0,length=0,type=0;
        result.read((char*)&dimensions,4);result.read((char*)&length,4);result.read((char*)&type,4);
        assert(dimensions==1 || dimensions==2); assert(length>0 && length<150);
        int64_t count=1;
        for(int j=0;j<dimensions;j++){int32_t d=0;result.read((char*)&d,4);count*=d;}
        assert(count==2);
        std::string name(length,'\0');result.read(name.data(),length);actual.insert(name);
        for(int j=0;j<2;j++) {
            float v;
            if(type==0)result.read((char*)&v,4);
            else {ggml_fp16_t h;result.read((char*)&h,2);v=ggml_fp16_to_fp32(h);}
            assert(v==values[j]);
        }
    }
    assert(actual==expected);
    std::cout<<"PASS: 947 source tensor names, tokenizer prefix, FP16/F32 conversion, dimensions and payloads"<<std::endl;
}
