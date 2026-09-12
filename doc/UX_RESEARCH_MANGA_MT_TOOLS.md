# 漫画机翻类工具 UX 调研：翻译结果页交互 + 性能设置呈现 + 模型管理

> 调研目的：为「VeneraX」Flutter 桌面漫画翻译 App 提炼可直接借鉴的交互与文案结论。
> 调研方式：公开文档 / README / Wiki / Release Notes / GitHub Issue / 权威 UX 资料（NN/g、Primer、GOV.UK、Microsoft Learn 等）。
> 证据等级标注：**【已核实】**＝有可点开的公开来源且原文可直接引用；**【待验证】**＝仅有二手来源或未找到公开证据。
> ⚠️ **本次调研发起时本机 `git`/`gh` CLI 通道不可用**（会话工具面在调研中途变更），因此**未能直接拉取仓库源码逐行确认**；凡涉及"源码里怎么写的"结论，一律以官方文档/README/Release Notes 为准，并显式标注待验证项。

---

## 一、"重新翻译"入口该放在哪

### 结论速览（粒度光谱）

| 粒度 | 是否有工具实现 | 代表工具 | 证据 |
|---|---|---|---|
| 整章 / 整个文件夹 | ✅ 普遍 | manga-image-translator、manga-translator-ui、BallonsTranslator | 【已核实】 |
| 仅重渲染（不重跑检测/OCR/翻译） | ✅ 有 | manga-translator-ui「导入翻译并渲染」、BallonsTranslator「全模块关闭仍重排重绘」 | 【已核实】 |
| 单页 | ⚠️ 部分 | manga-translator-ui（编辑器按图编辑 + 导出）、BallonsTranslator（按页浏览） | 【已核实/部分待验证】 |
| 单个文本框 / 单气泡 | ✅ 有（右键） | BallonsTranslator 右键文字框 → 翻译 | 【已核实】 |
| 只重译失败 / 低置信度部分 | ⚠️ 无成熟成品，只有「阈值过滤 + 置信度提示」 | manga-image-translator `ocr.prob` 阈值、ImageTrans 按置信度过滤、BallonsTranslator 字体识别 60% 置信度门槛 | 【已核实，但"批量挑出低置信度重跑"无公开实现，见 §1.5】 |

---

### 1.1 整章 / 整文件夹级"重跑"

- **【做法】** manga-image-translator 的批量模式提供 `--overwrite`（覆盖已翻译图片）与 `--skip-no-text`，配合 `--attempts`（出错重试次数，`-1` 无限）控制整批重跑行为。
  - **【来源】** <https://github.com/zyddnys/manga-image-translator>
  - **【是否值得借鉴】** 值得，但要改造。它的"重新翻译"语义是**命令行级的整批覆盖**，不是一个 UI 入口；桌面 App 应把它升格为 UI 上的明确动作，而不是让用户去改参数。**理由**：`--attempts -1` 这种"无限重试"默认值是典型的"参数泄漏给用户"，见 §2。

- **【做法】** manga-translator-ui 明确列出 8 种"工作流程模式"，其中与重译直接相关的有：**① 正常翻译流程 ② 导出翻译 ③ 导出原文 ④ 导入翻译并渲染（不进行翻译）⑤ 替换翻译**。
  - **【来源】** <https://github.com/hgmzhn/manga-translator-ui/blob/main/doc/USAGE.md>
  - **【是否值得借鉴】** ★★★ 高度值得。它把"重译"拆成了**语义清晰的动词短语**而不是一个笼统的"重试"按钮：
    - `导出原文 → 人工/AI 翻译 → 导入翻译并渲染`——这就是"只重做翻译这一步、保留检测与 OCR"的完整可复制范式；
    - `导入翻译并渲染（不进行翻译）`——纯粹的"重排版"，成本接近于零。
  - **理由**：对 VeneraX 这类多阶段流水线（检测→OCR→翻译→渲染）产品，**"重跑哪一段"比"要不要重跑"更重要**；用户真正想说的是"翻译这步我不满意，但版面别再动了"。

- **【做法】** 该工具的 Release Notes 里出现过 **"拉框全量重新解析"** 以及**"开启后只读取已有工程 JSON 并生成对应文本副文件，不重新检测图片、不执行 OCR、不调用翻译"**。
  - **【来源】** <https://github.com/hgmzhn/manga-translator-ui/releases>
  - **【是否值得借鉴】** ★★★ 高度值得，这是**"跳过某些阶段"的显式开关**。注意其文案已经把"不做什么"写得非常清楚（不重新检测、不执行 OCR、不调用翻译）——这正是 §2 里"每个开关都要写清作用"的最佳实例。

---

### 1.2 单页级重跑

- **【做法】** manga-translator-ui 的编辑器要求**先勾选"图片可编辑"**，翻译完成后才能"打开编辑器"逐图编辑（图片需有对应 `_translations.json`）；快捷键 `A`/`D` 在图片间翻页，`Ctrl+Q` 导出图片并同时保存 JSON。
  - **【来源】** <https://github.com/hgmzhn/manga-translator-ui/blob/main/doc/USAGE.md>
  - **【是否值得借鉴】** 部分值得。**"可编辑"是一个前置勾选**这一点不值得抄——它把"事后修"做成了"事前必须预测"。VeneraX 应改为：**结果页永远可编辑，".json/工程数据默认落盘"**。
  - **值得抄的是**：翻页快捷键（`A`/`D`）与"导出即保存工程"的耦合，让单页重跑无需额外的"保存"心智负担。

- **【做法】** BallonsTranslator 的浏览页把每页检测到的原文/译文列在右侧，直接在该页可改文字、调框位置/颜色/字号/旋转；右下角两个拉杆分别控制**嵌字层不透明度与原图不透明度**，便于对照原文校对。
  - **【来源】** <https://github.com/dmMaze/BallonsTranslator> 、第三方图文/视频教程 <https://ivonblog.com/posts/ballonstranslator-usage> 、<https://the-walking-fish.com/p/ballonstranslator>
  - **【是否值得借鉴】** ★★★ 高度值得：**"叠图层透明度拉杆"是低成本高价值的对照校对控件**。它让用户不离开当前页就能判断"是 OCR 错了还是翻译错了"——教程里正是这样定位到 `速い` 被识别成 `迷い`。
  - **【待验证】** 其浏览页是否存在独立的"重新翻译本页"按钮，未在公开文档中找到明确描述。

