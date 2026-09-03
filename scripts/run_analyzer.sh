#!/bin/bash

root=$(cd "$(dirname "$0")/.." && pwd)
exec "$root/scripts/xcodebuild.sh" analyze "$@"
