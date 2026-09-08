# Model Assets Catalog & Probe Records

This document records the official source, path, file size, SHA-256 checksum, and probe dates for all ONNX model assets used in VeneraX OCR.
All entries in this catalog have been verified via live API queries and git-lfs pointers.

Probe Date: 2026-09-08

---

## 1. Verified Active Model Assets

### 1.1 Text Detection

| Component ID | File | Source Repo | Path / URL | Size (Bytes) | SHA-256 Checksum |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `text_detector` (Fast) | `det.onnx` | `SWHL/RapidOCR` | `PP-OCRv4/ch_PP-OCRv4_det_infer.onnx` | 4,745,517 | `d2a7720d45a54257208b1e13e36a8479894cb74155a5efe29462512d42f49da9` |
| `text_detector_high` (High) | `det.onnx` | `SWHL/RapidOCR` | `PP-OCRv4/ch_PP-OCRv4_det_server_infer.onnx` | 113,352,104 | `cfa39a3f298f6d3fc71789834d15da36d11a6c59b489fc16ea4733728012f786` |

### 1.2 Text Recognition (Chinese / English / Korean)

| Component ID | File | Source Repo | Path / URL | Size (Bytes) | SHA-256 Checksum |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `ocr_zh` (Fast) | `rec.onnx` | `SWHL/RapidOCR` | `PP-OCRv4/ch_PP-OCRv4_rec_infer.onnx` | 10,857,958 | `48fc40f24f6d2a207a2b1091d3437eb3cc3eb6b676dc3ef9c37384005483683b` |
| `ocr_zh` (Fast) | `dict.txt` | `PaddlePaddle/PaddleOCR` | `ppocr/utils/ppocr_keys_v1.txt` | 26,249 (6623 lines) | `28b2362ad4ab2dc38769aa72feb535e3a9ddb3fd2a7585a05920e6393b1dc7f7` |
| `ocr_zh_high` (High) | `rec.onnx` | `SWHL/RapidOCR` | `PP-OCRv4/ch_PP-OCRv4_rec_server_infer.onnx` | 90,530,732 | `6a2676219be9907c7fc9cf61ebaa843bf2898777def567925b78886fcd90c07a` |
| `ocr_zh_high` (High) | `dict.txt` | `ocr_zh` (shared) | Shared with `ocr_zh` via `dictFrom` | - | - |
| `ocr_en` (Fast) | `rec.onnx` | `SWHL/RapidOCR` | `PP-OCRv3/en_PP-OCRv3_rec_infer.onnx` | 8,967,018 | `ef7abd8bd3629ae57ea2c28b425c1bd258a871b93fd2fe7c433946ade9b5d9ea` |
| `ocr_en` (Fast) | `dict.txt` | `PaddlePaddle/PaddleOCR` | `ppocr/utils/en_dict.txt` | 190 (95 lines) | `5662df9d2d03f0e8ca0d3b0649d6acbab904b6a14b3d3521463c71c37c668ce3` |
| `ocr_ko` (Fast) | `rec.onnx` | `SWHL/RapidOCR` | `PP-OCRv1/korean_mobile_v2.0_rec_infer.onnx` | 3,290,650 | `b6558500138b43b46a4941957fb8c918546dae5fb0e71718536f1883acc80faf` |
| `ocr_ko` (Fast) | `dict.txt` | `PaddlePaddle/PaddleOCR` | `ppocr/utils/dict/korean_dict.txt` | 14,480 (3688 lines) | `aa1fdc8ae8f7cd40a0ec4edb472eb0421e11427e6ccfee9915440742c18b0a20` |

### 1.3 Japanese Manga OCR (Vision Encoder-Decoder)

| Component ID | File | Source Repo | Path / URL | Size (Bytes) | SHA-256 Checksum |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `ocr_ja` (Fast) | `encoder.onnx` | `mayocream/manga-ocr-onnx` | `encoder_model.onnx` | 343,454,249 | `15fa8155fe9bc1a7d25d9bb353debaa4def033d0174e907dbd2dd6d995def85f` |
| `ocr_ja` (Fast) | `decoder.onnx` | `mayocream/manga-ocr-onnx` | `decoder_model.onnx` | 117,480,262 | `ef7765261e9d1cdc34d89356986c2bbc2a082897f753a89605ae80fdfa61f5e8` |
| `ocr_ja` (Fast) | `vocab.txt` | `mayocream/manga-ocr-onnx` | `vocab.txt` | 30,216 | `5cb5c5586d98a2f331d9f8828e4586479b0611bfba5d8c3b6dadffc84d6a36a3` |

### 1.4 FP16 GPU Variants (`requiresGpuEp: true`)

Generated using `to_fp16.py` with `keep_io_types=True`:
- `ocr_ja_fp16`: `encoder.onnx` (~172 MB), `decoder.onnx` (~59 MB), `vocab.txt` (shared).
- `ocr_zh_fp16`: `rec.onnx` (~5.5 MB), `dict.txt` (shared via `dictFrom: 'ocr_zh'`).
- `ocr_zh_high_fp16`: `rec.onnx` (~45 MB), `dict.txt` (shared via `dictFrom: 'ocr_zh'`).

---

## 2. Reserved & Deferred Components

| Component ID | Purpose | Status | Reason & Date |
| :--- | :--- | :--- | :--- |
| `text_detector_manga` | Manga bubble / vertical-specific text detector | Reserved (`enabled: false`) | Pending upstream model evaluation and integration testing (2026-09-08). |

---

## 3. Abandoned / Skipped Assets

| Candidate Asset | Candidate Repo | Reason for Omission | Date |
| :--- | :--- | :--- | :--- |
| `japan_rec_crnn.onnx` | `SWHL/RapidOCR/PP-OCRv1` | Low recognition accuracy on complex manga fonts and vertical arrangements compared to manga-ocr vision encoder-decoder. Skipped in favor of `mayocream/manga-ocr-onnx`. | 2026-09-08 |
| `en_PP-OCRv4_rec` | `SWHL/RapidOCR` | PP-OCRv4 does not have a dedicated English-only model; v3 rec model remains the official high-accuracy English model in RapidOCR. | 2026-09-08 |
