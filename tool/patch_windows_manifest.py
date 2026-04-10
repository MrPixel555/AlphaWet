from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET


TRUST_INFO_BLOCK = '''  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v2">
    <security>
      <requestedPrivileges xmlns="urn:schemas-microsoft-com:asm.v3">
        <requestedExecutionLevel level="requireAdministrator" uiAccess="false" />
      </requestedPrivileges>
    </security>
  </trustInfo>
'''

REQUESTED_EXECUTION_LEVEL_RE = re.compile(
    r'(<requestedExecutionLevel\b[^>]*\blevel\s*=\s*)(["\'])([^"\']*)(\2)([^>]*?/?>)',
    flags=re.IGNORECASE | re.DOTALL,
)
REQUESTED_PRIVILEGES_OPEN_RE = re.compile(r'(<requestedPrivileges\b[^>]*>)', flags=re.IGNORECASE)
SECURITY_OPEN_RE = re.compile(r'(<security\b[^>]*>)', flags=re.IGNORECASE)
TRUST_INFO_OPEN_RE = re.compile(r'(<trustInfo\b[^>]*>)', flags=re.IGNORECASE)
ASSEMBLY_OPEN_RE = re.compile(r'(<assembly\b[^>]*>)', flags=re.IGNORECASE | re.DOTALL)


REQUESTED_EXECUTION_LEVEL_ONLY = (
    '        <requestedExecutionLevel level="requireAdministrator" uiAccess="false" />\n'
)
REQUESTED_PRIVILEGES_BLOCK = (
    '      <requestedPrivileges xmlns="urn:schemas-microsoft-com:asm.v3">\n'
    '        <requestedExecutionLevel level="requireAdministrator" uiAccess="false" />\n'
    '      </requestedPrivileges>\n'
)
SECURITY_BLOCK = (
    '    <security>\n'
    '      <requestedPrivileges xmlns="urn:schemas-microsoft-com:asm.v3">\n'
    '        <requestedExecutionLevel level="requireAdministrator" uiAccess="false" />\n'
    '      </requestedPrivileges>\n'
    '    </security>\n'
)


def resolve_manifest_path(argv: list[str]) -> Path:
    if len(argv) > 1:
        return Path(argv[1])

    candidates = [
        Path('windows/runner/Runner.exe.manifest'),
        Path('windows/runner/runner.exe.manifest'),
    ]
    for candidate in candidates:
        if candidate.exists():
            return candidate
    return candidates[0]



def replace_requested_execution_level(xml_text: str) -> tuple[str, bool]:
    def _repl(match: re.Match[str]) -> str:
        prefix, quote, _level, closing_quote, suffix = match.groups()
        return f'{prefix}{quote}requireAdministrator{closing_quote}{suffix}'

    updated, count = REQUESTED_EXECUTION_LEVEL_RE.subn(_repl, xml_text, count=1)
    return updated, count > 0



def insert_after_first(pattern: re.Pattern[str], xml_text: str, block: str, reason: str) -> tuple[str, str] | None:
    match = pattern.search(xml_text)
    if not match:
        return None
    insert_at = match.end(1)
    updated = xml_text[:insert_at] + '\n' + block + xml_text[insert_at:]
    return updated, reason



def ensure_trust_info(xml_text: str) -> tuple[str, str]:
    for pattern, block, reason in (
        (
            REQUESTED_PRIVILEGES_OPEN_RE,
            REQUESTED_EXECUTION_LEVEL_ONLY,
            'Inserted requestedExecutionLevel inside existing <requestedPrivileges> block.',
        ),
        (
            SECURITY_OPEN_RE,
            REQUESTED_PRIVILEGES_BLOCK,
            'Inserted requestedPrivileges inside existing <security> block.',
        ),
        (
            TRUST_INFO_OPEN_RE,
            SECURITY_BLOCK,
            'Inserted security/requestedPrivileges inside existing <trustInfo> block.',
        ),
        (
            ASSEMBLY_OPEN_RE,
            TRUST_INFO_BLOCK,
            'Inserted canonical <trustInfo> block after <assembly>.',
        ),
    ):
        result = insert_after_first(pattern, xml_text, block, reason)
        if result is not None:
            return result

    raise SystemExit('Could not find a safe insertion point in the Windows manifest.')



def validate_xml(xml_text: str) -> None:
    try:
        ET.fromstring(xml_text)
    except ET.ParseError as error:
        raise SystemExit(f'Patched Windows manifest is not valid XML: {error}') from error



def main() -> int:
    manifest_path = resolve_manifest_path(sys.argv)
    if not manifest_path.exists():
        raise SystemExit(f'Manifest not found: {manifest_path}')

    original = manifest_path.read_text(encoding='utf-8')
    if 'requireAdministrator' in original:
        print(f'[OK] Windows manifest already requires elevation: {manifest_path}')
        return 0

    updated, replaced = replace_requested_execution_level(original)
    if replaced:
        validate_xml(updated)
        manifest_path.write_text(updated, encoding='utf-8')
        print(f'[OK] Updated requestedExecutionLevel in Windows manifest: {manifest_path}')
        return 0

    updated, reason = ensure_trust_info(original)
    validate_xml(updated)
    manifest_path.write_text(updated, encoding='utf-8')
    print(f'[OK] Updated Windows manifest: {manifest_path} ({reason})')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
