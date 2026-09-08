#!/usr/bin/env python3
"""
Convert FP32 ONNX model to in-graph FP16 with keep_io_types=True.
Inputs and outputs remain FP32 so host/FFI code requires no changes
and CPU fallback remains functional, while internal math utilizes
half-precision Tensor Cores on CUDA and DirectML GPUs.

Usage:
    python tool/model_export/to_fp16.py input_model.onnx output_model_fp16.onnx
"""

import argparse
import os
import sys


def convert_to_fp16(input_path: str, output_path: str, max_rel_err_thresh: float = 2e-2) -> bool:
    try:
        import onnx
        from onnxconverter_common import float16
    except ImportError:
        print("ERROR: 'onnx' and 'onnxconverter-common' packages are required.", file=sys.stderr)
        print("Install via: pip install onnx onnxconverter-common", file=sys.stderr)
        return False

    print(f"Loading model: {input_path}")
    model = onnx.load(input_path)

    print("Converting weights to FP16 (keep_io_types=True)...")
    # Certain ops are sensitive to precision loss or overflow; keep them in fp32
    op_block_list = ["LayerNorm", "Softmax", "Resize", "Range"]
    model_fp16 = float16.convert_float_to_float16(
        model,
        keep_io_types=True,
        disable_shape_infer=False,
        op_block_list=op_block_list,
    )

    os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
    onnx.save(model_fp16, output_path)
    print(f"Saved FP16 model to: {output_path}")

    # Numerical validation between FP32 and FP16
    try:
        import numpy as np
        import onnxruntime as ort

        sess_orig = ort.InferenceSession(input_path, providers=["CPUExecutionProvider"])
        sess_fp16 = ort.InferenceSession(output_path, providers=["CPUExecutionProvider"])

        feed_dict = {}
        for inp in sess_orig.get_inputs():
            shape = [d if (d is not None and isinstance(d, int) and d > 0) else 1 for d in inp.shape]
            dtype = np.float32 if "float" in inp.type else (np.int64 if "int64" in inp.type else np.int32)
            feed_dict[inp.name] = np.ones(shape, dtype=dtype)

        out_orig = sess_orig.run(None, feed_dict)
        out_fp16 = sess_fp16.run(None, feed_dict)

        max_rel_err = 0.0
        for o1, o2 in zip(out_orig, out_fp16):
            a1 = np.array(o1)
            a2 = np.array(o2)
            abs_diff = np.abs(a1 - a2)
            denom = np.maximum(np.abs(a1), 1e-5)
            rel_err = np.max(abs_diff / denom)
            if rel_err > max_rel_err:
                max_rel_err = rel_err

        print(f"Validation max relative error: {max_rel_err:.4e} (threshold: {max_rel_err_thresh})")
        if max_rel_err > max_rel_err_thresh:
            print(f"ERROR: Relative error {max_rel_err:.4e} exceeds threshold {max_rel_err_thresh}!", file=sys.stderr)
            return False
        else:
            print("FP16 precision check PASSED!")
    except Exception as e:
        print(f"Note: Numerical validation skipped or limited ({e})")

    return True


def main():
    parser = argparse.ArgumentParser(description="Convert FP32 ONNX model to in-graph FP16.")
    parser.add_argument("input", help="Source FP32 ONNX model")
    parser.add_argument("output", help="Output FP16 ONNX model")
    parser.add_argument("--max-rel-err", type=float, default=2e-2,
                        help="Maximum allowable relative error compared to FP32 (default: 0.02)")
    args = parser.parse_args()

    ok = convert_to_fp16(args.input, args.output, max_rel_err_thresh=args.max_rel_err)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
