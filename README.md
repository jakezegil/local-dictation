# Local Dictation

A Mac menu bar app for offline English dictation with [Phonon 2](https://www.fermionresearch.com/research/phonon-2/).

Press **Fn-Control** to open the recording box. Press it again to transcribe, close the box, and paste.
Your transcript also stays on the clipboard. If no text field is focused, paste later with **Command-V**.

## Install

Requires an **Apple Silicon Mac** running **macOS 13.3 or later**. Run this command in Terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/jakezegil/local-dictation/main/install.sh | bash
```

The installer downloads the app, model, and runtime together. Python and developer tools are not required.
It installs into `/Applications`, or `~/Applications` when `/Applications` is not writable. It then opens the app.

The release uses an ad-hoc signature and is not Apple-notarized.
The installer checks a pinned SHA-256 checksum and removes quarantine from that downloaded app only.
It does not change Gatekeeper settings or add trusted certificates.
You can [read the installer](install.sh) or [download the release](https://github.com/jakezegil/local-dictation/releases/latest) directly.

## First use

1. Allow **Microphone** access when prompted.
2. Click **Allow Automatic Insertion** in the setup window.
3. Enable **Local Dictation** in System Settings → Privacy & Security → Accessibility.
4. Click **Done** in the setup window.
5. Focus a text field.
6. Press **Fn-Control**, speak, and press **Fn-Control** again.

The model takes about 15 seconds to load on the tested Mac. Later recordings use the loaded model.
The recording box leaves your text field focused. Recordings stop automatically after ten minutes.

The microphone icon in the menu bar provides recording, clipboard, insertion, permission, and quit controls.
To reopen the app, use Spotlight: **Command-Space → Local Dictation → Return**.
It does not start automatically at login.

Before updating, quit the app from its menu bar icon and run the install command again.
After an update, macOS may require you to remove and add its Accessibility permission again.

## Privacy

Both the app and its speech worker use **macOS App Sandbox without network entitlements**.
Installation needs internet access. Recording and transcription run locally without an internet connection.

The app has no document, selected-text, screen, or clipboard context features.
The shortcut observes modifier changes only. It does not capture typed characters.
The app remembers the active application without inspecting its contents.
Automatic insertion restores that application and posts **Command-V** after you release the shortcut.

Audio stays in the app's private temporary directory and is deleted after transcription, including failures.
The app removes abandoned recordings when it starts. The last transcript stays in memory until you quit.
The system clipboard retains the transcript. Other clipboard tools may read or sync it.

Accessibility permission enables the shortcut and automatic insertion. This permission has broader system capabilities.
The app does not use accessibility APIs to read other applications.
Two local permission services have sandbox exceptions: `com.apple.tccd.system` and `com.apple.universalaccessAuthWarn`.
These exceptions allow permission checks and prompts. File and network restrictions remain enabled.

## Model and runtime

The app uses Fermion Research's native CPU encoder and decoder with bundled Python 3.12.12 and NumPy 2.3.4.
It does not require a server or system Python. The installed model container occupies about 177 MB.
The engine expands weights at startup. Model file size does not describe memory use.

`PhononRuntime/native.py` adapts the native bindings from fermion-research 0.2.7.
Audio preprocessing follows its CPU reference. Long recordings use windows of up to 30 seconds.
[Pinned versions and checksums](dependency-lock.json) identify the bundled dependencies.

The [Phonon 2 weights](https://huggingface.co/FermionResearch/Phonon-2) derive from NVIDIA's parakeet-tdt-0.6b-v3.
The weights use CC-BY-4.0. Fermion's engine and adapted container code use Apache-2.0.
Original app code uses the [MIT license](LICENSE). Third-party notices and licenses appear in [Resources/Licenses.txt](Resources/Licenses.txt).
The app includes those notices and the model's original attribution.

## Build from source

Requires an Apple Silicon Mac, Python 3.12 or later, and Xcode command-line tools.
Install the release first to obtain its model and bundled runtime. Then run:

```sh
git clone https://github.com/jakezegil/local-dictation.git
cd local-dictation
python3 build.py --ad-hoc --runtime-from '/Applications/Local Dictation.app'
```

If the installer used `~/Applications`, use that app path with `--runtime-from`.
The build creates and verifies `build/Local Dictation.app`.
The interpreter inherits the app's sandbox and communicates through private pipes.

Existing development setups can keep the model in `Models/Phonon2` and Python in `Vendor/Python`.
Running `python3 build.py` uses those directories.
If `.signing/dictation.keychain-db` exists, the build uses that private local identity.
Otherwise, it uses an ad-hoc signature. Private signing files are excluded from Git.

To package a release from a development setup, run `python3 release.py`.
It creates an ad-hoc signed app, a ZIP archive, and `SHA256SUMS.txt` in `build/release`.
Update the version and pinned archive checksum in `install.sh` before publishing the next release.

## Verify

Create a harmless file outside the app's container and run the signed app's self-test:

```sh
printf 'sandbox probe\n' > sandbox-probe.txt
'build/Local Dictation.app/Contents/MacOS/LocalDictation' --self-test "$PWD/sandbox-probe.txt"
```

The self-test transcribes a bundled generated speech sample and checks clipboard output.
It checks that both processes deny network access and access to the unrelated probe file.
It reports event-posting permission separately and replaces the clipboard with the sample transcript.
The Fn-Control toggle and automatic insertion have also been confirmed during normal use.
