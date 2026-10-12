#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
RUNNER=$(mktemp -t agent-meter-regressions)
trap 'rm -f "$RUNNER"' EXIT
xcrun swiftc -parse-as-library \
    Sources/AgentMeter/Models.swift \
    Sources/AgentMeter/Providers.swift \
    Tests/AgentMeterTests/ProvidersTests.swift \
    -o "$RUNNER"
"$RUNNER"