- **【做法】** BallonsTranslator 支持"关闭全部自动模块后仍可重排重绘全部文本"：`Disable or enable any automatic modules via titlebar->run, run with all modules disabled will re-letter and re-render all text according to corresponding settings.`
  - **【来源】** <https://github.com/dmMaze/BallonsTranslator/blob/dev/README_EN.md>
  - **【是否值得借鉴】** ★★★ 高度值得，**这是本次调研找到的最干净的"阶段级重跑"模型**：把流水线拆成可独立勾选的模块（检测/OCR/修复/翻译/渲染），用户取消勾选即"跳过"，全不勾则退化为"纯重排版"。比"重新翻译"一个模糊大按钮信息量大得多。

---

### 1.3 单气泡 / 单文本框级重译（用户最关心的粒度）

- **【做法】** BallonsTranslator 支持**右键文字框 → 翻译**，只重新翻译该单个项目。
  - **【来源】** <https://ivonblog.com/posts/ballonstranslator-usage>（原文：「如果你覺得個別的翻譯結果不好，可以直接右鍵文字框 → 翻譯，重新翻譯一次該項目」）
  - **【是否值得借鉴】** ★★★ 高度值得，**粒度精确到"单个文本框"是可行且已被验证的交互**。VeneraX 应把它作为气泡级重译的标准范式：右键（或长按/Hover 工具条）→ 重译此气泡。
  - **【待验证】** 该行为的具体 UI 截图与是否有"重译相邻气泡共享上下文"选项，未找到公开一手证据。

- **【做法】** manga-image-translator 的翻译层支持**上下文与选择性翻译**相关配置项：`selective_translation`、`no_text_lang_skip`、`skip_lang`、`translator_chain`（翻译器链式回退）。
  - **【来源】** <https://github.com/zyddnys/manga-image-translator>（README 配置 Schema 段）
  - **【是否值得借鉴】** 值得（作为能力），但**不要直接暴露**。`translator_chain` 意味着"主翻译器失败自动换下一个"——这是**应该默认开启的后台行为**，用户只需在结果上看到"本页由 X 引擎翻译"。

---

### 1.4 "只重译失败/低置信度部分"——现实做法

- **【做法】** manga-image-translator 存在一个 **OCR 置信度阈值** `ocr.prob`（**默认非 0，示例中为 0.2**），低于阈值的行会被**静默丢弃**。Issue #1113 的复现日志为：`OCR result exists but gets filtered: prob=0.021 < threshold=0.2`。
  - **【来源】** <https://github.com/zyddnys/manga-image-translator/issues/1113>
  - **【是否值得借鉴】** ★★★ 高度值得，且**该 Issue 本身就是最好的反面教材**。报告人指出：`bboxes_unfiltered.png` 里有此行，`bboxes.png` 里没有；并且——
    > "this parameter isn't shown in doc nor config templates. I only found it by reading code, so most users won't know it exists."
  - **结论**：**"因低置信度而被丢弃"是用户看不见的失败**。VeneraX 必须把这类丢弃变成**可见项**（"本页 2 行因置信度过低未翻译 → 查看/提高阈值重跑"），否则用户只会看到"漏翻了"。
  - **【待验证】** 是否存在"自动挑出低置信度项并批量重跑"的公开实现——**未找到**。

- **【做法】** ImageTrans 在批量操作中可设置**是否按置信度过滤文本区域**（`For batch operations, we can now set whether to enable text areas filtering based on confidence`），并支持"识别无文字区域"的自定义工作流项。
  - **【来源】** <https://www.basiccat.org/imagetrans/release-notes>
  - **【是否值得借鉴】** 值得：**把"置信度过滤"做成显式可切换的开关，而不是写死在代码里的常数**。

- **【做法】** BallonsTranslator 的字体识别带**显式置信度门槛**：置信度 > 60% 的字体名才会被写入 JSON 的 `_detected_font_name` 字段。
  - **【来源】** <https://github.com/dmMaze/BallonsTranslator/blob/dev/README_EN.md>
  - **【是否值得借鉴】** 值得：**"低置信度就不写结果、而不是写一个错结果"**——这条原则可迁移到 VeneraX 的字体/排版推断上。

- **【做法】** Ollama 用 `ollama ps` 的 `PROCESSOR` 列把**实际执行位置与比例**直接显示给用户：`100% GPU` / `100% CPU` / `48%/52% CPU/GPU`。
  - **【来源】** <https://docs.ollama.com/faq>
  - **【是否值得借鉴】** ★★★ 高度值得（且与 VeneraX 的 DirectML 场景强相关）：**用户需要一个"我这次到底跑在哪、跑成什么样"的事实陈述**，而不是靠猜。VeneraX 可直接映射为"本页 100% GPU（DirectML）" / "已回退 CPU（原因：显存不足）"。

---

## 二、性能相关设置怎么呈现

### 2.1 预设档位（把细粒度参数折叠起来）

- **【做法】** **Fooocus 的 Performance 档位是本次调研最强的正面样板**：官方定位就是"对 A1111/ComfyUI 参数过载的反面"，只给一个下拉：`Speed（默认，30 步）/ Quality（60 步）/ Extreme Speed（8 步，LCM）`，更高阶还有 `Lightning`、`Hyper SD`。
  - **【来源】** <https://localaimaster.com/blog/fooocus-guide>（含档位对照表）、<https://www.youtube.com/watch?v=ZLSJ44bvyxs>
  - **【是否值得借鉴】** ★★★ 高度值得。**"3 档 + 每档注明代价"** 正是"性能旋钮太多"的标准解。注意 Fooocus 的档位命名走的是**用户结果语言**（速度/质量），而不是技术语言（步数/采样器）。
  - **【待验证】** 上述档位参数表来自第三方整理，非官方文档；接入前建议以 Fooocus 仓库为准复核。

