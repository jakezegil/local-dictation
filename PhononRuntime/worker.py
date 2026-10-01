import errno
import json
import os
from pathlib import Path
import socket
import sys
import wave

sys.path.insert(0, str(Path(__file__).resolve().parent))

import numpy as np
from native import Engine


def respond(value):
    print(json.dumps(value), flush=True)


def sandbox_checks(probe):
    denied = {}
    try:
        with socket.socket() as connection:
            connection.settimeout(1)
            connection.connect(("1.1.1.1", 443))
        denied["network_denied"] = False
    except OSError as error:
        denied["network_denied"] = error.errno in [errno.EPERM, errno.EACCES]
        denied["network_errno"] = error.errno
    try:
        with open(probe, "rb"):
            pass
        denied["unrelated_file_read_denied"] = False
    except OSError as error:
        denied["unrelated_file_read_denied"] = error.errno in [errno.EPERM, errno.EACCES]
        denied["file_errno"] = error.errno
    return denied


def read_audio(path):
    with wave.open(str(path), "rb") as audio:
        if audio.getframerate() != 16000 or audio.getnchannels() != 1 or audio.getsampwidth() != 2:
            raise ValueError("The recording must be mono 16 kHz PCM16 audio")
        if audio.getnframes() > 16000 * 600:
            raise ValueError("The recording exceeds ten minutes")
        samples = np.frombuffer(audio.readframes(audio.getnframes()), dtype="<i2")
    return samples.astype(np.float32) / 32768


def main():
    resources = Path(__file__).resolve().parents[1]
    engine = None
    try:
        engine = Engine(resources / "Phonon2", Path(__file__).resolve().parent)
        respond({"ready": True, "model": "Phonon 2", "engine": "native CPU"})
        for line in sys.stdin:
            try:
                request = json.loads(line)
                if request.get("command") == "sandbox-check":
                    respond(sandbox_checks(request["probe"]))
                else:
                    path = Path(request["audio"]).resolve()
                    permitted = [resources / "test-speech.wav", Path(os.environ["TMPDIR"]).resolve() / "LocalDictationRecordings"]
                    if path != permitted[0] and not path.is_relative_to(permitted[1]):
                        raise ValueError("The audio path is outside the recording directory")
                    respond({"text": engine.transcribe(read_audio(path))})
            except Exception:
                respond({"error": "The local speech engine could not process this request."})
    except Exception:
        respond({"error": "The bundled Phonon 2 model could not be loaded."})
    finally:
        if engine is not None:
            engine.close()


if __name__ == "__main__":
    main()
