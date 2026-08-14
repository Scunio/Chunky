#!/usr/bin/env bash
# Alias storico: archivia e carica Chunky_iOS su TestFlight. Vedi release-appstore.sh, che
# gestisce anche Chunky_macOS (Mac App Store) con la stessa logica.
set -euo pipefail
exec "$(dirname "$0")/release-appstore.sh" ios
