#!/usr/bin/env python3
from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image, ImageDraw


APP_NAME = "AlphaWet"
PACKAGE_NAME = "ir.alphacraft.alphawet"
ASSET_DIR = Path("assets/common/logo")
ICO_NAME = "applogo.ico"
IN_APP_NAME = "inapplogo.png"


def ensure_logo_assets(repo_root: Path) -> tuple[Path, Path]:
    asset_dir = repo_root / ASSET_DIR
    asset_dir.mkdir(parents=True, exist_ok=True)
    ico_path = asset_dir / ICO_NAME
    png_path = asset_dir / IN_APP_NAME

    if ico_path.exists():
        icon = Image.open(ico_path)
    elif png_path.exists():
        icon = Image.open(png_path)
    else:
        icon = _build_fallback_icon()

    if icon.mode != "RGBA":
        icon = icon.convert("RGBA")

    if not png_path.exists():
        icon.resize((512, 512), Image.LANCZOS).save(png_path, format="PNG")

    if not ico_path.exists():
        icon.save(
            ico_path,
            format="ICO",
            sizes=[(256, 256), (128, 128), (64, 64), (48, 48), (32, 32), (16, 16)],
        )

    return ico_path, png_path


def _build_fallback_icon() -> Image.Image:
    size = 512
    image = Image.new("RGBA", (size, size), "#0b1f2a")
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((24, 24, size - 24, size - 24), radius=96, fill="#12384a")
    draw.rounded_rectangle((72, 72, size - 72, size - 72), radius=72, fill="#1d6a73")
    draw.text((size * 0.19, size * 0.28), "AW", fill="white")
    return image


def apply_android_branding(repo_root: Path, png_path: Path) -> None:
    android_main = repo_root / "android/app/src/main"
    if not android_main.exists():
        return

    strings_path = android_main / "res/values/strings.xml"
    strings_path.parent.mkdir(parents=True, exist_ok=True)
    strings_path.write_text(
        """<resources>\n    <string name="app_name">AlphaWet</string>\n</resources>\n""",
        encoding="utf-8",
    )

    manifest_path = android_main / "AndroidManifest.xml"
    if manifest_path.exists():
        text = manifest_path.read_text(encoding="utf-8")
        if 'android:label="@string/app_name"' not in text:
            text = text.replace(
                "<application",
                '<application android:label="@string/app_name"',
                1,
            )
        manifest_path.write_text(text, encoding="utf-8")

    icon = Image.open(png_path).convert("RGBA")
    for density, size in {
        "mipmap-mdpi": 48,
        "mipmap-hdpi": 72,
        "mipmap-xhdpi": 96,
        "mipmap-xxhdpi": 144,
        "mipmap-xxxhdpi": 192,
    }.items():
        target_dir = android_main / "res" / density
        target_dir.mkdir(parents=True, exist_ok=True)
        resized = icon.resize((size, size), Image.LANCZOS)
        resized.save(target_dir / "ic_launcher.png", format="PNG")
        resized.save(target_dir / "ic_launcher_round.png", format="PNG")


def apply_windows_branding(repo_root: Path, ico_path: Path) -> None:
    windows_dir = repo_root / "windows"
    if not windows_dir.exists():
        return

    icon_target = windows_dir / "runner/resources/app_icon.ico"
    icon_target.parent.mkdir(parents=True, exist_ok=True)
    icon_target.write_bytes(ico_path.read_bytes())

    for relative in ("windows/CMakeLists.txt", "windows/runner/Runner.rc"):
        path = repo_root / relative
        if not path.exists():
            continue
        text = path.read_text(encoding="utf-8")
        text = text.replace('set(BINARY_NAME "alphawet")', f'set(BINARY_NAME "{APP_NAME}")')
        text = text.replace('VALUE "FileDescription", "alphawet" "\\0"', f'VALUE "FileDescription", "{APP_NAME}" "\\0"')
        text = text.replace('VALUE "InternalName", "alphawet" "\\0"', f'VALUE "InternalName", "{APP_NAME}" "\\0"')
        text = text.replace('VALUE "OriginalFilename", "alphawet.exe" "\\0"', f'VALUE "OriginalFilename", "{APP_NAME}.exe" "\\0"')
        text = text.replace('VALUE "ProductName", "alphawet" "\\0"', f'VALUE "ProductName", "{APP_NAME}" "\\0"')
        path.write_text(text, encoding="utf-8")


def apply_linux_branding(repo_root: Path, png_path: Path) -> None:
    linux_dir = repo_root / "linux"
    if not linux_dir.exists():
        return

    icon_target = linux_dir / "runner/resources/app_icon.png"
    icon_target.parent.mkdir(parents=True, exist_ok=True)
    Image.open(png_path).convert("RGBA").resize((256, 256), Image.LANCZOS).save(icon_target, format="PNG")

    cmake_path = linux_dir / "CMakeLists.txt"
    if cmake_path.exists():
        text = cmake_path.read_text(encoding="utf-8")
        text = text.replace('set(BINARY_NAME "alphawet")', f'set(BINARY_NAME "{APP_NAME}")')
        text = text.replace('set(APPLICATION_ID "ir.alphacraft.alphawet.alphawet")', f'set(APPLICATION_ID "{PACKAGE_NAME}")')
        cmake_path.write_text(text, encoding="utf-8")

    application_path = linux_dir / "runner/my_application.cc"
    if application_path.exists():
        text = application_path.read_text(encoding="utf-8")
        text = text.replace('gtk_window_set_title(window, "alphawet");', f'gtk_window_set_title(window, "{APP_NAME}");')
        if "gtk_window_set_icon_from_file" not in text:
            needle = "gtk_widget_show(GTK_WIDGET(window));"
            replacement = (
                'gtk_window_set_icon_from_file(window, "data/flutter_assets/assets/common/logo/inapplogo.png", nullptr);\n'
                "  gtk_widget_show(GTK_WIDGET(window));"
            )
            text = text.replace(needle, replacement)
        application_path.write_text(text, encoding="utf-8")


def main() -> int:
    repo_root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path.cwd()
    target = sys.argv[2].lower() if len(sys.argv) > 2 else "all"

    ico_path, png_path = ensure_logo_assets(repo_root)

    if target in {"android", "all"}:
        apply_android_branding(repo_root, png_path)
    if target in {"windows", "all"}:
        apply_windows_branding(repo_root, ico_path)
    if target in {"linux", "all"}:
        apply_linux_branding(repo_root, png_path)

    print(f"[OK] Applied {APP_NAME} branding for target={target}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