- **【做法】** **ComfyUI 用互斥的 VRAM 模式旗标**把内存策略收敛成单选：`--gpu-only` / `--highvram` / `--lowvram` / `--novram` / `--cpu`（文档明确指出这些是互斥的），另有 `--reserve-vram GB`、`--enable-dynamic-vram`、`--disable-async-offload` 等。
  - **【来源】** <https://docs.comfy.org/development/comfyui-server/startup-flags>
  - **【是否值得借鉴】** 值得（结构），**但不要抄它的默认值**。互斥单选比 N 个独立开关更安全（不会出现"同时开了高显存和低显存"的荒谬组合）；然而这些旗标是**启动参数**，用户得先关软件——桌面 App 必须做成设置页内可切换。

- **【做法】** ComfyUI 官方排障文档给出的低显存建议顺序是**先降分辨率/批大小，再用内存优化旗标**，并配了可直接复制的命令；甚至注明"CPU 模式非常慢，仅作最后手段"。
  - **【来源】** <https://docs.comfy.org/troubleshooting/overview>
  - **【是否值得借鉴】** ★★★ 高度值得：**"先调工作负载，再调内存策略，最后才降级到 CPU"** 是一个可以直接抄进 VeneraX 帮助文案的决策顺序。并且它给降级路径标注了代价（"very slow"），而不是默默切 CPU。

- **【做法】** manga-translator-ui 把"显卡"与"程序构建"的匹配写成**显式矩阵与警告**：GeForce 10 系必须 CUDA 12.6 / RTX 50 系必须 CUDA 13.0；AMD 仅支持 RX 7000/9000，**RX 5000/6000 请用 CPU 版本**（`⚠️`）；ROCm 在 Windows 上支持有限，Linux 通常更好。
  - **【来源】** <https://github.com/hgmzhn/manga-translator-ui/blob/main/doc/en/INSTALLATION.md>
  - **【是否值得借鉴】** ★★★ 高度值得。这是"**先说不能跑什么，再说怎么跑得更好**"的写法。对 VeneraX（DirectML）尤其重要：应显式写出"哪些显卡会退化为 CPU"。

---

### 2.2 给每个参数写明作用（找具体例子）

- **【做法】** manga-translator-ui 的 OCR 模型列表是本次调研**最好的"参数即文档"实例**，每一行都写了适用场景与风险，且明确写出负面结论：
  - `32px`：旧版轻量模型，可作兼容性备选
  - `48px（推荐）`：默认模型，平衡速度和准确率
  - `48px_ctc`：CTC 变体模型，**可作为备选对比，不代表一定更精确**
  - `mocr`：Manga OCR 专用模型
  - `paddleocr`：PaddleOCR 引擎，支持多语言；`paddleocr_korean`：**韩漫推荐**；`paddleocr_latin`：拉丁字母文本推荐；`paddleocr_thai`：泰文推荐
  - `paddleocr_vl`：**效果最好但最吃配置**，建议配合 VLM OCR 语言提示或自定义提示词
  - **日漫混合 OCR 推荐：`48px + mocr`**
  - **【来源】** <https://github.com/hgmzhn/manga-translator-ui/blob/main/doc/USAGE.md>
  - **【是否值得借鉴】** ★★★ **强烈建议整条抄**。它同时做到四件事：① 标推荐 ② 说代价（"最吃配置"）③ 破除迷信（"不代表一定更精确"）④ 给组合配方（"48px + mocr"）。

- **【做法】** manga-image-translator 的 README 为参数写了**人类可读的作用说明**，包括负面建议：
  - `detector`：`don't use craft for manga, it's not designed for that`（**别用 craft，它不是为漫画设计的**）
  - `detection_size`：The size of the image to use for detection
  - `det_rotate` / `det_auto_rotate` / `det_invert`：各自标注 `Can improve detection`
  - `ignore_bubble`：`Threshold for ignoring non-bubble area text, valid values range from 1-50. Recommended 5 to 10. If too low, normal bubble areas might be ignored, if too large, non-bubble areas might be treated as normal bubbles`（**推荐值 + 过小/过大的后果各说一遍**）
  - **【来源】** <https://github.com/zyddnys/manga-image-translator>
  - **【是否值得借鉴】** ★★★ 高度值得。**`ignore_bubble` 的文案结构就是模板**：`是什么 → 取值范围 → 推荐值 → 太小会怎样 → 太大会怎样`。

- **【做法】** manga-translator-ui 的 DEBUGGING 文档把**症状 → 病因 → 对应旋钮**连成一条链：例如"检测不到文本"的病因含"检测置信度过高 / 图像分辨率太低 / 文本颜色与背景对比度低"，处置是"降低'文本置信度'和'边界框生成阈值'"。
  - **【来源】** <https://github.com/hgmzhn/manga-translator-ui/blob/main/doc/DEBUGGING.md>
  - **【是否值得借鉴】** ★★★ 高度值得：**把排障表做成设置页的一部分**（或从错误提示 deep-link 过去），比写一本"参数手册"有用得多。

- **【做法】** BallonsTranslator 的 README 直接给**否定式建议**：逐 textblock 跑 OCR"更慢且精度无显著提升，不推荐"；并给出组合优化建议（用 Tuanzi Detector 时建议把 OCR 设为 `none_ocr` 直接读文本，省时且减少请求数）。
  - **【来源】** <https://github.com/dmMaze/BallonsTranslator/blob/dev/README_EN.md>
  - **【是否值得借鉴】** ★★★ 高度值得。**"不推荐 + 为什么不推荐"是负责任文档的标志**；同时在 UI 里应对这些组合给出"预设"而非让用户手动拼。

---

### 2.3 自动调优 / 按硬件探测推荐配置

- **【做法】** **SakuraLLM 的 OneClickLLAMA 一键包"可以支持各种不同显存挡位的显卡，并提供与不同应用搭配的最优性能配置"**；其 README 还给出模型↔显存对照表（如 `sakura-14b-...-iq4xs.gguf` 对应 11G/12G/16G；`24G` 对应 `q6k`）。
  - **【来源】** <https://github.com/SakuraLLM/SakuraLLM>
  - **【是否值得借鉴】** ★★★ 高度值得，**这正是 VeneraX 最该抄的机制**：探测显存档位 → 直接给"最优性能配置"，而不是给用户一堆 batch size 让他猜。
  - **【待验证】** "自动探测"的具体实现方式（是读 `nvidia-smi` 还是按 GPU 型号查表）未在 README 中说明，标注**待验证**。

