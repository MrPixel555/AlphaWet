This folder is the active desktop runtime bundle.

Use tool/select_desktop_runtime.py windows   before a Windows build.
Use tool/select_desktop_runtime.py linux     before a Linux build.

Only this folder is packaged as a Flutter asset, so opposite-platform runtimes
are kept out of the final build output.
