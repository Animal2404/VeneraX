# 漫画机翻 App 模型选型调研报告（Flutter 桌面端 / 本地 ONNX Runtime / DirectML + CPU）

> 调研方法声明：本报告的数字（字节数、类别数、推理耗时）均由本地实测或官方 API 直接取得，不是二手转述。
> 实测环境：Windows / Python 3.12 / onnxruntime 1.28.0（CPUExecutionProvider）。
> 证据文件全部落在 `E:\Gemini\_research\` 下（`onnx/` 为下载的权重，`*.py` 为探针脚本，`*.txt` 为实测输出）。
> 标注规则：**可用** = 有官方来源且我们本地跑通或官方页明示；**无效** = 已失效/无权重/无 ONNX 且不可替代；**待验证** = 无公开来源或未能实证。

---

## 0. 一句话结论

**「9.5MB 的漫画气泡检测专用模型」完全可信，且正好落在业界主流尺寸上**——它不是异常值，而是 YOLO-nano/small 级别的标准大小。
反过来，**真正的坑在 DirectML 与许可证**：`onnxruntime-directml` 仍停在 ORT 1.24.4（基础版已到 1.28.0），官方文档明确 DirectML 只支持到 **opset 20** 且已进入 **sustained engineering（维护模式）**；同时漫画领域最好的检测模型（dmMaze/comic-text-detector、kitsumed 气泡分割）是 **GPL-3.0**。

---

## 1. 漫画文字检测（text detection / DBNet 类）

| # | 模型名 | 用途 | 来源链接 | 体积（精确） | 语言覆盖 | 许可证 | 最近维护 | 有 ONNX？ | Windows 可行性 | 结论 |
|---|---|---|---|---|---|---|---|---|---|---|
| 1.1 | dmMaze/comic-text-detector | 漫画文本检测 + 分割掩膜 | [GitHub](https://github.com/dmMaze/comic-text-detector) | 仓库内**无权重文件**（tree 实测 42 项，仅 .py/.md/LICENSE） | 日/中/英漫画 | GPL-3.0 | 最后 push **2023-08-13**（stars 372） | ❌ 仓库内无 | 需外链取权重 | **部分可用（仓库=训练代码，权重在别处）** |
| 1.2 | comictextdetector.pt | 漫画检测（Torch） | [release beta-0.3](https://github.com/zyddnys/manga-image-translator/releases/tag/beta-0.3) | **76.25 MB** | 日/中/英 | GPL-3.0 | release **2022-04-23** | — | 需 PyTorch | **可用（但非 ONNX）** |
| 1.3 | comictextdetector.pt.onnx | 漫画检测（ONNX） | [同上](https://github.com/zyddnys/manga-image-translator/releases/tag/beta-0.3) | **94,669,756 B = 90.28 MB** | 日/中/英 | GPL-3.0 | 2022-04-23 | ✅ 官方导出 | ✅ 本地跑通：in `images` float32 **[1,3,1024,1024]**（**固定尺寸**）；out `blk`[1,64512,7] + `seg`[1,1,1024,1024] + `det`[1,2,1024,1024] | **可用（当前最强漫画检测 ONNX）** |
| 1.4 | M-I-T `default` = detect-20241225.ckpt | 通用文本检测（DBNet） | [M-I-T default.py](https://github.com/zyddnys/manga-image-translator/blob/main/manga_translator/detection/default.py) | **294.09 MB**（sha256 `67ce1c4e…502e`，代码内置校验） | 日/中/英 | GPL-3.0 | 权重 **2024-12-25** 版；仓库 push **2026-07-20** | ❌ 无官方 ONNX | 需自转，且 DBNet 的 `det_rearrange_forward` 分块逻辑要自己实现 | **可用（精度优先，但重）** |
| 1.5 | M-I-T `craft` | CRAFT 检测 | [craft.py](https://github.com/zyddnys/manga-image-translator/blob/main/manga_translator/detection/craft.py) | craft_mlt_25k.pth **79.30 MB** + craft_refiner_CTW1500.pth **1.77 MB** | 拉丁/中文为主 | GPL-3.0 | 2022-04-23 | ❌ | CRAFT 自研后处理较重 | **可用（非首选）** |
| 1.6 | M-I-T `dbnet_convnext` | 高精度 DBNet-ConvNeXt | [dbnet_convnext.py](https://github.com/zyddnys/manga-image-translator/blob/main/manga_translator/detection/dbnet_convnext.py) | — | — | GPL-3.0 | — | ❌ | — | **无效 / 已废弃**（`_MODEL_MAPPING` 的 `url` 为空字符串，实际下不到权重） |
| 1.7 | PaddleOCR PP-OCRv5_mobile_det | 轻量文本检测 | [HF](https://huggingface.co/PaddlePaddle/PP-OCRv5_mobile_det_onnx) | ONNX **4.60 MB**（实测 4,826,518 B） | 中/英（官方标注） | Apache-2.0 | 2026-06-10 | ✅ **官方 ONNX** | ✅ 本地跑通：动态 H/W，输入 640×640 → 输出 **(1,1,640,640)** 概率图 | **可用（最省心的检测器）** |
| 1.8 | **PP-OCRv5_server_det** | **server 级高精度检测** | [HF](https://huggingface.co/PaddlePaddle/PP-OCRv5_server_det) | `inference.pdiparams` **83.86 MB** | **简中/繁中/英/日**，官方明示支持**手写、竖排、旋转、弯曲** | Apache-2.0 | 2025-07-22 | ✅ 有 [官方 ONNX 页](https://huggingface.co/PaddlePaddle/PP-OCRv5_server_det_onnx)，我们实测下载 **88,116,791 B = 84.03 MB** | ✅ 单图 ONNX，无自定义算子 | **可用（官方「server 级」变体真实存在）** |
| 1.9 | PP-OCRv6_small_det_onnx | 新一代轻量检测 | [HF](https://huggingface.co/PaddlePaddle/PP-OCRv6_small_det_onnx) | 实测 **9,880,512 B = 9.42 MB** | 中/英 | Apache-2.0 | 2026-06-18 | ✅ 官方 ONNX | ✅ | **可用（新选项）** |
| 1.10 | PP-OCRv6_medium_det_onnx | 新一代中量检测 | [HF](https://huggingface.co/PaddlePaddle/PP-OCRv6_medium_det_onnx) | **59.16 MB** | 中/英 | Apache-2.0 | 2026-06-18 | ✅ 官方 ONNX | ✅ | **可用** |
| 1.11 | PP-OCRv4_server_det / v4_mobile_det | 上一代检测 | [HF v4 server](https://huggingface.co/PaddlePaddle/PP-OCRv4_server_det) | server **108.05 MB**；v4 mobile 见同组织页 | 中/英 | Apache-2.0 | 2025-07-22 | ❌ **无官方 ONNX**（只有 Paddle 格式） | 需自转 | **待验证（无官方 ONNX，不推荐）** |

### 关于「server 级 / 高精度（large）变体是否真实存在」——**真实存在，具体到文件名与体积**

| 声称的变体 | 是否真实 | 具体文件名 | 精确体积 | 来源 |
|---|---|---|---|---|
| PP-OCRv5 **server** det（高精度检测） | ✅ 真实 | `inference.pdiparams` / ONNX `inference.onnx` | 83.86 MB / 84.03 MB | [v5_server_det](https://huggingface.co/PaddlePaddle/PP-OCRv5_server_det)、[v5_server_det_onnx](https://huggingface.co/PaddlePaddle/PP-OCRv5_server_det_onnx) |
| PP-OCRv5 **server** rec（高精度识别） | ✅ 真实 | `inference.onnx` | **84,503,027 B = 80.59 MB** | [v5_server_rec_onnx](https://huggingface.co/PaddlePaddle/PP-OCRv5_server_rec_onnx) |
| PP-OCRv6 medium det/rec | ✅ 真实 | `inference.onnx` | det 59.16 MB / rec **76,554,979 B = 73.01 MB** | [v6_medium_det_onnx](https://huggingface.co/PaddlePaddle/PP-OCRv6_medium_det_onnx)、[v6_medium_rec_onnx](https://huggingface.co/PaddlePaddle/PP-OCRv6_medium_rec_onnx) |
| M-I-T 「OCR large」 | ⚠️ **存在但是死代码** | `manga_translator/ocr/model_ocr_large.py` | 模块 23,678 B，**无 `_MODEL_MAPPING`** | [model_ocr_large.py](https://github.com/zyddnys/manga-image-translator/blob/main/manga_translator/ocr/model_ocr_large.py)；`ocr/__init__.py` 的 `OCRS` 只注册 `ocr32px / ocr48px / ocr48px_ctc / mocr`，**没有 ocr_large** |

> **结论**：PaddleOCR 系「server / medium」高精度变体是真的、有官方 ONNX、可直接下载；
> 而 M-I-T 里的 `ocr_large` 是**未被注册的死代码**，不要照它的名字去做选型。

### 官方检测性能基准（含 CPU 耗时，**这是选型最该看的一张表**）

来源：PaddleOCR 官方《文本检测模块使用教程》表格（我们已存档为 `_research/ppocr_det_doc_v3.md`）。
测试环境：**CPU = Intel Xeon Gold 6271C @ 2.60GHz / FP32 / 8 线程**；GPU = Tesla T4；数据集含中/繁/英/日共 2677 张。

| 模型 | 检测 Hmean(%) | GPU ms（常规/高性能） | **CPU ms（常规/高性能）** | 官方体积(MB) | 我们实测 ONNX 体积(MB) | 官方定位 |
|---|---|---|---|---|---|---|
| **PP-OCRv6_tiny_det** | 80.6* | - / - | **- / -** | **1.9**（0.43M 参数） | — | 超轻量，端侧/IoT |
| PP-OCRv6_small_det | 84.1* | - / - | - / - | 9.6 | **9.42** | 兼顾精度效率，移动端 |
| PP-OCRv6_medium_det | **86.2*** | - / - | - / - | 59.4 | 59.16 | **精度最高，服务端** |
| PP-OCRv5_server_det | 83.8 | 89.55 / 70.19 | **383.15 / 383.15** | 84.3 | 84.03 | 服务端，精度更高 |
| **PP-OCRv5_mobile_det** | 79.0 | 10.67 / 6.36 | **57.77 / 28.15** | 4.7 | **4.60** | 端侧部署 |
| PP-OCRv4_server_det | 69.2 | 127.82 / 98.87 | **585.95 / 489.77** | 109 | ❌ 无官方 ONNX | 上一代服务端 |
| PP-OCRv4_mobile_det | 63.8 | 9.87 / 4.17 | 56.60 / 20.79 | 4.7 | ❌ 无官方 ONNX | 上一代端侧 |

> ⚠️ **官方注明的关键 caveat**：PP-OCRv6 指标基于**内部多场景评估集**，PP-OCRv5/v4 基于**通用评估集**，
> **两者评估集不同，指标不可直接对比**。

**从这张表得到的三条硬结论（直接决定选型）**：

1. **v5_server_det 在 CPU 上要 383 ms/张**，比 v5_mobile_det 的 **57.77 ms** 慢 **6.6×**，Hmean 只高 4.8 分。
   → 桌面端默认档位应选 **v5_mobile_det（4.60 MB / 57.77 ms）**；v5_server 只作为「高精度模式」兜底。
2. **v4 已被全面取代**：v4_mobile_det 与 v5_mobile_det **同为 4.7 MB**，但 Hmean **63.8 → 79.0（+15.2 分）**；
   v4_server_det 更是 **109 MB / Hmean 69.2 / CPU 586 ms** 的三重劣势，且**无官方 ONNX**。
   → **任何 v4 检测模型都不应进入清单**。
3. **v6_tiny_det 仅 1.9 MB（0.43M 参数）却仍有 Hmean 80.6***，是「极致瘦身档」的真实可选项。

> **另一个落地细节（官方文档原文）**：PaddleOCR 官方模型**默认从 HuggingFace 获取**；
> 若运行环境访问 HuggingFace 不便，可设环境变量 `PADDLE_PDX_MODEL_SOURCE="BOS"` 改用百度 BOS 源。
> 对本 App 的含义：**模型源要可配置**，否则 HF 不通的地区用户会直接卡在下载步骤。

### 1.12 溯源与许可证分级：同一个权重可能有多份「马甲」（影响能不能商用）

我们在全网扫描时发现一个**对法务决策极其重要**的现象：**同一个模型文件在不同仓库下挂着不同的 license**。

| 权重（按 sha256 判定同一文件） | 体积（精确） | 托管仓库 | 该仓库声明的 license | 含义 |
|---|---|---|---|---|
| `comic-text-detector.onnx`<br>sha256 `1a86ace74961413cbd650002e7bb4dcec4980ffa21b2f19b86933372071d718f` | **94,669,756 B** | [mayocream/comic-text-detector-onnx](https://huggingface.co/mayocream/comic-text-detector-onnx) | **apache-2.0** | 社区再托管，声明宽松 |
| 同一权重的 safetensors 拆分版（dbnet 16,686,024 B + yolo-v5 14,120,386 B + unet 48,981,624 B） | 合计 79,788,034 B | [mayocream/comic-text-detector](https://huggingface.co/mayocream/comic-text-detector) | 仓库**自述为 GPL-3.0**（README 写明 "GPL-3.0, following the BallonsTranslator implementation"） | **同一作者的另一个仓库自述 GPL-3.0**，与其 onnx 仓库的 apache-2.0 标签**互相矛盾** |
| 同上（**同一 sha256**） | 94,669,756 B | [kuanhusn/mangayaku-onnx-int8](https://huggingface.co/kuanhusn/mangayaku-onnx-int8) | **GPL-3.0** | 同一文件挂 GPL-3.0 |
| 上游原始来源 | — | [dmMaze/comic-text-detector](https://github.com/dmMaze/comic-text-detector)（权重实际取自 M-I-T release） | **GPL-3.0** | **上游是 GPL-3.0** |

> ⚠️ **法务判断**：再托管仓库改成 Apache-2.0 **不改变**上游的 GPL-3.0 义务。
> **我们实测到的最危险组合**：`mayocream` 名下两个仓库对同一血统的权重给出**互相矛盾**的标签 ——
> `comic-text-detector-onnx` 标 **apache-2.0**，而 `comic-text-detector` 自述 **GPL-3.0**，同字节的 `kuanhusn` 版本标 **GPL-3.0**。
> **「同一作者的仓库写成 apache-2.0」会让团队误以为已核实过，这恰恰是最容易踩的坑。**
> 对闭源商用 App，要合法应走真正自治的 Apache-2.0 链路：
> **ogkalu（RT-DETR，Apache-2.0）+ PaddleOCR（Apache-2.0）+ manga-ocr 上游（Apache-2.0）**。
> M-I-T **官方从未就「权重单独许可」发表声明** → 该项标注 **无公开来源，待验证**。
> 相关的许可证分级（从严到宽）：**AGPL-3.0 > CC-BY-NC-SA-4.0（非商用）> GPL-3.0 > 未声明 > Apache-2.0**。
> 例：`Liiesl/bubble-segment-onnx`（koharu-yolo26s-seg，ONNX **42,056,366 B = 40.11 MB**）为 **AGPL-3.0**；
> `sepehrak/bubblerizermator` 的 ONNX **109,403,003 B = 104.33 MB** 为 **GPL-3.0**；
> **`lordtrilink/manga-text-detector-v0`（YOLO11s，1024×1024，8/16 更新）的 ONNX 质量很高
> （`best-1024-fp32.onnx` 38,191,707 B = 36.42 MB、`best-1024-fp16.onnx` 19,149,737 B = 18.26 MB）
> 但 license 是 `cc-by-nc-sa-4.0` = 明确禁止商用** → 对商业 App 直接排除。

> **另一个容易被忽略的法务细节**：PaddleOCR 的 HF 模型仓库（如 `PP-OCRv5_server_det_onnx`）
> **没有 LICENSE 文件**（`raw/main/LICENSE` 实测 404），许可证只存在于 README 的 front-matter（`license: apache-2.0`）。
> 合规归档时不要只找 `LICENSE` 文件，否则会误判为「无许可证」。

### 1.14 comictextdetector.onnx 的两个「静默陷阱」（**实测确认，最容易写错的地方**）

我们用**均匀灰度输入（全 0.5）**做了激活函数判别实验，结果如下：

| 输出 | 形状 | 均匀输入下的实测值 | 是否已带激活函数 | 正确用法 |
|---|---|---|---|---|
| `blk` | `[1,64512,7]` | max = 1021.3992 | — | YOLOv5 头：列 0-3 = `cx,cy,w,h`（1021 这种大数值即证明是**像素坐标**，不是归一化）；列 4 = obj；列 5-6 = text/bubble 类别分。**图内无 NonMaxSuppression 节点 → NMS 要自己写**。<br>⚠️ **该头在 M-I-T 现行代码中已停用** —— `ctd.py` 注释原文："YOLO was used for finding bboxes which to order the lines into. This is now solved through the textline merger"。**代价：这 64512×7 的头在每次推理中仍会白烧算力。** |
| `seg` | `[1,1,1024,1024]` | **min 0.0000 / max 0.0211 / mean 0.0000** | ❌ **是原始 DB logits，图内没有 sigmoid** | **必须自己做 `sigmoid` 再接阈值**。实测 `sigmoid(seg)` → min **0.5000** / max **0.5053**（正确回到了「全 0.5 输入≈0.5 概率」的预期） |
| `det` | `[1,2,1024,1024]` | ch0 0.0000–0.5481 / ch1 0.2909–0.5821 | 已带激活 | 概率图 + 阈值图 |

> **这是本项目最高危的静默 bug**：如果直接把 `seg` 当掩膜用，得到的是「几乎全 0 的图」，
> 不会报错、不会崩，只是**擦字/掩膜完全不生效**，而且很难定位（连通域阈值 @0.3 永远得空）。
> **反向陷阱**：PaddleOCR 的 det 输出**已过 sigmoid**（我们实测 min 0.00000 / max 0.02337 @640²）。
> **两者的后处理行为完全相反，代码不可共用。**

> **关于分块（tiling）的精确条件（修正我们早前的表述）**：
> M-I-T 并非对所有输入都分块。`generic.py:950` 的条件是 **`down_scale_ratio > 2.5` 且 `aspect_ratio > 3`** 时才走 `det_rearrange_forward`
> （重叠处 `tgtmap /= 2` 做平均融合）。
> 即：**普通单页漫画（接近 1:1~1:2）不需要分块；只有极端长条（如超长网漫条）才需要**。
> 但**输入尺寸仍是硬性固定 `[1,3,1024,1024]`**，所以 letterbox + 坐标反变换是必须的。

> **Paddle det 的动态形状也不是「任意尺寸」**：喂 1×1 / 64×64 会触发 ORT 缺陷
> （`NchwcConv::Compute output and sum shape must match`，`nchwc_ops.cc:197`）。
> 官方 yml 声明支持区间为 `[[1,3,32,32], [1,3,736,736], [1,3,4000,4000]]`，**建议限制最小输入边长（保守 ≥640）**。

### 1.15 落地必须自建的前/后处理契约（Flutter/Dart 侧的工作量清单）

| 环节 | comictextdetector.onnx（GPL-3.0） | PaddleOCR det 系（Apache-2.0） |
|---|---|---|
| 色彩/尺寸 | BGR→**RGB** → `letterbox(new_shape=(1024,1024), auto=False, **stride=64**)` → HWC→CHW → **纯 `/255`** → float32；**必须保留 `ratio, (dw,dh)`** | 动态长宽比可原生推理；官方 yml：`DetResizeForTest: resize_long 960` |
| 归一化 | 仅 `/255`（**无 mean/std**） | **ImageNet 归一化**：`mean [0.485,0.456,0.406] / std [0.229,0.224,0.225] / scale 1/255 / order hwc`（**与 comictextdetector 不同**） |
| 输出激活 | `seg` **需自己 sigmoid**；`det` 已激活 | 输出**已过 sigmoid** |
| 后处理阈值 | `SegDetectorRepresenter(thresh=0.3, box_thresh=0.7, max_candidates=1000, unclip_ratio=1.5)` → 二值化 → 轮廓 → **unclip** → 再用 `box_thresh=0.6` 二次过滤 | `DBPostProcess: thresh 0.3, box_thresh 0.6, max_candidates 1000, unclip_ratio 1.5` |
| **外部依赖** | **`pyclipper` + `shapely`**（多边形偏移/几何运算）→ **Dart 无现成等价包，需自研** | 同上（unclip 逻辑需自研） |
| 坐标还原 | `seg` 先裁 `dw/dh` 再 `cv2.resize` 回原图 → **必须严格按 letterbox `ratio` 反算**，否则文本行整体偏移 | 按实际输入比例反算 |
| 输出顺序 | **不要复制 M-I-T 的 `cv2.dnn` 猜测逻辑**（源码注释自承 "some version of opencv spit out reversed result"）→ 走 ORT 时**按图输出名显式取 `blk/seg/det`** | 单输出 `fetch_name_0`，无歧义 |

> **工作量提示**：comictextdetector 虽然精度最好，但它把 **letterbox stride-64 对齐 + 两次 resize 坐标反算 + pyclipper/shapely 等价实现** 都推给了消费方。
> 相比之下 PaddleOCR det 是**动态形状单输出**，接入成本低得多 —— 这是「默认档位选 PaddleOCR」的第二条工程理由（第一条见 §1.15 耗时对照）。

### 1.16 CPU 实测耗时对照（同一台机器 / ORT 1.28.0 / CPUExecutionProvider）

| 模型 | 输入 | 实测单张耗时 | 备注 |
|---|---|---|---|
| `comictextdetector.onnx` | 1024×1024 | **2.29–2.73 s** | 漫画专用，精度最好，但 **GPL-3.0** |
| `ppocrv5_server_det.onnx` | 640×640 | **1.28 s** | 官方基准（8 线程 Xeon）为 383 ms，本机为普通桌面 CPU |
| `ppocrv5_server_det.onnx` | 1024×1024 | **4.39 s** | 与 subagent 独立测得的 5.75 s 同量级，结论一致 |
| `ppocrv5_mobile_det.onnx` | 640×640 | 远快于上述（官方基准 57.77 ms / 8 线程） | **桌面端默认档位** |

> **结论**：**v5_server_det 在漫画场景上相对 comictextdetector 没有精度优势，却慢 4–6×**（该结论来自独立复核子代理）。
> 因此漫画页检测应优先 **ogkalu（Apache-2.0）** 或 **comictextdetector（GPL-3.0，需法务）**，
> 而 `v5_server_det` 更适合做「通用/文档型页面」的高精度档。

> **另一个可复现的 ORT 缺陷（避免误判为模型问题）**：给 `ppocrv5_server_det.onnx` 喂**极小输入**（如 1×1、64×64）时，
> ORT 的 NCHWC contrib Conv 路径会抛 `output and sum shape must match`（`nchwc_ops.cc:197`）。
> **对策：始终喂真实尺寸**（>=320×320），不要用 1×1 做「连通性测试」。

### 1.13 M-I-T 294MB 检测模型的 ONNX 化现状：已有第三方转换，但**必须分块推理**

[Skepsun/manga-translator-ui-onnx](https://huggingface.co/Skepsun/manga-translator-ui-onnx)（GPL-3.0）提供了 M-I-T 全家桶的 ONNX 转换与转换脚本：

| 文件 | 体积（精确） | 说明 |
|---|---|---|
| `detect-20241225.onnx` | **306,013,054 B = 291.84 MB** | M-I-T `default` 检测器的 ONNX 版（对应 294.09 MB 的 .ckpt） |
| `alphabet-all-v7.txt` | 186,651 B | 与官方 release 的文件**字节数完全一致**（我们实测同为 186,651 B） |
| `convert_detect_to_onnx.py` / `convert_ocr_to_onnx_v6.py` | 9,805 B / 9,173 B | 官方转换脚本 |
| `detect-20241225-onnx-usage.md` | 16,810 B | **使用说明长文 —— 暗示该模型不是「塞进去就能跑」** |

> **坑（已精确定位条件，非「一律分块」）**：该模型是 **291.84 MB 的 DBNet**。
> M-I-T 的 `default.py` 用 `det_rearrange_forward(...)` 做分块前向，但触发条件是
> `generic.py:950` 的 **`down_scale_ratio > 2.5` 且 `aspect_ratio > 3`**：
> **普通单页漫画不需要分块，只有极端长条（超长网漫条）才需要**。
> 即便如此，**分块拼接、padding、边界缝合逻辑仍要自己实现**，工作量远大于直接用 PaddleOCR 单图模型。
> 这也是我们建议「默认档位用 PP-OCRv5_mobile_det，而不是 M-I-T default」的工程理由。

---

## 2. 漫画文字识别（OCR，重点：日语竖排）

| # | 模型名 | 用途 | 来源链接 | 体积（精确） | 语言覆盖 | 许可证 | 最近维护 | 有 ONNX？ | Windows 可行性 | 结论 |
|---|---|---|---|---|---|---|---|---|---|---|
| 2.1 | **kha-white/manga-ocr** | 日语漫画 OCR（竖排+横排） | [GitHub](https://github.com/kha-white/manga-ocr) / [manga-ocr-base](https://huggingface.co/kha-white/manga-ocr-base) | 首次运行下载 **约 400 MB**（官方 README 原文） | **日语**（竖排、横排、振假名、多行单次前向） | **Apache-2.0** | 仓库 push **2026-07-19**（stars 2777） | ❌ 官方不出 ONNX（第三方导出多） | ✅ 社区已有 Windows/Android 版 | **可用（日语竖排的首选）** |
| 2.2 | l0wgear/manga-ocr-2025-onnx | manga-ocr 的 ONNX 导出 | [HF](https://huggingface.co/l0wgear/manga-ocr-2025-onnx) | encoder **22,356,885 B = 21.32 MB** + decoder **118,053,454 B = 112.58 MB**（合计 133.90 MB）；vocab.txt 24,072 B | 日语 | **未声明**（无 license 字段） | 2025-06-30 | ✅ Optimum 导出 | ✅ **我们本地裸跑通**（不装 transformers/optimum，手写 greedy 循环） | **可用（推荐）** |
| 2.3 | onnx-community/manga-ocr-base-ONNX | 官方社区 ONNX（含量化） | [HF](https://huggingface.co/onnx-community/manga-ocr-base-ONNX) | fp32 encoder 327.47 MB + decoder 112.00 MB；**量化后 encoder int8 82.94 MB + decoder int8 28.26 MB ≈ 111 MB**；q4 更小 | 日语 | Apache-2.0 | 2026-04-18 | ✅ | ✅ `transformers.js` 生态，量化最全 | **可用（体积/量化最优）** |
| 2.4 | ragavsachdeva/Magi（含 magiv2/magiv3） | 漫画 VLM：角色/文本块/分镜检测 + 说话人归属 + OCR | [GitHub](https://github.com/ragavsachdeva/magi) / [magi](https://huggingface.co/ragavsachdeva/magi) / [magiv2](https://huggingface.co/ragavsachdeva/magiv2) / [magiv3](https://huggingface.co/ragavsachdeva/magiv3) | v1 `pytorch_model.bin` **1967.84 MB** + `model.safetensors` 1967.58 MB；v2 1968.09 MB；v3（Florence-2 底座）`model.safetensors` **1588.31 MB** | 英语为主（训练语料），OCR 能力随 VLM | **未声明 license**（GitHub API `license: null`） | v3 更新至 **2026-07-21** | ❌ **无 ONNX**，`trust_remote_code=True` **必须自定义 Python 代码** | ❌ 不适合本地 ONNX 桌面端 | **无效（对本 App 不可用）** |
| 2.5 | PP-OCRv5_mobile_rec_onnx | 通用识别 | [HF](https://huggingface.co/PaddlePaddle/PP-OCRv5_mobile_rec_onnx) | 实测 **16,534,782 B = 15.77 MB** | 中/英（v5 通用词典含 86 平假名 + 94 片假名 + 15565 汉字） | Apache-2.0 | 2026-06-10 | ✅ 官方 | ✅ 实测输出 **(1,1,18385)** | **可用** |
| 2.6 | PP-OCRv5_server_rec_onnx | server 级识别 | [HF](https://huggingface.co/PaddlePaddle/PP-OCRv5_server_rec_onnx) | 实测 **84,503,027 B = 80.59 MB** | 同上 | Apache-2.0 | 2026-06-10 | ✅ 官方 | ✅ 实测输出 **(1,1,18385)** | **可用** |
| 2.7 | 日/韩/拉丁 **专用** v5 识别 | 语言专用 | [latin](https://huggingface.co/PaddlePaddle/latin_PP-OCRv5_mobile_rec) | latin **7.60 MB**；korean **12.72 MB**；**v5 无日语专用** | latin / korean | Apache-2.0 | 2025-10-16 / 2026-07-22 | latin/korean 有官方 ONNX | ✅ | **latin/korean 可用；日语专用仅 v3（见下）** |
| 2.8 | japan_PP-OCRv3_mobile_rec | 日语专用识别（**唯一日语专用项**） | [HF](https://huggingface.co/PaddlePaddle/japan_PP-OCRv3_mobile_rec) | `inference.pdiparams` **9.57 MB** | 日语 | Apache-2.0 | 2025-07-22 | ❌ **无 ONNX**（官方仓库中 japan 系列只到 v3 且无 onnx 页） | 需自转 | **待验证（无官方 ONNX，精度远不如 manga-ocr）** |

### 关于「高精度中文/拉丁识别这类大模型变体」——**真实存在**

- **PP-OCRv5_server_rec_onnx**：80.59 MB，实测输出 18385 类（[链接](https://huggingface.co/PaddlePaddle/PP-OCRv5_server_rec_onnx)）。
  **重要发现**：它和 mobile 版的**类别数完全相同（18385）**，说明「server 级」提升的是**骨干网络精度与容量，而不是词表**。
- **PP-OCRv6_medium_rec_onnx**：73.01 MB，实测输出 **18710** 类（[链接](https://huggingface.co/PaddlePaddle/PP-OCRv6_medium_rec_onnx)）。
- **PP-OCRv6_small_rec_onnx**：实测 21,159,378 B = **20.18 MB**，同样是 18710 类。

### 日语竖排实测结果（自证，非引用）

我们把 `l0wgear/manga-ocr-2025-onnx` 的 encoder+decoder **不借助 transformers/optimum**、手写 greedy 解码跑通真实漫画页：

```
onnx/manga_ocr_l0wgear_encoder.onnx   in : pixel_values float32 [batch,3,224,224]  out: last_hidden_state [batch,197,192]
onnx/manga_ocr_l0wgear_decoder.onnx   in : input_ids int64 [batch,seq] + encoder_hidden_states float32 [batch,197,192]
                                     out: logits [batch,seq,6144]