- **【做法】** ComfyUI 已把动态显存管理做成**默认行为**：`--enable-dynamic-vram` 在 Nvidia 上 `auto on Nvidia`（默认开启），`--lowvram` 在动态显存启用时"无效果"；官方文档同时警告老教程里的旗标可能已失效。
  - **【来源】** <https://docs.comfy.org/development/comfyui-server/startup-flags>
  - **【是否值得借鉴】** ★★★ 高度值得（且是重要警示）：**"自动调优应该默认开着，以至于手动旋钮变得无意义"**——这是自动调优做成功的标志。同时提醒 VeneraX：**不要把过时的调优旋钮留在 UI 里**。

- **【做法】** Ollama 在加载模型时会**评估所需显存与当前可用显存**：能整块放进单卡就放单卡（减少 PCI 传输），放不下则跨多卡分摊；用户可用 `ollama ps` 复核实际落点。
  - **【来源】** <https://docs.ollama.com/faq>
  - **【是否值得借鉴】** ★★★ 高度值得：**"自动决策 + 可复核"** 的组合。自动调优必须配一个"我到底跑在哪"的显示，否则用户无法判断该不该手动干预。

- **【做法】** manga-translator-ui 的"通用"设置里有**批量大小**（控制同时处理的图片数量），且在 USAGE 的提示里点名"可以在设置 → 通用 中设置'批量大小'来控制同时处理的图片数量"。
  - **【来源】** <https://github.com/hgmzhn/manga-translator-ui/blob/main/doc/USAGE.md>
  - **【是否值得借鉴】** 值得（作为兜底），但**这正是 VeneraX 应该用自动档位替掉的东西**：让用户直接调"同时处理图片数"是把显存管理的责任推给了用户。

- **【做法】** manga-image-translator 提供 `--use-gpu-limited`（开启 GPU 但**排除离线翻译器**），以及 `--use-gpu`（在 mps/cuda 间自动切换）；FAQ 类文章把"GPU 内存不足 → 加 `--use-gpu-limited`"、"翻译慢 → 降低 inpainting_size 至 1024"作为标准处置。
  - **【来源】** <https://github.com/zyddnys/manga-image-translator>
  - **【是否值得借鉴】** 值得（作为降级策略）。对 VeneraX：**"显存不足时把最吃显存的阶段（修复/超分）挪出 GPU"是一条可自动化执行的降级路径**，不该只写在文档里。
  - **【待验证】** 上述"降低 inpainting_size 至 1024"出自第三方教程，非官方文档。

---

### 2.4 UX 最佳实践（权威来源）

- **【做法/原则】** **渐进披露（Progressive Disclosure）**：初始只展示最重要的少量选项，次级选项在用户索取时才出现；并强调"从主层级到次级层级的路径必须明显"。
  - **【来源】** Nielsen Norman Group — <https://www.nngroup.com/articles/progressive-disclosure>
  - **【是否值得借鉴】** ★★★ 必抄（权威一手来源）。这是"性能旋钮太多"的第一性解法。
  - **补充**：NN/g 同时警告——初始视图仍须包含用户**高频需要**的东西，否则会拖慢专家用户；可考虑给专家角色提供"保持展开"的个人化选项。

- **【做法/原则】** **默认值的威力**：用户极少使用高级自定义功能，因此**必须优化默认体验**；研究显示约 60% 用户会把默认项理解为"推荐项"，**即使从未这样标注**。
  - **【来源】** NN/g — <https://www.nngroup.com/articles/the-power-of-defaults>（含"用户几乎不用 fancy customization features"的原文）；60% 数字见 [The Psychology of Defaults](https://uxmag.medium.com/the-psychology-of-defaults-how-pre-selected-options-influence-behavior-1280b1f404b4)
  - **【是否值得借鉴】** ★★★ 必抄。**推论**：VeneraX 的默认性能档必须在**用户的真实机器**上跑得好；否则用户不会去调，只会认为"这软件卡"。
  - **伦理提醒**（同源）：默认值不应为转化率而设，要为长期满意度而设——不要默认选最贵/最重的档。

- **【做法/原则】** **Primer 的渐进披露模式规范**：应"谨慎使用，仅在确有必要截断信息时用"；展开/折叠要有明确文案（"Show more"），chevron 图标不应被滥用为下拉触发器。
  - **【来源】** <https://primer.style/product/ui-patterns/progressive-disclosure>
  - **【是否值得借鉴】** ★★★ 值得（设计系统级规范，适合直接落到 Flutter 组件规范）。

- **【做法/原则】** **错误信息不能只说"出错了"**：要贴近错误来源显示、用人类语言、非技术用途下隐藏错误码；错误对话框应回答"发生了什么、用户该做什么"。
  - **【来源】** NN/g — <https://www.nngroup.com/articles/error-message-guidelines> ；Microsoft Learn — <https://learn.microsoft.com/en-us/dynamics365/business-central/dev-itpro/developer/devenv-error-handling-guidelines>
  - **【是否值得借鉴】** ★★★ 必抄，直接用于 §3 的校验失败提示。

- **【做法/原则】** **降低表单认知负荷的 4 原则**：Structure（结构化）/ Transparency（提前说清要求）/ Clarity（无歧义）/ Support（及时帮助）；并明确反对"占位符代替标签"与"过早校验（premature validation）"。
  - **【来源】** NN/g — <https://www.nngroup.com/articles/4-principles-reduce-cognitive-load>
  - **【是否值得借鉴】** ★★★ 值得。**注意"避免过早校验"这条与 §3 直接冲突**：模型校验不应在用户刚选中文件时就弹红字，而应在下载完成后给出结论。

---

## 三、模型管理页的 UX

### 3.1 校验失败（checksum / 结构检测）怎么提示

- **【做法】** **ComfyUI 官方排障文档**把"Missing Models Error"的处置写成可执行清单：**① 重新下载模型（文件可能在下载过程中损坏）② 检查磁盘空间是否足够（模型可能 2–15 GB+）③ 检查文件权限 ④ 用不同模型测试**以区分"是这个模型坏了"还是"整个系统坏了"。
  - **【来源】** <https://docs.comfy.org/troubleshooting/model-issues>
  - **【是否值得借鉴】** ★★★ 强烈建议抄这个**四步结构**，尤其第 ④ 步"用不同模型测试"是**区分故障域**的关键动作，绝大多数产品都漏了。

