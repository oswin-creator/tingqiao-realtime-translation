#include "onnxruntime_c_api.h"
#include <memory>
#include <stdexcept>

class KoreanTTS {
    const OrtApi *api = OrtGetApiBase()->GetApi(ORT_API_VERSION);
    OrtEnv *environment = nullptr;
    OrtSession *session = nullptr;
    OrtMemoryInfo *memory = nullptr;
    NSDictionary *frontend = nil;
    NSDictionary<NSString *, NSNumber *> *tokens = nil;

    void check(OrtStatus *status) {
        if (!status) return;
        std::string message = api->GetErrorMessage(status);
        api->ReleaseStatus(status);
        throw std::runtime_error(message);
    }

    NSString *replace(NSString *text, NSString *pattern, NSString *value) const {
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nullptr];
        if (!regex) throw std::runtime_error("invalid pronunciation rule");
        return [regex stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:value];
    }

    NSString *numbers(NSString *text) const {
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"[0-9]+(?:\\.[0-9]+)?" options:0 error:nullptr];
        NSArray<NSTextCheckingResult *> *matches = [regex matchesInString:text options:0 range:NSMakeRange(0, text.length)];
        NSMutableString *result = [text mutableCopy];
        NSArray *digits = @[@"영", @"일", @"이", @"삼", @"사", @"오", @"육", @"칠", @"팔", @"구"];
        NSArray *units = @[@"", @"십", @"백", @"천", @"만", @"십", @"백", @"천", @"억", @"십", @"백", @"천", @"조"];
        for (NSTextCheckingResult *match in matches.reverseObjectEnumerator) {
            NSString *number = [text substringWithRange:match.range];
            NSMutableString *spoken = [NSMutableString string];
            NSArray *parts = [number componentsSeparatedByString:@"."];
            NSString *integer = parts[0];
            bool digitsOnly = integer.length > units.count || (integer.length > 1 && [integer hasPrefix:@"0"]);
            if (digitsOnly) {
                for (NSUInteger i = 0; i < integer.length; ++i) [spoken appendString:digits[[integer characterAtIndex:i] - '0']];
            } else {
                for (NSUInteger i = 0; i < integer.length; ++i) {
                    int digit = [integer characterAtIndex:i] - '0';
                    NSUInteger position = integer.length - i - 1;
                    if (digit) {
                        if (digit != 1 || position % 4 == 0) [spoken appendString:digits[digit]];
                        if (position % 4) [spoken appendString:units[position % 4]];
                    }
                    if (position > 0 && position % 4 == 0) {
                        NSUInteger start = i >= 3 ? i - 3 : 0;
                        NSString *group = [integer substringWithRange:NSMakeRange(start, i - start + 1)];
                        if (group.intValue) [spoken appendString:units[position]];
                    }
                }
                if (!spoken.length) [spoken appendString:digits[0]];
            }
            if (parts.count == 2) {
                [spoken appendString:@"점"];
                NSString *fraction = parts[1];
                for (NSUInteger i = 0; i < fraction.length; ++i) [spoken appendString:digits[[fraction characterAtIndex:i] - '0']];
            }
            [result replaceCharactersInRange:match.range withString:spoken];
        }
        return result;
    }