vocab.txt = 6144 行  →  类别数 6144 = 词表行数   ✅ 完全相等
实测输出（UTF-8 字节核验）：topleft = 正体がバレると思っている。今回は800万人が大 / topright = 納得できません
```

> **踩坑提示**：在 Windows Git Bash / CP936 终端里直接 `print()` 日文会显示成 mojibake（`���夬�Х���...`）。
> 这是**终端编码问题，不是模型坏**——写入 UTF-8 文件后读出即为正确日文。做 App 时务必用 UTF-8 落盘再传 GUI。

---

## 3. 漫画/语音气泡（speech balloon）检测与分割

### 3.1 直接可用的 ONNX 气泡模型（全部实测过图结构）

| # | 模型名 | 用途 | 来源链接 | 体积（精确） | 语言覆盖 | 许可证 | 最近维护 | 有 ONNX？ | 实测输入/输出 | 结论 |
|---|---|---|---|---|---|---|---|---|---|---|
| 3.1.1 | **ogkalu/comic-text-and-bubble-detector**（`detector-v4-s_int8.onnx`） | **气泡 + 文本一次前向**（RT-DETR-v2 r50vd） | [HF](https://huggingface.co/ogkalu/comic-text-and-bubble-detector) | **11,120,765 B = 10.61 MB** | 漫画/网漫/国漫/西漫（约 11k 图训练） | **Apache-2.0** | 2026-05-15（下载 77,394 / 赞 50） | ✅ | in `images` float32 **[N,3,640,640]（固定）** + `orig_target_sizes` int64 [N,2]；out `labels`[1,300] `boxes`[1,300,4] `scores`[1,300] | **✅ 强烈推荐** |
| 3.1.2 | 同仓库 `detector_int8.onnx` | 同上（较大版） | 同上 | **43,838,857 B = 41.81 MB** | 同上 | Apache-2.0 | 2026-05-15 | ✅ | 同上 | **可用** |
| 3.1.3 | 同仓库 `detector.onnx` | 同上（fp32） | 同上 | **168,481,531 B = 160.68 MB** | 同上 | Apache-2.0 | 2026-05-15 | ✅ | 同上 | **可用（精度上限）** |
| 3.1.4 | kitsumed/yolov8m_seg-speech-bubble | 气泡**分割**（带掩膜） | [HF](https://huggingface.co/kitsumed/yolov8m_seg-speech-bubble) | `model_dynamic.onnx` **103.93 MB** + `model.pt` 52.27 MB | en/ja | **GPL-3.0** | 2026-09-02 | ✅ 动态形状 | in `images` 动态 [batch,3,H,W] → out `output0` [batch,300,6] | **可用但 GPL-3.0（商用有传染风险）** |
| 3.1.5 | ogkalu/comic-speech-bubble-detector-yolov8m | 气泡检测（纯 PT） | [HF](https://huggingface.co/ogkalu/comic-speech-bubble-detector-yolov8m) | `comic-speech-bubble-detector.pt` **49.67 MB** | 漫画 | Apache-2.0 | 2024-01-31 | ❌ 仅 .pt | 需自转 ONNX | **可用（需自转）** |
| 3.1.6 | mnemic/comic_speechbubble_yolov8 | 气泡检测 | [HF](https://huggingface.co/mnemic/comic_speechbubble_yolov8) | m 版 **49.63 MB** / s 版 **21.48 MB** | 漫画 | **未声明 license** | 2024-02-15 | ❌ 仅 .pt | — | **待验证（无 license，法务风险）** |
| 3.1.7 | mayocream/speech-bubble-segmentation | 气泡分割 | [HF](https://huggingface.co/mayocream/speech-bubble-segmentation) | 见页面（yolov8-seg 微调） | 漫画 | 见页面 | 2026-07-12 | 部分 | — | **可用（次选）** |
| 3.1.8 | huyvux3005/manga109-segmentation-bubble | 气泡分割（YOLO11） | [HF](https://huggingface.co/huyvux3005/manga109-segmentation-bubble) | 见页面 | en/ja | 见页面 | 2025-12-29 | 部分 | — | **可用（次选）** |

### 3.2 关键质疑解答：**「一个 9.5MB 的漫画气泡检测专用模型是否可信/常见？」→ 可信，且非常常见**

我们从两个方向实证：

**(A) 同类模型实测尺寸分布（我们自己下载并跑 ONNX 探针取得）**

| 模型（实测文件） | 精确体积 | 实测输出 | 许可证 |
|---|---|---|---|
| `kiuyha/Manga-Bubble-YOLO` yolo26n | **5.79 MiB** | in 动态 [batch,3,H,W] → out [batch,300,6]（**端到端，无需 NMS**） | Apache-2.0 |
| `remidesbois/onepiece_detector_nano` | **9.44 MiB** | in [1,3,800,800] → out [1,300,6] | 见页面 |
| `vermilion10/manga-bubble-yolo-finetune` | **9.83 MiB** | in [1,3,1280,1280] → out [1,300,6] | 见页面 |
| `the1just/MangaExpertYOLO` | **10.22 MiB** | in [1,3,800,800] → out [1,21,13125] | 见页面 |
| **ogkalu `detector-v4-s_int8`** | **10.61 MiB** | in [N,3,640,640] → out labels/boxes/scores | Apache-2.0 |
| `mednasserallah/manga109-onnx` | **11.30 MiB** | in [1,3,1024,1024] → out [1,37,21504] + mask [1,32,256,256] | 见页面 |
| `neuroncstate/manga109-onnx` | **11.93 MiB** | in [1,3,1600,1600] → out [1,37,52500] + mask [1,32,400,400] | 见页面 |

**(B) 参数量的算术解释（决定性的「9.5」）**

`kiuyha/Manga-Bubble-YOLO` 的模型卡给出了精确参数量与精度表：

| 变体 | 参数量 | mAP@50 | mAP@50-95 | 显存/速度(T4) |
|---|---|---|---|---|
| YOLO26**n** | **2.4M** | 0.947 | 0.765 | ~11.0 ms |
| YOLO26**s** | **9.5M** | **0.961** | 0.802 | ~27.5 ms |

> **所以「9.5」这个数字在漫画气泡检测领域是有明确出处的**：它正好等于 **YOLO26-small 的 9.5M 参数量**，
> 也正好落在我们实测的 5.79–11.93 MiB 气泡模型区间中位数附近。
> 判定：若某清单里的「漫画气泡检测（专用）」模型体积约 9.5MB ——
> **(i) 作为 nano YOLO 检测模型：可信（略偏大，但 nano 带多类头可达）；(ii) 作为 nano/small YOLO 分割模型：可信（最贴合）；(iii) 作为 RT-DETR：偏小但可信（我们实测 RT-DETR-v2 的 int8 小变体就是 10.61MB）；(iv) 「完全不可能」：错误判断。**
> 唯一需要警惕的是**许可证与来源**：GPL-3.0 或未声明 license 的 9.5MB 模型，比体积本身风险大得多。

### 3.4 ⛔ 许可证终极陷阱：**Ultralytics 系 YOLO 的 AGPL-3.0 藏在文件元数据里**（我们逐个实测）

**这是本次调研最重要的法务发现，直接推翻了一批「看起来 Apache-2.0/MIT」的候选。**

我们用 `onnxruntime` 读取每个 ONNX 的 `get_modelmeta().custom_metadata_map`，实测结果：

| ONNX 文件 | 精确体积 | **仓库标签 license** | **文件内部元数据 license** | `author` | 判定 |
|---|---|---|---|---|---|
| `kiuyha/…yolo26n.onnx` | 6,069,760 B | apache-2.0 | **`AGPL-3.0 License (https://ultralytics.com/license)`** | Ultralytics | ❌ 排除 |
| `remidesbois/…nano.onnx` | 9,898,957 B | **mit** | **AGPL-3.0** | Ultralytics | ❌ 排除 |
| `the1just/…best.onnx` | 10,711,922 B | apache-2.0 | **AGPL-3.0** | Ultralytics | ❌ 排除 |
| `mednasserallah/…1024.onnx` | 11,845,329 B | apache-2.0 | **AGPL-3.0** | Ultralytics | ❌ 排除 |
| `neuroncstate/…best.onnx` | 12,509,314 B | apache-2.0 | **AGPL-3.0** | Ultralytics | ❌ 排除 |
| `vermilion10/…weights.onnx` | 10,309,100 B | （未声明） | **AGPL-3.0** | Ultralytics | ❌ 排除 |
| **`ogkalu/detector-v4-s_int8.onnx`** | **11,120,765 B** | apache-2.0 | **无 license 字段**（仅 `onnx.infer = onnxruntime.quant`） | — | ✅ **清白的唯一选择** |

> 元数据原文长这样（实测打印）：
> ```
> license = AGPL-3.0 License (https://ultralytics.com/license)
> author  = Ultralytics
> version = 8.4.118 / 8.4.138 / 8.3.235 ...
> ```
> **Ultralytics 要求：任何专有/闭源、SaaS、商业产品或内部业务工具都需要购买 Enterprise License**
> （见 <https://www.ultralytics.com/license>）。
>
> **可操作结论**：
> 1. **只检查 HF 仓库页的 license 标签是不够的** —— 必须**在文件内部**校验（`get_modelmeta()` 或 `onnx.load(...).metadata_props`）。
> 2. 闭源商用 App **唯一干净的气泡检测器**是 **ogkalu 的 RT-DETR-v2 系列**（ONNX 内无 AGPL 字符串，上游 RT-DETR 为 Apache-2.0）。
> 3. 若确实要用 YOLO11n-seg 做掩膜，**必须先购买 Ultralytics Enterprise License**。
> 4. `mnemic` / `TheBlindMaster` 系**未声明 license = 保留所有权利**，同样不可用。
> 5. 镜像仓库（`NorwayFish`/`Zaidppo`/`Kingkong2354`/`Sundowner123`/`comicbox`）与 ogkalu 逐字节相同 → **镜像的 license 随上游，不随镜像页**。

### 3.5 「9.5 MB 是否可信」的完整算术（第一性换算率，可复算）

我们（与验证子代理各自独立）测出三条**换算率**，这是回答质疑的关键工具：

| 换算率 | 实测依据 | 数值 |
|---|---|---|
| Ultralytics `.pt` 是 **FP16** | `deepghs/manga109_yolo` 的 YOLO11n（2.59M 参数）→ `model.pt` 5,500,911 B | **2.12 B/参数** |
| Ultralytics ONNX 导出默认 **FP32** | 同模型 → `model.onnx` 10,483,947 B（元数据 `args.half=False`） | **4.05 B/参数** |
| **ONNX(fp32) ≈ 1.906 × .pt(fp16)** | 上述同一对文件 | 1.906 |
| **INT8 ≈ 0.260 × FP32** | ogkalu 主模型 168,481,531 B → 43,838,857 B | **0.2602** |

对「9.5 MiB = 9,961,472 B」逐假设判定：

| 假设 | 算式 | 判定 |
|---|---|---|
| **(i) FP32 nano YOLO 检测 ONNX** | 9,961,472 ÷ 4.05 ≈ **2.46M 参数** = YOLO26n/YOLO11n 量级；且实测 5 个真实文件落在 9.44/9.83/10.00/10.22/10.61 MiB | ✅ **完全合理、且是众数尺寸** |
| **(ii) nano YOLO 分割 ONNX（FP32）** | FP32 yolo11n-seg（2.87M）实测 11.30 / 11.93 MiB → 9.5MB 需 ~2.46M 参数（低 ~14%） | ⚠️ 勉强可能 |
| **(ii-b) 同上但 INT8** | 2.87M × ~1.05 ≈ **3.0 MiB** → 9.5MB 差了 **~3.2×** | ❌ **不可能 —— 「yolov8n-seg 的 INT8 约 9.5MB」这一前提是错的** |
| **(iii) RT-DETR FP32** | RT-DETRv2-R50 = **160.68 MiB** | ❌ 不可能 |
| **(iii-b) RT-DETR INT8 小变体** | 实测 ogkalu `detector-v4-s_int8.onnx` = **10.61 MiB** | ✅ 可能 |
| **(iv) 其他** | INT8 nano ≈2.6 MiB；FP16 nano ONNX ≈5.8–6.6 MiB；FP32 small ≈36–43 MiB（yolo11s ONNX 实测 36.06 MiB） | ❌ 均排除 |

> **附带巧合**：**小模型的 INT8 也恰好落在 ~9.4MB**（yolo11s 36.06 MiB × 0.260 ≈ 9.38 MiB；YOLO26s 标注参数量正好 **9.5M**）。
> **结论（可直接用来回应质疑）**：9.5 MB 的资产声明**站得住**，但**必须同时标注格式与变体** ——
> 它要么是 **nano 级 FP32 ONNX**，要么是 **small 级 INT8**；**不能**说成「nano 的 INT8」。
> 行业实测气泡 ONNX 尺寸带 = **9.4–12.5 MiB**，且已有落地桌面翻译 App 使用 **10.91 MiB** 气泡分割 ONNX（MattyMroz/MangaShift，该文件实测 401 gated）。

### 3.6 「传统 CV vs 深度学习」——**公开评测确实存在**（修正 §3.3 的早期结论）

早期我们写「无公开来源」。经子代理检索，**公开头对头评测是存在的**，此处补上并给出精确数字：

**(1) Dubray & Laubrock 2019，Table II**（eBDtheque v2 像素级 GT）— <https://arxiv.org/abs/1902.08137>

| 方法 | 类型 | R | P | **F1** |
|---|---|---|---|---|
| Arai & Tolle | 传统 | 18.70 | 23.14 | **20.69** |
| Ho et al. | 传统 | 14.78 | 32.37 | **20.30** |
| Rigaud et al.（活动轮廓） | 传统 | 69.81 | 32.83 | **44.66** |
| Rigaud et al.（二值化+连通域） | 传统 | 62.92 | 62.27 | **63.59** |
| Nguyen Mask R-CNN | 深度 | 75.31 | 92.42 | **82.99** |
| Dubray U-Net+VGG16（域内） | 深度 | 94.04 | 95.58 | **94.48** |

> 同论文关键警告：他们的 CNN 在 **Manga109 上「fails miserably」（跨域失败）**。

**(2) MangaSeg，CVPR 2025，Table 2**（Manga109，927 页测试集，Balloon 列）— <https://openaccess.thecvf.com/content/CVPR2025/papers/Xie_Advancing_Manga_Analysis_Comprehensive_Segmentation_Annotations_for_the_Manga109_Dataset_CVPR_2025_paper.pdf>

| 方法 | BAP↑ | MAP↑ | BdAP↑ |
|---|---|---|---|
| Liu et al.（**手工特征**） | 0.683 | **0.688** | 0.686 |
| GroundedSAM（**零样本**深度） | 0.158 | **0.171** | 0.161 |
| 微调 LoRA-SAM | 0.914 | **0.956** | **0.954** |

> **决定性 nuance**：**深度学习只有在「域内微调」时才赢**。零样本基础模型（GroundedSAM 0.171 MAP）**惨败给手工启发式（0.688 MAP）**。
> 这对本 App 的含义：**不要用零样本通用检测器去做漫画气泡**；要么用漫画域内训练的模型（ogkalu 用约 11k 漫画/网漫/国漫图微调，正是这个道理），要么别指望 DL 自动生效。

**(3)** 仍标注为**待验证**的项：Nguyen/Rigaud/Burie, *J. Imaging* 4(7):89（传统 vs DL 对比，正文返回 HTTP 403 → **无公开来源，待验证**，<https://www.mdpi.com/2313-433X/4/7/89>）。
**(4)** **现代 YOLOv8/11/26 气泡检测器 vs 传统 CV 在同一漫画测试集上的公开头对头评测：无公开来源，待验证。**

### 3.7 补充工程坑（气泡链路实测）

1. **`detector-v4-s_int8.onnx` 的 batch 是假动态**：元数据声明符号 batch `N`，但 **N>1 直接崩**（`Reshape 2,256,20,20 → 1,256,400`）；而 ogkalu 主模型 fp32/int8 都能跑 N=2。→ **v4-s 必须硬编码 batch=1**。
2. **INT8 在 CPU 上不一定更快**：同一机器实测 ogkalu 主模型 **INT8 1114 ms vs FP32 883 ms（INT8 慢 26%）**，各跑 5 次取中位。→ **不要默认「量化=更快」，要实测。**
3. **体积 ≠ 能力**：同一张真实漫画页上，**9.44 MiB 的模型 0 个检测（最高分 0.014）**，而 **10.61 MiB 的模型 17 个检测**。→ 选型必须实跑，不能只看体积。
4. **「bubble」一词有歧义**：存在**流体微气泡成像**领域的同名模型（如 `callumtilbury/bubble-student-v1`，与漫画无关）。→ **必须看 ONNX 的 `names` 元数据**（`{0:'bubble'}` / `{0:'speech bubble'}`），不要只看仓库名。
5. **`huyvux3005` 的 mAP50 99.1% 是自报**（自家 epoch-44 验证集）→ 无第三方评测，**待验证**。
6. **RT-DETR 必须喂两个输入**（`images` + `orig_target_sizes` int64[N,2]），漏了就是最常见 bug。

### 3.3 `bubble.py` 与「传统 CV 方案」的真实能力边界（源码级）

> 说明：本节最初写于「未找到公开评测」阶段；**公开头对头评测确实存在，已在 §3.6 补全精确数字**。
> 本节保留的是对 M-I-T 传统方案本身的分析，仍然有效且是选型的直接依据。

**结论（已被 §3.6 更新）**：**公开的「传统 CV vs 深度学习」头对头评测确实存在**（Dubray&Laubrock 2019 的 F1 对比、MangaSeg CVPR 2025 的 BAP/MAP/BdAP 对比），精确数字见 §3.6。
**仍然成立、且必须标注「无公开来源，待验证」的那一条是**：**现代 YOLOv8/11/26 气泡检测器 与 传统 CV 在「同一漫画测试集」上的公开头对头评测 —— 未找到**。

但我们找到了**更有力的替代证据：上游主流项目自己的源码注释承认传统启发式方案的根本缺陷**。
`manga-image-translator` 的 `manga_translator/utils/bubble.py` **全文仅 85 行**，其做法是：

```python
_, binary_raw_mask = cv2.threshold(region_img, 127, 255, cv2.THRESH_BINARY)
# 只取文本框四边各 2 像素宽的边缘，统计黑像素比例
val0 += sum(binary_raw_mask[0:2, 0:width].ravel() == 0)          # 上边 2px
val0 += sum(binary_raw_mask[height-2:height, 0:width].ravel() == 0)  # 下边 2px
val0 += sum(binary_raw_mask[2:height-2, 0:2].ravel() == 0)       # 左边 2px
val0 += sum(binary_raw_mask[2:height-2, width-2:width].ravel() == 0) # 右边 2px
ratio = round(val0 / total, 6) * 100
if ratio >= ignore_bubble and ratio <= (100 - ignore_bubble):
    return True   # 跳过不翻译
```

源码注释里**项目建设者亲自列出了该方案的 4 条失效模式**（原文）：

1. **纯色背景误判**：「该方法不检测气泡边界或轮廓；它只检查局部背景颜色。」
2. **无法识别气泡边界**：「代码不涉及任何形状或轮廓检测。无法判断文本框周围是否存在闭合的、颜色相对均匀的线条。」
3. **对气泡尺寸与相对位置不敏感**：「只检查紧邻的 2 像素区域，不考虑气泡的整体尺寸、形状或文本框在气泡内的相对位置。」
4. **连体气泡无法处理**：「完全基于单个文本框的局部环境，无法检测跨多个文本框的共享气泡结构。」

> **对 App 的结论**：`ignore_bubble` 这类 **Canny/阈值+边缘比例启发式是「是否翻译」的过滤器，不是气泡检测器**。
> 要做真正的气泡定位与掩膜，**必须用深度学习**（ogkalu RT-DETR 或 YOLO 系）。
> 若产品需求是「只翻气泡内文字、跳过背景拟声词」，可以用 `bubble.py` 这种廉价启发式做二次过滤；
> 若需求是「气泡边框重绘/擦字」，则非 DL 不可。

---

## 4. 韩语 OCR：「类别数必须匹配 dict.txt 行数」规则的实测验证

### 4.1 规则的确切内容（源码级）

`PaddleOCR/ppocr/postprocess/rec_postprocess.py` 中：

```python
# CTCLabelDecode
def add_special_char(self, dict_character):
    dict_character = ["blank"] + dict_character   # 行 230-232：词表最前面插一个 blank
    return dict_character
```

`CharacterOps.__init__`（行 26-51）：逐行读取 `character_dict_path` → 若 `use_space_char` 则 `append(" ")` → `add_special_char` 加 blank → 建 `self.dict` 索引。

**因此规则是：模型 CTC 头的类别数 = `dict.txt 行数 + 1 (blank) + 1 (space)`。**

### 4.2 实测验证（本次调研最硬的证据）

我们下载真实 ONNX 模型并**实际推理**，读取输出的最后一维：

| 模型 | ONNX 文件 | 实测输出类别数 | 对应 dict 行数 | 公式核对 | 结论 |
|---|---|---|---|---|---|
| PaddlePaddle/korean_PP-OCRv5_mobile_rec_onnx | 13,418,787 B = 12.80 MB | **(1, 40, 11947)** | `ppocrv5_korean_dict.txt` = **11945** 行 | 11945 + 1 + 1 = **11947** ✅ | **精确吻合** |
| PaddlePaddle/PP-OCRv5_mobile_rec_onnx | 16,534,782 B = 15.77 MB | (1, 1, **18385**) | `ppocrv5_dict.txt` = **18383** 行 | 18383 + 2 = **18385** ✅ | **精确吻合** |
| PaddlePaddle/PP-OCRv5_server_rec_onnx | 84,503,027 B = 80.59 MB | (1, 1, **18385**) | 同上 18383 行 | 18385 ✅ | **精确吻合（与 mobile 同词表）** |
| PaddlePaddle/PP-OCRv6_small_rec_onnx | 21,159,378 B = 20.18 MB | (1, 1, **18710**) | `ppocrv6_dict.txt` = **18708** 行 | 18708 + 2 = **18710** ✅ | **精确吻合** |
| PaddlePaddle/PP-OCRv6_medium_rec_onnx | 76,554,979 B = 73.01 MB | (1, 1, **18710**) | 同上 18708 行 | 18710 ✅ | **精确吻合** |
| PaddlePaddle/PP-OCRv6_tiny_rec_onnx | 4,462,639 B = 4.26 MB | (1, 1, **6906**) | `ppocrv6_tiny_dict.txt` = **6904** 行 | 6904 + 2 = **6906** ✅ | **精确吻合** |

> **重要补充**：`ppocrv5_korean_dict.txt` 的文件**总行数是 11946，但最后一行是空行**，
> 所以内容行数是 **11945**（`nonEmpty=11945, lastEmpty=true`）。
> **这正是「行数」类 bug 的经典来源**：用 `wc -l`（得 11946）而不是「非空行数」（11945）去校验，会差 1 而误判为不匹配。
> 务必用「非空行数」或「去掉 BOM/空行后的条目数」来比对。

### 4.3 成对可用的韩语识别模型 + 词典（真实来源）

| 项目 | 精确来源 | 体积 | 说明 |
|---|---|---|---|
| **韩语模型（ONNX）** | [PaddlePaddle/korean_PP-OCRv5_mobile_rec_onnx](https://huggingface.co/PaddlePaddle/korean_PP-OCRv5_mobile_rec_onnx) → `inference.onnx` | **12.80 MB** | 官方 ONNX，实测 11947 类 |
| **配套词典（两处等价）** | ① **同模型仓库内 `inference.yml` 的 `character_dict` 内联 11945 条**（96,039 B，推荐：与权重同源，天然配对）<br>② [PaddleOCR 源码 `ppocr/utils/dict/ppocrv5_korean_dict.txt`](https://github.com/PaddlePaddle/PaddleOCR/blob/main/ppocr/utils/dict/ppocrv5_korean_dict.txt)（47,451 B，11945 非空行） | 0.09 MB / 47 KB | **两者实测条目数完全相等：yml=11945，dict=11945** ✅ |
| 训练配置（证明配对关系） | [korean_PP-OCRv5_mobile_rec.yml](https://github.com/PaddlePaddle/PaddleOCR/blob/main/configs/rec/PP-OCRv5/multi_language/korean_PP-OCRv5_mobile_rec.yml) | — | 内含 `character_dict_path: ./ppocr/utils/dict/ppocrv5_korean_dict.txt`、`use_space_char: true`、`algorithm: SVTR_LCNet` + `MultiHead(CTCHead+NRTRHead)` |
| 韩语词表内容 | `ppocrv5_korean_dict.txt` | 11945 条 | 由**韩文字母(Jamo) + 谚文音节 + 拉丁 + 符号**构成；**实测 0 个平假名/片假名/汉字**（所以**不能拿韩语模型去跑日文漫画**） |
| 旧版韩语（备选） | [korean_PP-OCRv3_mobile_rec](https://huggingface.co/PaddlePaddle/korean_PP-OCRv3_mobile_rec) / `korean_dict.txt` | 模型 9.39 MB / 词典 14,480 B（3688 行） | v3 词表与 v5 词表**不同**，混用必然崩 |

> **落地建议**：直接读模型仓库里的 `inference.yml`，把 `character_dict` 列表当作唯一真源（single source of truth），
> 在 App 里加一条启动自检：`assert onnx_output_shape[-1] == len(character_dict) + 2`。这样模型/词典任何一方升级都会被立刻发现。

### 4.4 manga-ocr ONNX 的落地契约与「118 秒」陷阱（**独立验证子代理实测，含 DML 真机验证**）

**关键结论：kha-white 官方从未提供 ONNX 导出**（`api/models?author=kha-white` 仅 1 个模型；官方 README 无 onnx 字样；
[issue #45 "convert the pretrained model into onnx format?" 仍为 open](https://github.com/kha-white/manga-ocr/issues/45)）。
**HF 上 6 个 manga-ocr ONNX 全部是第三方导出**。上游 `manga-ocr-base` 仍是 2022-06-22 的版本，
「2025 refresh」**不是上游的**，而是第三方的 192 维蒸馏小模型。

| 版本 | 文件与精确体积 | license | 判定 |
|---|---|---|---|
| 上游 `kha-white/manga-ocr-base` | `pytorch_model.bin` **444,135,475 B = 423.56 MB**；`vocab.txt` **24,072 B**（md5 `18022f84055b9e54c82612e85bdb8633`） | apache-2.0 | 词表真源 |
| **`onnx-community/manga-ocr-base-ONNX`（首选）** | encoder fp32 343,377,067 B / **int8 86,967,767 B**；decoder fp32 117,445,718 B / **int8 29,627,936 B**；**合计 INT8 仅 111.2 MB** | **apache-2.0** | ✅ **推荐**（但**不带词表**，须自带上游 vocab.txt） |
| `l0wgear/manga-ocr-2025-onnx` | encoder 22,356,885 B + decoder 118,053,454 B | **未声明** | 可用但**精度明显更差**（192 维蒸馏）+ license 不明 |
| `NorwayFish/manga-ocr` | encoder 343,377,067 B + decoder 117,444,140 B | apache-2.0 | 可用（带 vocab + tokenizer） |
| `mayocream/manga-ocr-onnx` | encoder 343,454,249 B + decoder 117,480,262 B | apache-2.0 | 可用，但 **vocab.txt 是 CRLF**（30,216 = 24,072 + 6,144 个 `\r`）→ 按 `\n` 切分得到 `"[PAD]\r"`，**必须 trim** |
| `ms57rd/manga-ocr-base-ONNX` | encoder/decoder 同上 | **未声明** | ❌ **无效**：`tokenizer.json` 只有 2,723 B、`model.vocab` **仅 5 个 token**（正常 6,144），且无 vocab.txt |

**必须自实现的 4 件事（"把 ONNX 塞进去就能跑" 是错的）**：

| 环节 | 实测契约 |
|---|---|
| 预处理 | 上游是 `convert("L").convert("RGB")`（**先灰度再 RGB**）→ 224×224（**BICUBIC**）→ `/255` → **mean/std = 0.5**。⚠️ l0wgear 的 README 用 `TrOCRProcessor`，与上游实际用的 `ViTImageProcessor` **不一致，照抄有风险** |
| 自回归解码 | encoder `pixel_values` f32 [b,3,H,W] → `last_hidden_state` [b,197,D]；decoder `input_ids` **int64** + `encoder_hidden_states` f32 → `logits` [b,L,**6144**]。**decoder 只有 2 个输入 → 没有 KV cache**（连名为 `decoder_model_merged` 的版本也被剪掉了 KV 分支），每步重跑整段前缀，复杂度 ≈ **O(L²)** |
| **beam search（必需，不是优化项）** | 参数在 **config.json（Python 侧，不在图里）**：`num_beams=4, max_length=300, no_repeat_ngram_size=3, length_penalty=2.0, early_stopping=true, decoder_start_token_id=2, eos_token_id=3, pad_token_id=0`。**实测：greedy 会把样例 03 做错，beam4 才完全正确** |
| 后处理 | `''.join(text.split())`、`…`→`...`、`[・.]{2,}` 折叠、`jaconv.h2z`（半角→全角）—— 否则「第３０話」这类文本对不上 |

> 🚨 **最高危性能陷阱（实测）**：因为**无 KV cache**，`beam4` 若**漏掉 early stopping**，就会跑满 300 步 →
> **单图 118 秒**；补上提前终止后同一张图 **0.6–1.4 s**（**约 100× 差距**）。
> 这个 bug 不会报错，只会让 App「卡死」，务必在实现里写死 early stop。

> **量化实测**：`onnx-community` 的 **INT8 与 FP32 输出在 5 张样例上完全一致** → 直接用 INT8 对（111.2 MB）即可，
> 无需为了精度保留 FP32。另：encoder 单跑 fp32 0.255 s vs int8 0.455 s（**int8 单跑更慢**，但整体仍推荐 int8 省体积）。

> **opset 提示**：l0wgear = opset **16**；onnx-community / xingliao = opset **18**（`DynamicQuantizeLinear` 需 ≥11）→ **Flutter 端必须确认打包的 ORT 版本支持该 opset**。

**DirectML 真机实测（推翻我们「无法验证」的早期说法）**：
在独立 venv 安装 `onnxruntime-directml==1.24.4` 后，**manga-ocr 的 6 个 ONNX 图全部成功建 session 并在 RTX 3060 上完成推理**（device_id=0），
**但每图有 8–87 个节点回落 CPU**（int8 decoder 回落 87 个）。
→ **DirectML 对本清单是「可用」，不是「不可用」**；剩余风险是 ①**实际加速比需实测**（节点回落会吃掉收益）②**int8 在 DML 上的数值一致性待验证**（DML 上未做精度对比）。

---

## 5. 建议保留 / 建议删除 / 建议新增

### 5.1 建议保留（Keep）

| 模型 | 体积 | 保留理由 |
|---|---|---|
| **ogkalu/comic-text-and-bubble-detector `detector-v4-s_int8.onnx`** | **10.61 MB** | **闭源商用唯一清白的气泡检测器**：ONNX 内部元数据**无 AGPL 字符串**（实测），仓库标签 apache-2.0，上游 RT-DETR 亦为 Apache-2.0。一次性给出 `bubble / text_bubble / text_free` 三类，**检测+定位同一前向**，固定 640×640，端到端免 NMS。**实测**：真实漫画页 13–17 个目标、最高分 0.94、`text_bubble` 框正确嵌套在 `bubble` 框内；CPU 单张 0.33–0.76 s。⚠️ 必须 **batch=1**（见 §3.7）。 |
| **manga-ocr ONNX 对 —— 首选 `onnx-community/manga-ocr-base-ONNX` 的 INT8 版（encoder 86,967,767 B + decoder 29,627,936 B）** | **111.2 MB** | 日语竖排事实标准，**Apache-2.0 且 ONNX 实测可跑**。INT8 与 FP32 输出**完全一致**（实测），性价比最佳。⚠️ **该仓库不带词表**，须自带上游 `kha-white/manga-ocr-base` 的 `vocab.txt`（24,072 B，md5 `18022f84055b9e54c82612e85bdb8633`）。**不要**选 l0wgear（未声明 license）或 ms57rd（tokenizer 损坏、仅 5 token）。 |
| **PP-OCRv5_server_det** | 83.86 MB（ONNX 84.03 MB） | 官方明示支持**竖排/旋转/弯曲/手写**与日语，是通用页面的兜底检测器。 |
| **comictextdetector.pt.onnx** | 90.28 MB | 漫画专用检测+分割掩膜，是「擦字」链路的关键件（实测 1024² CPU 2.29–2.73 s）。**两个必须注意的点**：① 权重 **GPL-3.0**（镜像标 apache-2.0 是错的，见 §1.12）；② 其 `seg` 输出是**原始 logits、图内无 sigmoid**，必须自己激活，否则掩膜静默失效（见 §1.14）。 |

### 5.2 建议删除（Remove）

| 模型 | 删除理由 |
|---|---|
| **M-I-T `dbnet_convnext`**（高精度 DBNet-ConvNeXt） | `_MODEL_MAPPING` 中 `url` 为空字符串，**权重实际下不到**，为历史残留。 |
| **M-I-T `model_ocr_large.py`「大模型 OCR」** | **未被注册的死代码**（`OCRS` 中不存在 `ocr_large`），且无 `_MODEL_MAPPING`，无可下载权重。清单里若有「高精度 large OCR」项，应从 M-I-T 侧删除；如需高精度请改用 PaddleOCR 的 `*_server_rec_onnx`。 |
| **Magi / magiv2 / magiv3** | 体积 **1.6–2.0 GB**、**无 ONNX**、**未声明许可证**、必须 `trust_remote_code=True` 跑 Python。对「Flutter + 本地 ONNX + DirectML」的架构**完全不适用**，删除以免误导。 |
| **`japan_PP-OCRv3_mobile_rec`**（若在清单中） | **无官方 ONNX**，精度与竖排能力远不及 manga-ocr；日语识别应统一到 manga-ocr。 |
| **任何 `mnemic/comic_speechbubble_yolov8` 类未声明 license 的权重** | 法务不可控（未声明 = 保留所有权利），且已有 Apache-2.0 的等效替代（ogkalu）。 |
| **全部 Ultralytics 系 YOLO ONNX 导出**（kiuyha / remidesbois / the1just / mednasserallah / neuroncstate / vermilion10 / kitsumed） | **这些文件的内部元数据写着 `license = AGPL-3.0`（我们逐个实测），Ultralytics 要求闭源商用购买 Enterprise License。** 仓库页标 mit/apache-2.0 **一律不算数**（见 §3.4）。若清单里有它们且是闭源商用产品，**必须删除或改为已购授权**。 |
| **`lordtrilink/manga-text-detector-v0`**（若被推荐过） | 质量确实好（YOLO11s，ONNX fp32 36.42 MB / fp16 18.26 MB），但 license 为 **`cc-by-nc-sa-4.0` = 禁止商用** → 商业 App 必须排除。 |
| **`callumtilbury/bubble-student-v1`**（若出现在清单中） | **不是漫画模型**：属流体微气泡成像领域；且其 `best_model.pt` 4,795,991 B 的许可未明。属于「按名字误选」的典型。 |

### 5.3 建议新增（Add）

| 建议新增 | 体积 | 新增理由 |
|---|---|---|
| **PaddlePaddle/korean_PP-OCRv5_mobile_rec_onnx + 内联 `inference.yml` 词典** | 12.80 MB + 96 KB | **成对可用、官方 Apache-2.0、我们实测 11947 = 11945+2 精确吻合**。是韩语漫画/webtoon 的正确选择；**不要用 `korean_dict.txt`（3688 行）去配 v5 模型**。 |
| **PP-OCRv5_mobile_det_onnx** | 4.60 MB | 官方基准 **Hmean 79.0 / CPU 57.77 ms**，是桌面端的「默认检测档」；实测 640×640 → (1,1,640,640)，最省心。 |
| **PP-OCRv6_tiny_det_onnx** | **1.9 MB**（0.43M 参数） | 官方基准 Hmean 80.6*，**体积仅 1.9 MB**，适合「极致瘦身/低配机」档位。 |
| **PP-OCRv6_small_det_onnx** | 9.42 MB | 官方基准 Hmean 84.1*（注意与 v5 评估集不同、不可直接比），移动端定位，做 v5_mobile 的替代候选。 |
| **PP-OCRv6_small_rec_onnx / PP-OCRv6_medium_rec_onnx** | 20.18 MB / 73.01 MB | 新一代（18710 类 > v5 的 18385 类），可作为中文/通用精度档位，与 v5 并存做 A/B。 |
| **kiuyha/Manga-Bubble-YOLO（yolo26n ONNX）** | 5.79 MB | ~~Apache-2.0、端到端无 NMS~~ ❌ **已撤回推荐**：其 ONNX 文件**内部元数据写着 `license = AGPL-3.0 License (https://ultralytics.com/license)`**（我们实测读 `get_modelmeta()` 确认，见 §3.4）。仓库标签写 apache-2.0 **不代表可用**。 |
| **onnx-community/manga-ocr-base-ONNX 的 int8/q4 量化版** | ~111 MB / 更小 | 若包体积吃紧，量化版能把日语 OCR 压到 ~111MB 且保留 Apache-2.0。 |

> **不要新增 v4 系检测/识别模型**：官方基准显示 v4_mobile_det 与 v5_mobile_det **同为 4.7 MB 但 Hmean 63.8 vs 79.0**，
> v4_server_det 更是 **109 MB / Hmean 69.2 / CPU 585.95 ms** 且无官方 ONNX —— 属于被全面取代的一代。

---

## 6. 跨类别的工程「已知坑」（按优先级）

1. **DirectML 是最大的平台风险，不是模型问题。**
   - 官方文档：DirectML EP **只支持到 ONNX opset 20**，且 **Gridsample 20: 5d 与 DeformConv 不支持**；DirectML 版本为 1.15.2。来源：[DirectML Execution Provider](https://onnxruntime.ai/docs/execution-providers/DirectML-ExecutionProvider.html)
   - DirectML **不支持 memory pattern 优化与并行执行**，必须在 session options 中关闭，否则报错（同链接）。
   - 微软已把 **DirectML 标为 sustained engineering（维护模式）**，推荐迁移到 **WinML / WebGPU EP**。来源：[Windows 上 ONNX Runtime](https://onnxruntime.ai/docs/get-started/with-windows.html)、[Windows ML execution providers](https://learn.microsoft.com/en-us/windows/ai/new-windows-ml/supported-execution-providers)
   - **版本错位**：`onnxruntime-directml` 最新为 **1.24.4**（2026-03-17 发布，win_amd64 wheel 约 23.95 MB，requires_python >=3.11），而基础 `onnxruntime` 已到 **1.28.0**。→ **App 不能假设两个 EP 同名同版本**，必须分别锁版本。
   - **我们的实测环境**（默认 venv）里 `ort.get_available_providers()` 只有 `['AzureExecutionProvider','CPUExecutionProvider']` —— **DirectML 不会随基础包出现，必须单独安装/打包**。
   - ✅ **DirectML 已在本机 RTX 3060 上实测跑通**（验证子代理建独立 venv 安装 `onnxruntime-directml==1.24.4`）：
     manga-ocr 的 **6 个 ONNX 图全部成功建 session 并完成推理**（device_id=0），**但每图有 8–87 个节点回落 CPU**。
     → 结论修正：**DirectML 路径是"可用"而非"不可用"**；风险从"能否跑"转为"**性能收益需实测**（节点回落会吃掉部分加速）
     以及"**INT8 图在 DML 上的数值一致性待验证**"（int8 图含 `MatMulInteger/DynamicQuantizeLinear/ConvInteger/DequantizeLinear`，
     decoder 有 87 节点回落；DML 上未做精度对比）。
   - **交付要求**：即便如此仍**必须保留 CPU 回退路径**（DirectML 官方已进入维护模式，且驱动差异大）。
2. **Flutter 侧的绑定较旧**：`pub.dev` 上 `onnxruntime`（Flutter 插件）最新 **1.4.1，发布于 2024-03-27**（[链接](https://pub.dev/packages/onnxruntime)）。它能否透出 DirectML EP 需自行验证（**待验证**）。替代思路：用 `sherpa_onnx` 系或直接 FFI 调 ORT C API。
3. **固定尺寸 vs 动态尺寸**：`comictextdetector.onnx` 是**固定 1024×1024**；ogkalu 是**固定 640×640**；kitsumed 是动态。漫画页长宽比差异大 → 固定尺寸必须做 letterbox + 坐标反变换，否则框会错位。
4. **输入 dtype 有坑**：RT-DETR 的 `orig_target_sizes` 必须是 **int64**（我们第一次传 float32 直接 `InvalidArgument`）；manga-ocr 的导出里 `input_ids` 是 **int64**——不同导出差异大，**必须按实测 schema 喂**。
5. **ONNX 导出可能没有内嵌 shape**：PaddleOCR 的 `inference.onnx` 中 I/O 维度显示为 `DynamicDimension.x`，`onnx.shape_inference` 拿不到真实类别数。**唯一可靠办法是跑一次真实推理读输出最后一维**（我们就是这么确认 11947 的）。
6. **词典配对要做启动自检**：见 §4.2 的空行陷阱（11946 vs 11945）。建议写成断言。
7. **许可证传染**：dmMaze/comic-text-detector 与 manga-image-translator 均为 **GPL-3.0**；kitsumed 气泡分割为 **GPL-3.0**。若 App 闭源商用，**GPL-3.0 权重不可打包**（应走 Apache-2.0 的 ogkalu / PaddleOCR / manga-ocr 链路）。
8. **OCR 幻觉**：manga-ocr 官方 README 明确警告「模型总会试图识别出一些文字，即使图上没有」，因为它是带日语语言理解的 transformer decoder，可能「脑补」出通顺句子。→ 必须加空行/低置信度过滤。

---

## 7. 证据清单（本次调研产出的可复核文件）

| 文件 | 内容 |
|---|---|
| `E:\Gemini\_research\onnx\` | 全部实测模型权重（comictextdetector.onnx、ogkalu 三个变体、manga-ocr encoder/decoder、PP-OCRv5 v4-v6 系列 ONNX 等，约 1 GB） |
| `E:\Gemini\_research\probe_all.py` / `probe_det.py` / `probe_rtdetr.py` | ONNX 形状与类别数探针脚本 |
| `E:\Gemini\_research\bench_ogkalu.py` | ogkalu 三个变体的精度/耗时对比（fp32 vs int8 vs v4-s_int8） |
| `E:\Gemini\_research\run_mangaocr2.py` + `mangaocr_out.txt` | 不依赖 transformers/optimum 的 manga-ocr ONNX 实跑与日文输出 |
| `E:\Gemini\_research\mit\*.py` | M-I-T 检测/OCR/bubble 源码留档（含 `paddle_rust.py`、`bubble.py`） |
| `E:\Gemini\_research\onnx\alphabet-all-v7.txt` | M-I-T 词典（实测 46272 条） |
| `E:\Gemini\_research\ppocr_det_doc_v3.md` | PaddleOCR 官方《文本检测模块使用教程》存档（936 行，含 Hmean 与 CPU/GPU 耗时基准表；来源 <https://github.com/PaddlePaddle/PaddleOCR/blob/main/docs/version3.x/module_usage/text_detection.md>） |

---

## 8. 明确标注「无公开来源，待验证」的项目

- 漫画气泡检测任务上**传统 CV 与深度学习方案的公开量化对比评测（含 mAP/F1 表）**：**无公开来源，待验证**。我们仅找到上游项目源码注释形式的自我批评（§3.3）。
- `l0wgear/manga-ocr-2025-onnx` 的**许可证**：该 HF 仓库**未声明 license 字段**；其上位来源 `kha-white/manga-ocr` 为 Apache-2.0，但**再分发该 ONNX 导出的法务状态待验证**（建议改用 `onnx-community/manga-ocr-base-ONNX`，其明确标注 Apache-2.0）。
- Flutter `onnxruntime` 插件（1.4.1）**是否透出 DirectML EP**：**待验证**。
- `remidesbois / vermilion10 / the1just / mednasserallah / neuroncstate` 等社区 ONNX 的**许可证与维护状态**：页面未明示处均标 **待验证**。
