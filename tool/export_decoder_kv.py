#!/usr/bin/env python3
"""Export a KV-cache decoder ONNX for manga-ocr and prove it equivalent to the
shipped no-cache export.

Why this exists
---------------
The decoder shipped in ``mayocream/manga-ocr-onnx`` (``decoder_model.onnx``)
exposes exactly two graph inputs (``input_ids``, ``encoder_hidden_states``) and
one output (``logits``).  It has **no** ``past_key_values``, so every decode step
re-feeds the whole token prefix: O(L^2) work and one tiny inference per step.
On the app's own baseline that decode pass is 49% of OCR wall clock
(dec 1917 ms of 3897 ms per page).

The decoder is a stock ``BertLMHeadModel`` (``is_decoder=true``,
``add_cross_attention=true``, 2 layers) and transformers' BERT *does* implement
an incremental cache.  This script exports that cache path to ONNX and then
verifies it step-by-step against the old full-prefix computation.

What it exports
---------------
``manga_ocr_decoder_kv_step0.onnx``
    First step.  ``input_ids`` [batch,1] + ``encoder_hidden_states``
    [batch,S,768] -> ``logits`` [batch,1,6144] + ``present.*``.
    Used once per sequence to seed the cache.

``manga_ocr_decoder_kv.onnx``
    Incremental step.  ``input_ids`` [batch,1] + ``encoder_hidden_states``
    + ``position_ids`` [batch,1] + ``past_key_values.*`` -> ``logits`` +
    ``present.*``.  Feed exactly one new token per call.

Two graphs, not one merged graph
--------------------------------
``BertSelfAttention.forward`` reuses a supplied cross-attention cache
*unconditionally* (transformers v4.44.2 ``modeling_bert.py`` L271-275), so a
"merged" graph handed a zero-length past for the first step would consume that
empty cache as real cross keys and produce garbage.  The first step therefore
has to be its own graph with ``past_key_values=None``.

``position_ids`` is an explicit input because ``BertEmbeddings`` (L195-196) and
``BertModel`` (L1067) derive the position offset from
``past_key_values[0][0].shape[2]``, which the TorchScript tracer freezes to the
trace-time constant.  Feeding positions explicitly is the accepted fix and makes
the graph correct for every past length.

Equivalence gate
----------------
The script exits non-zero unless, for every step of every case, the cache path's
argmax token equals the old full-prefix path's argmax token:

* immediate-EOS / single step,
* repetition loop,
* long line (up to the app's ``MangaOcrTokens.maxTokens = 80`` ceiling),
* batch > 1 with the app's pad-while-done schedule.

The old path is computed twice: once with PyTorch (``use_cache=False``, the
exact math the shipped graph traces) and once with the shipped
``decoder_model.onnx`` itself.

Usage
-----
    python tool/export_decoder_kv.py --out-dir dist
    python tool/export_decoder_kv.py --fp16          # also convert + re-verify

Nothing here runs inside the app; it is an offline/CI tool.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

REPO_ROOT = Path(__file__).resolve().parent.parent
TOOL_DIR = Path(__file__).resolve().parent
DEFAULT_MODEL_ID = "kha-white/manga-ocr-base"
DEFAULT_REFERENCE_REPO = "mayocream/manga-ocr-onnx"
DEFAULT_REFERENCE_FILE = "decoder_model.onnx"
DEFAULT_ENDPOINTS = ("https://hf-mirror.com", "https://huggingface.co")

# MangaOcrTokens (lib/foundation/image_translation/ocr_batching.dart)
START_ID = 2
EOS_ID = 3
PAD_ID = 0
MAX_TOKENS = 80  # driveDecode() stops at currentStep < maxTokens

STEP0_NAME = "manga_ocr_decoder_kv_step0.onnx"
KV_NAME = "manga_ocr_decoder_kv.onnx"
META_NAME = "manga_ocr_decoder_kv.meta.json"


def log(msg: str) -> None:
    print(f"[kv-export] {msg}", flush=True)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


# --------------------------------------------------------------------------- #
# model download (mirror first, official second)
# --------------------------------------------------------------------------- #
def download_snapshot(repo_id: str, endpoints: Sequence[str], cache_dir: Path) -> Tuple[str, str]:
    from huggingface_hub import snapshot_download

    errors: List[str] = []
    for endpoint in endpoints:
        try:
            log(f"snapshot_download {repo_id} via {endpoint}")
            local = snapshot_download(
                repo_id=repo_id,
                endpoint=endpoint,
                cache_dir=str(cache_dir),
                allow_patterns=["*.json", "*.bin", "*.safetensors", "*.txt", "*.model"],
                max_workers=4,
            )
            log(f"snapshot ready at {local}")
            return local, endpoint
        except Exception as exc:  # noqa: BLE001 - try the next mirror on purpose
            errors.append(f"{endpoint}: {type(exc).__name__}: {exc}")
            log(f"download via {endpoint} failed: {type(exc).__name__}: {exc}")
    raise RuntimeError(
        "could not download %s from any endpoint:\n  %s" % (repo_id, "\n  ".join(errors))
    )


def download_file(
    repo_id: str, filename: str, endpoints: Sequence[str], cache_dir: Path
) -> Optional[Tuple[str, str]]:
    from huggingface_hub import hf_hub_download

    for endpoint in endpoints:
        try:
            log(f"hf_hub_download {repo_id}/{filename} via {endpoint}")
            local = hf_hub_download(
                repo_id=repo_id, filename=filename, endpoint=endpoint, cache_dir=str(cache_dir)
            )
            return local, endpoint
        except Exception as exc:  # noqa: BLE001
            log(f"reference download via {endpoint} failed: {type(exc).__name__}: {exc}")
    return None


# --------------------------------------------------------------------------- #
# cache layout discovery
# --------------------------------------------------------------------------- #
def _flatten_cache(cache: Any) -> Tuple[Any, ...]:
    flat: List[Any] = []
    for layer in cache:
        for tensor in layer:
            flat.append(tensor)
    return tuple(flat)


def discover_cache_layout(decoder: Any, enc_seq_len: int) -> Dict[str, Any]:
    """Inspect one real forward pass and describe the per-layer cache tensors.

    transformers' BERT packs each decoder layer's cache as
    ``(self_key, self_value, cross_key, cross_value)``
    (modeling_bert.py v4.44.2 L583/L609/L624).
    """
    import torch

    with torch.no_grad():
        out = decoder(
            input_ids=torch.tensor([[START_ID]], dtype=torch.long),
            encoder_hidden_states=torch.zeros(1, enc_seq_len, decoder.config.hidden_size),
            use_cache=True,
            return_dict=True,
        )
    cache = out.past_key_values
    if cache is None:
        raise RuntimeError("decoder returned no past_key_values - cache export impossible")
    num_layers = len(cache)
    expected_layers = int(decoder.config.num_hidden_layers)
    if num_layers != expected_layers:
        raise RuntimeError(f"cache has {num_layers} layers, config says {expected_layers}")
    per_layer = len(cache[0])
    if per_layer == 4:
        suffixes = ["decoder.key", "decoder.value", "encoder.key", "encoder.value"]
    elif per_layer == 2:
        suffixes = ["decoder.key", "decoder.value"]
    else:
        raise RuntimeError(f"unexpected cache tuple arity {per_layer} (expected 2 or 4)")
    entries: List[Dict[str, Any]] = []
    for layer_idx in range(num_layers):
        if len(cache[layer_idx]) != per_layer:
            raise RuntimeError(
                f"layer {layer_idx} has {len(cache[layer_idx])} cache tensors, expected {per_layer}"
            )
        for slot, suffix in enumerate(suffixes):
            tensor = cache[layer_idx][slot]
            entries.append(
                {
                    "layer": layer_idx,
                    "suffix": suffix,
                    "cross": suffix.startswith("encoder."),
                    "input_name": f"past_key_values.{layer_idx}.{suffix}",
                    "output_name": f"present.{layer_idx}.{suffix}",
                    "example_shape": [int(d) for d in tensor.shape],
                }
            )
    return {
        "num_layers": num_layers,
        "per_layer": per_layer,
        "entries": entries,
        "cross_seq_len": int(cache[0][2].shape[2]) if per_layer == 4 else None,
        "heads": int(cache[0][0].shape[1]),
        "head_dim": int(cache[0][0].shape[3]),
        "self_len_at_step0": int(cache[0][0].shape[2]),
    }


def dynamic_axes_for(layout: Dict[str, Any]) -> Dict[str, Dict[int, str]]:
    axes: Dict[str, Dict[int, str]] = {}
    for entry in layout["entries"]:
        if entry["cross"]:
            axes[entry["input_name"]] = {0: "batch"}
        else:
            axes[entry["input_name"]] = {0: "batch", 2: "past_sequence_length"}
    for entry in layout["entries"]:
        if entry["cross"]:
            axes[entry["output_name"]] = {0: "batch"}
        else:
            axes[entry["output_name"]] = {0: "batch", 2: "total_sequence_length"}
    return axes


# --------------------------------------------------------------------------- #
# export wrappers
# --------------------------------------------------------------------------- #
def build_wrappers(decoder: Any, layout: Dict[str, Any]) -> Tuple[Any, Any]:
    import torch

    class Step0(torch.nn.Module):
        def __init__(self, inner: Any) -> None:
            super().__init__()
            self.inner = inner

        def forward(self, input_ids: Any, encoder_hidden_states: Any) -> Tuple[Any, ...]:
            out = self.inner(
                input_ids=input_ids,
                encoder_hidden_states=encoder_hidden_states,
                use_cache=True,
                return_dict=True,
            )
            return (out.logits,) + _flatten_cache(out.past_key_values)

    class WithPast(torch.nn.Module):
        def __init__(self, inner: Any, num_layers: int, per_layer: int) -> None:
            super().__init__()
            self.inner = inner
            self.num_layers = num_layers
            self.per_layer = per_layer
            # Attention mask of shape [1,1,1] filled with ones.  BertModel turns
            # a mask into additive form via (1.0 - mask) * finfo.min
            # (modeling_utils.py L1153-1154), so ones => additive zeros => every
            # key visible.  A constant shape keeps the trace-time past length out
            # of the graph.
            self.register_buffer("keep_all_mask", torch.ones(1, 1, 1), persistent=False)

        def forward(
            self,
            input_ids: Any,
            encoder_hidden_states: Any,
            position_ids: Any,
            *flat_past: Any,
        ) -> Tuple[Any, ...]:
            past: List[Any] = []
            cursor = 0
            for _ in range(self.num_layers):
                past.append(tuple(flat_past[cursor : cursor + self.per_layer]))
                cursor += self.per_layer
            out = self.inner(
                input_ids=input_ids,
                encoder_hidden_states=encoder_hidden_states,
                position_ids=position_ids,
                attention_mask=self.keep_all_mask,
                past_key_values=tuple(past),
                use_cache=True,
                return_dict=True,
            )
            return (out.logits,) + _flatten_cache(out.past_key_values)

    return Step0(decoder), WithPast(decoder, layout["num_layers"], layout["per_layer"])


def _torch_onnx_export(
    wrapper: Any,
    args: Tuple[Any, ...],
    path: Path,
    input_names: List[str],
    output_names: List[str],
    dynamic_axes: Dict[str, Any],
    opset: int,
) -> None:
    import inspect

    import torch

    kwargs: Dict[str, Any] = {}
    try:
        if "dynamo" in inspect.signature(torch.onnx.export).parameters:
            kwargs["dynamo"] = False  # keep the deterministic TorchScript tracer
    except (TypeError, ValueError):
        pass
    path.parent.mkdir(parents=True, exist_ok=True)
    with torch.no_grad():
        torch.onnx.export(
            wrapper,
            args,
            str(path),
            input_names=input_names,
            output_names=output_names,
            dynamic_axes=dynamic_axes,
            opset_version=opset,
            do_constant_folding=True,
            export_params=True,
            verbose=False,
            **kwargs,
        )


def export_step0(
    decoder: Any, layout: Dict[str, Any], example_eh: Any, path: Path, opset: int
) -> Dict[str, Any]:
    import torch

    wrapper, _ = build_wrappers(decoder, layout)
    args = (torch.tensor([[START_ID]], dtype=torch.long), example_eh)
    input_names = ["input_ids", "encoder_hidden_states"]
    output_names = ["logits"] + [entry["output_name"] for entry in layout["entries"]]
    dynamic_axes: Dict[str, Any] = {
        "input_ids": {0: "batch"},
        "encoder_hidden_states": {0: "batch"},
        "logits": {0: "batch"},
    }
    for entry in layout["entries"]:
        dynamic_axes[entry["output_name"]] = {0: "batch"}
    _torch_onnx_export(wrapper, args, path, input_names, output_names, dynamic_axes, opset)
    return {"input_names": input_names, "output_names": output_names}


def export_with_past(
    decoder: Any, layout: Dict[str, Any], example_eh: Any, path: Path, opset: int
) -> Dict[str, Any]:
    import torch

    _, wrapper = build_wrappers(decoder, layout)
    with torch.no_grad():
        seed = decoder(
            input_ids=torch.tensor([[START_ID, 42]], dtype=torch.long),
            encoder_hidden_states=example_eh,
            use_cache=True,
            return_dict=True,
        )
    past = _flatten_cache(seed.past_key_values)
    past_len = int(seed.past_key_values[0][0].shape[2])
    args = (
        torch.tensor([[43]], dtype=torch.long),
        example_eh,
        torch.tensor([[past_len]], dtype=torch.long),
    ) + tuple(past)
    input_names = ["input_ids", "encoder_hidden_states", "position_ids"] + [
        entry["input_name"] for entry in layout["entries"]
    ]
    output_names = ["logits"] + [entry["output_name"] for entry in layout["entries"]]
    dynamic_axes: Dict[str, Any] = {
        "input_ids": {0: "batch"},
        "encoder_hidden_states": {0: "batch"},
        "position_ids": {0: "batch"},
        "logits": {0: "batch"},
    }
    dynamic_axes.update(dynamic_axes_for(layout))
    _torch_onnx_export(wrapper, args, path, input_names, output_names, dynamic_axes, opset)
    return {"input_names": input_names, "output_names": output_names}


# --------------------------------------------------------------------------- #
# ONNX metadata
# --------------------------------------------------------------------------- #
def describe_onnx(path: Path) -> Dict[str, Any]:
    import onnx

    model = onnx.load(str(path), load_external_data=False)
    onnx.checker.check_model(str(path))

    def dims(value_info: Any) -> List[Any]:
        out: List[Any] = []
        for dim in value_info.type.tensor_type.shape.dim:
            if dim.HasField("dim_value"):
                out.append(int(dim.dim_value))
            elif dim.HasField("dim_param"):
                out.append(dim.dim_param)
            else:
                out.append(None)
        return out

    def tensor_info(value_info: Any) -> Dict[str, Any]:
        return {
            "name": value_info.name,
            "dtype": onnx.TensorProto.DataType.Name(value_info.type.tensor_type.elem_type),
            "shape": dims(value_info),
        }

    dtypes = {onnx.TensorProto.DataType.Name(t.data_type) for t in model.graph.initializer}
    precision = "fp16" if any("FLOAT16" in dtype for dtype in dtypes) else "fp32"
    return {
        "file": path.name,
        "bytes": path.stat().st_size,
        "sha256": sha256_file(path),
        "precision": precision,
        "ir_version": int(model.ir_version),
        "opset": {imp.domain or "ai.onnx": int(imp.version) for imp in model.opset_import},
        "producer": f"{model.producer_name} {model.producer_version}".strip(),
        "inputs": [tensor_info(v) for v in model.graph.input],
        "outputs": [tensor_info(v) for v in model.graph.output],
    }


# --------------------------------------------------------------------------- #
# inference helpers
# --------------------------------------------------------------------------- #
class OrtGraph:
    def __init__(self, path: Path) -> None:
        import onnxruntime as ort

        options = ort.SessionOptions()
        options.log_severity_level = 3
        self.session = ort.InferenceSession(
            str(path), sess_options=options, providers=["CPUExecutionProvider"]
        )
        self.input_names = [i.name for i in self.session.get_inputs()]
        self.output_names = [o.name for o in self.session.get_outputs()]

    def run(self, feed: Dict[str, Any]) -> Dict[str, Any]:
        return dict(zip(self.output_names, self.session.run(None, feed)))

    def pick(self, wanted: Sequence[str]) -> str:
        for want in wanted:
            if want in self.input_names:
                return want
        for want in wanted:
            for name in self.input_names:
                if want in name:
                    return name
        raise KeyError(f"none of {wanted} in {self.input_names}")

    def pick_out(self, wanted: Sequence[str]) -> str:
        for want in wanted:
            if want in self.output_names:
                return want
        for want in wanted:
            for name in self.output_names:
                if want in name:
                    return name
        raise KeyError(f"none of {wanted} in {self.output_names}")


def torch_nocache_decode(
    decoder: Any, eh: Any, max_steps: int, stop_on_eos: bool
) -> Tuple[List[Any], List[Any]]:
    """The old behaviour: re-feed the whole prefix every step, use_cache=False."""
    import torch

    batch = eh.shape[0]
    ids = torch.full((batch, 1), START_ID, dtype=torch.long)
    done = torch.zeros(batch, dtype=torch.bool)
    logits_hist: List[Any] = []
    token_hist: List[Any] = []
    for _ in range(max_steps):
        with torch.no_grad():
            out = decoder(input_ids=ids, encoder_hidden_states=eh, use_cache=False, return_dict=True)
        step_logits = out.logits[:, -1, :]
        token = step_logits.argmax(-1)
        logits_hist.append(step_logits.cpu().numpy())
        token_hist.append(token.cpu().numpy())
        if stop_on_eos:
            done = done | (token == EOS_ID)
            if bool(done.all()):
                break
        nxt = token.clone()
        nxt[done] = PAD_ID
        ids = torch.cat([ids, nxt.unsqueeze(1)], dim=1)
    return logits_hist, token_hist


def onnx_cache_decode(
    step0: OrtGraph, kv: OrtGraph, eh: Any, max_steps: int, stop_on_eos: bool
) -> Tuple[List[Any], List[Any]]:
    """The new behaviour: one token per step plus past_key_values."""
    import numpy as np

    batch = eh.shape[0]
    out = step0.run(
        {"input_ids": np.full((batch, 1), START_ID, dtype=np.int64), "encoder_hidden_states": eh}
    )
    logits = out["logits"][:, -1, :]
    past = {name: value for name, value in out.items() if name.startswith("present.")}
    logits_hist = [logits.copy()]
    token_hist = [logits.argmax(-1).astype(np.int64)]
    done = np.zeros(batch, dtype=bool)
    if stop_on_eos:
        done = done | (token_hist[0] == EOS_ID)
    feed_tokens = token_hist[0].copy()
    for step in range(1, max_steps):
        if done.all():
            break
        feed_tokens[done] = PAD_ID
        feed: Dict[str, Any] = {
            "input_ids": feed_tokens.reshape(batch, 1).astype(np.int64),
            "encoder_hidden_states": eh,
            "position_ids": np.full((batch, 1), step, dtype=np.int64),
        }
        for name, value in past.items():
            feed["past_key_values." + name[len("present.") :]] = value
        out = kv.run(feed)
        logits = out["logits"][:, -1, :]
        past = {name: value for name, value in out.items() if name.startswith("present.")}
        token = logits.argmax(-1).astype(np.int64)
        logits_hist.append(logits.copy())
        token_hist.append(token)
        if stop_on_eos:
            done = done | (token == EOS_ID)
        feed_tokens = token.copy()
    return logits_hist, token_hist


def shipped_nocache_decode(
    graph: OrtGraph, eh: Any, max_steps: int, stop_on_eos: bool
) -> Tuple[List[Any], List[Any]]:
    import numpy as np

    batch = eh.shape[0]
    ids_name = graph.pick(["input_ids"])
    eh_name = graph.pick(["encoder_hidden_states"])
    logits_name = graph.pick_out(["logits"])
    ids = np.full((batch, 1), START_ID, dtype=np.int64)
    done = np.zeros(batch, dtype=bool)
    logits_hist: List[Any] = []
    token_hist: List[Any] = []
    for _ in range(max_steps):
        out = graph.run({ids_name: ids, eh_name: eh})
        step_logits = out[logits_name][:, -1, :]
        token = step_logits.argmax(-1).astype(np.int64)
        logits_hist.append(step_logits.copy())
        token_hist.append(token)
        if stop_on_eos:
            done = done | (token == EOS_ID)
            if bool(done.all()):
                break
        nxt = token.copy()
        nxt[done] = PAD_ID
        ids = np.concatenate([ids, nxt.reshape(batch, 1)], axis=1)
    return logits_hist, token_hist


def compare_stepwise(
    ref_logits: List[Any], ref_tokens: List[Any], new_logits: List[Any], new_tokens: List[Any], label: str
) -> Tuple[List[str], float, int]:
    """Compare every compared step's argmax on every row, and logit distance."""
    import numpy as np

    steps = min(len(ref_logits), len(new_logits))
    if steps == 0:
        return [f"{label}: no steps compared"], 0.0, 0
    mismatches: List[str] = []
    max_diff = 0.0
    for step in range(steps):
        ref_l = np.asarray(ref_logits[step])
        new_l = np.asarray(new_logits[step])
        if ref_l.shape != new_l.shape:
            mismatches.append(f"{label}: step={step} shape {ref_l.shape} vs {new_l.shape}")
            break
        max_diff = max(max_diff, float(np.abs(ref_l - new_l).max()))
        ref_t = np.asarray(ref_tokens[step])
        new_t = np.asarray(new_tokens[step])
        bad = ref_t != new_t
        if bad.any():
            for row in np.where(bad)[0][:4]:
                ref_top = np.argsort(-ref_l[row])[:2].tolist()
                new_top = np.argsort(-new_l[row])[:2].tolist()
                mismatches.append(
                    f"{label}: step={step} row={int(row)} ref_argmax={int(ref_t[row])} "
                    f"new_argmax={int(new_t[row])} ref_top2={ref_top} new_top2={new_top}"
                )
    return mismatches, max_diff, steps


