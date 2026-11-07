#pragma once
#include "ggml.h"
#include "json.hpp"
#include <fstream>
#include <vector>
#include <string>
#include <map>
#include <set>
#include <stdexcept>
#include <algorithm>
#include <cstdint>

namespace komix {
using json = nlohmann::json;
inline std::string tensor_name(std::string name) {
    if (name.rfind("model.", 0) != 0) throw std::runtime_error("unexpected tensor");
    name.erase(0, 6);
    const std::map<std::string, std::string> replacements = {
        {"self_attn.k_proj", "attn.key"}, {"self_attn.q_proj", "attn.query"},
        {"self_attn.v_proj", "attn.value"}, {"self_attn.out_proj", "attn.out"},
        {"self_attn_layer_norm", "attn_ln"}, {"encoder_attn.k_proj", "cross_attn.key"},
        {"encoder_attn.q_proj", "cross_attn.query"}, {"encoder_attn.v_proj", "cross_attn.value"},
        {"encoder_attn.out_proj", "cross_attn.out"}, {"encoder_attn_layer_norm", "cross_attn_ln"},
        {"fc1", "mlp.0"}, {"fc2", "mlp.2"}, {"final_layer_norm", "mlp_ln"}
    };
    auto p = name.find(".layers.");
    if (p != std::string::npos) {
        name.replace(p, 8, ".blocks.");
        const auto layerEnd = name.find('.', p + 8);
        if (layerEnd == std::string::npos) throw std::runtime_error("invalid layer");
        const auto suffix = name.rfind('.');
        const auto key = name.substr(layerEnd + 1, suffix - layerEnd - 1);
        auto mapped = replacements.find(key);
        if (mapped == replacements.end()) throw std::runtime_error("unknown layer tensor");
        return name.substr(0, layerEnd + 1) + mapped->second + name.substr(suffix);
    }
    const std::map<std::string, std::string> direct = {
        {"encoder.layer_norm.weight", "encoder.ln_post.weight"}, {"encoder.layer_norm.bias", "encoder.ln_post.bias"},
        {"decoder.layer_norm.weight", "decoder.ln.weight"}, {"decoder.layer_norm.bias", "decoder.ln.bias"},
        {"encoder.embed_positions.weight", "encoder.positional_embedding"},
        {"decoder.embed_positions.weight", "decoder.positional_embedding"},
        {"decoder.embed_tokens.weight", "decoder.token_embedding.weight"}
    };
    auto it = direct.find(name);
    return it == direct.end() ? name : it->second;
}
inline void put32(std::ofstream& out, int32_t v) { out.write(reinterpret_cast<const char*>(&v), 4); }
inline void convert(const char* source, const char* prefix, const char* destination) {
    std::ifstream in(source, std::ios::binary);
    uint64_t headerSize = 0;
    if (!in.read(reinterpret_cast<char*>(&headerSize), 8) || headerSize > 4*1024*1024 || headerSize == 0) throw std::runtime_error("invalid safetensors");
    std::string header(headerSize, '\0');
    if (!in.read(header.data(), header.size())) throw std::runtime_error("truncated header");
    auto tensors = json::parse(header);
    std::ifstream asset(prefix, std::ios::binary);
    std::vector<char> metadata((std::istreambuf_iterator<char>(asset)), std::istreambuf_iterator<char>());
    if (metadata.size() < 500000) throw std::runtime_error("missing tokenizer");
    std::ofstream out(destination, std::ios::binary | std::ios::trunc);
    out.write(metadata.data(), metadata.size());
    std::set<std::string> written;
    for (auto it = tensors.begin(); it != tensors.end(); ++it) {
        if (it.key() == "__metadata__" || it.key() == "proj_out.weight") continue;
        const auto name = tensor_name(it.key());
        if (!written.insert(name).second) throw std::runtime_error("duplicate tensor");
        auto shape = it.value().at("shape").get<std::vector<int64_t>>();
        const auto dtype = it.value().at("dtype").get<std::string>();
        auto offsets = it.value().at("data_offsets").get<std::vector<uint64_t>>();
        if (dtype != "F32" || offsets.size() != 2 || offsets[1] < offsets[0]) throw std::runtime_error("unsupported tensor");
        uint64_t count = 1;
        for (auto d : shape) { if (d <= 0 || d > 1000000 || count > 100000000) throw std::runtime_error("invalid shape"); count *= d; }
        if (count > 100000000 || offsets[1]-offsets[0] != count*4) throw std::runtime_error("invalid length");
        shape.erase(std::remove(shape.begin(), shape.end(), 1), shape.end());
        if (name == "encoder.conv1.bias" || name == "encoder.conv2.bias") shape.push_back(1);
        const bool f32 = shape.size() < 2 || name == "encoder.conv1.bias" || name == "encoder.conv2.bias" || name == "encoder.positional_embedding" || name == "decoder.positional_embedding";
        put32(out, (int32_t)shape.size()); put32(out, (int32_t)name.size()); put32(out, f32 ? 0 : 1);
        for (auto d = shape.rbegin(); d != shape.rend(); ++d) put32(out, (int32_t)*d);
        out.write(name.data(), name.size());
        in.clear(); in.seekg(8 + headerSize + offsets[0]);
        const uint64_t block = 262144;
        std::vector<float> floats(block);
        std::vector<ggml_fp16_t> halves(block);
        for (uint64_t offset = 0; offset < count; offset += block) {
            const auto n = std::min(block, count-offset);
            if (!in.read(reinterpret_cast<char*>(floats.data()), n*4)) throw std::runtime_error("truncated tensor");
            for (uint64_t i=0; i<n; ++i) halves[i] = ggml_fp32_to_fp16(floats[i]);
            if (f32) {
                for (uint64_t i=0; i<n; ++i) floats[i] = ggml_fp16_to_fp32(halves[i]);
                out.write(reinterpret_cast<const char*>(floats.data()), n*4);
            } else { out.write(reinterpret_cast<const char*>(halves.data()), n*2); }
        }
        if (!out) throw std::runtime_error("write failed");
    }
    if (written.size() != 947) throw std::runtime_error("incomplete Whisper medium");
    out.close(); if (!out) throw std::runtime_error("write failed");
}
}
