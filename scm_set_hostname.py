#!/usr/bin/env python3
"""
scm_set_hostname.py — Read and optionally set a device display_name in SCM.

Looks up a device by serial number within an SCM folder, prints the current
display_name, and updates it if a --hostname is provided and it differs.

Credentials are read from environment variables:
    SCM_CLIENT_ID      OAuth2 client ID
    SCM_CLIENT_SECRET  OAuth2 client secret
    SCM_SCOPE          OAuth2 scope (e.g. tsg_id:1234567890)

Usage:
    export SCM_CLIENT_ID=...
    export SCM_CLIENT_SECRET=...
    export SCM_SCOPE=tsg_id:...

    python3 scm_set_hostname.py --folder <folder> --serial <serial> --hostname <hostname>
    python3 scm_set_hostname.py --folder <folder> --serial <serial>  # read-only

Requirements:
    pip install requests
"""

import argparse
import os
import sys
import requests

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

AUTH_URL = "https://auth.apps.paloaltonetworks.com/auth/v1/oauth2/access_token"
API_BASE = "https://api.sase.paloaltonetworks.com"


def get_token(client_id, client_secret, scope):
    r = requests.post(AUTH_URL, data={
        "grant_type":    "client_credentials",
        "client_id":     client_id,
        "client_secret": client_secret,
        "scope":         scope,
    })
    r.raise_for_status()
    return r.json()["access_token"]


def find_device(token, folder, serial):
    """List devices in folder and find by serial number."""
    headers = {"Authorization": f"Bearer {token}"}
    params  = {"folder": folder, "limit": 200}

    r = requests.get(f"{API_BASE}/sase/config/v1/folders", headers=headers, params=params)
    if not r.ok:
        print(f"GET /sase/config/v1/folders failed: {r.status_code} {r.text}")
        sys.exit(1)

    data = r.json()
    items = data if isinstance(data, list) else data.get("data", data.get("items", []))

    for item in items:
        if item.get("name") == serial:
            return item

    return None


def set_hostname(token, device_id, serial, hostname):
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type":  "application/json",
    }
    body = {"name": serial, "display_name": hostname}

    r = requests.put(
        f"{API_BASE}/sase/config/v1/folders/{device_id}",
        headers=headers,
        json=body,
    )
    if not r.ok:
        print(f"PUT failed: {r.status_code} {r.text}")
        sys.exit(1)
    return r.json()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Read/set SCM device display_name")
    parser.add_argument("--folder",   required=True, help="SCM folder name")
    parser.add_argument("--serial",   required=True, help="Device serial number")
    parser.add_argument("--hostname", default=None,  help="Desired hostname (omit for read-only)")
    args = parser.parse_args()

    client_id     = os.environ.get("SCM_CLIENT_ID")
    client_secret = os.environ.get("SCM_CLIENT_SECRET")
    scope         = os.environ.get("SCM_SCOPE")

    missing = [k for k, v in {"SCM_CLIENT_ID": client_id, "SCM_CLIENT_SECRET": client_secret, "SCM_SCOPE": scope}.items() if not v]
    if missing:
        print(f"ERROR: Missing environment variables: {', '.join(missing)}")
        sys.exit(1)

    print("Getting token...")
    token = get_token(client_id, client_secret, scope)
    print("Token OK")

    print(f"Looking for serial {args.serial} in folder '{args.folder}'...")
    device = find_device(token, args.folder, args.serial)

    if not device:
        print(f"ERROR: Device with serial '{args.serial}' not found in folder '{args.folder}'")
        sys.exit(1)

    device_id    = device.get("id")
    current_name = device.get("display_name") or device.get("name")
    print(f"Found device: id={device_id}  current display_name='{current_name}'")

    if args.hostname is None:
        print("No --hostname specified. Read-only mode, done.")
        return

    if current_name == args.hostname:
        print(f"display_name already '{args.hostname}', nothing to do.")
        return

    print(f"Setting display_name '{current_name}' → '{args.hostname}'...")
    result = set_hostname(token, device_id, args.serial, args.hostname)
    print(f"Done: {result}")


if __name__ == "__main__":
    main()
