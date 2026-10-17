#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
./build-app.sh
xcrun swiftc -O -swift-version 5 -parse-as-library App/LightCore.swift Tests/TransportCheck.swift -o .build/TransportCheck
xcrun swiftc -O -swift-version 5 -parse-as-library App/LightCore.swift App/LightModel.swift App/ScreenSampler.swift Tests/ModelCheck.swift -o .build/ModelCheck -framework SwiftUI -framework AppKit -framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo
.build/ModelCheck
python3 -B -m unittest discover -s Tests -p 'test_*.py' -v
