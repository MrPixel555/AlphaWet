#!/usr/bin/env python3
import io
import json
import os
import pathlib
import re
import sys
import urllib.request
import zipfile

API_URL = 'https://api.github.com/repos/XTLS/Xray-core/releases/latest'

EXACT_ASSET_NAMES = {
    'windows': 'Xray-windows-64.zip',
    'linux': 'Xray-linux-64.zip',
}

BINARY_NAMES = {
    'windows': 'xray.exe',
    'linux': 'xray',
}


def fetch_json(url: str):
    request = urllib.request.Request(
        url,
        headers={
            'Accept': 'application/vnd.github+json',
            'User-Agent': 'AlphaWet-GitHub-Actions',
        },
    )
    with urllib.request.urlopen(request) as response:
        return json.load(response)


def download_bytes(url: str) -> bytes:
    request = urllib.request.Request(url, headers={'User-Agent': 'AlphaWet-GitHub-Actions'})
    with urllib.request.urlopen(request) as response:
        return response.read()


def select_asset(assets, platform_key: str):
    exact_name = EXACT_ASSET_NAMES[platform_key].lower()
    for asset in assets:
        if asset.get('name', '').lower() == exact_name:
            return asset

    pattern = re.compile(rf'^xray-{platform_key}-(64|amd64)\.zip$', re.IGNORECASE)
    for asset in assets:
        name = asset.get('name', '')
        if pattern.match(name):
            return asset

    raise SystemExit(f'Could not find a release asset for platform: {platform_key}')


def extract_from_zip(zip_bytes: bytes, member_basename: str) -> bytes:
    with zipfile.ZipFile(io.BytesIO(zip_bytes)) as archive:
        for member in archive.namelist():
            if pathlib.PurePosixPath(member).name.lower() == member_basename.lower():
                return archive.read(member)
    raise SystemExit(f'Archive did not contain required file: {member_basename}')


def extract_optional(zip_bytes: bytes, member_basename: str):
    with zipfile.ZipFile(io.BytesIO(zip_bytes)) as archive:
        for member in archive.namelist():
            if pathlib.PurePosixPath(member).name.lower() == member_basename.lower():
                return archive.read(member)
    return None


def main() -> int:
    repo_root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else '.').resolve()
    assets_root = repo_root / 'assets' / 'xray'
    (assets_root / 'windows').mkdir(parents=True, exist_ok=True)
    (assets_root / 'linux').mkdir(parents=True, exist_ok=True)
    (assets_root / 'common').mkdir(parents=True, exist_ok=True)

    release = fetch_json(API_URL)
    assets = release.get('assets', [])
    if not assets:
        raise SystemExit('Latest Xray release did not expose downloadable assets.')

    for platform_key in ('windows', 'linux'):
        asset = select_asset(assets, platform_key)
        print(f'[INFO] Downloading {asset["name"]} ...')
        zip_bytes = download_bytes(asset['browser_download_url'])
        binary_name = BINARY_NAMES[platform_key]
        target_binary = assets_root / platform_key / binary_name
        target_binary.write_bytes(extract_from_zip(zip_bytes, binary_name))
        print(f'[OK] Wrote {target_binary}')

        geoip_bytes = extract_optional(zip_bytes, 'geoip.dat')
        geosite_bytes = extract_optional(zip_bytes, 'geosite.dat')
        if geoip_bytes is not None:
            (assets_root / 'common' / 'geoip.dat').write_bytes(geoip_bytes)
            print('[OK] Wrote assets/xray/common/geoip.dat')
        if geosite_bytes is not None:
            (assets_root / 'common' / 'geosite.dat').write_bytes(geosite_bytes)
            print('[OK] Wrote assets/xray/common/geosite.dat')

    return 0


if __name__ == '__main__':
    raise SystemExit(main())
