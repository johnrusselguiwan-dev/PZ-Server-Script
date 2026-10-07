#!/bin/bash
# Shortcut: opens the live dashboard of pz-server.sh
exec "$(dirname "$(readlink -f "$0")")/pz-server.sh" dashboard "$@"
