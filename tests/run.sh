#!/usr/bin/env bash
# Run the local test suite (Git Bash or Linux/macOS).
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

export PATH="$root/tests/mocks:$PATH"
local_tools=$(cd "$root/../.." 2>/dev/null && pwd)/tools
if [[ -x $local_tools/jq || -x $local_tools/jq.exe ]]; then
  export PATH="$local_tools:$PATH"
fi
chmod +x tests/mocks/herdr tests/mocks/hc scripts/attach-tui.sh 2>/dev/null || true

bash tests/attach-tui.test.sh