public:
    KoreanTTS(const std::string &root) {
        NSData *data = [NSData dataWithContentsOfFile:@( (root + "/frontend.json").c_str() )];
        frontend = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nullptr] : nil;
        if (![frontend[@"symbols"] isKindOfClass:[NSArray class]]) throw std::runtime_error("missing Korean frontend");
        NSMutableDictionary *mapping = [NSMutableDictionary dictionary];
        NSArray *symbols = frontend[@"symbols"];
        for (NSUInteger i = 0; i < symbols.count; ++i) mapping[symbols[i]] = @(i);
        tokens = mapping;
        OrtSessionOptions *options = nullptr;
        try {
            check(api->CreateEnv(ORT_LOGGING_LEVEL_ERROR, "TingQiaoKorean", &environment));
            check(api->CreateSessionOptions(&options));
            check(api->SetIntraOpNumThreads(options, 4));
            check(api->SetSessionGraphOptimizationLevel(options, ORT_ENABLE_ALL));
            check(api->CreateSession(environment, (root + "/model.onnx").c_str(), options, &session));
            check(api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memory));
            api->ReleaseSessionOptions(options);
        } catch (...) {
            if (options) api->ReleaseSessionOptions(options);
            release();
            throw;
        }
    }

    ~KoreanTTS() { release(); }

    void release() {
        if (memory) api->ReleaseMemoryInfo(memory);
        if (session) api->ReleaseSession(session);
        if (environment) api->ReleaseEnv(environment);
        memory = nullptr; session = nullptr; environment = nullptr;
    }

    NSString *phonemes(NSString *text) const {
        text = [[text precomposedStringWithCanonicalMapping] lowercaseString];
        for (NSArray *pair in frontend[@"idioms"]) text = replace(text, pair[0], pair[1]);
        text = numbers(text);
        NSArray *letters = @[@"에이", @"비", @"시", @"디", @"이", @"에프", @"지", @"에이치", @"아이", @"제이", @"케이", @"엘", @"엠", @"엔", @"오", @"피", @"큐", @"알", @"에스", @"티", @"유", @"브이", @"더블유", @"엑스", @"와이", @"지"];
        NSMutableString *spelled = [NSMutableString string];
        for (NSUInteger i = 0; i < text.length; ++i) {
            unichar value = [text characterAtIndex:i];
            if (value >= 'a' && value <= 'z') [spelled appendString:letters[value - 'a']];
            else if (value == '%') [spelled appendString:@"퍼센트"];
            else [spelled appendFormat:@"%C", value];
        }
        text = spelled.decomposedStringWithCanonicalMapping;
        text = replace(text, @"([ᄌᄍᄎ])ᅧ", @"$1ᅥ");
        text = replace(text, @"([ᄀᄁᄂᄃᄄᄅᄆᄇᄈᄉᄊᄌᄍᄎᄏᄐᄑᄒ])ᅴ", @"$1ᅵ");
        text = replace(text, @"ᆮᄋ([ᅵᅧ])", @"ᄌ$1");
        text = replace(text, @"ᇀᄋ([ᅵᅧ])", @"ᄎ$1");
        text = replace(text, @"ᆴᄋ([ᅵᅧ])", @"ᆯᄎ$1");
        text = replace(text, @"ᆮ히", @"치");
        for (NSArray *pair in frontend[@"rules"]) text = replace(text, pair[0], pair[1]);
        NSArray *from = @[@"ᆨ", @"ᆩ", @"ᆫ", @"ᆮ", @"ᆯ", @"ᆷ", @"ᆸ", @"ᆺ", @"ᆻ", @"ᆽ", @"ᆾ", @"ᆿ", @"ᇀ", @"ᇁ", @"ᆪ", @"ᆬ", @"ᆰ", @"ᆱ", @"ᆲ", @"ᆳ", @"ᆴ", @"ᆵ", @"ᆹ", @"ᇂ", @"ᆭ", @"ᆶ"];
        NSArray *to = @[@"ᄀ", @"ᄁ", @"ᄂ", @"ᄃ", @"ᄅ", @"ᄆ", @"ᄇ", @"ᄉ", @"ᄊ", @"ᄌ", @"ᄎ", @"ᄏ", @"ᄐ", @"ᄑ", @"ᆨᄊ", @"ᆫᄌ", @"ᆯᄀ", @"ᆯᄆ", @"ᆯᄇ", @"ᆯᄊ", @"ᆯᄐ", @"ᆯᄑ", @"ᆸᄊ", @"ᄋ", @"ᄂ", @"ᄅ"];
        for (NSUInteger i = 0; i < from.count; ++i) {
            text = [text stringByReplacingOccurrencesOfString:[from[i] stringByAppendingString:@"ᄋ"]
                                                 withString:to[i] options:NSLiteralSearch range:NSMakeRange(0, text.length)];
        }
        return text;
    }

    std::vector<float> generate(NSString *text) {
        NSString *pronounced = phonemes(text);
        std::vector<int64_t> phones = {0, 0, 0}, tones = {0, 11, 0};
        for (NSUInteger i = 0; i < pronounced.length; ++i) {
            NSString *symbol = [pronounced substringWithRange:NSMakeRange(i, 1)];
            if ([symbol isEqual:@"\n"] || [symbol isEqual:@"\t"]) symbol = @" ";
            if ([symbol isEqual:@" "]) continue;
            if ([symbol isEqual:@"—"] || [symbol isEqual:@"–"]) symbol = @"-";
            NSNumber *token = tokens[symbol];
            if (!token) throw std::runtime_error("Unsupported Korean phoneme code " + std::to_string([pronounced characterAtIndex:i]));
            phones.push_back(token.longLongValue); phones.push_back(0);
            tones.push_back(11); tones.push_back(0);
        }
        phones.push_back(0); phones.push_back(0);
        tones.push_back(11); tones.push_back(0);
        int64_t length = phones.size(), sid = 0;
        int64_t sequenceShape[] = {1, length}, scalarShape[] = {1};
        float noise = 0.6f, scale = 1.0f, width = 0.8f;
        std::vector<OrtValue *> inputs;
        OrtValue *output = nullptr;
        auto tensor = [&](void *data, size_t bytes, const int64_t *shape, size_t dims, ONNXTensorElementDataType type) {
            OrtValue *value = nullptr;
            check(api->CreateTensorWithDataAsOrtValue(memory, data, bytes, shape, dims, type, &value));
            inputs.push_back(value);
        };
        try {
            tensor(phones.data(), phones.size()*8, sequenceShape, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64);
            tensor(&length, 8, scalarShape, 1, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64);
            tensor(tones.data(), tones.size()*8, sequenceShape, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64);
            tensor(&sid, 8, scalarShape, 1, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64);
            tensor(&noise, 4, scalarShape, 1, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT);
            tensor(&scale, 4, scalarShape, 1, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT);
            tensor(&width, 4, scalarShape, 1, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT);
            const char *names[] = {"x", "x_lengths", "tones", "sid", "noise_scale", "length_scale", "noise_scale_w"};
            const char *outNames[] = {"y"};
            check(api->Run(session, nullptr, names, inputs.data(), inputs.size(), outNames, 1, &output));
            OrtTensorTypeAndShapeInfo *info = nullptr;
            check(api->GetTensorTypeAndShape(output, &info));
            size_t count = 0;
            OrtStatus *status = api->GetTensorShapeElementCount(info, &count);
            api->ReleaseTensorTypeAndShapeInfo(info);
            check(status);
            float *samples = nullptr;
            check(api->GetTensorMutableData(output, reinterpret_cast<void **>(&samples)));
            std::vector<float> result(samples, samples + count);
            api->ReleaseValue(output);
            for (auto *value : inputs) api->ReleaseValue(value);
            return result;
        } catch (...) {
            if (output) api->ReleaseValue(output);
            for (auto *value : inputs) api->ReleaseValue(value);
            throw;
        }
    }
};
