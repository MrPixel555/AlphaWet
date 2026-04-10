from pathlib import Path
import sys


def main() -> int:
    manifest_path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path('windows/runner/Runner.exe.manifest')
    if not manifest_path.exists():
        raise SystemExit(f'Manifest not found: {manifest_path}')

    original = manifest_path.read_text(encoding='utf-8')
    if 'requireAdministrator' in original:
        print(f'[OK] Windows manifest already requires elevation: {manifest_path}')
        return 0

    old = '<requestedExecutionLevel level="asInvoker" uiAccess="false"/>'
    new = '<requestedExecutionLevel level="requireAdministrator" uiAccess="false"/>'
    if old not in original:
        raise SystemExit('Could not find the default requestedExecutionLevel entry in the Windows manifest.')

    manifest_path.write_text(original.replace(old, new), encoding='utf-8')
    print(f'[OK] Updated Windows manifest: {manifest_path}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
