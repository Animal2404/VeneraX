#!/usr/bin/env python3
"""
Inspect ONNX models: inputs, outputs, dimensions, dynamic batching, and checksums.
Supports checking individual models or directories, with an assertion flag for CI.

Usage:
    python tool/model_export/check_model.py path/to/model.onnx
    python tool/model_export/check_model.py --assert-dynamic-batch path/to/*.onnx
    python tool/model_export/check_model.py --json path/to/model.onnx
"""

import argparse
import hashlib
import json
import os
import sys
from typing import Any, Dict, List, Optional


def compute_sha256(filepath: str) -> str:
    h = hashlib.sha256()
    with open(filepath, "rb") as f:
        while chunk := f.read(1024 * 1024):
            h.update(chunk)
    return h.hexdigest()


def inspect_with_ort(filepath: str) -> Dict[str, Any]:
    import onnxruntime as ort

    # Disable telemetry and set low logging
    opts = ort.SessionOptions()
    opts.log_severity_level = 3
    session = ort.InferenceSession(filepath, sess_options=opts, providers=["CPUExecutionProvider"])

    inputs = []
    has_dynamic_batch = True

    for inp in session.get_inputs():
        shape = inp.shape
        # Check batch dimension (index 0)
        # Dim is dynamic if it is None, negative, or a string name
        is_dyn = False
        if len(shape) > 0:
            batch_dim = shape[0]
            if batch_dim is None or isinstance(batch_dim, str) or (isinstance(batch_dim, int) and batch_dim <= 0):
                is_dyn = True
            elif batch_dim == 1:
                # May be static 1
                is_dyn = False
            else:
                is_dyn = False
        else:
            is_dyn = False

        if not is_dyn:
            has_dynamic_batch = False

        inputs.append({
            "name": inp.name,
            "type": inp.type,
            "shape": shape,
            "dynamic_batch": is_dyn,
        })

    outputs = []
    for out in session.get_outputs():
        outputs.append({
            "name": out.name,
            "type": out.type,
            "shape": out.shape,
        })

    return {
        "file": filepath,
        "size_bytes": os.path.getsize(filepath),
        "sha256": compute_sha256(filepath),
        "inputs": inputs,
        "outputs": outputs,
        "dynamic_batch_capable": has_dynamic_batch,
    }


def inspect_with_onnx(filepath: str) -> Dict[str, Any]:
    import onnx

    model = onnx.load(filepath)
    inputs = []
    has_dynamic_batch = True

    for inp in model.graph.input:
        shape_dims = []
        is_dyn = False
        tensor_type = inp.type.tensor_type
        elem_type = onnx.TensorProto.DataType.Name(tensor_type.elem_type)
        if tensor_type.HasField("shape"):
            for idx, dim in enumerate(tensor_type.shape.dim):
                if dim.HasField("dim_param"):
                    shape_dims.append(dim.dim_param)
                    if idx == 0:
                        is_dyn = True
                elif dim.HasField("dim_value"):
                    shape_dims.append(dim.dim_value)
                    if idx == 0 and dim.dim_value <= 0:
                        is_dyn = True
                else:
                    shape_dims.append("?")
                    if idx == 0:
                        is_dyn = True

        if not is_dyn:
            has_dynamic_batch = False

        inputs.append({
            "name": inp.name,
            "type": elem_type,
            "shape": shape_dims,
            "dynamic_batch": is_dyn,
        })

    outputs = []
    for out in model.graph.output:
        shape_dims = []
        tensor_type = out.type.tensor_type
        elem_type = onnx.TensorProto.DataType.Name(tensor_type.elem_type)
        if tensor_type.HasField("shape"):
            for dim in tensor_type.shape.dim:
                if dim.HasField("dim_param"):
                    shape_dims.append(dim.dim_param)
                elif dim.HasField("dim_value"):
                    shape_dims.append(dim.dim_value)
                else:
                    shape_dims.append("?")
        outputs.append({
            "name": out.name,
            "type": elem_type,
            "shape": shape_dims,
        })

    return {
        "file": filepath,
        "size_bytes": os.path.getsize(filepath),
        "sha256": compute_sha256(filepath),
        "inputs": inputs,
        "outputs": outputs,
        "dynamic_batch_capable": has_dynamic_batch,
    }


def inspect_model(filepath: str) -> Dict[str, Any]:
    try:
        import onnx
        return inspect_with_onnx(filepath)
    except ImportError:
        try:
            import onnxruntime
            return inspect_with_ort(filepath)
        except ImportError:
            # Fallback to basic file info
            return {
                "file": filepath,
                "size_bytes": os.path.getsize(filepath),
                "sha256": compute_sha256(filepath),
                "error": "Neither 'onnx' nor 'onnxruntime' is installed.",
                "dynamic_batch_capable": False,
            }


def main():
    parser = argparse.ArgumentParser(description="Inspect ONNX model dimensions, batching, and checksums.")
    parser.add_argument("models", nargs="+", help="Paths to .onnx model files")
    parser.add_argument("--json", action="store_true", help="Output results as formatted JSON")
    parser.add_argument("--assert-dynamic-batch", "--fail-on-static", action="store_true",
                        help="Exit with code 1 if any model has static batch dimension")
    args = parser.parse_args()

    results = []
    failed_models = []

    for path in args.models:
        if not os.path.isfile(path):
            print(f"Warning: file not found: {path}", file=sys.stderr)
            continue
        info = inspect_model(path)
        results.append(info)
        if not info.get("dynamic_batch_capable", False):
            failed_models.append(path)

    if args.json:
        print(json.dumps(results, indent=2))
    else:
        for r in results:
            print(f"Model: {r['file']}")
            print(f"  Size: {r['size_bytes']:,} bytes")
            print(f"  SHA-256: {r['sha256']}")
            print(f"  Dynamic Batch: {'YES' if r.get('dynamic_batch_capable') else 'NO'}")
            if "inputs" in r:
                print("  Inputs:")
                for inp in r["inputs"]:
                    dyn_str = " (dynamic batch)" if inp.get("dynamic_batch") else ""
                    print(f"    - {inp['name']}: {inp['type']} {inp['shape']}{dyn_str}")
            if "outputs" in r:
                print("  Outputs:")
                for out in r["outputs"]:
                    print(f"    - {out['name']}: {out['type']} {out['shape']}")
            print()

    if args.assert_dynamic_batch and failed_models:
        print(f"ERROR: {len(failed_models)} model(s) do not support dynamic batching:", file=sys.stderr)
        for m in failed_models:
            print(f"  - {m}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
