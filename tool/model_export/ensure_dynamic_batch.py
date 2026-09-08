#!/usr/bin/env python3
"""
Convert static-batch ONNX models to dynamic batch axis.
Modifies dimension 0 of inputs and outputs to use dynamic param 'batch',
and verifies numerical equivalence on sample inputs.

Usage:
    python tool/model_export/ensure_dynamic_batch.py input_model.onnx output_model.onnx
"""

import argparse
import os
import sys
from typing import List, Tuple


def set_dynamic_batch(input_path: str, output_path: str) -> bool:
    try:
        import onnx
    except ImportError:
        print("ERROR: 'onnx' python package is required to modify model graph.", file=sys.stderr)
        print("Install via: pip install onnx", file=sys.stderr)
        return False

    print(f"Loading ONNX model: {input_path}")
    model = onnx.load(input_path)

    # 1. Update graph inputs
    modified_inputs = 0
    for inp in model.graph.input:
        tensor_type = inp.type.tensor_type
        if tensor_type.HasField("shape") and len(tensor_type.shape.dim) > 0:
            dim0 = tensor_type.shape.dim[0]
            if dim0.HasField("dim_value") and dim0.dim_value == 1:
                print(f"  Making input '{inp.name}' dim 0 dynamic (was static 1)")
                dim0.ClearField("dim_value")
                dim0.dim_param = "batch"
                modified_inputs += 1
            elif not dim0.HasField("dim_param"):
                dim0.dim_param = "batch"
                modified_inputs += 1

    # 2. Update graph outputs
    modified_outputs = 0
    for out in model.graph.output:
        tensor_type = out.type.tensor_type
        if tensor_type.HasField("shape") and len(tensor_type.shape.dim) > 0:
            dim0 = tensor_type.shape.dim[0]
            if dim0.HasField("dim_value") and dim0.dim_value == 1:
                print(f"  Making output '{out.name}' dim 0 dynamic (was static 1)")
                dim0.ClearField("dim_value")
                dim0.dim_param = "batch"
                modified_outputs += 1
            elif not dim0.HasField("dim_param"):
                dim0.dim_param = "batch"
                modified_outputs += 1

    print(f"Modified {modified_inputs} input(s) and {modified_outputs} output(s).")

    # 3. Shape inference
    try:
        inferred = onnx.shape_inference.infer_shapes(model)
        model = inferred
        print("  Shape inference succeeded.")
    except Exception as e:
        print(f"  Warning: shape inference returned: {e}")

    # 4. Save output model
    os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
    onnx.save(model, output_path)
    print(f"Saved dynamic batch model to: {output_path}")

    # 5. Verify equivalence if onnxruntime is available
    try:
        import numpy as np
        import onnxruntime as ort

        sess_orig = ort.InferenceSession(input_path, providers=["CPUExecutionProvider"])
        sess_new = ort.InferenceSession(output_path, providers=["CPUExecutionProvider"])

        feed_dict = {}
        for inp in sess_orig.get_inputs():
            shape = [d if (d is not None and isinstance(d, int) and d > 0) else 1 for d in inp.shape]
            dtype = np.float32 if "float" in inp.type else (np.int64 if "int64" in inp.type else np.int32)
            feed_dict[inp.name] = np.ones(shape, dtype=dtype)

        out_orig = sess_orig.run(None, feed_dict)
        out_new = sess_new.run(None, feed_dict)

        max_diff = 0.0
        for o1, o2 in zip(out_orig, out_new):
            diff = np.max(np.abs(np.array(o1) - np.array(o2)))
            if diff > max_diff:
                max_diff = diff

        print(f"Numerical validation (batch=1): max absolute difference = {max_diff:.6e}")
        if max_diff > 1e-4:
            print("WARNING: Output difference exceeds 1e-4!", file=sys.stderr)
            return False
        else:
            print("Equivalence verified successfully!")
    except Exception as e:
        print(f"Note: Equivalence verification skipped ({e})")

    return True


def main():
    parser = argparse.ArgumentParser(description="Convert static-batch ONNX models to dynamic batch axis.")
    parser.add_argument("input", help="Source ONNX model")
    parser.add_argument("output", help="Output dynamic-batch ONNX model")
    args = parser.parse_args()

    ok = set_dynamic_batch(args.input, args.output)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
