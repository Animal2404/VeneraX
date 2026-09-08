# ONNX Runtime & DirectML Lockfile

- **DirectML ORT Version**: `1.22.0`
  - Package: `https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime.directml/1.22.0/microsoft.ml.onnxruntime.directml.1.22.0.nupkg`
  - Package SHA-256: `29f9872d786236b79aa83f94482f3a17c14297e4833768d6d0ed4883ee732e60`
  - onnxruntime.dll SHA-256: `95366724919f4e95ecc60010912ed538ad9804b6683fbd0aad389749102834b9`
- **DirectML Library Version**: `1.15.4`
  - Package: `https://api.nuget.org/v3-flatcontainer/microsoft.ai.directml/1.15.4/microsoft.ai.directml.1.15.4.nupkg`
  - Package SHA-256: `4e7cb7ddce8cf837a7a75dc029209b520ca0101470fcdf275c1f49736a3615b9`
  - DirectML.dll SHA-256: `9c9e6d822561c6c41b90e6994b3e8857cf1d66dbfb1e0c4c799c7c89b4e92da1`

Minimum OS: Windows 10 Version 1903 (Build 18362) or later (DirectX 12 / WDDM 2.x).

## DirectML 已知不支持项（D-15）

- **现象**：本表锁定的组合（ORT DirectML 1.22.0 + DirectML 1.15.4）在 RTX 3060 Laptop 上，
  `Run` 阶段于 `Softmax_0` 节点返回 `80070057`（E_INVALIDARG），报自
  `providers/dml/DmlExecutionProvider/src/MLOperatorAuthorImpl.cpp(2851)`。
- **归属（离线扫描节点名，不靠猜）**：`Softmax_0` 只在 `ocr_en/rec.onnx`（PP-OCRv3 en）
  与 `ocr_ko/rec.onnx`（PP-OCRv1 ko）中出现；`ocr_zh/rec.onnx`、`ocr_ja/{encoder,decoder}.onnx`
  无此节点名，两个检测模型完全不含 Softmax。
- **已排除的假设**：并非"该模型在 DML 上必崩"——单独只放英文页时 `recBatch=1` 与 `recBatch=32`
  均成功。触发条件与跨语言会话共存/形状序列相关；`MLOperatorAuthorImpl` 闭源，
  精确形状谓词**无法由本仓库判定，此处不做猜测**。
- **临时边界（数据，不是逻辑）**：`translation_worker.dart` 的
  `_cpuOnlyRecDirs = ['ocr_en', 'ocr_ko']` 将这两个识别器钉在 CPU EP（8.9 MB / 3.3 MB 模型，
  CPU 开销可忽略）。理由：`Run` 期错误没有 EP 回退路径（回退状态机只保护建会话），
  不处理就是整页失败。
- **顺带修正**：`OrtFfiException.classify` 原把宽泛的 `'provider'` 子串放在最前，
  含 `DmlExecutionProvider` 的 OOM 会被误标为 `epUnavailable`——本该收缩批量的错误
  变成"换个 EP 重试"。现改为资源耗尽类先行，并删除因此不可达的重复分支。
- **解除条件**：查清触发谓词或上游修复后，从该清单移除，并以
  `--headless ocr-golden --batches 1,4,16,32 --repeat 3` 复测金标文本一致性（门 G1）。
