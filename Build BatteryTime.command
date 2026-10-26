#!/bin/bash
cd "$(dirname "$0")" || exit 1
./build.sh
RESULT=$?
if [ -t 0 ]; then
    printf '\nPress Return to close this window… '
    read -r _ || true
fi
exit "$RESULT"
