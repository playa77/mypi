#!/bin/sh
SELF="$(readlink -f "$0")"
HERE="$(dirname "$SELF")"
exec "$HERE/pi-desktop" --no-sandbox "$@"
