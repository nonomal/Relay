#!/bin/sh
# Relay's end-to-end UI tests: drives the app in an iOS simulator against the real
# BoxJS backend script, served with test data by Server/e2e-server.mjs, and checks
# both what the app shows and what it writes back.
#
#   Tools/E2E/run.sh
#
# Needs Node 18+ and a checkout of chavyleung/scripts next to this repository (or
# BOXJS_SCRIPT=/path/to/box/chavy.boxjs.js). Runs on RELAY_E2E_DEVICE (a simulator
# UDID), else a booted iPhone simulator, else the first available one. It never
# creates simulators, and shuts down again one it had to boot.
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
build="$root/build/E2E"
port="${RELAY_E2E_PORT:-8124}"
server_url="http://127.0.0.1:$port"
script="${BOXJS_SCRIPT:-$root/../scripts/box/chavy.boxjs.js}"

if [ ! -f "$script" ]; then
    echo "BoxJS script not found at $script; set BOXJS_SCRIPT to chavy.boxjs.js" >&2
    exit 2
fi

device="${RELAY_E2E_DEVICE:-$(xcrun simctl list devices available -j | node -e '
    const all = Object.values(JSON.parse(require("fs").readFileSync(0, "utf8")).devices).flat();
    const phones = all.filter((device) => device.name.startsWith("iPhone"));
    const device = phones.find((phone) => phone.state === "Booted") ?? phones[0];
    if (device) console.log(device.udid);
')}"
if [ -z "$device" ]; then
    echo "No iPhone simulator available" >&2
    exit 2
fi

booted_here=false
if ! xcrun simctl list devices booted | grep -q "$device"; then
    xcrun simctl boot "$device"
    booted_here=true
fi
xcrun simctl bootstatus "$device" -b > /dev/null

BOXJS_SCRIPT="$script" node "$here/Server/e2e-server.mjs" "$port" &
server=$!
# The exit status must survive the cleanup. macOS's sh reports 0 in the trap after
# some errors (an unset variable), so reaching the end is tracked explicitly.
finished=false
cleanup() {
    status=$?
    if [ "$finished" != true ] && [ "$status" -eq 0 ]; then
        status=1
    fi
    kill "$server" 2> /dev/null || true
    wait "$server" 2> /dev/null || true
    xcrun simctl uninstall "$device" e2e.relay.uitests.xctrunner 2> /dev/null || true
    if [ "$booted_here" = true ]; then
        xcrun simctl shutdown "$device" || true
    fi
    exit "$status"
}
trap cleanup EXIT

# The server builds its data through BoxJS before it listens.
tries=0
until curl -fs "$server_url/__e2e/log" > /dev/null 2>&1; do
    tries=$((tries + 1))
    if [ "$tries" -gt 100 ]; then
        echo "E2E server did not start on $server_url" >&2
        exit 1
    fi
    sleep 0.1
done
if ! kill -0 "$server" 2> /dev/null; then
    echo "E2E server exited; is port $port already in use?" >&2
    exit 1
fi

destination="platform=iOS Simulator,id=$device"
echo "Building Relay for ${device}..."
mkdir -p "$build"
if ! xcodebuild -project "$root/Relay.xcodeproj" -scheme Relay -destination "$destination" \
    -derivedDataPath "$build" CODE_SIGNING_ALLOWED=NO build > "$build/relay-build.log" 2>&1; then
    grep -E ": error: " "$build/relay-build.log" | sort -u >&2
    echo "Building Relay failed; see $build/relay-build.log" >&2
    exit 1
fi
xcrun simctl install "$device" "$build/Build/Products/Debug-iphonesimulator/Relay.app"

# Parallel testing would clone the simulator, so it is off.
echo "Running end-to-end tests..."
result="$build/Results-$(date +%Y%m%d-%H%M%S).xcresult"
log="$build/e2e-tests.log"
status=0
TEST_RUNNER_RELAY_E2E_SERVER="$server_url" xcodebuild test \
    -project "$here/RelayE2E.xcodeproj" -scheme RelayE2EUITests -destination "$destination" \
    -derivedDataPath "$build" -resultBundlePath "$result" \
    -parallel-testing-enabled NO -disable-concurrent-destination-testing > "$log" 2>&1 || status=$?

grep -E "Test Case .*(passed|failed)|: error: " "$log" | sort -u
grep -m 1 -E "Executed [0-9]+ test" "$log" || true
echo "Screenshots: $result"
echo "Full log: $log"
finished=true
exit "$status"
