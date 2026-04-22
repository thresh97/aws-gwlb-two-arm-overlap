#!/usr/bin/env python3
"""
scm_set_hostname.py — Read and optionally set a device display_name in SCM.

Credentials are read from environment variables (SCM_CLIENT_ID, SCM_CLIENT_SECRET,
SCM_SCOPE) or from terraform.tfvars in the current directory. Environment variables
take precedence.

Usage:
    # List all devices in a folder (serial / hostname table)
    python3 scm_set_hostname.py --folder <folder>

    # Show current hostname for a specific device
    python3 scm_set_hostname.py --folder <folder> --serial <serial>

    # Set hostname if different from current
    python3 scm_set_hostname.py --folder <folder> --serial <serial> --hostname <hostname>

Requirements:
    pip install requests
"""

import argparse
import os
import re
import sys
import requests

AUTH_URL = "https://auth.apps.paloaltonetworks.com/auth/v1/oauth2/access_token"
API_BASE = "https://api.sase.paloaltonetworks.com"
TFVARS   = "terraform.tfvars"

TFVAR_KEYS = {
    "SCM_CLIENT_ID":     "scm_client_id",
    "SCM_CLIENT_SECRET": "scm_client_secret",
    "SCM_SCOPE":         "scm_scope",
}


def read_tfvars():
    values = {}
    try:
        with open(TFVARS) as f:
            for line in f:
                for env_key, tf_key in TFVAR_KEYS.items():
                    m = re.match(rf'^\s*{tf_key}\s*=\s*"([^"]+)"', line)
                    if m:
                        values[env_key] = m.group(1)
    except FileNotFoundError:
        pass
    return values


def get_creds():
    """Return (client_id, client_secret, scope). Env vars override tfvars."""
    tfvars = read_tfvars()
    creds  = {k: os.environ.get(k) or tfvars.get(k) for k in TFVAR_KEYS}
    missing = [k for k, v in creds.items() if not v]
    if missing:
        print(f"ERROR: Missing credentials (set env vars or add to terraform.tfvars): {', '.join(missing)}")
        sys.exit(1)
    return creds["SCM_CLIENT_ID"], creds["SCM_CLIENT_SECRET"], creds["SCM_SCOPE"]


def get_token(client_id, client_secret, scope):
    r = requests.post(AUTH_URL, data={
        "grant_type":    "client_credentials",
        "client_id":     client_id,
        "client_secret": client_secret,
        "scope":         scope,
    })
    r.raise_for_status()
    return r.json()["access_token"]


def list_devices(token, folder):
    headers = {"Authorization": f"Bearer {token}"}
    params  = {"folder": folder, "limit": 200}
    r = requests.get(f"{API_BASE}/sase/config/v1/folders", headers=headers, params=params)
    if not r.ok:
        print(f"GET /sase/config/v1/folders failed: {r.status_code} {r.text}")
        sys.exit(1)
    data = r.json()
    return data if isinstance(data, list) else data.get("data", data.get("items", []))


def find_device(items, serial):
    for item in items:
        if item.get("name") == serial:
            return item
    return None


def set_hostname(token, device_id, serial, hostname):
    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
    r = requests.put(
        f"{API_BASE}/sase/config/v1/folders/{device_id}",
        headers=headers,
        json={"name": serial, "display_name": hostname},
    )
    if not r.ok:
        print(f"PUT failed: {r.status_code} {r.text}")
        sys.exit(1)
    return r.json()


def main():
    parser = argparse.ArgumentParser(description="Read/set SCM device display_name")
    parser.add_argument("--folder",   required=True, help="SCM folder name")
    parser.add_argument("--serial",   default=None,  help="Device serial number (omit to list all)")
    parser.add_argument("--hostname", default=None,  help="Desired hostname (omit for read-only)")
    parser.add_argument("--debug",    action="store_true", help="Dump HTTP request/response details")
    args = parser.parse_args()

    if args.debug:
        import logging
        import http.client
        http.client.HTTPSConnection.debuglevel = 1
        logging.basicConfig(level=logging.DEBUG)
        requests_log = logging.getLogger("urllib3")
        requests_log.setLevel(logging.DEBUG)
        requests_log.propagate = True

    client_id, client_secret, scope = get_creds()
    token = get_token(client_id, client_secret, scope)
    items = list_devices(token, args.folder)

    # --- folder-only: dump table ---
    if args.serial is None:
        col_s = max(len("SERIAL"),   max((len(d.get("name", "")) for d in items), default=0))
        col_h = max(len("HOSTNAME"), max((len(d.get("display_name", "") or "") for d in items), default=0))
        fmt = f"{{:<{col_s}}}  {{:<{col_h}}}"
        print(fmt.format("SERIAL", "HOSTNAME"))
        print("-" * (col_s + col_h + 2))
        for d in items:
            print(fmt.format(d.get("name", ""), d.get("display_name", "") or ""))
        return

    # --- serial provided ---
    device = find_device(items, args.serial)
    if not device:
        print(f"ERROR: Serial '{args.serial}' not found in folder '{args.folder}'")
        sys.exit(1)

    device_id    = device.get("id")
    current_name = device.get("display_name") or device.get("name")
    print(f"serial={args.serial}  display_name='{current_name}'  id={device_id}")

    if args.hostname is None:
        return

    if current_name == args.hostname:
        print(f"Already '{args.hostname}', nothing to do.")
        return

    print(f"Setting '{current_name}' → '{args.hostname}'...")
    set_hostname(token, device_id, args.serial, args.hostname)
    print("Done.")


if __name__ == "__main__":
    main()
