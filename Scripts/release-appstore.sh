#!/usr/bin/env bash
# Archivia Chunky_iOS, Chunky_macOS o Chunky_tvOS, incrementa il build number e carica su App
# Store Connect (TestFlight per iOS/tvOS, Mac App Store per macOS) tramite l'API di App Store
# Connect. Va lanciato dalla root del repo: ./Scripts/release-appstore.sh ios|macos|tvos
#
# Credenziali richieste (mai committate — vedi Config/appstoreconnect.env.example):
#   ASC_KEY_ID          Key ID della chiave API (App Store Connect > Users and Access >
#                        Integrations > App Store Connect API)
#   ASC_ISSUER_ID       Issuer ID mostrato nella stessa pagina
#   ASC_KEY_PATH         percorso del file AuthKey_<ASC_KEY_ID>.p8 scaricato una volta sola
#                        alla creazione della chiave (Apple non lo fa riscaricare)
#
# Vanno impostate come variabili d'ambiente, o in Config/appstoreconnect.env (gitignorato,
# caricato automaticamente se presente).

set -euo pipefail
cd "$(dirname "$0")/.."

PLATFORM="${1:-}"
case "$PLATFORM" in
  ios)
    SCHEME="Chunky_iOS"
    DESTINATION="generic/platform=iOS"
    ;;
  macos)
    SCHEME="Chunky_macOS"
    DESTINATION="generic/platform=macOS"
    ;;
  tvos)
    SCHEME="Chunky_tvOS"
    DESTINATION="generic/platform=tvOS"
    ;;
  *)
    echo "uso: $0 ios|macos|tvos" >&2
    exit 1
    ;;
esac

ENV_FILE="Config/appstoreconnect.env"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

: "${ASC_KEY_ID:?Manca ASC_KEY_ID (vedi Config/appstoreconnect.env.example)}"
: "${ASC_ISSUER_ID:?Manca ASC_ISSUER_ID (vedi Config/appstoreconnect.env.example)}"
: "${ASC_KEY_PATH:?Manca ASC_KEY_PATH (vedi Config/appstoreconnect.env.example)}"
[[ -f "$ASC_KEY_PATH" ]] || { echo "error: ASC_KEY_PATH non trovato: $ASC_KEY_PATH" >&2; exit 1; }

EXPORT_OPTIONS_PLIST="Config/ExportOptions.plist"
[[ -f "$EXPORT_OPTIONS_PLIST" ]] || {
  echo "error: manca $EXPORT_OPTIONS_PLIST (gitignorato, contiene il tuo Team ID)." >&2
  echo "       cp Config/ExportOptions.plist.example $EXPORT_OPTIONS_PLIST, poi inserisci il Team ID." >&2
  exit 1
}

# Build number monotono: un timestamp cresce sempre, quindi non serve tenere traccia
# dell'ultimo valore usato né rischiare di riusarne uno già caricato su App Store Connect
# (che lo rifiuterebbe). CURRENT_PROJECT_VERSION resta "1" in project.yml — il valore vero è
# passato solo qui, come override sulla riga di comando di xcodebuild, quindi project.yml
# non cambia a ogni release. Le build iOS e macOS condividono lo stesso bundle ID ma sono
# numerate su App Store Connect separatamente per piattaforma, quindi riusare lo stesso
# schema di numerazione per entrambe non crea conflitti.
BUILD_NUMBER="$(date -u +%Y%m%d%H%M)"

ARCHIVE_PATH="build/Chunky-$PLATFORM.xcarchive"
EXPORT_PATH="build/export-$PLATFORM"

echo "==> Rigenero il progetto (xcodegen)"
xcodegen generate

echo "==> Archivio $SCHEME — build $BUILD_NUMBER"
rm -rf "$ARCHIVE_PATH"
xcodebuild archive \
  -project Chunky.xcodeproj \
  -scheme "$SCHEME" \
  -archivePath "$ARCHIVE_PATH" \
  -destination "$DESTINATION" \
  -allowProvisioningUpdates \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER"

echo "==> Esporto e carico su App Store Connect"
rm -rf "$EXPORT_PATH"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"

echo "==> Fatto. Build $BUILD_NUMBER caricata — comparirà su App Store Connect dopo l'elaborazione di Apple (di solito pochi minuti)."
