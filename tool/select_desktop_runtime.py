#!/usr/bin/env python3
import pathlib
import shutil
import sys

BINARY_NAMES = {
    'windows': 'xray.exe',
    'linux': 'xray',
}


def main() -> int:
    if len(sys.argv) < 2 or sys.argv[1].lower() not in BINARY_NAMES:
        print('Usage: tool/select_desktop_runtime.py <windows|linux> [repo_root]', file=sys.stderr)
        return 1

    platform_key = sys.argv[1].lower()
    repo_root = pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else '.').resolve()
    assets_root = repo_root / 'assets' / 'xray'
    source_dir = assets_root / platform_key
    active_dir = assets_root / 'desktop'
    source_file = source_dir / BINARY_NAMES[platform_key]

    if not source_file.is_file():
        print(f'[ERROR] Missing source runtime: {source_file}', file=sys.stderr)
        return 2

    active_dir.mkdir(parents=True, exist_ok=True)
    for binary_name in set(BINARY_NAMES.values()):
        candidate = active_dir / binary_name
        if candidate.exists():
            candidate.unlink()

    target_file = active_dir / BINARY_NAMES[platform_key]
    shutil.copy2(source_file, target_file)
    print(f'[OK] Activated desktop runtime: {platform_key} -> {target_file}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