def has_repetition_loop(tokens: Sequence[int]) -> bool:
    """Mirror of BatchDecodeState.hasRepetitionLoop: 4 identical tail tokens, or
    a trigram repeated twice."""
    n = len(tokens)
    if n >= 4 and tokens[n - 1] == tokens[n - 2] == tokens[n - 3] == tokens[n - 4]:
        return True
    if n >= 6 and all(tokens[n - 1 - i] == tokens[n - 4 - i] for i in range(3)):
        return True
    return False


# --------------------------------------------------------------------------- #
# corpus
# --------------------------------------------------------------------------- #
def build_corpus(model: Any, snapshot: str, enc_seq_len_hint: Optional[int]) -> List[Dict[str, Any]]:
    import numpy as np
    import torch

    items: List[Dict[str, Any]] = []

    def encode_image(image: Any, label: str) -> Optional[Dict[str, Any]]:
        try:
            from transformers import ViTImageProcessor

            processor = ViTImageProcessor.from_pretrained(snapshot)
            with torch.no_grad():
                pixels = processor(images=image.convert("RGB"), return_tensors="pt").pixel_values
                hidden = model.encoder(pixel_values=pixels).last_hidden_state
            return {"label": label, "eh": hidden.cpu().numpy().astype(np.float32), "source": "vit_encoder"}
        except Exception as exc:  # noqa: BLE001
            log(f"encoder path failed for {label}: {type(exc).__name__}: {exc}")
            return None

    try:
        from PIL import Image, ImageDraw

        def blank(color: str) -> Any:
            return Image.new("RGB", (224, 224), color)

        def bars() -> Any:
            img = blank("white")
            draw = ImageDraw.Draw(img)
            for row in range(3):
                top = 30 + row * 60
                draw.rectangle([20, top, 204, top + 26], fill="black")
            return img

        def glyphs() -> Any:
            img = blank("white")
            draw = ImageDraw.Draw(img)
            for row in range(6):
                top = 16 + row * 32
                for col in range(9):
                    left = 12 + col * 22
                    draw.rectangle([left, top, left + 14, top + 22], fill="black")
            return img

        def noise() -> Any:
            rng = np.random.default_rng(1234)
            return Image.fromarray(rng.integers(0, 256, size=(224, 224, 3), dtype=np.uint8), "RGB")

        factories = [
            ("white", lambda: blank("white")),
            ("black", lambda: blank("black")),
            ("bars", bars),
            ("glyphs", glyphs),
            ("noise", noise),
        ]
        for label, factory in factories:
            item = encode_image(factory(), label)
            if item is not None:
                items.append(item)
    except Exception as exc:  # noqa: BLE001
        log(f"PIL corpus unavailable: {type(exc).__name__}: {exc}")

    width = enc_seq_len_hint or (items[0]["eh"].shape[1] if items else 196)
    hidden = items[0]["eh"].shape[2] if items else 768
    items.append(
        {"label": "zeros", "eh": np.zeros((1, width, hidden), dtype=np.float32), "source": "synthetic"}
    )
    for seed in (7, 21, 99):
        rng = np.random.default_rng(seed)
        items.append(
            {
                "label": f"rand{seed}",
                "eh": (rng.standard_normal((1, width, hidden)) * 0.6).astype(np.float32),
                "source": "synthetic",
            }
        )
    shapes = {item["eh"].shape[1:] for item in items}
    if len(shapes) != 1:
        raise RuntimeError(f"corpus items disagree on encoder shape: {shapes}")
    return items


