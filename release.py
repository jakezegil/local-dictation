#!/usr/bin/env python3
import hashlib
from pathlib import Path
import plistlib
import subprocess
import sys

ROOT = Path(__file__).resolve().parent


def main():
    with (ROOT / "Resources" / "Info.plist").open("rb") as file:
        version = plistlib.load(file)["CFBundleShortVersionString"]
    release = ROOT / "build" / "release"
    app = release / "Local Dictation.app"
    subprocess.run([sys.executable, str(ROOT / "build.py"), "--ad-hoc", "--output", str(app)], check=True)
    archive = release / f"Local-Dictation-{version}-arm64.zip"
    archive.unlink(missing_ok=True)
    subprocess.run(["/usr/bin/ditto", "-c", "-k", "--keepParent", "--norsrc", "--noextattr",
                    str(app), str(archive)], check=True)
    checksum = hashlib.sha256()
    with archive.open("rb") as file:
        for block in iter(lambda: file.read(1024 * 1024), b""):
            checksum.update(block)
    record = f"{checksum.hexdigest()}  {archive.name}\n"
    (release / "SHA256SUMS.txt").write_text(record)
    print(record, end="")


if __name__ == "__main__":
    main()
