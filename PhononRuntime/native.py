# SPDX-License-Identifier: Apache-2.0
# Adapted from Fermion Research fermion-research 0.2.7. See Resources/Licenses.txt.
"""Phonon 2 native CPU bindings, adapted from fermion-research 0.2.7 (Apache-2.0)."""
import ctypes
import hashlib
from concurrent.futures import ThreadPoolExecutor
import json
import mmap
import os
from pathlib import Path

import numpy as np

import fermion_container as container

# Bump when the cached layout or the decoding below changes.
CACHE_VERSION = 1
CACHE_MAGIC = b"PHN2CACH"


class Engine:
    def __init__(self, model_dir, library_dir, threads=4, cache_dir=None):
        model_dir = Path(model_dir)
        self.config = json.loads((model_dir / "config.json").read_text())
        self.vocabulary = self.config["joint"]["vocabulary"]
        self.encoder = None
        self.decoder = None
        self.matrices = {}
        self.decoder_data = []
        self.cache_hit = False
        self.enc_lib = ctypes.CDLL(str(Path(library_dir) / "libphonon2_enc-macos-arm64.dylib"))
        self.tdt_lib = ctypes.CDLL(str(Path(library_dir) / "libphonon2_tdt-macos-arm64.dylib"))
        self._configure_libraries(threads)
        try:
            matrices, tensors, raw = self._load_weights(model_dir / "model.fermion", cache_dir)
            self._create_matrices(matrices)
            # The native library copies matrix data, so the packed planes can be released now.
            del matrices
            self._create_encoder(tensors)
            self._create_decoder(tensors, raw, threads)
            self.projector = np.array(tensors["encoder_projector.weight"], dtype=np.float32, order="C")
            self.projector_bias = np.array(tensors["encoder_projector.bias"], dtype=np.float32, order="C")
        except BaseException:
            self.close()
            raise
        self.filters = mel_filters()
        self.window = np.pad(np.hanning(400).astype(np.float32), (56, 56))

    def _configure_libraries(self, threads):
        lib = self.enc_lib
        lib.phonon2_cpu_abi_version.restype = ctypes.c_int
        lib.phonon2_enc_abi_version.restype = ctypes.c_int
        if lib.phonon2_cpu_abi_version() != 1 or lib.phonon2_enc_abi_version() != 1:
            raise RuntimeError("Unsupported Phonon encoder ABI")
        lib.phonon2_cpu_create.argtypes = [ctypes.c_int] * 2 + [ctypes.c_void_p] * 4 + [ctypes.c_int]
        lib.phonon2_cpu_create.restype = ctypes.c_void_p
        lib.phonon2_cpu_enable_onedot.argtypes = [ctypes.c_void_p]
        lib.phonon2_cpu_enable_onedot.restype = ctypes.c_float
        lib.phonon2_cpu_destroy.argtypes = [ctypes.c_void_p]
        lib.phonon2_cpu_set_threads.argtypes = [ctypes.c_int]
        lib.phonon2_cpu_set_threads(threads)
        lib.phonon2_enc_create.argtypes = [ctypes.c_int] * 7
        lib.phonon2_enc_create.restype = ctypes.c_void_p
        lib.phonon2_enc_set_subsampling.argtypes = [ctypes.c_void_p] * 14
        lib.phonon2_enc_set_subsampling.restype = ctypes.c_int
        lib.phonon2_enc_set_layer.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p]
        lib.phonon2_enc_set_layer.restype = ctypes.c_int
        lib.phonon2_enc_out_len.argtypes = [ctypes.c_void_p, ctypes.c_int]
        lib.phonon2_enc_out_len.restype = ctypes.c_int
        lib.phonon2_enc_forward.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
        lib.phonon2_enc_forward.restype = ctypes.c_int
        lib.phonon2_enc_destroy.argtypes = [ctypes.c_void_p]
        lib = self.tdt_lib
        lib.phonon2_tdt_abi_version.restype = ctypes.c_int
        if lib.phonon2_tdt_abi_version() != 2:
            raise RuntimeError("Unsupported Phonon decoder ABI")
        lib.phonon2_tdt_create.argtypes = [ctypes.c_int] * 5 + [ctypes.c_void_p] + [ctypes.c_int] * 2 + [ctypes.c_void_p] * 20
        lib.phonon2_tdt_create.restype = ctypes.c_void_p
        lib.phonon2_tdt_set_threads.argtypes = [ctypes.c_int]
        lib.phonon2_tdt_decode.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
        lib.phonon2_tdt_decode.restype = ctypes.c_int
        lib.phonon2_tdt_destroy.argtypes = [ctypes.c_void_p]

    def _load_weights(self, path, cache_dir):
        cache = _cache_path(path, cache_dir)
        if cache is not None and cache.is_file():
            try:
                arrays = _read_cache(cache)
                self.cache_hit = True
                return _split_arrays(arrays)
            except Exception:
                _remove(cache)
        matrices, tensors, raw = _decode_weights(path)
        if cache is not None:
            _write_cache(cache, _join_arrays(matrices, tensors, raw))
        return matrices, tensors, raw

    def _create_matrices(self, records):
        # ctypes releases the GIL, so the native packing work runs in parallel.
        def create(item):
            name, record = item
            rows, columns = record["rows"], record["columns"]
            handle = self.enc_lib.phonon2_cpu_create(
                rows, columns, record["first"].ctypes.data, record["second"].ctypes.data,
                record["lo"].ctypes.data, record["hi"].ctypes.data, 0)
            if handle:
                self.enc_lib.phonon2_cpu_enable_onedot(handle)
            return name, handle
        with ThreadPoolExecutor(max_workers=_workers()) as pool:
            results = list(pool.map(create, records.items()))
        for name, handle in results:
            if handle:
                self.matrices[name] = handle
        if len(self.matrices) != len(records):
            raise RuntimeError("Could not allocate Phonon matrix")

    def _create_encoder(self, tensors):
        cfg = self.config["encoder"]
        d = cfg["d_model"]
        self.dimension = d
        self.encoder = self.enc_lib.phonon2_enc_create(cfg["n_layers"], d, d * cfg["ff_expansion_factor"], cfg["n_heads"], cfg["conv_kernel_size"], cfg["feat_in"], cfg["subsampling_conv_channels"])
        if not self.encoder:
            raise RuntimeError("Could not allocate Phonon encoder")
        keep = []
        def pointer(name):
            array = np.ascontiguousarray(tensors[name], dtype=np.float32)
            keep.append(array)
            return array.ctypes.data
        sub = []
        for index in [0, 2, 3, 5, 6]:
            for suffix in ["weight", "bias"]:
                sub.append(pointer(f"encoder.subsampling.layers.{index}.{suffix}"))
        sub.extend([pointer("encoder.subsampling.linear.weight"), pointer("encoder.subsampling.linear.bias")])
        inverse = (1 / (10000 ** (np.arange(0, d, 2, dtype=np.float32) / d))).astype(np.float32)
        sub.append(inverse.ctypes.data)
        if self.enc_lib.phonon2_enc_set_subsampling(self.encoder, *sub):
            raise RuntimeError("Could not initialize Phonon subsampling")
        modules = ["feed_forward1.linear1", "feed_forward1.linear2", "self_attn.q_proj", "self_attn.k_proj", "self_attn.v_proj", "self_attn.o_proj", "self_attn.relative_k_proj", "conv.pointwise_conv1", "conv.pointwise_conv2", "feed_forward2.linear1", "feed_forward2.linear2"]
        vectors = [f"{name}.{suffix}" for name in ["norm_feed_forward1", "norm_self_att", "norm_conv", "norm_feed_forward2", "norm_out"] for suffix in ["weight", "bias"]]
        vectors += ["self_attn.bias_u", "self_attn.bias_v", "conv.depthwise_conv.weight", "conv.norm.weight", "conv.norm.bias", "conv.norm.running_mean", "conv.norm.running_var"]
        for index in range(cfg["n_layers"]):
            prefix = f"encoder.layers.{index}."
            handles = (ctypes.c_void_p * 11)(*[self.matrices[prefix + name] for name in modules])
            data = (ctypes.c_void_p * 17)(*[pointer(prefix + name) for name in vectors])
            if self.enc_lib.phonon2_enc_set_layer(self.encoder, index, handles, data):
                raise RuntimeError("Could not initialize Phonon encoder layer")

    def _create_decoder(self, tensors, raw, threads):
        keep = []
        def quantized(name):
            record = raw[name]
            return [np.array(record["q"], dtype=np.int8, order="C"), np.array(record["scale"], dtype=np.float16, order="C")]
        keep.extend(quantized("decoder.embedding.weight"))
        for index in [0, 1]:
            for side in ["ih", "hh"]:
                keep.extend(quantized(f"decoder.lstm.weight_{side}_l{index}"))
                keep.append(np.array(tensors[f"decoder.lstm.bias_{side}_l{index}"], dtype=np.float16, order="C"))
        for name in ["decoder.decoder_projector", "joint.head"]:
            keep.extend(quantized(name + ".weight"))
            keep.append(np.array(tensors[name + ".bias"], dtype=np.float16, order="C"))
        durations = self.config["decoding"]["durations"]
        self.durations = (ctypes.c_int * len(durations))(*durations)
        self.decoder = self.tdt_lib.phonon2_tdt_create(keep[0].shape[0], keep[0].shape[1], raw["decoder.lstm.weight_hh_l0"]["q"].shape[1], raw["joint.head.weight"]["q"].shape[0], len(durations), ctypes.addressof(self.durations), len(self.vocabulary), 10, *[array.ctypes.data for array in keep])
        if not self.decoder:
            raise RuntimeError("Could not allocate Phonon decoder")
        self.tdt_lib.phonon2_tdt_set_threads(threads)
        self.decoder_data = keep

    def _features(self, samples):
        emphasized = samples.copy()
        emphasized[1:] -= np.float32(0.97) * samples[:-1]
        padded = np.pad(emphasized, (256, 256))
        frames = np.lib.stride_tricks.sliding_window_view(padded, 512)[::160]
        spectrum = np.fft.rfft(frames * self.window, axis=-1)
        power = (np.abs(spectrum) ** 2).astype(np.float32)
        features = np.log(power @ self.filters.T + np.float32(2 ** -24))
        return np.ascontiguousarray((features - features.mean(axis=0)) / (features.std(axis=0, ddof=1) + np.float32(1e-5)), dtype=np.float32)

    def _transcribe_chunk(self, samples):
        features = self._features(samples)
        count = self.enc_lib.phonon2_enc_out_len(self.encoder, len(features))
        if count <= 0:
            return ""
        encoded = np.empty((count, self.dimension), dtype=np.float32)
        if self.enc_lib.phonon2_enc_forward(self.encoder, features.ctypes.data, len(features), encoded.ctypes.data):
            raise RuntimeError("Phonon encoder failed")
        projected = np.ascontiguousarray(encoded @ self.projector.T + self.projector_bias, dtype=np.float32)
        tokens = np.zeros(max(64, count * 12), dtype=np.int32)
        length = self.tdt_lib.phonon2_tdt_decode(self.decoder, projected.ctypes.data, count, tokens.ctypes.data, len(tokens))
        if length < 0 or length >= len(tokens):
            raise RuntimeError("Phonon decoder exceeded its token limit")
        pieces = []
        for token in tokens[:length]:
            if not 0 <= token < len(self.vocabulary):
                raise RuntimeError("Phonon decoder returned an invalid token")
            piece = self.vocabulary[token]
            if not (piece.startswith("<|") and piece.endswith("|>")) and piece not in ["<unk>", "<pad>"]:
                pieces.append(piece)
        return "".join(pieces).replace("▁", " ").strip()

    def transcribe(self, samples):
        samples = np.asarray(samples, dtype=np.float32)
        if len(samples) < 4000 or np.max(np.abs(samples)) <= 0.001:
            return ""
        pieces, start = [], 0
        while start < len(samples):
            end = min(start + 30 * 16000, len(samples))
            if end < len(samples):
                search = samples[start + 25 * 16000:end]
                energy = (search[:len(search) // 1600 * 1600].reshape(-1, 1600) ** 2).mean(axis=1)
                end = start + 25 * 16000 + (int(energy.argmin()) + 1) * 1600
            if end - start >= 4000:
                pieces.append(self._transcribe_chunk(samples[start:end]))
            start = end
        return " ".join(piece for piece in pieces if piece)

    def close(self):
        if self.decoder:
            self.tdt_lib.phonon2_tdt_destroy(self.decoder)
            self.decoder = None
        if self.encoder:
            self.enc_lib.phonon2_enc_destroy(self.encoder)
            self.encoder = None
        for handle in self.matrices.values():
            self.enc_lib.phonon2_cpu_destroy(handle)
        self.matrices.clear()
        self.decoder_data = []


def mel_filters():
    def mel(hz):
        return hz / (200 / 3) if hz < 1000 else 15 + np.log(hz / 1000) / (np.log(6.4) / 27)
    def hz(value):
        return value * (200 / 3) if value < 15 else 1000 * np.exp((value - 15) * (np.log(6.4) / 27))
    frequencies = np.linspace(0, 8000, 257)
    centers = np.array([hz(value) for value in np.linspace(mel(0), mel(8000), 130)])
    differences = np.diff(centers)
    ramps = centers[:, None] - frequencies[None, :]
    weights = np.maximum(0, np.minimum(-ramps[:-2] / differences[:-1, None], ramps[2:] / differences[1:, None]))
    weights *= (2 / (centers[2:] - centers[:-2]))[:, None]
    return weights.astype(np.float32)


# Each container byte holds five base-3 digits ("trits"); this table expands every byte value at once.
_TRITS = (np.arange(256, dtype=np.uint16)[:, None] // (3 ** np.arange(5, dtype=np.uint16)) % 3).astype(np.uint8)


def _pack(values, rows, columns):
    values = values.reshape(rows, columns // 4, 4)
    return np.ascontiguousarray(values[:, :, 0] | values[:, :, 1] << 2 | values[:, :, 2] << 4 | values[:, :, 3] << 6)


def _five_value_planes(blob, shape):
    """Decode one five-value matrix straight into the two packed planes the native library expects.

    Equivalent to fermion_container._five_value followed by packing (sign + 1) and (1 + sign * is_hi),
    without building the dense float16 matrix."""
    rows, columns = shape
    row_bytes = (columns + 4) // 5
    codes = _TRITS[np.frombuffer(blob, dtype=np.uint8, count=rows * row_bytes)]
    codes = codes.reshape(rows, row_bytes * 5)[:, :columns]
    nonzero = codes != 1
    count = int(np.count_nonzero(nonzero))
    offset = rows * row_bytes
    high_bytes = (count + 7) // 8
    bits = np.unpackbits(np.frombuffer(blob, dtype=np.uint8, count=high_bytes, offset=offset), bitorder="little")[:count]
    offset += high_bytes
    if offset + 4 * rows != len(blob):
        raise RuntimeError("Invalid Phonon matrix")
    second = np.ones((rows, columns), dtype=np.uint8)
    second[nonzero] = np.where(bits.astype(bool), codes[nonzero], 1)
    return {
        "first": _pack(codes, rows, columns),
        "second": _pack(second, rows, columns),
        "lo": np.frombuffer(blob, dtype=np.float16, count=rows, offset=offset).copy(),
        "hi": np.frombuffer(blob, dtype=np.float16, count=rows, offset=offset + 2 * rows).copy(),
        "rows": rows, "columns": columns,
    }


def _decode_weights(path):
    matrices, tensors, raw = {}, {}, {}
    pending = []
    with open(path, "rb") as file:
        header_size = int.from_bytes(file.read(8), "little")
        header = json.loads(file.read(header_size))
        if header["format"] != container.FORMAT:
            raise RuntimeError("Unsupported Phonon model format")
        for entry in header["index"]:
            blob = file.read(entry["b"])
            if len(blob) != entry["b"]:
                raise RuntimeError("Truncated Phonon weights")
            name, kind, shape = entry["n"], entry["k"], tuple(entry["shape"])
            if kind == "five_value":
                pending.append((name, blob, shape))
            elif kind.startswith("int"):
                record = {}
                tensors[name] = container._intn(blob, shape, int(kind[3:]), record)
                raw[name] = {"q": record["q"], "scale": record["scale"]}
            elif kind == "fp16":
                tensors[name] = np.frombuffer(blob, dtype=np.float16).reshape(shape).copy()
            else:
                raise RuntimeError("Unsupported Phonon tensor format")
        if file.read(1):
            raise RuntimeError("Unexpected trailing Phonon weights")
    # NumPy releases the GIL for these array operations, so matrices decode in parallel.
    with ThreadPoolExecutor(max_workers=_workers()) as pool:
        decoded = pool.map(lambda item: (item[0], _five_value_planes(item[1], item[2])), pending)
        matrices.update(decoded)
    return matrices, tensors, raw


def _workers():
    return max(1, min(8, os.cpu_count() or 1))


def _join_arrays(matrices, tensors, raw):
    arrays = {}
    for name, record in matrices.items():
        for part in ["first", "second", "lo", "hi"]:
            arrays[f"m\0{name}\0{part}"] = record[part]
    for name, tensor in tensors.items():
        arrays[f"t\0{name}"] = tensor
    for name, record in raw.items():
        for part in ["q", "scale"]:
            arrays[f"r\0{name}\0{part}"] = record[part]
    return arrays


def _split_arrays(arrays):
    matrices, tensors, raw = {}, {}, {}
    for key, array in arrays.items():
        kind, *rest = key.split("\0")
        if kind == "m":
            record = matrices.setdefault(rest[0], {})
            record[rest[1]] = array
            if rest[1] == "first":
                record["rows"], record["columns"] = array.shape[0], array.shape[1] * 4
        elif kind == "t":
            tensors[rest[0]] = array
        elif kind == "r":
            raw.setdefault(rest[0], {})[rest[1]] = array
        else:
            raise RuntimeError("Unexpected Phonon cache entry")
    for record in matrices.values():
        if set(record) != {"first", "second", "lo", "hi", "rows", "columns"}:
            raise RuntimeError("Incomplete Phonon cache entry")
    return matrices, tensors, raw


def _cache_path(model, cache_dir):
    if not cache_dir:
        return None
    try:
        status = os.stat(model)
        with open(model, "rb") as file:
            # The container header indexes every tensor's name, kind, shape, and size.
            header = file.read(8 + int.from_bytes(file.read(8), "little"))
        directory = Path(cache_dir)
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    except OSError:
        return None
    digest = hashlib.sha256(header + str((status.st_size, status.st_mtime_ns)).encode()).hexdigest()[:24]
    return directory / f"phonon2-v{CACHE_VERSION}-{digest}.weights"


def _remove(path):
    try:
        path.unlink()
    except OSError:
        pass


def _write_cache(path, arrays):
    """Atomically write arrays as a 64-byte-aligned flat file with a JSON index. Failures are ignored."""
    index, offset = [], 0
    for key, array in arrays.items():
        array = np.ascontiguousarray(array)
        offset = (offset + 63) // 64 * 64
        index.append({"k": key, "d": array.dtype.str, "s": list(array.shape), "o": offset})
        offset += array.nbytes
    header = json.dumps({"version": CACHE_VERSION, "index": index, "data_bytes": offset}).encode()
    data_start = (16 + len(header) + 63) // 64 * 64
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        with open(temporary, "wb") as file:
            file.write(CACHE_MAGIC + len(header).to_bytes(8, "little") + header)
            for entry, array in zip(index, arrays.values()):
                file.seek(data_start + entry["o"])
                file.write(np.ascontiguousarray(array).tobytes())
            file.truncate(data_start + offset)
            file.flush()
            os.fsync(file.fileno())
        os.replace(temporary, path)
        for stale in path.parent.glob("phonon2-v*.weights"):
            if stale != path:
                _remove(stale)
    except OSError:
        _remove(temporary)


def _read_cache(path):
    with open(path, "rb") as file:
        mapping = mmap.mmap(file.fileno(), 0, access=mmap.ACCESS_READ)
    if mapping[:8] != CACHE_MAGIC:
        raise RuntimeError("Invalid Phonon cache")
    header_size = int.from_bytes(mapping[8:16], "little")
    header = json.loads(mapping[16:16 + header_size])
    data_start = (16 + header_size + 63) // 64 * 64
    if header["version"] != CACHE_VERSION or len(mapping) != data_start + header["data_bytes"]:
        raise RuntimeError("Invalid Phonon cache")
    arrays = {}
    for entry in header["index"]:
        dtype = np.dtype(entry["d"])
        count = int(np.prod(entry["s"], dtype=np.int64))
        if entry["o"] + count * dtype.itemsize > header["data_bytes"]:
            raise RuntimeError("Invalid Phonon cache")
        arrays[entry["k"]] = np.frombuffer(mapping, dtype=dtype, count=count,
                                           offset=data_start + entry["o"]).reshape(entry["s"])
    return arrays
