#!/usr/bin/env python3
import io
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
import zipfile

API_URL = 'https://api.github.com/repos/XTLS/Xray-core/releases/latest'
LATEST_DOWNLOAD_BASE_URL = 'https://github.com/XTLS/Xray-core/releases/latest/download'

EXACT_ASSET_NAMES = {
    'windows': 'Xray-windows-64.zip',
    'linux': 'Xray-linux-64.zip',
}

BINARY_NAMES = {
    'windows': 'xray.exe',
    'linux': 'xray',
}

OPTIONAL_PLATFORM_MEMBERS = {
    'windows': ('wintun.dll',),
    'linux': (),
}


def build_headers(extra_headers=None):
    headers = {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'AlphaWet-GitHub-Actions',
    }

    github_token = os.environ.get('XRAY_GITHUB_TOKEN') or os.environ.get('GITHUB_TOKEN')
    if github_token:
        headers['Authorization'] = f'Bearer {github_token}'
        headers['X-GitHub-Api-Version'] = '2022-11-28'

    if extra_headers:
        headers.update(extra_headers)

    return headers


def fetch_json(url: str):
    request = urllib.request.Request(url, headers=build_headers())
    with urllib.request.urlopen(request) as response:
        return json.load(response)


def download_bytes(url: str) -> bytes:
    request = urllib.request.Request(
        url,
        headers=build_headers({'Accept': 'application/octet-stream'}),
    )
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


def download_release_zip(platform_key: str) -> bytes:
    asset_name = EXACT_ASSET_NAMES[platform_key]
    direct_url = f'{LATEST_DOWNLOAD_BASE_URL}/{asset_name}'

    try:
        print(f'[INFO] Downloading {asset_name} from latest/download ...')
        return download_bytes(direct_url)
    except urllib.error.HTTPError as error:
        if error.code not in (403, 404):
            raise
        print(
            f'[WARN] latest/download returned HTTP {error.code} for {asset_name}; '
            'falling back to GitHub API release discovery.'
        )

    release = fetch_json(API_URL)
    assets = release.get('assets', [])
    if not assets:
        raise SystemExit('Latest Xray release did not expose downloadable assets.')

    asset = select_asset(assets, platform_key)
    print(f'[INFO] Downloading {asset["name"]} from GitHub API metadata ...')
    return download_bytes(asset['browser_download_url'])


def activate_target(repo_root: pathlib.Path, platform_key: str) -> None:
    script = repo_root / 'tool' / 'select_desktop_runtime.py'
    subprocess.run([sys.executable, str(script), platform_key, str(repo_root)], check=True)


def main() -> int:
    repo_root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else '.').resolve()
    target_platform = sys.argv[2].lower() if len(sys.argv) > 2 else os.environ.get('ALPHAWET_DESKTOP_TARGET', '').lower()
    if target_platform and target_platform not in BINARY_NAMES:
        raise SystemExit('Target platform must be windows or linux.')

    assets_root = repo_root / 'assets' / 'xray'
    (assets_root / 'windows').mkdir(parents=True, exist_ok=True)
    (assets_root / 'linux').mkdir(parents=True, exist_ok=True)
    (assets_root / 'desktop').mkdir(parents=True, exist_ok=True)
    (assets_root / 'common').mkdir(parents=True, exist_ok=True)

    for platform_key in ('windows', 'linux'):
        zip_bytes = download_release_zip(platform_key)
        binary_name = BINARY_NAMES[platform_key]
        target_binary = assets_root / platform_key / binary_name
        target_binary.write_bytes(extract_from_zip(zip_bytes, binary_name))
        print(f'[OK] Wrote {target_binary}')

        for extra_name in OPTIONAL_PLATFORM_MEMBERS.get(platform_key, ()):
            extra_bytes = extract_optional(zip_bytes, extra_name)
            if extra_bytes is not None:
                extra_target = assets_root / platform_key / extra_name
                extra_target.write_bytes(extra_bytes)
                print(f'[OK] Wrote {extra_target}')

        geoip_bytes = extract_optional(zip_bytes, 'geoip.dat')
        geosite_bytes = extract_optional(zip_bytes, 'geosite.dat')
        if geoip_bytes is not None:
            (assets_root / 'common' / 'geoip.dat').write_bytes(geoip_bytes)
            print('[OK] Wrote assets/xray/common/geoip.dat')
        if geosite_bytes is not None:
            (assets_root / 'common' / 'geosite.dat').write_bytes(geosite_bytes)
            print('[OK] Wrote assets/xray/common/geosite.dat')

    if target_platform:
        activate_target(repo_root, target_platform)
    else:
        print('[INFO] Source runtimes were refreshed. Activate one target with tool/select_desktop_runtime.py.')

    return 0


if __name__ == '__main__':
    raise SystemExit(main())
