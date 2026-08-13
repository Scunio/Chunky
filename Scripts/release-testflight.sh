#!/usr/bin/env bash
# Archivia Chunky_iOS, incrementa il build number e carica su TestFlight tramite l'API di
# App Store Connect. Va lanciato dalla root del repo: ./Scripts/release-testflight.sh
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
# dell'ultimo valore usato né rischiare di riusarne uno già caricato su TestFlight (che lo
# rifiuterebbe). CURRENT_PROJECT_VERSION resta "1" in project.yml — il valore vero è passato
# solo qui, come override sulla riga di comando di xcodebuild, quindi project.yml non cambia
# a ogni release.
BUILD_NUMBER="$(date -u +%Y%m%d%H%M)"

ARCHIVE_PATH="build/Chunky.xcarchive"
EXPORT_PATH="build/export"

echo "==> Rigenero il progetto (xcodegen)"
xcodegen generate

echo "==> Archivio Chunky_iOS — build $BUILD_NUMBER"
rm -rf "$ARCHIVE_PATH"
xcodebuild archive \
  -project Chunky.xcodeproj \
  -scheme Chunky_iOS \
  -archivePath "$ARCHIVE_PATH" \
  -destination 'generic/platform=iOS' \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER"

echo "==> Esporto e carico su TestFlight"
rm -rf "$EXPORT_PATH"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"

echo "==> Fatto. Build $BUILD_NUMBER caricata — comparirà in TestFlight dopo l'elaborazione di Apple (di solito pochi minuti)."
