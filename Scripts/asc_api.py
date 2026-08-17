#!/usr/bin/env python3
"""Minimal App Store Connect API client, authenticated with the ES256 API key.

Usage: python3 Scripts/asc_api.py <command> [args...]

Commands:
  get-version <platform> <version>   Show the appStoreVersion resource (IOS|MAC_OS, e.g. "1.0.1")
  set-notes <platform> <version> <locale> <text>   Set "What's New" for a version localization
  set-description <platform> <version> <locale> <text>   Set the app description

Credentials come from Config/appstoreconnect.env (ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH).
"""
import base64
import json
import os
import sys
import time
import urllib.request
import urllib.error

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENV_FILE = os.path.join(ROOT, "Config", "appstoreconnect.env")
BUNDLE_ID = "com.scunio.Chunky"
API_BASE = "https://api.appstoreconnect.apple.com/v1"


def load_env():
    if os.path.exists(ENV_FILE):
        with open(ENV_FILE) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                os.environ.setdefault(k, os.path.expandvars(v.strip('"')))
    for key in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_PATH"):
        if key not in os.environ:
            sys.exit(f"error: manca {key} (vedi {ENV_FILE})")


def make_jwt():
    # Deferred import: cryptography is not a stdlib dependency, only needed here.
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec, utils

    key_id = os.environ["ASC_KEY_ID"]
    issuer_id = os.environ["ASC_ISSUER_ID"]
    key_path = os.environ["ASC_KEY_PATH"]

    with open(key_path, "rb") as f:
        private_key = serialization.load_pem_private_key(f.read(), password=None)

    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    now = int(time.time())
    payload = {
        "iss": issuer_id,
        "iat": now,
        "exp": now + 19 * 60,
        "aud": "appstoreconnect-v1",
    }

    def b64url(data: bytes) -> str:
        return base64.urlsafe_b64encode(data).rstrip(b"=").decode()

    signing_input = f"{b64url(json.dumps(header, separators=(',', ':')).encode())}.{b64url(json.dumps(payload, separators=(',', ':')).encode())}"
    der_sig = private_key.sign(signing_input.encode(), ec.ECDSA(hashes.SHA256()))
    r, s = utils.decode_dss_signature(der_sig)
    raw_sig = r.to_bytes(32, "big") + s.to_bytes(32, "big")
    return f"{signing_input}.{b64url(raw_sig)}"


def call(method, path, body=None):
    token = make_jwt()
    url = path if path.startswith("http") else f"{API_BASE}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        print(e.read().decode(), file=sys.stderr)
        raise


def get_app_id():
    res = call("GET", f"/apps?filter[bundleId]={BUNDLE_ID}")
    items = res.get("data", [])
    if not items:
        sys.exit(f"error: nessuna app trovata con bundle ID {BUNDLE_ID}")
    return items[0]["id"]


def get_version(app_id, platform, version_string):
    res = call(
        "GET",
        f"/apps/{app_id}/appStoreVersions"
        f"?filter[platform]={platform}&filter[versionString]={version_string}"
        f"&include=appStoreVersionLocalizations",
    )
    items = res.get("data", [])
    if not items:
        return None, res
    return items[0], res


def cmd_get_version(platform, version_string):
    app_id = get_app_id()
    version, res = get_version(app_id, platform, version_string)
    print(json.dumps(res, indent=2))


def cmd_set_notes(platform, version_string, locale, text):
    app_id = get_app_id()
    version, res = get_version(app_id, platform, version_string)
    if version is None:
        sys.exit(f"error: versione {version_string} ({platform}) non trovata su App Store Connect")
    loc = next(
        (l for l in res.get("included", []) if l["attributes"]["locale"] == locale),
        None,
    )
    if loc is None:
        sys.exit(f"error: nessuna localizzazione '{locale}' per la versione {version_string}")
    call(
        "PATCH",
        f"/appStoreVersionLocalizations/{loc['id']}",
        {"data": {"type": "appStoreVersionLocalizations", "id": loc["id"], "attributes": {"whatsNew": text}}},
    )
    print(f"ok: whatsNew aggiornato per {locale} su {version_string} ({platform})")


def cmd_set_description(platform, version_string, locale, text):
    app_id = get_app_id()
    version, res = get_version(app_id, platform, version_string)
    if version is None:
        sys.exit(f"error: versione {version_string} ({platform}) non trovata su App Store Connect")
    loc = next(
        (l for l in res.get("included", []) if l["attributes"]["locale"] == locale),
        None,
    )
    if loc is None:
        sys.exit(f"error: nessuna localizzazione '{locale}' per la versione {version_string}")
    call(
        "PATCH",
        f"/appStoreVersionLocalizations/{loc['id']}",
        {"data": {"type": "appStoreVersionLocalizations", "id": loc["id"], "attributes": {"description": text}}},
    )
    print(f"ok: description aggiornata per {locale} su {version_string} ({platform})")


COMMANDS = {
    "get-version": cmd_get_version,
    "set-notes": cmd_set_notes,
    "set-description": cmd_set_description,
}


def main():
    load_env()
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        sys.exit(__doc__)
    COMMANDS[sys.argv[1]](*sys.argv[2:])


if __name__ == "__main__":
    main()
