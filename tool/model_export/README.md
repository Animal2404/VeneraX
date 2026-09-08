# VeneraX Offline Model Export Toolchain

This directory contains offline scripts to inspect, convert to dynamic batch, convert to in-graph FP16, and publish ONNX models for VeneraX OCR and AI Translation.

> **Note**: These scripts are strictly for offline preparation and release management. None of these Python dependencies are included in the packaged VeneraX desktop or mobile application.

---

## 1. Setup

```bash
pip install -r tool/model_export/requirements.txt
```

---

## 2. Workflow

### Step 1: Inspect Upstream Models
Check inputs, outputs, dimensions, and dynamic batch status:
```bash
python tool/model_export/check_model.py path/to/model.onnx
```

### Step 2: Ensure Dynamic Batch
Ensure dimension 0 of inputs and outputs is dynamic:
```bash
python tool/model_export/ensure_dynamic_batch.py source_model.onnx dynamic_model.onnx
```

### Step 3: Convert to In-Graph FP16
Convert FP32 weights to FP16 while preserving FP32 input/output interfaces (`keep_io_types=True`):
```bash
python tool/model_export/to_fp16.py dynamic_model.onnx model_fp16.onnx
```

### Step 4: Verify Models
Ensure all models satisfy dynamic batching requirements:
```bash
python tool/model_export/check_model.py --assert-dynamic-batch dist/*.onnx
```

### Step 5: Publish to GitHub Release
Upload models to the `models` release tag:
```bash
python tool/model_export/publish.py dist/*.onnx
```

---

## 3. Upstream Licenses & Attribution

All models used in VeneraX are permissively licensed:

1. **PaddleOCR / RapidOCR (PP-OCRv4, PP-OCRv3, PP-OCRv1)**:
   - Source: [PaddlePaddle/PaddleOCR](https://github.com/PaddlePaddle/PaddleOCR) and [SWHL/RapidOCR](https://github.com/RapidAI/RapidOCR)
   - License: **Apache-2.0**
   - Re-exporting weights to dynamic batch / FP16 does not modify the underlying model weights or license.

2. **manga-ocr (Vision Encoder-Decoder)**:
   - Source: [kha-white/manga-ocr](https://github.com/kha-white/manga-ocr) and [mayocream/manga-ocr-onnx](https://github.com/mayocream/manga-ocr-onnx)
   - License: **Apache-2.0**
   - Vocabulary: RoBERTa / Japanese BERT vocabulary under Apache-2.0.
