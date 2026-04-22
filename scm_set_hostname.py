#!/usr/bin/env python3
"""
scm_set_hostname.py — Read and optionally set a device display_name in SCM.

Credentials are read from environment variables (takes precedence) or
terraform.tfvars in the current directory:
    SCM_CLIENT_ID      OAuth2 client ID
    SCM_CLIENT_SECRET  OAuth2 client secret
    SCM_SCOPE          OAuth2 scope (e.g. tsg_id:1234567890)

Optional env var:
    SCM_PANORAMA_HOST  Panorama API host (default: paas-12.prod.panorama.paloaltonetworks.com)

Usage:
    # List all devices in a folder (serial / hostname table)
    python3 scm_set_hostname.py --folder <folder>

    # Show current hostname for a specific serial
    python3 scm_set_hostname.py --folder <folder> --serial <serial>

    # Set hostname if different
    python3 scm_set_hostname.py --folder <folder> --serial <serial> --hostname <hostname>

    # Skip discovery with known device UUID
    python3 scm_set_hostname.py --folder <folder> --serial <serial> --hostname <hostname> --device-id <uuid>

    # Show HTTP traffic
    python3 scm_set_hostname.py --folder <folder> --debug

Requirements:
    pip install requests
"""

import argparse
import os
import re
import sys
import requests

AUTH_URL  = "https://auth.apps.paloaltonetworks.com/auth/v1/oauth2/access_token"
TFVARS    = "terraform.tfvars"

TFVAR_KEYS = {
    "SCM_CLIENT_ID":     "scm_client_id",
    "SCM_CLIENT_SECRET": "scm_client_secret",
    "SCM_SCOPE":         "scm_scope",
}


# ---------------------------------------------------------------------------
# Credentials
# ---------------------------------------------------------------------------

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
    tfvars = read_tfvars()
    creds  = {k: os.environ.get(k) or tfvars.get(k) for k in TFVAR_KEYS}
    missing = [k for k, v in creds.items() if not v]
    if missing:
        print(f"ERROR: Missing credentials (env vars or terraform.tfvars): {', '.join(missing)}")
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


# ---------------------------------------------------------------------------
# Tree walking
# ---------------------------------------------------------------------------

def find_folder_node(tree, folder_name):
    """Recursively find a node by name in the folder tree."""
    for node in tree:
        if node.get("name") == folder_name:
            return node
        children = node.get("children", [])
        result = find_folder_node(children, folder_name)
        if result:
            return result
    return None


def collect_devices(node):
    """Collect all on-prem devices within a node and its descendants."""
    devices = []
    if node.get("type") == "on-prem":
        devices.append(node)
    for child in node.get("children", []):
        devices.extend(collect_devices(child))
    return devices


def fetch_tree(token, panorama_host, debug=False):
    url     = f"https://{panorama_host}/sase/config/v1/folders"
    headers = {"x-auth-jwt": token}
    params  = {"pagination": "false"}
    r = requests.get(url, headers=headers, params=params)
    if debug:
        print(f"  GET {r.url} -> {r.status_code}")
    if not r.ok:
        print(f"ERROR: {r.status_code} {r.text}")
        sys.exit(1)
    data = r.json()
    return data if isinstance(data, list) else data.get("data", [])


def list_devices(token, folder, panorama_host, debug=False):
    tree   = fetch_tree(token, panorama_host, debug)
    node   = find_folder_node(tree, folder)
    if node is None:
        print(f"ERROR: Folder '{folder}' not found in SCM tree.")
        sys.exit(1)
    return collect_devices(node)


# ---------------------------------------------------------------------------
# Update
# ---------------------------------------------------------------------------

def set_hostname(token, panorama_host, device_id, serial, hostname):
    url     = f"https://{panorama_host}/sase/config/v1/folders/{device_id}"
    headers = {"x-auth-jwt": token, "Content-Type": "application/json"}
    r = requests.put(url, headers=headers, json={"name": serial, "display_name": hostname})
    if not r.ok:
        print(f"PUT failed: {r.status_code} {r.text}")
        sys.exit(1)
    return r.json()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Read/set SCM device display_name")
    parser.add_argument("--folder",    required=True, help="SCM folder name")
    parser.add_argument("--serial",    default=None,  help="Device serial number (omit to list all)")
    parser.add_argument("--hostname",  default=None,  help="Desired hostname (omit for read-only)")
    parser.add_argument("--device-id", default=None,  help="SCM device UUID (bypasses tree discovery)")
    parser.add_argument("--debug",     action="store_true", help="Dump HTTP request/response details")
    args = parser.parse_args()

    panorama_host = os.environ.get("SCM_PANORAMA_HOST", "paas-12.prod.panorama.paloaltonetworks.com")

    if args.debug:
        import logging
        import http.client
        http.client.HTTPSConnection.debuglevel = 1
        logging.basicConfig(level=logging.DEBUG)
        logging.getLogger("urllib3").setLevel(logging.DEBUG)

    client_id, client_secret, scope = get_creds()
    token = get_token(client_id, client_secret, scope)

    # --- device-id shortcut ---
    if args.device_id:
        if not args.serial or not args.hostname:
            print("ERROR: --device-id requires --serial and --hostname")
            sys.exit(1)
        print(f"Setting display_name via device-id {args.device_id}...")
        set_hostname(token, panorama_host, args.device_id, args.serial, args.hostname)
        print("Done.")
        return

    devices = list_devices(token, args.folder, panorama_host, debug=args.debug)

    # --- folder only: dump table ---
    if args.serial is None:
        if not devices:
            print(f"No devices found in folder '{args.folder}'.")
            return
        col_s = max(len("SERIAL"),   max(len(d.get("serial_number", "")) for d in devices))
        col_h = max(len("HOSTNAME"), max(len(d.get("display_name", "") or "") for d in devices))
        col_i = max(len("ID"),       max(len(d.get("id", "")) for d in devices))
        fmt = f"{{:<{col_s}}}  {{:<{col_h}}}  {{:<{col_i}}}"
        print(fmt.format("SERIAL", "HOSTNAME", "ID"))
        print("-" * (col_s + col_h + col_i + 4))
        for d in devices:
            print(fmt.format(
                d.get("serial_number", ""),
                d.get("display_name", "") or "",
                d.get("id", ""),
            ))
        return

    # --- serial provided ---
    device = next((d for d in devices if d.get("serial_number") == args.serial), None)
    if not device:
        print(f"ERROR: Serial '{args.serial}' not found in folder '{args.folder}'")
        sys.exit(1)

    device_id    = device["id"]
    current_name = device.get("display_name") or ""
    print(f"serial={args.serial}  display_name='{current_name}'  id={device_id}")

    if args.hostname is None:
        return

    if current_name == args.hostname:
        print(f"Already '{args.hostname}', nothing to do.")
        return

    print(f"Setting '{current_name}' → '{args.hostname}'...")
    set_hostname(token, panorama_host, device_id, args.serial, args.hostname)
    print("Done.")


if __name__ == "__main__":
    main()
