#!/bin/sh
# Xcode Cloud: il .xcodeproj è gitignorato e generato da project.yml, quindi va creato dopo
# il clone, prima che Xcode Cloud risolva i pacchetti e compili.
set -euo pipefail
cd "$CI_PRIMARY_REPOSITORY_PATH"

if ! command -v xcodegen >/dev/null 2>&1; then
  export HOMEBREW_NO_AUTO_UPDATE=1
  brew install xcodegen
fi

xcodegen generate

# Xcode Cloud disattiva la risoluzione automatica dei pacchetti: serve un Package.resolved
# nel progetto generato. Quello versionato in Config/ fissa le versioni di AMSMB2, ZIPFoundation
# e Unrar; aggiornalo (copia da xcshareddata/swiftpm) quando cambi le dipendenze.
mkdir -p Chunky.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
cp Config/Package.resolved Chunky.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