- **【做法】** **ComfyUI 的报错文案本身**长这样（原始、粗糙但信息完整）：`Prompt outputs failed validation: CheckpointLoaderSimple: - Value not in list: ckpt_name: 'model-name.safetensors' not in []`——它把**失败阶段（validation）→ 组件（CheckpointLoaderSimple）→ 字段（ckpt_name）→ 实际值 → 期望集合**全列了出来。
  - **【来源】** <https://docs.comfy.org/troubleshooting/model-issues>
  - **【是否值得借鉴】** ★★★ 抄它的**信息结构**，改成人类语言。对 VeneraX 的"韩文模型 3689 类 vs 词典 3688 行"这类**结构性不匹配**，这个结构刚好够用：`校验失败 · 识别模型输出类数 (3689) ≠ 词典行数 + 2 (3690) · 差 1 类 · [改用兼容词典] [仍然使用] [查看详情]`。

- **【做法】** **下载中断 + 续传 → 最终校验失败**是这类产品的**典型失败链**：LM Studio 的 Issue 明确描述"下载经常超时；点重试续传后，下载结束时出现 checksum 错误"（`The error message is "Timed-out. Please try to resume."`）。
  - **【来源】** <https://github.com/lmstudio-ai/lmstudio-bug-tracker/issues/1222>
  - **【是否值得借鉴】** ★★★ 高度值得（教训型）。**"断点续传 + 静默拼接 = 校验失败"** 必须在 VeneraX 里被显式建模：续传后**必须重算全文件校验值**，而不是只校验新增分片；失败时应提示"续传导致文件损坏，建议删除后重新下载"，并给一键"删除并重下"。

- **【做法】** Ollama 的校验失败文案区分了**粒度**：`Pull Failed - Blob Checksum Mismatch` 的含义是"**不是说整个模型坏了，只是某个 blob 未通过校验**"。
  - **【来源】** <https://adhdecode.com/debugging/ollama/error-pull-failed-blob-checksum-mismatch>（第三方解析，非官方文档）
  - **【是否值得借鉴】** 值得。**"是整包坏了还是某一片坏了"** 决定了"重下全部"还是"重下分片"——文案必须说清，否则用户被迫整包重下（2–15 GB 的代价）。
  - **【待验证】** 该说法为第三方解读，Ollama 官方文档未直接对应该措辞。

- **【做法】** 模型文件完整性存在**可自动化**的公开手段：HuggingFace Hub 的 `etag` **就是 SHA-256**，可通过 `get_hf_file_metadata` 取出；本地用 `sha256sum` / `certutil -hashfile <file> SHA256` 比对即可。ComfyUI 生态的第三方 ModelResolver 插件明确宣传"**下载时按源提供的哈希做 SHA256 校验**"。
  - **【来源】** <https://toolpry.com/blog/verify-ai-model-downloads-sha256-checksum> ；<https://discuss.huggingface.co/t/local-model-backups/171119> ；<https://www.reddit.com/r/comfyui/comments/1vd9o31/comfyuimodelresolver_finds_and_downloads_the>
  - **【是否值得借鉴】** ★★★ 高度值得（**直接对应 VeneraX 的 `MODELS_NEEDED.md` 里向外部索要 SHA256 的诉求**）。
  - **【待验证】** "来源提供哈希"并非普遍成立；应把"无哈希可用"作为一等状态处理（回退到结构检测，见 §3.2）。

- **【做法】** ComfyUI 把**哈希相同但结果异常**（NaN）单独归类为"不是损坏，而是精度/数学问题"，处置方式是"一次只加一个 LoRA、逐个排除"。
  - **【来源】** <https://discuss.huggingface.co/t/local-model-backups/171119>
  - **【是否值得借鉴】** ★★★ 值得，这是**校验通过后的第二类失败**：`校验通过但推理输出异常`。VeneraX 应有独立提示："模型文件校验通过，但输出疑似异常（全空/乱码）→ 可能是 EP/精度不兼容"。

---

### 3.2 多语言模型怎么组织

- **【做法】** **按语言/用途分组的实例（最接近"可抄"）**——manga-translator-ui 的 OCR 列表按**引擎族 + 语言专长**组织，并对语言给出明确推荐：`paddleocr_korean`：韩漫推荐；`paddleocr_latin`：拉丁字母文本推荐（英文建议优先使用）；`paddleocr_thai`：泰文推荐；`mocr`：Manga OCR 专用模型；并给出跨模型的**组合配方**"日漫混合 OCR 推荐：`48px + mocr`"。
  - **【来源】** <https://github.com/hgmzhn/manga-translator-ui/blob/main/doc/USAGE.md>
  - **【是否值得借鉴】** ★★★ 强烈建议抄。**组织维度 = "我翻译什么语言"**（用户语言），而不是"模型是什么架构"（厂商语言）。并保留"组合配方"，因为真实最优解常是模型组合，不是单选。

- **【做法】** ComfyUI 采用**按用途分目录**的物理组织：`models/checkpoints/`、`models/vae/`、`models/loras/`、`models/controlnet/`、`models/embeddings/`；并提供"共享模型 / 自定义模型目录"的配置能力。
  - **【来源】** <https://docs.comfy.org/troubleshooting/model-issues>
  - **【是否值得借鉴】** 值得（文件系统层），但**不要把目录名直接当 UI 分类名**。`loras` 对漫画用户毫无意义；应映射为"用途"（检测/识别/翻译/修复/超分）。

- **【做法】** BallonsTranslator 的组织方式是按**流水线阶段分模块目录**（`ballontranslator/modules/` 下按模块分目录存放各实现），且每个模块的模型与参数在**设置面板**中调整；README 还提示"选择需要额外库的模块时，程序会提示安装缺失的可选依赖（也可在设置中启用自动安装）"。
  - **【来源】** <https://github.com/dmMaze/BallonsTranslator> ；<https://blog.csdn.net/gitblog_00200/article/details/163979665>（第三方解析，标注待验证）
  - **【是否值得借鉴】** ★★★ 值得：**"按阶段分组"比"按语言分组"更适合技术用户，按语言分组更适合翻译用户**。VeneraX 建议做成**双入口**：主视图按"语言/用途"分组，详情页可见其所属**流水线阶段**，并标注依赖状态。

