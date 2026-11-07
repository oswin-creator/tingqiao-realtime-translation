#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h}"
mkdir -p "$project_dir/build/tests" "$project_dir/build/module-cache"
# Synthesize to files only: no microphone, speaker, recognition API or user data.
say -v Samantha -o "$project_dir/build/tests/vad-en.aiff" "In this academic research meeting, we discuss statistical analysis and repeated measures. Please explain the results of the experiment and the next steps."
say -v Yuna -o "$project_dir/build/tests/vad-ko.aiff" "오늘 연구 회의에서는 통계 분석과 실험 결과에 대해 이야기하겠습니다. 교수님께서 설명하신 내용을 확인하고 다음 연구 계획을 논의하겠습니다."
for language in en ko; do
    afconvert -f WAVE -d LEI16@16000 -c 1 "$project_dir/build/tests/vad-$language.aiff" "$project_dir/build/tests/vad-$language.wav"
done
xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$project_dir/build/module-cache" "$project_dir/Sources/Models.swift" "$project_dir/Sources/SileroVAD.swift" "$project_dir/Sources/AudioCapture.swift" "$project_dir/Sources/MeetingRules.swift" "$project_dir/Tests/VADTests.swift" -o "$project_dir/build/tests/VADTests"
"$project_dir/build/tests/VADTests" "$project_dir"
