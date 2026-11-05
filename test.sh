#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h}"
zsh "$project_dir/scripts/fetch-android-deps.sh"
mkdir -p "$project_dir/build/tests" "$project_dir/build/module-cache"
xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$project_dir/build/module-cache" "$project_dir/Sources/Models.swift" "$project_dir/Sources/Translation.swift" "$project_dir/Sources/AudioCapture.swift" "$project_dir/Sources/MeetingRules.swift" "$project_dir/Sources/PhoneServer.swift" "$project_dir/Tests/CoreTests.swift" -o "$project_dir/build/tests/CoreTests"
"$project_dir/build/tests/CoreTests" "$project_dir/build/tests"
sources=("$project_dir"/Sources/*.swift)
sources=("${(@)sources:#*/App.swift}")
xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$project_dir/build/module-cache" "${sources[@]}" "$project_dir/Tests/RecordBehaviorTests.swift" -o "$project_dir/build/tests/RecordBehaviorTests"
"$project_dir/build/tests/RecordBehaviorTests"
xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$project_dir/build/module-cache" "$project_dir/Sources/Models.swift" "$project_dir/Sources/PhoneServer.swift" "$project_dir/Sources/BluetoothProtocol.swift" "$project_dir/Tests/BluetoothTests.swift" -o "$project_dir/build/tests/BluetoothTests"
"$project_dir/build/tests/BluetoothTests" "$project_dir/build/tests"
java_dir="$(/usr/libexec/java_home -v 17)"
"$java_dir/bin/javac" --release 8 -d "$project_dir/build/tests/java" "$project_dir/android/app/src/main/java/cn/tingqiao/companion/BleFrames.java" "$project_dir/Tests/BleFramesTest.java"
"$java_dir/bin/java" -cp "$project_dir/build/tests/java" BleFramesTest "$project_dir/build/tests/ble-frames.bin"

xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$project_dir/build/module-cache" "$project_dir/Sources/Models.swift" "$project_dir/Sources/Translation.swift" "$project_dir/Sources/AudioCapture.swift" "$project_dir/Sources/MeetingRules.swift" "$project_dir/Sources/BluetoothTrust.swift" "$project_dir/Tests/MeetingTests.swift" -o "$project_dir/build/tests/MeetingTests"
"$project_dir/build/tests/MeetingTests"
"$java_dir/bin/javac" --release 8 -classpath "$project_dir/android/libs/zxing-core-3.5.3.jar" -d "$project_dir/build/tests/java" "$project_dir/android/app/src/main/java/cn/tingqiao/companion/PairingLink.java" "$project_dir/Tests/PairingQRTest.java"
"$java_dir/bin/java" -cp "$project_dir/build/tests/java:$project_dir/android/libs/zxing-core-3.5.3.jar" PairingQRTest

xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$project_dir/build/module-cache" "${sources[@]}" "$project_dir/Tests/PipelineRecoveryTests.swift" -o "$project_dir/build/tests/PipelineRecoveryTests"
"$project_dir/build/tests/PipelineRecoveryTests"

xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$project_dir/build/module-cache" "$project_dir/Sources/Models.swift" "$project_dir/Sources/Translation.swift" "$project_dir/Sources/MeetingAssistant.swift" "$project_dir/Sources/PhoneServer.swift" "$project_dir/Sources/BluetoothProtocol.swift" "$project_dir/Tests/AssistantTests.swift" -o "$project_dir/build/tests/AssistantTests"
"$project_dir/build/tests/AssistantTests"