- **【做法】** HuggingFace 生态用 `base_model` 元数据标注模型的**血统关系**（ComfyUI 排障中强调"替换的模型必须与工作流兼容，需要匹配架构/checkpoint 家族"）。
  - **【来源】** <https://docs.comfy.org/troubleshooting/model-issues>
  - **【是否值得借鉴】** 值得：**"这个模型能不能和当前流程配套"应该是 UI 的一等信息**（如"与当前 OCR 词典配套 ✓"），而不是让用户在报错后自己推断。

---

### 3.3 变体（高精/轻量/GPU）如何命名与说明才不误导

- **【做法】** manga-image-translator 的**检测模型枚举直接摊开**：`default` / `dbconvnext` / `ctd` / `craft` / `paddle` / `none`，并在说明里**主动排除某个选项**（`don't use craft for manga, it's not designed for that`）。
  - **【来源】** <https://github.com/zyddnys/manga-image-translator>
  - **【是否值得借鉴】** ★★★ 值得。**"不要用 X"比"X 是什么"更有价值**。VeneraX 的变体卡片应有明确的"不适用于/慎用"行。

- **【做法】** **SakuraLLM 的量化档位表用"质量损失 + 显存占用 + 速度 + 推荐场景"四元组描述变体**，且措辞克制诚实：
  - `IQ4_XS`：小的质量损失，占用更小，但**速度比 Q4_K 慢（6G 显存推荐）**
  - `Q4_K`：小的质量损失（6G 显存推荐）
  - `Q5_K`：很小的质量损失（6G/8G 显存推荐，**6G 显存可能需要减小窗口大小 '-c'**）
  - `Q6_k`：细小的质量损失（8G 及以上显存推荐）
  - **【来源】** <https://github.com/SakuraLLM/SakuraLLM> ；模型卡 <https://ollama.com/crosery/GalTransl-7B-v2.6>
  - **【是否值得借鉴】** ★★★ **这是本次调研"变体命名不误导"的最佳模板**。三条精髓：① 每条都带**显存档位**（用户能自我定位）② 明确写出**反直觉的权衡**（"更小 ≠ 更快"，IQ4_XS 比 Q4_K 慢）③ 给出**副作用与补救**（6G 需减小窗口）。
  - **命名建议**：变体名 = `用途/语言 + 档位`（如 "日文 OCR · 标准 48px"），而不是厂商内部代号；代号可放在副标题或详情里。

- **【做法】** manga-translator-ui 用一句**"不代表一定更精确"**破除变体迷信：`48px_ctc：CTC 变体模型，可作为备选对比，不代表一定更精确`；`paddleocr_vl：效果最好但最吃配置`。
  - **【来源】** <https://github.com/hgmzhn/manga-translator-ui/blob/main/doc/USAGE.md>
  - **【是否值得借鉴】** ★★★ 强烈建议抄。**"新型号/变体 ≠ 更好的结果"** 必须在 UI 里说出口，否则用户会盲目切到最重的变体，然后抱怨卡。

- **【做法】** "高精 / 轻量"这类命名的**代价必须成对出现**：ComfyUI 文档给低显存路径标注了"CPU 模式非常慢，仅作绝对最后手段"；manga-translator-ui 给 CPU 路径标注"CPU 版本比 GPU 版本慢 5-10 倍"。
  - **【来源】** <https://docs.comfy.org/troubleshooting/overview> ；<https://github.com/hgmzhn/manga-translator-ui/blob/main/doc/USAGE.md>
  - **【是否值得借鉴】** ★★★ 必抄：**任何"省显存/轻量"档位旁必须写"代价：慢 5–10 倍"**。有量化代价的降级是可接受的，无代价标注的降级是误导。
  - **注意**：manga-translator-ui 的原文是"CPU 版本比 GPU 版本慢 5-10 倍"（针对其自身实现），**不要把 5–10× 直接搬到 VeneraX 文案**，应实测后填自己的数字。

- **【做法】** IsManga 一类的"档位"命名以**结果为导向**并附适用场景：`Manga Translate Lite：以速度优先（处理时间低于 10 秒），专注于标准对话气泡` / `Pro：追求高保真，能识别全图所有文字（不仅限于气泡）并保留原始字体风格`。
  - **【来源】** <https://www.aitoolnet.com/zh/manga-translator-online>（第三方收录页，**待验证**，需以产品官网复核）
  - **【是否值得借鉴】** 值得（命名思路）：**用"你会得到什么"命名档位，而不是用"我们用了什么技术"**。

---

## 四、建议的交互与文案结构草案（Flutter 桌面漫画翻译 App）

> 前提（来自本项目 `MODELS_NEEDED.md`）：ONNX + ONNX Runtime 1.22 + DirectML EP；RTX 3060 Laptop 6144 MiB，桌面合成器占 1.5–2 GB ⇒ **可分配显存 ≈ 4 GB**；存在"模型输出类数 ≠ 词典行数 + 2"这类**结构性校验失败**。

### 4.1 性能设置：三档预设 + 折叠的高级项

**默认视图（首次进入设置只显示这些）**

```
性能模式
( ) 省显存    适合 4GB 可用显存；速度较慢          ← 当前硬件推荐
(•) 均衡      默认；兼顾速度与画质
( ) 极速      最快；占用最高，可能触发降级

当前运行状态：GPU（DirectML）· 本页峰值 2.4 GB / 可用约 4.0 GB
                ↑ 可复核的事实陈述（借鉴 Ollama `ollama ps` 的 PROCESSOR 列）
[ 检测到 RTX 3060 Laptop · 已自动选择「均衡」     ]  [ 重新检测 ]
                     ↑ 借鉴 SakuraLLM OneClickLLaMA / ComfyUI 动态显存默认开启
[ ▸ 高级设置 ]        ← chevron + 明确文案（Primer 规范）
```

**展开"高级设置"后（渐进披露第二层）**

| 参数 | 文案（抄 §2.2 的结构） |
|---|---|
| 同时处理页数 | 一次并行处理多少页。**推荐 2**。设为 1 最省显存但更慢；大于 4 容易触发显存不足并自动回退 CPU。 |
| 检测分辨率 | 检测时的图像缩放边长。**推荐 1024**（省显存）／2048（更准但更慢）。**太小会漏检小字，太大会显存不足**。 |
| 修复精度 | 擦字修复的输入尺寸。**推荐 1024**。调低可显著省显存，代价是复杂背景擦除残留更明显。 |
| 失败重试次数 | 单页失败后自动重试次数。**推荐 2**；设为"无限"会让坏页卡住整批。 |

