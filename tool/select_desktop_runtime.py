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
    for candidate in active_dir.iterdir():
        if candidate.is_file() or candidate.is_symlink():
            candidate.unlink()
        elif candidate.is_dir():
            shutil.rmtree(candidate)

    copied = []
    for candidate in source_dir.iterdir():
        if not candidate.is_file():
            continue
        target_file = active_dir / candidate.name
        shutil.copy2(candidate, target_file)
        copied.append(target_file.name)

    print(
        f'[OK] Activated desktop runtime: {platform_key} -> {active_dir} '
        f'({", ".join(sorted(copied))})'
    )
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
