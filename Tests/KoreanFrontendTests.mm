#import <Foundation/Foundation.h>
#include <algorithm>
#include <iostream>
#include <string>
#include <vector>
#include "../Tools/TTS/Korean.h"

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    @autoreleasepool {
        KoreanTTS tts(argv[1]);
        NSArray *sentences = @[@"안녕하세요.", @"오늘은 통계 분석을 공부하겠습니다.",
            @"두 집단의 변화를 비교해서 정책 효과를 추정합니다.",
            @"결과가 유의하지 않다고 해서 효과가 없다는 뜻은 아닙니다.",
            @"표본 크기는 150명이고 신뢰 수준은 95퍼센트입니다.",
            @"차이의 차이 분석과 신뢰구간을 확인하겠습니다.",
            @"2026년 11월 14일 자료입니다.", @"효과는 3.5%이고 API 설정도 확인합니다."];
        NSDictionary *resource = [NSJSONSerialization JSONObjectWithData:
            [NSData dataWithContentsOfFile:[@(argv[1]) stringByAppendingPathComponent:@"frontend.json"]]
            options:0 error:nullptr];
        NSSet *symbols = [NSSet setWithArray:resource[@"symbols"]];
        for (NSString *sentence in sentences) {
            NSString *phonemes = tts.phonemes(sentence);
            for (NSUInteger index = 0; index < phonemes.length; ++index) {
                NSString *symbol = [phonemes substringWithRange:NSMakeRange(index, 1)];
                if (![symbol isEqual:@" "] && ![symbols containsObject:symbol]) return 3;
            }
            const auto audio = tts.generate(sentence);
            if (audio.size() < 4410 || audio.size() > 44100 * 30 ||
                !std::all_of(audio.begin(), audio.end(), [](float x) { return std::isfinite(x); })) return 4;
        }
        if ([tts.phonemes(@"뜻은") containsString:@"ᆺ"]) return 5;
        std::cout << "PASS: 韩语常见音变、数字、字母和八段连续音频" << std::endl;
    }
}
