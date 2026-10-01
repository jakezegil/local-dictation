#!/bin/bash
set -euo pipefail

fail() { printf '%s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || fail 'Local Dictation requires an Apple Silicon Mac.'
os_version="$(sw_vers -productVersion)"
os_major="${os_version%%.*}"
os_rest="${os_version#*.}"
os_minor="${os_rest%%.*}"
(( os_major > 13 || (os_major == 13 && os_minor >= 3) )) || fail 'Local Dictation requires macOS 13.3 or later.'

version='0.3.0'
archive_name="Local-Dictation-${version}-arm64.zip"
expected_sha256='cc294209a5c8f50e04793a558d26a81777adbae79df018b86b63af8aebfd023e'
download_url="https://github.com/jakezegil/local-dictation/releases/download/v${version}/${archive_name}"
install_dir="${LOCAL_DICTATION_INSTALL_DIR:-/Applications}"
if [[ -z "${LOCAL_DICTATION_INSTALL_DIR:-}" && ! -w /Applications ]]; then
    install_dir="$HOME/Applications"
fi
app="$install_dir/Local Dictation.app"
if [[ -e "$app" || -L "$app" ]]; then
    [[ ! -L "$app" && -d "$app" ]] || fail "Cannot replace $app: it is not an application bundle."
    identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
    [[ "$identifier" == local.jake.dictation ]] || fail "Cannot replace an unrelated application at $app."
    if /usr/bin/pgrep -x LocalDictation >/dev/null; then
        fail 'Quit Local Dictation from its menu bar icon, then run the installer again.'
    fi
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/local-dictation-install.XXXXXXXX")"
stage=''
cleanup() {
    if [[ -n "$stage" && -d "$stage/previous.app" && ! -e "$app" ]]; then
        /bin/mv "$stage/previous.app" "$app"
    fi
    /bin/rm -rf "$work"
    if [[ -n "$stage" ]]; then /bin/rm -rf "$stage"; fi
}
trap cleanup EXIT

printf 'Downloading Local Dictation %s…\n' "$version"
/usr/bin/curl --fail --location --show-error --proto '=https' --tlsv1.2 --retry 3 \
    "$download_url" --output "$work/$archive_name"
actual_sha256="$(LC_ALL=C /usr/bin/shasum -a 256 "$work/$archive_name")"
[[ "${actual_sha256%% *}" == "$expected_sha256" ]] || fail 'Download checksum mismatch. Installation stopped.'
/usr/bin/ditto -x -k "$work/$archive_name" "$work/unpacked"
downloaded="$work/unpacked/Local Dictation.app"
/usr/bin/codesign --verify --deep --strict "$downloaded"

/bin/mkdir -p "$install_dir"
stage="$(mktemp -d "$install_dir/.LocalDictation-install.XXXXXXXX")"
/bin/cp -R "$downloaded" "$stage/Local Dictation.app"
# The release uses an ad-hoc signature. Remove quarantine only from this verified download.
/usr/bin/xattr -dr com.apple.quarantine "$stage/Local Dictation.app"
/usr/bin/codesign --verify --deep --strict "$stage/Local Dictation.app"
if [[ -e "$app" ]]; then /bin/mv "$app" "$stage/previous.app"; fi
/bin/mv "$stage/Local Dictation.app" "$app"
printf 'Installed: %s\nAllow Microphone and Accessibility when prompted. Fn-Control starts and stops recording.\n' "$app"
if [[ "${LOCAL_DICTATION_NO_OPEN:-0}" != 1 ]]; then /usr/bin/open "$app"; fi
