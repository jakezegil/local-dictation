# SPDX-License-Identifier: Apache-2.0
# Adapted from Fermion Research fermion-research 0.2.7. See Resources/Licenses.txt.
"""Phonon 2 native CPU bindings, adapted from fermion-research 0.2.7 (Apache-2.0)."""
import ctypes
import json
from pathlib import Path

import numpy as np

import fermion_container as container


class Engine:
    def __init__(self, model_dir, library_dir, threads=4):
        model_dir = Path(model_dir)
        self.config = json.loads((model_dir / "config.json").read_text())
        self.vocabulary = self.config["joint"]["vocabulary"]
        self.encoder = None
        self.decoder = None
        self.matrices = {}
        self.matrix_data = []
        self.enc_lib = ctypes.CDLL(str(Path(library_dir) / "libphonon2_enc-macos-arm64.dylib"))
        self.tdt_lib = ctypes.CDLL(str(Path(library_dir) / "libphonon2_tdt-macos-arm64.dylib"))
        self._configure_libraries(threads)
        tensors, raw = self._read_weights(model_dir / "model.fermion")
        self._create_encoder(tensors)
        self._create_decoder(tensors, raw, threads)
        self.projector = np.ascontiguousarray(tensors["encoder_projector.weight"], dtype=np.float32)
        self.projector_bias = np.ascontiguousarray(tensors["encoder_projector.bias"], dtype=np.float32)
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

    def _read_weights(self, path):
        tensors, raw = {}, {}
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
                    record = {}
                    container._five_value(blob, shape, record)
                    self.matrices[name] = self._create_matrix(record)
                elif kind.startswith("int"):
                    record = {}
                    tensors[name] = container._intn(blob, shape, int(kind[3:]), record)
                    raw[name] = record
                elif kind == "fp16":
                    tensors[name] = np.frombuffer(blob, dtype=np.float16).reshape(shape).copy()
                else:
                    raise RuntimeError("Unsupported Phonon tensor format")
            if file.read(1):
                raise RuntimeError("Unexpected trailing Phonon weights")
        return tensors, raw

    def _create_matrix(self, record):
        sign = record["sign"]
        rows, columns = sign.shape
        def pack(values):
            values = values.astype(np.uint8).reshape(rows, columns // 4, 4)
            return np.ascontiguousarray(values[:, :, 0] | values[:, :, 1] << 2 | values[:, :, 2] << 4 | values[:, :, 3] << 6)
        first = pack(sign + 1)
        second = pack(1 + sign * record["is_hi"].astype(np.int8))
        low, high = np.ascontiguousarray(record["lo"]), np.ascontiguousarray(record["hi"])
        handle = self.enc_lib.phonon2_cpu_create(rows, columns, first.ctypes.data, second.ctypes.data, low.ctypes.data, high.ctypes.data, 0)
        if not handle:
            raise RuntimeError("Could not allocate Phonon matrix")
        self.enc_lib.phonon2_cpu_enable_onedot(handle)
        self.matrix_data.extend([first, second, low, high])
        return handle

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
            return [np.ascontiguousarray(record["q"]), np.ascontiguousarray(record["scale"], dtype=np.float16)]
        keep.extend(quantized("decoder.embedding.weight"))
        for index in [0, 1]:
            for side in ["ih", "hh"]:
                keep.extend(quantized(f"decoder.lstm.weight_{side}_l{index}"))
                keep.append(np.ascontiguousarray(tensors[f"decoder.lstm.bias_{side}_l{index}"], dtype=np.float16))
        for name in ["decoder.decoder_projector", "joint.head"]:
            keep.extend(quantized(name + ".weight"))
            keep.append(np.ascontiguousarray(tensors[name + ".bias"], dtype=np.float16))
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
        self.matrix_data.clear()
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