> 措辞全部遵循 `推荐值 + 太小会怎样 + 太大会怎样`（manga-image-translator `ignore_bubble` 的文案结构）。

### 4.2 翻译结果页：重新翻译入口（三层粒度，全部可见）

```
┌ 第 12 页 / 共 40 页 ─────────── [A 上一页] [D 下一页] ┐
│                                                      │
│   [ 译文画布 ]                     ▸ 本页文本块 (23)  │
│                                        · 气泡 1 ✓     │
│                                        · 气泡 2 ⚠ 低置信度 │
│                                        · 气泡 3 ✓     │
│                              [ 原图透明度 ▬▬▬○── ]   │
│                              [ 译文透明度 ▬▬○──── ]   │
└──────────────────────────────────────────────────────┘
[ 本页重译 ]  [ 重新排版（不重跑 OCR/翻译）]  [ 整批重译…]
                    ↑ 借鉴 BallonsTranslator「全模块关闭仍重排重绘」
                                       ↑ 借鉴 manga-translator-ui「导入翻译并渲染（不进行翻译）」
```

**单个气泡右键（或 Hover 工具条）**

```
重译此气泡
仅重跑 OCR（保留译文）
编辑原文 / 编辑译文
────────────────
查看为什么这样翻译（原文 · 置信度 0.87 · 引擎：X）
```

> 借鉴 BallonsTranslator 的"右键文字框 → 翻译，重新翻译一次该项目"。

**必须有的"漏翻可见化"面板**（针对 §1.4 的静默丢弃问题）

```
本页有 2 行未翻译
原因是 OCR 置信度过低（0.021 < 阈值 0.20）而被丢弃
[ 查看这些区域 ]  [ 降低阈值并重跑本页 ]  [ 忽略 ]
```
> 若不做这一步，用户只会看到"漏翻了"，永远找不到 `ocr.prob` 这类隐藏参数。

**整批重译对话框（让用户选"重跑哪一段"）**

```
重新翻译：[✓] 文字检测  [✓] OCR  [✓] 翻译  [✓] 修复  [✓] 排版
范围：  ( ) 全部 40 页   ( ) 仅本页   (•) 仅失败/低置信度的 3 页
提示：取消勾选「文字检测」「OCR」可保留现有原文，只重做翻译与排版（更快）。
```
> 借鉴 BallonsTranslator 的模块级勾选 + manga-translator-ui 的"不做什么"显式说明。

### 4.3 模型管理页

**卡片结构（每个模型一张卡）**

```
日文 OCR · 漫画专用                       [ 已安装 ✓ 校验通过 ]
体积 552 MB · 语言：日文 · 阶段：OCR
推荐用于：日漫对话气泡、竖排文字
代价：比轻量档慢约 40%；显存占用 +0.6 GB
组合建议：与「日文检测 · 漫画版」搭配效果最佳
[ 查看详情 ]  [ 重新校验 ]  [ 删除 ]
```
> 命名遵循"用途+语言+档位"，避免厂商代号误导；"代价"一行必填（借鉴 SakuraLLM 量化表的四元组与 manga-translator-ui 的"不代表一定更精确"）。

**校验失败（三种状态必须区分）**

```
① 文件损坏 / 哈希不符
   校验失败：文件与官方哈希不一致
   可能是下载中断或断点续传拼接导致。
   [ 删除并重新下载 ]  [ 仍然使用（风险自担）]  [ 查看详情 ]
      ↑ 借鉴 LM Studio 的"续传 → 校验失败"失败链；给出根因而非只给结论

② 结构不匹配（VeneraX 真实场景）
   校验失败 · 结构不匹配
   识别模型输出类数 3689 ≠ 词典行数 + 2（需要 3690），差 1 类。
   说明：此模型与当前词典的世代不匹配，装入后韩文识别会输出乱码。
   [ 改用兼容词典 ]  [ 仍然使用（该语言将不可用）]  [ 查看详情 ]
      ↑ 借鉴 ComfyUI 报错的信息结构（阶段→组件→字段→实际值→期望值），改写为人类语言

③ 校验通过但输出异常
   校验通过，但输出疑似异常（本页结果为空）
   可能原因：DirectML EP 精度不兼容 / 模型与执行后端不匹配。
   [ 用另一模型测试 ]  [ 切换到 CPU 运行 ]  [ 反馈日志 ]
      ↑ 借鉴 ComfyUI「用不同模型测试」的故障域区分步骤，以及"哈希相同但 NaN ≠ 损坏"的分类
```

**校验失败文案三原则**（全部有权威来源）
1. **说清根因与后果**，不要只给错误码（NN/g 错误信息指南）；
2. **贴近错误来源显示**，不要弹一个远离模型卡片的全局 toast（NN/g）；
3. **不要过早校验**——不要在用户刚选中文件时就红字警告，等下载/校验完成再给结论（NN/g 认知负荷 4 原则里的 anti-pattern）。

---

## 五、明确标注的「待验证」清单

以下结论**本次调研未能找到一手公开证据**，使用前必须自行验证：

1. **「只重译失败/低置信度部分」的成品实现**——未找到任何开源漫画翻译工具提供"批量挑出低置信度项并自动重跑"的功能。现有能力只到"阈值过滤 + 置信度写入 JSON"。**无公开来源，待验证。**
2. **BallonsTranslator 是否存在"重新翻译本页"的显式按钮**——其"右键文字框 → 翻译"有二手教程支持，但页面级重译未找到一手证据。
3. **BallonsTranslator 的 `presets.py` 是否就是 UI 上的"预设档位"**——仅在第三方代码目录快照中见到该文件名，**语义未验证**。
4. **Fooocus 性能档位的具体参数（30/60/8 步、采样器）**——来自第三方整理文章，需以 Fooocus 仓库复核。
5. **SakuraLLM OneClickLLaMA "按显存档位给最优配置"的实现方式**——README 有该表述，但未说明探测机制（`nvidia-smi` 读取 vs 型号查表）。
6. **"自动调优/按硬件探测推荐配置"在漫画机翻工具中的直接实现**——本次**未找到漫画翻译工具自身的实例**；最接近的是 SakuraLLM（LLM 推理侧）与 ComfyUI（动态显存默认开启）。若 VeneraX 要做，属于**该品类内的差异化能力**。
7. **Ollama "blob 级校验失败"的官方措辞**——来自第三方解析文章。
8. **IsManga 的 Lite/Pro 档位描述**——来自第三方收录页，需以官网复核。
9. **manga-translator-ui / manga-image-translator 源码内部的显存自动检测逻辑**——本次因本机 CLI 通道不可用未能拉取源码确认。