# --------------------------------------------------------------------------- #
# equivalence suite
# --------------------------------------------------------------------------- #
def run_equivalence(
    args: argparse.Namespace,
    decoder: Any,
    step0_path: Path,
    kv_path: Path,
    corpus: List[Dict[str, Any]],
    shipped_path: Optional[Path],
) -> Dict[str, Any]:
    import numpy as np
    import torch

    step0 = OrtGraph(step0_path)
    kv = OrtGraph(kv_path)
    shipped = OrtGraph(shipped_path) if shipped_path is not None else None

    report: Dict[str, Any] = {"cases": [], "mismatches": [], "notes": []}
    fatal: List[str] = []

    def record(case: str, ok: bool, detail: Dict[str, Any]) -> None:
        payload = dict(detail)
        payload["case"] = case
        payload["verdict"] = "PASS" if ok else "FAIL"
        report["cases"].append(payload)
        if not ok:
            fatal.append(case)

    # ---- case 1: immediate EOS / single step -----------------------------
    one_step_ok = True
    one_step_detail: Dict[str, Any] = {
        "items": len(corpus),
        "immediate_eos_items": [],
        "max_logit_diff": 0.0,
    }
    for item in corpus:
        eh_t = torch.from_numpy(item["eh"])
        ref_logits, ref_tokens = torch_nocache_decode(decoder, eh_t, 1, stop_on_eos=False)
        new_logits, new_tokens = onnx_cache_decode(step0, kv, item["eh"], 1, stop_on_eos=False)
        bad, diff, _ = compare_stepwise(
            ref_logits, ref_tokens, new_logits, new_tokens, f"step0[{item['label']}]"
        )
        one_step_detail["max_logit_diff"] = max(one_step_detail["max_logit_diff"], diff)
        if bad:
            one_step_ok = False
            report["mismatches"].extend(bad)
        if int(ref_tokens[0][0]) == EOS_ID:
            one_step_detail["immediate_eos_items"].append(item["label"])
    search_found = False
    for seed in range(64):
        rng = np.random.default_rng(1000 + seed)
        eh = (rng.standard_normal((1, corpus[0]["eh"].shape[1], corpus[0]["eh"].shape[2])) * 0.5).astype(
            np.float32
        )
        out = step0.run(
            {"input_ids": np.full((1, 1), START_ID, dtype=np.int64), "encoder_hidden_states": eh}
        )
        if int(out["logits"][:, -1, :].argmax(-1)[0]) != EOS_ID:
            continue
        search_found = True
        one_step_detail["immediate_eos_search"] = {"found": True, "seed": 1000 + seed}
        ref_logits, ref_tokens = torch_nocache_decode(decoder, torch.from_numpy(eh), 1, stop_on_eos=True)
        new_logits, new_tokens = onnx_cache_decode(step0, kv, eh, 1, stop_on_eos=True)
        bad, diff, _ = compare_stepwise(ref_logits, ref_tokens, new_logits, new_tokens, "immediate_eos")
        one_step_detail["max_logit_diff"] = max(one_step_detail["max_logit_diff"], diff)
        if bad:
            one_step_ok = False
            report["mismatches"].extend(bad)
        break
    if not search_found:
        one_step_detail["immediate_eos_search"] = {"found": False, "searched": 64}
        report["notes"].append(
            "no input emitted EOS at step 0; the immediate-EOS path is still covered because step-0 "
            "logits/argmax are compared on every corpus input"
        )
    record("immediate_eos_single_step", one_step_ok, one_step_detail)

    # ---- case 2: repetition loop ----------------------------------------
    loop_ok = True
    loop_detail: Dict[str, Any] = {
        "items": len(corpus),
        "looped_items": [],
        "steps": 48,
        "max_logit_diff": 0.0,
    }
    for item in corpus:
        eh_t = torch.from_numpy(item["eh"])
        ref_logits, ref_tokens = torch_nocache_decode(decoder, eh_t, 48, stop_on_eos=False)
        new_logits, new_tokens = onnx_cache_decode(step0, kv, item["eh"], 48, stop_on_eos=False)
        bad, diff, _ = compare_stepwise(
            ref_logits, ref_tokens, new_logits, new_tokens, f"loop[{item['label']}]"
        )
        loop_detail["max_logit_diff"] = max(loop_detail["max_logit_diff"], diff)
        if bad:
            loop_ok = False
            report["mismatches"].extend(bad)
        if has_repetition_loop([int(step_tokens[0]) for step_tokens in ref_tokens]):
            loop_detail["looped_items"].append(item["label"])
    if not loop_detail["looped_items"]:
        report["notes"].append("no corpus item produced a repetition loop within 48 forced steps")
    record("repetition_loop", loop_ok, loop_detail)

    # ---- case 3: long line up to the app ceiling ------------------------
    long_steps = min(args.max_steps, MAX_TOKENS - 1)
    long_ok = True
    long_detail: Dict[str, Any] = {"items": len(corpus), "steps": long_steps, "max_logit_diff": 0.0}
    torch_seconds = 0.0
    onnx_seconds = 0.0
    for item in corpus:
        eh_t = torch.from_numpy(item["eh"])
        started = time.perf_counter()
        ref_logits, ref_tokens = torch_nocache_decode(decoder, eh_t, long_steps, stop_on_eos=False)
        torch_seconds += time.perf_counter() - started
        started = time.perf_counter()
        new_logits, new_tokens = onnx_cache_decode(step0, kv, item["eh"], long_steps, stop_on_eos=False)
        onnx_seconds += time.perf_counter() - started
        bad, diff, _ = compare_stepwise(
            ref_logits, ref_tokens, new_logits, new_tokens, f"long[{item['label']}]"
        )
        long_detail["max_logit_diff"] = max(long_detail["max_logit_diff"], diff)
        if bad:
            long_ok = False
            report["mismatches"].extend(bad)
    long_detail["cpu_seconds_torch_nocache"] = round(torch_seconds, 3)
    long_detail["cpu_seconds_onnx_cache"] = round(onnx_seconds, 3)
    long_detail["note"] = "CPU timing only; not a GPU speed claim"
    record("long_line", long_ok, long_detail)

    # ---- case 4: batch > 1 with pad-while-done --------------------------
    picks = [item for item in corpus if item["source"] == "vit_encoder"][:3]
    if len(picks) < 3:
        picks = corpus[:3]
    batch_ok = True
    batch_detail: Dict[str, Any] = {
        "rows": len(picks),
        "steps": 24,
        "max_logit_diff": 0.0,
        "labels": [p["label"] for p in picks],
        "batch_invariant": None,
    }
    eh_batch = np.concatenate([p["eh"] for p in picks], axis=0)
    ref_logits, ref_tokens = torch_nocache_decode(
        decoder, torch.from_numpy(eh_batch), 24, stop_on_eos=False
    )
    new_logits, new_tokens = onnx_cache_decode(step0, kv, eh_batch, 24, stop_on_eos=False)
    bad, diff, _ = compare_stepwise(ref_logits, ref_tokens, new_logits, new_tokens, "batch")
    batch_detail["max_logit_diff"] = diff
    if bad:
        batch_ok = False
        report["mismatches"].extend(bad)
    invariant = True
    for row, item in enumerate(picks):
        single_logits, single_tokens = onnx_cache_decode(step0, kv, item["eh"], 24, stop_on_eos=False)
        for step in range(min(len(single_tokens), len(new_tokens))):
            if int(single_tokens[step][0]) != int(new_tokens[step][row]):
                invariant = False
                report["mismatches"].append(
                    f"batch_invariance: row={row} step={step} single={int(single_tokens[step][0])} "
                    f"batched={int(new_tokens[step][row])}"
                )
                break
    batch_detail["batch_invariant"] = invariant
    batch_ok = batch_ok and invariant
    record("batch_gt_1", batch_ok, batch_detail)

    # ---- case 5: cross-check the shipped no-cache artifact ---------------
    if shipped is not None:
        ship_ok = True
        ship_detail: Dict[str, Any] = {"file": str(shipped_path), "items": 0, "max_logit_diff": 0.0}
        for item in corpus[:4]:
            eh_t = torch.from_numpy(item["eh"])
            ref_logits, ref_tokens = torch_nocache_decode(decoder, eh_t, 16, stop_on_eos=False)
            ship_logits, ship_tokens = shipped_nocache_decode(shipped, item["eh"], 16, stop_on_eos=False)
            bad, diff, _ = compare_stepwise(
                ref_logits, ref_tokens, ship_logits, ship_tokens, f"shipped[{item['label']}]"
            )
            ship_detail["items"] += 1
            ship_detail["max_logit_diff"] = max(ship_detail["max_logit_diff"], diff)
            if bad:
                ship_ok = False
                report["mismatches"].extend(bad)
        record("shipped_reference_crosscheck", ship_ok, ship_detail)
    else:
        report["notes"].append(
            "shipped decoder_model.onnx unavailable; the old-path reference is PyTorch only"
        )

    report["fatal"] = fatal
    return report


