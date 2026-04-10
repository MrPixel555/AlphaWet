from pathlib import Path
import re
import sys


LINKER_BLOCK = """if (MSVC)
  target_link_options(${BINARY_NAME} PRIVATE
    \"/MANIFESTUAC:level='requireAdministrator'\"
    \"/MANIFESTUAC:uiAccess='false'\"
  )
endif()
"""

MANIFEST_UAC_MARKERS = (
    "/MANIFESTUAC:level='requireAdministrator'",
    '/MANIFESTUAC:level=\'requireAdministrator\'',
    '/MANIFESTUAC:\"level=\'requireAdministrator\' uiAccess=\'false\'\"',
)


def resolve_cmake_path(argv: list[str]) -> Path:
    if len(argv) > 1:
        return Path(argv[1])
    return Path('windows/runner/CMakeLists.txt')


def already_patched(text: str) -> bool:
    return any(marker in text for marker in MANIFEST_UAC_MARKERS)


def patch_cmake(text: str) -> tuple[str, str]:
    if already_patched(text):
        return text, 'Windows runner CMake already configures requireAdministrator UAC.'

    pattern = re.compile(r'(^\s*apply_standard_settings\(\$\{BINARY_NAME\}\)\s*$)', re.MULTILINE)
    match = pattern.search(text)
    if match:
        insert_at = match.end(1)
        updated = text[:insert_at] + '\n\n' + LINKER_BLOCK + text[insert_at:]
        return updated, 'Inserted MSVC /MANIFESTUAC linker options after apply_standard_settings().'

    updated = text.rstrip() + '\n\n' + LINKER_BLOCK
    return updated, 'Appended MSVC /MANIFESTUAC linker options to windows/runner/CMakeLists.txt.'


def main() -> int:
    cmake_path = resolve_cmake_path(sys.argv)
    if not cmake_path.exists():
        raise SystemExit(f'Windows runner CMake file not found: {cmake_path}')

    original = cmake_path.read_text(encoding='utf-8')
    updated, reason = patch_cmake(original)

    if updated == original:
        print(f'[OK] {reason} ({cmake_path})')
        return 0

    cmake_path.write_text(updated, encoding='utf-8', newline='\n')
    print(f'[OK] Updated Windows runner build settings: {cmake_path} ({reason})')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
