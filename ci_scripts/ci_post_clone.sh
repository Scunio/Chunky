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
