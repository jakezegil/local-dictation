#!/usr/bin/env python3
import argparse
import pathlib
import shlex
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent
KEYCHAIN = ROOT / ".signing" / "dictation.keychain-db"
IDENTITY = "Local Dictation Development"


def run(arguments):
    return subprocess.run(arguments, check=True, capture_output=True, text=True).stdout


def sign(path, identity, entitlements=None):
    arguments = ["/usr/bin/codesign", "--force", "--sign", identity, "--timestamp=none"]
    if identity != "-":
        arguments.extend(["--keychain", str(KEYCHAIN)])
    if entitlements:
        arguments.extend(["--entitlements", str(ROOT / "Resources" / entitlements)])
    run([*arguments, str(path)])


def is_mach_file(path):
    if path.is_symlink() or not path.is_file():
        return False
    with path.open("rb") as file:
        return file.read(4) in [b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"]


def main():
    parser = argparse.ArgumentParser(description="Build the sandboxed Apple Silicon app.")
    parser.add_argument("--ad-hoc", action="store_true", help="Build without a private signing identity.")
    parser.add_argument("--output", type=pathlib.Path, default=ROOT / "build" / "Local Dictation.app")
    parser.add_argument("--runtime-from", type=pathlib.Path, help="Reuse model and Python from an installed release.")
    options = parser.parse_args()
    app = options.output.resolve()
    if app.suffix != ".app" or app == ROOT or ROOT.is_relative_to(app):
        raise SystemExit("The output must be a separate .app bundle.")
    model = ROOT / "Models" / "Phonon2"
    python = ROOT / "Vendor" / "Python"
    if options.runtime_from:
        runtime_resources = options.runtime_from.resolve() / "Contents" / "Resources"
        model = runtime_resources / "Phonon2"
        python = runtime_resources / "Python"
    if not model.is_dir() or not python.is_dir():
        raise SystemExit("Missing model or Python. Install a release and use --runtime-from. See README.md.")
    if app in model.parents or app in python.parents:
        raise SystemExit("The output cannot overwrite the input runtime.")
    identity = "-" if options.ad_hoc or not KEYCHAIN.is_file() else IDENTITY
    if app.exists():
        shutil.rmtree(app)
    contents = app / "Contents"
    resources = contents / "Resources"
    for name in ["MacOS", "Resources"]:
        (contents / name).mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / "Resources" / "Info.plist", contents / "Info.plist")
    for name in ["test-speech.wav", "Licenses.txt"]:
        shutil.copy2(ROOT / "Resources" / name, resources / name)
    for source, destination in [(model, "Phonon2"), (python, "Python"), (ROOT / "PhononRuntime", "PhononRuntime")]:
        subprocess.run(["/bin/cp", "-cR", str(source), str(resources / destination)], check=True)
    sources = sorted((ROOT / "Sources").glob("*.swift"))
    subprocess.run([
        "/usr/bin/xcrun", "swiftc", "-swift-version", "5", "-O",
        "-target", "arm64-apple-macosx13.3", "-module-name", "LocalDictation",
        "-framework", "AppKit", "-framework", "AVFoundation", "-framework", "ApplicationServices",
        "-o", str(contents / "MacOS" / "LocalDictation"), *map(str, sources)
    ], check=True)
    previous = None
    try:
        if identity != "-":
            previous = shlex.split(run(["/usr/bin/security", "list-keychains", "-d", "user"]))
            run(["/usr/bin/security", "list-keychains", "-d", "user", "-s", str(KEYCHAIN),
                 *[path for path in previous if path != str(KEYCHAIN)]])
            password = (ROOT / ".signing" / "password").read_text()
            run(["/usr/bin/security", "unlock-keychain", "-p", password, str(KEYCHAIN)])
        for path in resources.rglob("*"):
            if is_mach_file(path):
                sign(path, identity, "Worker.entitlements" if path == resources / "Python/bin/python3.12" else None)
        sign(app, identity, "LocalDictation.entitlements")
        run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    finally:
        if previous is not None:
            run(["/usr/bin/security", "list-keychains", "-d", "user", "-s", *previous])
    print(app)


if __name__ == "__main__":
    main()