# --------------------------------------------------------------------------- #
# main
# --------------------------------------------------------------------------- #
def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Export a KV-cache manga-ocr decoder ONNX and verify equivalence."
    )
    parser.add_argument("--model-id", default=DEFAULT_MODEL_ID)
    parser.add_argument("--reference-repo", default=DEFAULT_REFERENCE_REPO)
    parser.add_argument("--reference-file", default=DEFAULT_REFERENCE_FILE)
    parser.add_argument("--out-dir", default=str(REPO_ROOT / "dist"))
    parser.add_argument(
        "--cache-dir", default=os.environ.get("HF_HOME", str(Path.home() / ".cache" / "huggingface"))
    )
    parser.add_argument("--hf-endpoint", default=DEFAULT_ENDPOINTS[0])
    parser.add_argument("--opset", type=int, default=17)
    parser.add_argument("--max-steps", type=int, default=MAX_TOKENS - 1)
    parser.add_argument("--fp16", action="store_true", help="also emit fp16 (keep_io_types) and re-verify")
    parser.add_argument(
        "--no-shipped-check",
        action="store_true",
        help="skip the cross-check against the shipped decoder_model.onnx",
    )
    return parser.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)
    out_dir = Path(args.out_dir).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    cache_dir = Path(args.cache_dir).expanduser().resolve()
    endpoints = [args.hf_endpoint] + [e for e in DEFAULT_ENDPOINTS if e != args.hf_endpoint]

    import numpy as np
    import torch
    import transformers
    from transformers import VisionEncoderDecoderModel

    log(f"torch={torch.__version__} transformers={transformers.__version__} numpy={np.__version__}")

    snapshot, used_endpoint = download_snapshot(args.model_id, endpoints, cache_dir)
    log(f"model snapshot: {snapshot} (endpoint {used_endpoint})")

    config = VisionEncoderDecoderModel.config_class.from_pretrained(snapshot)
    # Force eager attention.  This MUST be set on the top-level config:
    # VisionEncoderDecoderModel passes config._attn_implementation down to both
    # sub-models (modeling_vision_encoder_decoder.py L193/L196), and
    # PreTrainedModel._from_config lets that kwarg win over the sub-config's own
    # value (modeling_utils.py L1478-1485).  PreTrainedModel.from_pretrained also
    # autosets the top-level config (L3826), which would otherwise pick "sdpa".
    config._attn_implementation = "eager"
    config.encoder._attn_implementation = "eager"
    config.decoder._attn_implementation = "eager"
    model = VisionEncoderDecoderModel.from_pretrained(
        snapshot, config=config, torch_dtype=torch.float32
    )
    model.eval()
    decoder = model.decoder
    if not hasattr(decoder, "bert"):
        raise RuntimeError(
            f"decoder is {type(decoder).__name__}, not a BERT decoder; this exporter targets the "
            "manga-ocr BertLMHeadModel decoder"
        )
    attn_impl = type(decoder.bert.encoder.layer[0].attention.self).__name__
    log(
        f"decoder: {type(decoder).__name__} layers={decoder.config.num_hidden_layers} "
        f"heads={decoder.config.num_attention_heads} use_cache={decoder.config.use_cache} "
        f"attn={attn_impl}"
    )
    if attn_impl != "BertSelfAttention":
        raise RuntimeError(
            "could not force eager attention (found %s); the export would depend on the SDPA "
            "ONNX decomposition. The top-level config._attn_implementation must be 'eager' "
            "(VisionEncoderDecoderModel propagates it to the sub-models); check the "
            "transformers/torch version pinning." % attn_impl
        )

    corpus = build_corpus(model, snapshot, None)
    enc_seq_len = int(corpus[0]["eh"].shape[1])
    log(f"corpus: {[item['label'] for item in corpus]} encoder_seq_len={enc_seq_len}")

    layout = discover_cache_layout(decoder, enc_seq_len)
    log(
        f"cache layout: layers={layout['num_layers']} per_layer={layout['per_layer']} "
        f"cross_seq_len={layout['cross_seq_len']} heads={layout['heads']} head_dim={layout['head_dim']}"
    )

    step0_path = out_dir / STEP0_NAME
    kv_path = out_dir / KV_NAME
    example_eh = torch.from_numpy(corpus[0]["eh"])
    export_step0(decoder, layout, example_eh, step0_path, args.opset)
    log(f"exported {step0_path.name} ({step0_path.stat().st_size} bytes)")
    export_with_past(decoder, layout, example_eh, kv_path, args.opset)
    log(f"exported {kv_path.name} ({kv_path.stat().st_size} bytes)")

    shipped_path: Optional[Path] = None
    if not args.no_shipped_check:
        found = download_file(args.reference_repo, args.reference_file, endpoints, cache_dir)
        if found is not None:
            shipped_path = Path(found[0])
            log(f"shipped reference: {shipped_path} via {found[1]}")
        else:
            log("shipped reference unavailable; equivalence falls back to the PyTorch old path")

    report = run_equivalence(args, decoder, step0_path, kv_path, corpus, shipped_path)

    artifacts = [describe_onnx(step0_path), describe_onnx(kv_path)]
    if shipped_path is not None:
        report["reference_artifact"] = {
            "file": shipped_path.name,
            "bytes": shipped_path.stat().st_size,
            "sha256": sha256_file(shipped_path),
        }

    if args.fp16:
        converter = TOOL_DIR / "model_export" / "to_fp16.py"
        fp16_paths: Dict[Path, Path] = {}
        for source in (step0_path, kv_path):
            target = source.with_name(source.stem + "_fp16.onnx")
            log(f"fp16: {source.name} -> {target.name} via {converter}")
            proc = subprocess.run(
                [sys.executable, str(converter), str(source), str(target)],
                check=False,
                capture_output=True,
                text=True,
            )
            if proc.returncode != 0:
                raise RuntimeError(f"to_fp16.py failed for {source.name}: {proc.stderr[-2000:]}")
            fp16_paths[source] = target
        fp16_report = run_equivalence(
            args, decoder, fp16_paths[step0_path], fp16_paths[kv_path], corpus, shipped_path
        )
        if fp16_report["fatal"]:
            raise RuntimeError(
                f"fp16 equivalence FAILED: {fp16_report['mismatches'][:4]}"
            )
        artifacts.append(describe_onnx(fp16_paths[step0_path]))
        artifacts.append(describe_onnx(fp16_paths[kv_path]))
        report["fp16"] = {"verdict": "PASS", "cases": fp16_report["cases"]}

    meta = {
        "schema": "venerax.manga_ocr.decoder_kv.v1",
        "generated_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "source_model": args.model_id,
        "source_endpoint": used_endpoint,
        "versions": {
            "torch": torch.__version__,
            "transformers": transformers.__version__,
            "numpy": np.__version__,
        },
        "token_ids": {"pad": PAD_ID, "start": START_ID, "eos": EOS_ID, "max_tokens": MAX_TOKENS},
        "decoder": {
            "arch": type(decoder).__name__,
            "attention_implementation": attn_impl,
            "num_hidden_layers": int(decoder.config.num_hidden_layers),
            "num_attention_heads": int(decoder.config.num_attention_heads),
            "hidden_size": int(decoder.config.hidden_size),
            "vocab_size": int(decoder.config.vocab_size),
            "max_position_embeddings": int(decoder.config.max_position_embeddings),
            "encoder_seq_len": enc_seq_len,
        },
        "cache_layout": layout,
        "artifacts": artifacts,
        "equivalence": report,
        "contract": {
            "step0": "feed input_ids [batch,1] holding the start token; keep present.* as the cache",
            "with_past": "feed one new token [batch,1], position_ids [[step]] and every "
                         "past_key_values.*; the self-attention mask is internal (all keys visible)",
            "graph_inputs_note": "encoder_hidden_states sequence length is fixed at export time "
                                 f"(S={enc_seq_len}); batch is dynamic",
        },
    }
    (out_dir / META_NAME).write_text(json.dumps(meta, indent=2, ensure_ascii=False), encoding="utf-8")
    (out_dir / "SHA256SUMS.txt").write_text(
        "".join(f"{a['sha256']}  {a['file']}\n" for a in artifacts), encoding="utf-8"
    )

    summary_lines = ["# manga-ocr KV-cache decoder export", ""]
    summary_lines.append(f"- source model: `{args.model_id}` (endpoint `{used_endpoint}`)")
    summary_lines.append(
        f"- torch `{torch.__version__}`, transformers `{transformers.__version__}`, "
        f"numpy `{np.__version__}`"
    )
    summary_lines.append(
        f"- decoder: `{type(decoder).__name__}` layers={decoder.config.num_hidden_layers} "
        f"heads={decoder.config.num_attention_heads} vocab={decoder.config.vocab_size} attn={attn_impl}"
    )
    summary_lines.append("")
    summary_lines.append("## Artifacts")
    summary_lines.append("")
    summary_lines.append("| file | bytes | sha256 | precision | opset | inputs | outputs |")
    summary_lines.append("| :--- | ---: | :--- | :--- | :--- | ---: | ---: |")
    for art in artifacts:
        summary_lines.append(
            f"| `{art['file']}` | {art['bytes']} | `{art['sha256']}` | {art['precision']} | "
            f"{art['opset']} | {len(art['inputs'])} | {len(art['outputs'])} |"
        )
    summary_lines.append("")
    summary_lines.append("## Equivalence: new cache path vs old full-prefix path")
    summary_lines.append("")
    summary_lines.append("| case | verdict | detail |")
    summary_lines.append("| :--- | :--- | :--- |")
    for case in report["cases"]:
        detail = {k: v for k, v in case.items() if k not in ("case", "verdict")}
        summary_lines.append(
            f"| `{case['case']}` | **{case['verdict']}** | `{json.dumps(detail, ensure_ascii=False)}` |"
        )
    summary_lines.append("")
    if report["mismatches"]:
        summary_lines.append("### Mismatches")
        summary_lines.append("")
        for line in report["mismatches"][:40]:
            summary_lines.append(f"- {line}")
        summary_lines.append("")
    if report["notes"]:
        summary_lines.append("### Notes")
        summary_lines.append("")
        for line in report["notes"]:
            summary_lines.append(f"- {line}")
        summary_lines.append("")
    summary_lines.append("### Contract")
    for key, value in meta["contract"].items():
        summary_lines.append(f"- `{key}`: {value}")
    summary_text = "\n".join(summary_lines) + "\n"
    (out_dir / "SUMMARY.md").write_text(summary_text, encoding="utf-8")
    step_summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if step_summary:
        with open(step_summary, "a", encoding="utf-8") as handle:
            handle.write(summary_text)

    print(summary_text)
    if report["fatal"]:
        log("EQUIVALENCE FAILED: " + ", ".join(report["fatal"]))
        return 1
    log("equivalence PASSED for all cases")
    return 0


if __name__ == "__main__":
    sys.exit(main())
