from pathlib import Path
import re
import sys


TRUST_INFO_BLOCK = '''  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">
    <security>
      <requestedPrivileges>
        <requestedExecutionLevel level="requireAdministrator" uiAccess="false"/>
      </requestedPrivileges>
    </security>
  </trustInfo>
'''


REQUESTED_EXECUTION_LEVEL_RE = re.compile(
    r'(<requestedExecutionLevel\b[^>]*\blevel\s*=\s*)(["\'])([^"\']*)(\2)([^>]*?/?>)',
    flags=re.IGNORECASE | re.DOTALL,
)


SECURITY_CLOSE_RE = re.compile(r'(</security\s*>)', flags=re.IGNORECASE)
ASSEMBLY_CLOSE_RE = re.compile(r'(</assembly\s*>)', flags=re.IGNORECASE)



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



def inject_requested_privileges(xml_text: str) -> tuple[str, str]:
    requested_privileges = (
        '      <requestedPrivileges>\n'
        '        <requestedExecutionLevel level="requireAdministrator" uiAccess="false"/>\n'
        '      </requestedPrivileges>\n'
    )

    if SECURITY_CLOSE_RE.search(xml_text):
        updated = SECURITY_CLOSE_RE.sub(requested_privileges + r'\1', xml_text, count=1)
        return updated, 'Inserted requestedPrivileges inside existing <security> block.'

    if ASSEMBLY_CLOSE_RE.search(xml_text):
        updated = ASSEMBLY_CLOSE_RE.sub(TRUST_INFO_BLOCK + r'\1', xml_text, count=1)
        return updated, 'Inserted new <trustInfo> block before </assembly>.'

    raise SystemExit('Could not find a safe insertion point in the Windows manifest.')



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
        manifest_path.write_text(updated, encoding='utf-8')
        print(f'[OK] Updated requestedExecutionLevel in Windows manifest: {manifest_path}')
        return 0

    updated, reason = inject_requested_privileges(original)
    manifest_path.write_text(updated, encoding='utf-8')
    print(f'[OK] Updated Windows manifest: {manifest_path} ({reason})')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
