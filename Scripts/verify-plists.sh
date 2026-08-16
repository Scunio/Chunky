#!/bin/bash
# Verifica che i due bundle contengano solo le chiavi che gli competono.
#
# Serve perché finché Chunky è stato un unico target multipiattaforma, il bundle Mac
# riceveva UILaunchScreen / UISupportedInterfaceOrientations / UIBackgroundModes /
# UIDeviceFamily. Sono chiavi inerti su macOS, quindi nessun compilatore le segnala:
# senza questo controllo la regressione tornerebbe in silenzio.
#
# Uso: Scripts/verify-plists.sh <derived-data-path> [macos|ios|both]
# La piattaforma richiesta fallisce se il bundle non c'è: senza questo, una build saltata
# passerebbe il controllo senza verificare nulla.
set -uo pipefail

DERIVED_DATA="${1:-build/DerivedData}"
REQUIRE="${2:-both}"
MAC_PLIST="$DERIVED_DATA/Build/Products/Debug/Chunky.app/Contents/Info.plist"
IOS_PLIST="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/Chunky.app/Info.plist"

failures=0

fail() { echo "❌ $1"; failures=$((failures + 1)); }
pass() { echo "✅ $1"; }

has_key() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" >/dev/null 2>&1; }

require_absent() {
    if has_key "$1" "$2"; then fail "$3: la chiave $2 non dovrebbe esserci"; else pass "$3: $2 assente"; fi
}

require_present() {
    if has_key "$1" "$2"; then pass "$3: $2 presente"; else fail "$3: manca la chiave $2"; fi
}

if [ -f "$MAC_PLIST" ]; then
    echo "== macOS: $MAC_PLIST"
    for key in UILaunchScreen UISupportedInterfaceOrientations UIBackgroundModes UIDeviceFamily LSSupportsOpeningDocumentsInPlace UIFileSharingEnabled; do
        require_absent "$MAC_PLIST" "$key" macOS
    done
    for key in LSMinimumSystemVersion CFBundleDocumentTypes UTExportedTypeDeclarations NSUbiquitousContainers; do
        require_present "$MAC_PLIST" "$key" macOS
    done
    if [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$MAC_PLIST" 2>/dev/null)" = "com.scunio.Chunky" ]; then
        pass "macOS: CFBundleIdentifier invariato"
    else
        # Un bundle id diverso significa un container iCloud diverso: le librerie esistenti sparirebbero.
        fail "macOS: CFBundleIdentifier cambiato"
    fi
elif [ "$REQUIRE" = "macos" ] || [ "$REQUIRE" = "both" ]; then
    fail "bundle macOS non trovato in $MAC_PLIST"
else
    echo "⏭  bundle macOS non richiesto, salto"
fi

if [ -f "$IOS_PLIST" ]; then
    echo "== iOS: $IOS_PLIST"
    for key in UILaunchScreen UISupportedInterfaceOrientations UIBackgroundModes CFBundleDocumentTypes NSFaceIDUsageDescription UIFileSharingEnabled; do
        require_present "$IOS_PLIST" "$key" iOS
    done
    if [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$IOS_PLIST" 2>/dev/null)" = "com.scunio.Chunky" ]; then
        pass "iOS: CFBundleIdentifier invariato"
    else
        fail "iOS: CFBundleIdentifier cambiato"
    fi
elif [ "$REQUIRE" = "ios" ] || [ "$REQUIRE" = "both" ]; then
    fail "bundle iOS non trovato in $IOS_PLIST"
else
    echo "⏭  bundle iOS non richiesto, salto"
fi

if [ "$failures" -gt 0 ]; then echo; echo "$failures verifiche fallite"; exit 1; fi
echo; echo "Tutte le verifiche superate"
