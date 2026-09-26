#!/bin/sh
# Compiles the Foundation-only model layer together with main.swift and runs it.
#
#   Tools/ModelTests/run.sh              # built-in cases
#   Tools/ModelTests/run.sh <dir>        # also project every *.json /query/boxdata
#                                        # payload in <dir> (e.g. saved from a device)
set -eu

root="$(cd "$(dirname "$0")/../.." && pwd)"
models="$root/Relay/Models"
build="$(mktemp -d)"
trap 'rm -rf "$build"' EXIT

swiftc -O -o "$build/model-tests" \
    "$models/JSONValue.swift" \
    "$models/LenientDecoding.swift" \
    "$models/AppModel.swift" \
    "$models/SubscriptionModels.swift" \
    "$models/UserConfig.swift" \
    "$models/SessionModels.swift" \
    "$models/BoxDataModel.swift" \
    "$root/Tools/ModelTests/main.swift"

"$build/model-tests" "$@"