---

## 六、来源清单

**被测工具（一手）**
- zyddnys/manga-image-translator — <https://github.com/zyddnys/manga-image-translator>
- manga-image-translator 中文说明 — <https://github.com/zyddnys/manga-image-translator/blob/main/README_CN.md>
- manga-image-translator Issue #1113（OCR 置信度阈值 / `ocr.prob` 隐藏参数）— <https://github.com/zyddnys/manga-image-translator/issues/1113>
- dmMaze/BallonsTranslator — <https://github.com/dmMaze/BallonsTranslator>
- BallonsTranslator README_EN（模块开关 / 字体识别 60% 置信度 / 否定式建议）— <https://github.com/dmMaze/BallonsTranslator/blob/dev/README_EN.md>
- BallonsTranslator 本地化文档 — <https://github.com/dmMaze/BallonsTranslator/blob/dev/doc/localization.md>
- BallonsTranslator Issue #1030（AMD/CUDA 设备问题）— <https://github.com/dmMaze/BallonsTranslator/issues/1030>
- hgmzhn/manga-translator-ui — <https://github.com/hgmzhn/manga-translator-ui>
- manga-translator-ui USAGE（工作流程 8 模式 / OCR 模型列表 / 编辑器）— <https://github.com/hgmzhn/manga-translator-ui/blob/main/doc/USAGE.md>
- manga-translator-ui INSTALLATION（显卡矩阵 / 环境变量表）— <https://github.com/hgmzhn/manga-translator-ui/blob/main/doc/en/INSTALLATION.md>
- manga-translator-ui DEBUGGING（症状→病因→旋钮）— <https://github.com/hgmzhn/manga-translator-ui/blob/main/doc/DEBUGGING.md>
- manga-translator-ui Releases（拉框全量重新解析 / 只读 JSON 不重跑）— <https://github.com/hgmzhn/manga-translator-ui/releases>
- BallonsTranslator-Pro（模块对照表 / 工作流）— <https://github.com/thomaswantstobeaskeleton/BallonsTranslator-Pro>
- jedzqer/manga-translator-android（移动端：可拖动译文气泡 / 译名表缓存）— <https://github.com/jedzqer/manga-translator-android>
- ImageTrans Release Notes（按置信度过滤文本区域 / 批量）— <https://www.basiccat.org/imagetrans/release-notes>

**相邻生态（性能与模型管理参考）**
- ComfyUI Startup Flags（互斥 VRAM 模式 / 动态显存 / reserve-vram）— <https://docs.comfy.org/development/comfyui-server/startup-flags>
- ComfyUI Troubleshooting 总览（低显存处置顺序 / CPU 模式仅最后手段）— <https://docs.comfy.org/troubleshooting/overview>
- ComfyUI Model Issues（Missing Models 四步 / 报错信息结构 / 按用途分目录）— <https://docs.comfy.org/troubleshooting/model-issues>
- ComfyUI-Manager Issue #234（大模型下载中断）— <https://github.com/Comfy-Org/ComfyUI-Manager/issues/234>
- Ollama FAQ（`ollama ps` PROCESSOR 列 / 显存评估与跨卡分摊）— <https://docs.ollama.com/faq>
- SakuraLLM（显存需求表 / OneClickLLaMA 按显存档位给最优配置）— <https://github.com/SakuraLLM/SakuraLLM>
- GalTransl-7B-v2.6 模型卡（量化档位四元组说明）— <https://ollama.com/crosery/GalTransl-7B-v2.6>
- LM Studio Bug Tracker #1222（续传 → checksum 失败）— <https://github.com/lmstudio-ai/lmstudio-bug-tracker/issues/1222>
- HuggingFace 校验和说明 — <https://toolpry.com/blog/verify-ai-model-downloads-sha256-checksum> ; <https://discuss.huggingface.co/t/local-model-backups/171119>
- Fooocus 性能档位 — <https://localaimaster.com/blog/fooocus-guide>

**UX 权威来源**
- NN/g Progressive Disclosure — <https://www.nngroup.com/articles/progressive-disclosure>
- NN/g The Power of Defaults — <https://www.nngroup.com/articles/the-power-of-defaults>
- NN/g Error-Message Guidelines — <https://www.nngroup.com/articles/error-message-guidelines>
- NN/g 4 Principles to Reduce Cognitive Load in Forms — <https://www.nngroup.com/articles/4-principles-reduce-cognitive-load>
- Primer Progressive disclosure — <https://primer.style/product/ui-patterns/progressive-disclosure>
- Microsoft Learn 错误处理指南 — <https://learn.microsoft.com/en-us/dynamics365/business-central/dev-itpro/developer/devenv-error-handling-guidelines>
- GOV.UK Design System — <https://design-system.service.gov.uk/components/task-list>

**中文实战教程（二手，用于交叉印证交互细节）**
- BallonsTranslator 上手指南（右键文字框 → 翻译）— <https://ivonblog.com/posts/ballonstranslator-usage>
- BallonsTranslator 使用教學（OCR 切换 / 修复画笔 / 透明度拉杆）— <https://the-walking-fish.com/p/ballonstranslator>
- 日漫机翻经验谈(3)之BallonsTranslator — <https://zhuanlan.zhihu.com/p/1933323550409880762>
- 日漫机翻经验谈(7)之manga-translator-ui — <https://zhuanlan.zhihu.com/p/1986202736191116006>
- manga-image-translator 全离线翻译方案（`--use-gpu-limited` / 降 `inpainting_size`）— <https://blog.csdn.net/gitblog_00134/article/details/151772100>

---

*调研时间：2026-09-12 · 频道：agent-reach（GitHub 检索）+ web_search（Bing 主力，Tavily 多次超时后自动回退）*
