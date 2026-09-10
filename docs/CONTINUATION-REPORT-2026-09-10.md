# VeneraX 开发接续报告

> **生成时间**：2026-09-10 13:28 +0800
> **覆盖对话范围**：`d1db429`（09-09 04:23）→ `5ea202a`（09-10 12:36），共 **54 个提交**
> **区间起点为推断**：依据是对话摘要中提到的缺陷名与本区间提交 message 一一对应（例："S1 overflow 未经测试" ↔ `d1db429`，"日文 fixture 与自身清单不符" ↔ `67e763a`，"analyze 门恒为零" ↔ `ec924a4`，"headless 挂住 CI" ↔ `e59cece`）。**更早的 09-08 及之前提交属于上一次会话，本文不覆盖（对话中未记录）。**
> **HEAD 状态**：`5ea202a`，工作树干净（`git status --porcelain` 输出为空）。
> **注意**：本仓库文档目录是 `doc/`（单数）。本报告按指令写入 `docs/`（新建），是仓库里唯一的 `docs/` 目录 —— 新会话找文档时**请同时看 `doc/` 与 `docs/`**。

---

## 《新会话接续卡》（≤30 行）

**当前状态**
- HEAD `5ea202a`；工作树**干净**；领先上游 `Kyosee/VeneraX` **77** 个提交，**未落后**。
- 最新云端全量验证 = run `34438083165`（@`5ea202a`）：`Test: success` + `Build_Windows: success`，`executed 1329 / passed 1329 / failed 0 / skipped 1 / flutter test exit 0`，守卫 `GUARD PASS`。
- 可测产物：`E:\Gemini\VeneraX-latest\`（41.9 MB zip 解出，含 `venera.exe` + `DirectML.dll`）。
- 已知未完成：KV-cache 解码器导出（等价性门禁拦住，见 §7）；墨迹判据默认关闭待真机验证；准确率无 ground truth。

**下一步第一个动作（按优先级）**
1. **收用户实测反馈**：让用户用 `E:\Gemini\VeneraX-latest\venera.exe` 重翻一话，抓三行日志：`OcrFunnel page=…`、`BlockFunnel page=… skippedAsTarget=… modelDropped=…`、`OcrInk page=… rejected=…`。日志位置：`%APPDATA%\io.github.kyosee\venera\logs.txt`。
2. **或**修 KV 导出：`tool/export_decoder_kv.py` + `.github/workflows/export_decoder_kv.yml`，等价性 4/5 失败（细节见 §7）。
3. **或**继续做 Phase 15（保存"AI 翻译后漫画"+ 侧栏专区），设计见 `doc/AI_TRANSLATION_PHASE3_PLAN.md` §3.5，**代码未开始**。

**必读文件**
- `doc/AI_TRANSLATION_PHASE3_PLAN.md`（计划、验收门、决策）
- `doc/ocr-baseline.md`（基线 B0/B1、D-15/D-16 记录）
- `doc/decoder_kv_export.md`（KV 导出怎么做、失败怎么查）
- `docs/CONTINUATION-REPORT-2026-09-10.md`（本文）
- `lib/foundation/image_translation/`（23 个文件，全部核心逻辑）

**构建与验证命令（云端，唯一允许的验证方式）**
```bash
cd /e/Gemini/VeneraX
gh workflow run main.yml -R Animal2404/VeneraX --ref master -f platform=windows -f ort_edition=directml
gh run list -R Animal2404/VeneraX --workflow main.yml --limit 1
gh workflow run main.yml -R Animal2404/VeneraX --ref master -f platform=test   # 只跑测试，不构建
```

**关键约定与约束（用户明令）**
- **禁止本地 `flutter test` / `flutter build` / `dart test`**（用户三次强调）。验证一律走 GitHub Actions。
- **红线**：`cacheKeyFor` / `renderedKey` / `InpaintMode.token` 冻结（改了会导致旧渲染缓存不失效）；`PipelineMode` 出厂默认必须保持 `freeVram`；FFI 只允许在 worker isolate 内（R3）。
- 子代理**禁止 git 写**、禁止碰别人的文件；交付必须声明"未编译验证"。

**待用户拍板**
1. KV-cache 导出是否继续投入（收益上限约整章 20%，不改准确率）。
2. 墨迹边界开关（`imageTranslationInkBoundarySplit`）是否改默认开启。
3. 是否需要准确率门 G4-acc（需用户提供人工标注真实页）。

---

## 1. 本次对话的变更集

> 全部条目均已 **commit 并 push**（工作树干净为证：`git status --porcelain` 空）。本节末尾单列"未提交 / 仅讨论过"的内容。

### 1.1 排版与渲染（用户肉眼可见的缺陷）

| # | 目标 | 改动文件 | 现状 | 依据 |
|---|---|---|---|---|
| 1 | 消除"文字叠字/双重绘制" | `page_renderer.dart`（`resolveRegionCollisions`） | 完成 | `d9acefa` |
| 2 | "让位"分支永远不可能触发（把自己的障碍物算作障碍） | `page_renderer.dart`（`_pushClears`） | 完成 | `6a2a998` |
| 3 | 竖排标点、CJK 换行、4px 文字不再静默绘制 | `page_renderer.dart`、`vertical_typesetting.dart` | 完成 | `cfbd65c` |
| 4 | 描边计入排版预算、同组字号统一 | `page_renderer.dart` | 完成 | `c27900e` |
| 5 | **黑色色块真因**：底色判据数的是"暗像素覆盖率"，网点墨点本身就是暗像素 ⇒ 浅灰网点底被判深色 ⇒ 启用黑描边 ⇒ 相邻 CJK 字熔成黑斑 | `page_renderer.dart`（`backgroundReadsDark` + 新增 `_blurredLum`） | 完成，5 条反向测试锁住"真黑气泡仍走黑底分支" | `bb91581`；测试 `test/ocr_layout_solid_dark_background_test.dart` |
| 6 | 消解 pass 以前对"还原区"视而不见 ⇒ 译文压在原文上 | `page_renderer.dart`（`restores()`/`blocks()`/`yieldToRestore`/`settle`） | 完成，patch 模式逐字节等价有测试锁 | `f4b5356`；测试 `test/ocr_layout_restore_overlap_test.dart` |
| 7 | 网点底让"黑块防回退"判据自我缴械（环判据被点覆盖率骗过） | `inpaint.dart`（环感知亮度 <60 + `_solidDarkShare` 纹理修正）、`translation_pipeline.dart` | 完成 | `f4b5356`；测试 `test/inpaint_screentone_dark_mass_test.dart` |
| 8 | 擦除台账永远打印（`describeLedger`） | `inpaint.dart`、`translation_pipeline.dart`、`translation_service.dart` | 完成（补齐 cache-hit / patch / no-regions 分支） | `b456079`、`66b0abd` |

### 1.2 OCR 正确性与可观测性

| # | 目标 | 改动文件 | 现状 | 依据 |
|---|---|---|---|---|
| 9 | 漏斗仪表：让"漏识别"可归因（四条恒等式 + 每页一行） | `translation_worker.dart`（`OcrPageFunnel`）、`translation_pipeline.dart`、`pre_translation_tasks.dart` | 完成 | `6df6f71`；测试 `test/ocr_funnel_test.dart`（26 例） |
| 10 | 失败页不再冒充"已识别"（遥测诚信） | `pre_translation_tasks.dart`（拆 `settledProcessed`/`recognizedProcessed` + 纯函数 `sweepPageAccounting`） | 完成 | `66b0abd`；测试 `test/pre_translation_sweep_accounting_test.dart` |
| 11 | `recLinesDropped` 在 Pass B 双计 | `translation_worker.dart`（`_ClusterWork.linesTallied`） | 完成 | `66b0abd`；测试 `test/ocr_funnel_line_tally_test.dart` |
| 12 | `backgroundReadsDark` 短 buffer 越界（RangeError 窗口） | `page_renderer.dart`（守卫按 `min(bottom+probe, h)` 收紧） | 完成 | `66b0abd`；测试 `test/ocr_background_probe_guard_test.dart` |
| 13 | **Pass B 死兜底**：`item.engine` 只在成功时赋值 ⇒ `=='ja'` 恒假 ⇒ 被日文引擎拒的簇永不试通用引擎，还白烧一次解码 | `translation_worker.dart`（新增 `attemptedWith` + 纯函数 `planPassBFallback`） | 完成，3072 例穷举对照（旧代码复刻为 oracle） | `5ea202a`；测试 `test/ocr_pass_b_fallback_test.dart`（28 例） |
| 14 | 静默丢弃可见化：同语言跳过、模型漏 id/回抄、`hasOcr` 把 DB 异常读成"没缓存"、`_notifyDone` 吞异常 | `translation_pipeline.dart`、`translation_service.dart`、`translation_store.dart`、`ocr_fingerprint.dart` | 完成 | `b456079`、`66b0abd`；测试 `test/translation_silent_drop_test.dart`（21 例） |
| 15 | 指纹从"只看字节长度"改内容哈希（否则换同尺寸模型后旧译文永久命中） | `ocr_fingerprint.dart`（`_stampFile` 用 `statSync` 定哨兵 + 采样哈希） | 完成。**代价：既有 OCR 缓存失效，需重识别一次（不花 LLM 请求）** | `b456079`；测试 `test/ocr_fingerprint_hash_test.dart`（12–14 例） |
| 16 | 墨迹边界判据（唯一能切开"两气泡融合"的信号） | `translation_worker.dart`（`ocrInkGap`）、`translation_performance_config.dart`、`pages/settings/reader.dart` | 完成但**默认关闭**（`imageTranslationInkBoundarySplit=false`），无论开关都打 `OcrInk` 日志 | `686c3aa`；`60af3d7` 修状态机；测试 `test/translation_ink_boundary_test.dart` |

### 1.3 性能

| # | 目标 | 改动文件 | 现状 | 依据 |
|---|---|---|---|---|
| 17 | 解码批不再被识别滑条钳住（8→16），长行聚簇减少 pad 步 | `ocr_batching.dart`（`resolveDecBatch`/`decDecodeOrder`/`driveDecode`）、`translation_worker.dart` | 完成 | `5e31c31`；测试 `test/manga_dec_batch_equivalence_test.dart` |
| 18 | 阶段一 sweep 重叠、perf 行真正可加 | `translation_worker.dart`、`pre_translation_tasks.dart` | 完成 | `8a2e893` |
| 19 | 滑条显示 2.0 被当"不可解析"而实际跑 1（UI 说谎） | `translation_performance_config.dart`（`_intSetting` 接受 `num`） | 完成 | `2b2e69c` |
| 20 | 建议函数读环境应来自入参而非全局（`App.isDesktop`） | `translation_performance_config.dart`（`advise({isDesktop,…})` + `AdviceBasis`） | 完成 | `b159408` |
| 21 | 阅读器复用已存 OCR，不再重跑 GPU | `translation_service.dart` 等 | 完成 | `9dde004` |

**实测基线（对话中测量，非估算）**
- 日文 OCR 每页中位 **3897 ms**：`det 1060 / recGpu 907 / dec 1917（49%）/ rest 13.5`；恒等式 20/20 成立（依据：从 `logs.txt` 20 个批次统计）。
- 整章墙钟拆分：**LLM 82–90%**、OCR ≈ 41%（37 页 ≈144 s）。LLM 耗时样本 min 31.7 s / 中位 67.4 s / max 100.4 s（4 页一组）⇒ 波动是 API 侧。
- GPU 12% 占用有**两个**原因：① OCR 先跑完，之后纯等网络；② OCR 内部解码占 49%，每步是极小推理且无 KV cache（模型导出限制）。

### 1.4 进度显示与导航

| # | 目标 | 改动文件 | 现状 | 依据 |
|---|---|---|---|---|
| 22 | 三阶段各自速率 + 独立刷新时钟 + 结束后保留数据 | `pre_translation_tasks.dart`、`tasks_page.dart` | 完成 | `ae1c818`、`6df6f71` |
| 23 | 同一卡片同时显示 `16.8 页/分钟` 与 `15727 毫秒/页` 自相矛盾（并发下把区间相加） | `pre_translation_tasks.dart`（`throughputSecondsPerPage`）、`tasks_page.dart` | 完成：改为"吞吐 X 秒/页 + 组内延迟 Y 毫秒/页"两个各有其名的数 | `bb91581`；`ab106d0` 修 1000 倍单位错（`60000/stable`→`60/stable`） |
| 24 | 侧栏 AI 翻译入口 + 选中态唯一 + 不重复压页 | `components/navigation_bar.dart`、`pages/main_page.dart`、`settings/settings_page.dart` | 完成；补 `Semantics(button/selected)` + wordmark `Flexible` 修 6.8px 溢出 | `1fc07be`、`17c747f`、`ab106d0` |

### 1.5 模型与工具链

| # | 目标 | 改动文件 | 现状 | 依据 |
|---|---|---|---|---|
| 25 | ONNX 读取器 graph input/output 字段号写反 | `local_model_import.dart` | 完成 | `9e50326`；测试 `test/native_api_guard_test.dart` 等 |
| 26 | 输出 dtype 断言、类数漂移报告 | `ort_*`、`local_model_import.dart` | 完成 | `df2ed38` |
| 27 | 每个模型路径一个 session、det/dec 共享 OOM 阶梯 | `translation_worker.dart` | 完成 | `10e0e60` |
| 28 | 本地模型文件免 FFI 校验 + 打开模型文件夹 | `local_model_import.dart`、设置页 | 完成 | `b82f18d` |
| 29 | 英/韩识别器钉 CPU（D-15） | `translation_worker.dart` | 完成；**但对话中已退回该归因**（见 §4） | `13d06b2`、`f826a9a` |
| 30 | 云端导出带 KV cache 的解码器 + 逐步等价性门禁 | `tool/export_decoder_kv.py`(1125 行)、`.github/workflows/export_decoder_kv.yml`(145 行)、`doc/decoder_kv_export.md` | **未通过**：门禁抓到 4/5 用例不一致，按设计拒绝上传 artifact | `c981e6c`；失败 run `34352623416` |

### 1.6 CI / 测试基础设施（本对话影响最大的一项）

| # | 目标 | 改动文件 | 现状 | 依据 |
|---|---|---|---|---|
| 31 | analyze 门因 Flutter 3.47 改了分隔符而恒计零 | `analyze.yml` | 完成 | `ec924a4`、`c60bd28` |
| 32 | headless 测试挂住 CI | `test/headless*`、`lib/headless.dart` | 完成 | `e59cece` |
| 33 | **Test job 只跑 33/138 个测试文件（105 文件 / 789 用例从未在任何 CI 执行）** | `.github/workflows/main.yml` | 完成：改为跑全量 `flutter test`、加 `pull_request` 触发、恢复"未登记测试即失败"守卫、加"最小执行用例数"下限 | `3537bc6`、`295131c`、`f0e1435e` 派生的 `8f2d67f` |
| 34 | 全量测试日志在结束前不可见（stdout 重定向进文件）⇒ "慢"与"死"无法区分 | `main.yml`（30 s 心跳） | 完成 | `8564854`、`d28ea8f` |
| 35 | 退出码异常（全绿但 `flutter test` exit 1）无法定位 | `main.yml`（`TestBisect` 二分 job）、`tool/ci/check_test_run.dart`（`PROCESS-TEARDOWN` 判定） | 完成；**该现象在后续 run 中未复现** | `8f2d67f`；测试 `test/ci_guard_teardown_verdict_test.dart` |

### 1.7 未提交 / 仅讨论过（**新会话注意**）

- **工作树干净**：`git status --porcelain` 输出为空（2026-09-10 13:28 核查）。**没有任何改动只躺在工作区。**
- **仅讨论、未落地**：
  - **Phase 15「保存 AI 翻译后的漫画 + 侧栏专区」**：设计写在 `doc/AI_TRANSLATION_PHASE3_PLAN.md` §3.5（`translated/<comic>/<chapter>/NNN.png`、PNG-only、显式"保存本章"、`manifest.json`），**代码一行未写**。依据：对话中该需求由用户提出，此后全部精力用于修缺陷。
  - **气泡分割模型接入**：候选 ONNX 存在（`NeuronCState/manga109-segmentation-bubble-onnx` 等），但 **Manga109 数据集仅限非营利学术使用** ⇒ 不能随应用分发。依据：对话中的 license 核查结论；**未再验证**。
  - **`doc/AI_TRANSLATION_PHASE3_PLAN.md` 内的 Phase 13 部分修复项**：F13.1（跨气泡融合）已证明"几何口径无解"并改用墨迹判据（已落地但默认关）；F13.4 未做。
  - **`--offline` 零外发证明**：审计结论是"今天零外发"成立，但**理由是那段路径恰好没 socket，不是被禁网**（`headlessOffline` 全库只有两处被读，都是写报告）。**未修**。

---

## 2. 与上游的关系

**上游**：`https://github.com/Kyosee/VeneraX.git`（GPL-3.0）。本仓库 `origin` = `https://github.com/Animal2404/VeneraX.git`。

**差距**（2026-09-10 核查）：领先上游 **77** 个提交，**落后 0**。上游 `master` 最新为 `8163166` "chore: 更新 AltStore 安装清单至 v2.3.2"（2026-09-05）。

**差异清单与动机**（按主题）

| 主题 | 相对上游的主要差异 | 动机 |
|---|---|---|
| AI 翻译（最大差异） | 新增 `lib/foundation/image_translation/` 整个目录（23 文件）：ONNX 推理、OCR、（无）翻译、排版融合、擦除 | 上游无此功能 |
| 推理后端 | 纯 `dart:ffi` 绑定 + DirectML EP，无 Python/PaddlePaddle/PyTorch 运行时 | 用户硬约束：不得引入 Python 运行时 |
| headless CLI | `lib/headless.dart` + `lib/headless_cli.dart`，含 `--offline`、`ocr-selfcheck`、`ocr-golden` | 用于无 GUI 的批量验证与离线证明 |
| 漫画源运行 | 未改动上游的 JS 引擎（`lib/foundation/js_engine.dart`、`assets/init.js`） | 无需求 |
| CI | `main.yml` 由"白名单 33 个测试文件"改为"全量 + 守卫 + PR 触发"；新增 `export_decoder_kv.yml` | 上游 CI 不覆盖这些测试 |
| Rust | `rust/` 目录**不存在于本仓库**（`ls rust/` 无输出） | 上游部分功能依赖 Rust；本仓库当前不构建 Rust 组件 |

**上游跟进策略**：本次对话**未执行任何上游合并**（`git log HEAD..upstream/master` 为空，即未落后；但也没有新的上游提交可跟进）。建议：合并前先在 `git log --oneline upstream/master..HEAD` 检查 77 个提交里哪些触碰了同文件（`lib/foundation/image_translation/` 全部是新增，冲突面小；`navigation_bar.dart`、`tasks_page.dart`、`translation.json` 是**高风险**，上游若改过这些文件会冲突）。

**不适合回授上游的改动**：
- `docs/CONTINUATION-REPORT-*.md`（本报告，含本机路径 `E:\Gemini\...`）。
- `test/` 下与 AI 翻译强绑定的套件（上游无该功能）。
- `.github/workflows/export_decoder_kv.yml`（依赖用户的模型选择）。
- 任何带本机绝对路径的脚本。

**GPL-3.0 义务与注意事项**：
- `LICENSE` = GNU GPL v3（已核对文件头）。
- 分发（含 AltStore/侧载、Release 附件、编译产物）**必须**：① 附带完整对应源码（含 `rust/` 若恢复、`assets/init.js`、所有 patch）；② 保留版权声明与许可原文；③ 修改过的文件需标注改动；④ 不得对下游附加额外限制。
- **注意**：本项目已有 `altstore-source.json` / `altstore-source-beta.json`，即对外分发渠道 ⇒ 上述义务是实际义务，不是纸面要求。
- `assets/translation.json` 等资源文件若来自第三方，需保持其原始许可（**本次未逐项核查，标为待办**）。

---

## 3. 仓库结构与文件地图

| 路径 | 作用 | 本次是否改动 | 状态 |
|---|---|---|---|
| `lib/main.dart` / `init.dart` | App 入口与初始化 | 间接（无直接改动） | 稳定 |
| `lib/foundation/` | 核心领域层：漫画源、JS 引擎、网络、存储、AI 翻译 | **是**（`image_translation/` 大量） | 活跃开发 |
| `lib/foundation/image_translation/` | **AI 翻译全部逻辑**（23 文件）：`translation_worker.dart`(≈4200 行，OCR+ONNX)、`page_renderer.dart`(排版融合)、`inpaint.dart`(擦除)、`translation_pipeline.dart`、`translation_service.dart`、`pre_translation_tasks.dart`、`translation_store.dart`、`ocr_batching.dart`、`ocr_fingerprint.dart`、`local_model_import.dart`、`ort_ffi.dart`、`llm_translator.dart` 等 | **是（本对话主战场）** | 活跃开发；测试覆盖 1329 例全绿 |
| `lib/pages/` | UI 页面（主页、阅读器、设置、任务页等） | **是**（`tasks_page.dart`、`settings/reader.dart`、`main_page.dart`、`settings/settings_page.dart`） | 稳定 |
| `lib/components/` | 复用组件（导航栏、JS UI、窗口框等） | **是**（`navigation_bar.dart`） | 稳定 |
| `lib/network/` | 网络层（下载、漫画源请求） | 否 | 稳定 |
| `lib/utils/` | 工具（同步、数据库、日志等） | 否 | 稳定 |
| `lib/headless.dart` / `headless_cli.dart` | 无 GUI 命令行（`--offline`、`ocr-selfcheck`、`ocr-golden`） | 是（`e59cece`、`18fd135`） | 可用 |
| `rust/` | Rust 组件（上游用于部分能力） | **不存在**（`ls rust/` 无输出） | 未使用 |
| `assets/` | 资源：`init.js`（漫画源引导）、`translation.json`（i18n，zh_CN/zh_TW 各 1448 键）、`opencc.txt`（简繁转换表）、图标 | **是**（`translation.json` 多次加键） | 稳定 |
| `assets/init.js` | 漫画源 JS 运行时引导 | 否 | 稳定 |
| `test/` | 146 个 `*_test.dart` | **是**（新增约 20 个套件） | **全部在 CI 执行（守卫保证）** |
| `tool/` | 开发工具：`ci/check_test_run.dart`（测试守卫）、`export_decoder_kv.py`、`fetch_ort_runtime.py`、`gen_*` 生成器 | **是** | 活跃 |
| `doc/` | 文档：`AI_TRANSLATION_PHASE3_PLAN.md`、`ocr-baseline.md`、`decoder_kv_export.md`、`js_api.md`、`headless_doc.md` 等 | **是** | 活跃 |
| `docs/` | **本报告所在目录（新建）** | 是（新建） | 仅本报告 |
| `.github/workflows/` | `main.yml`（构建+测试）、`analyze.yml`（静态门）、`export_decoder_kv.yml`（模型导出）、`symbolicate_ios.yml`、`delete_old_workflows.yml` | **是**（前三个） | 活跃 |
| `windows/` `android/` `ios/` `linux/` `macos/` `debian/` | 各平台工程 | 否 | 未验证（见 §6） |
| `patch/` | 补丁资源（`font.dart` 等） | 否 | 稳定 |
| `release-notes/` | 发布说明 | 否 | 稳定 |
| `shaders/` | 着色器 | 否 | 稳定 |
| `windows/build.py` | Windows 构建脚本（**`GIT_SHA` 注入点，对话中提到未做**） | 否 | 待办 |
| `altstore-source*.json` | AltStore 分发清单 | 否 | 稳定（⇒ 对外分发，GPL 义务生效） |

---

## 4. 开发历程时间线

> 时间取自 `git log --date=format:"%m-%d %H:%M"`；"结论"列的"依据"指提交或对话中的核查结论。

| 阶段 | 做了什么 | 关键产出 | 结论 / 弯路 |
|---|---|---|---|
| **09-09 04:00–05:00** 基线 | 记录 B0 基线；给已发布的 S1 溢出策略补测试；撤回自己的 D-15 归因 | `3a3ad10`、`d1db429`、`f826a9a` | **弯路**：D-15（英/韩识别器性能问题归因于 CPU pinning）**被自己的测量推翻** —— `f826a9a` 的 message 明写 "retract my own D-15 attribution — the measurement falsified it"。"离线归因"也曾被撤回 |
| **09-09 05:00–06:00** 模型与推理 | 模型文件免 FFI 校验、每模型路径一个 session、OOM 阶梯、输出 dtype 断言 | `b82f18d`、`10e0e60`、`df2ed38`、`c27900e`、`9dde004` | 完成。**弯路**：D-15 的 CPU pinning 实现里 `path.replaceAll(r'\','/')` 丢了反斜杠 ⇒ **pin 从第一天就是死代码**（对话记录，未记录修复提交） |
| **09-09 08:00–09:00** CI 门禁 | analyze 门因 3.47 改分隔符而恒计零；headless 测试挂住 CI | `ec924a4`、`c60bd28`、`e59cece`、`df5a850` | **弯路**：门打印 `errors=0 warnings=0 info=0` 而实际有 12 个问题 —— 假绿。修法：`grep -cE "^ *error +([-•]) "` + "无汇总行即失败"。**headless 挂起**根因是测试里 `Process.runSync` 起子 VM ⇒ 改纯函数断言后 16 秒跑完 |
| **09-09 09:00–13:00** 排版主战场 | 阶段一 sweep 重叠、perf 行可加、叠字消解、黑晕、取消释放显存、侧栏三修、性能预设、建议函数纯度 | `8a2e893`、`d9acefa`、`104a743`、`6a2a998`、`4ef0424`、`2b2e69c`、`17c747f`、`b159408` | 完成。**弯路**：① 曾以为黑块是"擦除失败留黑"⇒ 错，实为描边选色；② 曾以为叠字是"双重绘制"⇒ 错，实为 worker 层聚类把相邻气泡并成一块；③ `_intSetting` 只接受 `int`，JSON 往返 `2.0`→`int.tryParse("2.0")`=null⇒回退 1（UI 显示 2 引擎跑 1） |
| **09-09 13:00–19:00** 性能与仪表 | 解码批解绑识别滑条、三阶段速率、刷新时钟、OcrFunnel、D-16 记录 | `ae1c818`、`5e31c31`、`6df6f71`、`654acbb` | 完成。**弯路**：`_parsePerfLog` 的正则 `key[:{](\d+)` 会先匹配到 `batch={det:1,rec:8}` ⇒ detMs/recMs 报的是**批上限**而非耗时（记为 D-16）。我的替代正则被自己回退（插值后返回 null，未定位） |
| **09-09 19:00–22:00** 用户实测反馈轮 | 用户报"更慢 + GPU 闲 + 黑块仍在 + 两气泡叠字 + 一行日文没翻"；测量证明慢在 LLM API（82–90%）；黑块真因（描边选色）修复；进度数字自洽；静默丢弃可见化 | `9823a8b`、`bb91581`、`686c3aa`、`b456079` | 完成。**关键测量**：LLM min 31.7 / 中位 67.4 / max 100.4 秒每 4 页 ⇒ 3 倍波动，"变慢"是 API 方差 |
| **09-09 20:00–23:00** CI 大改 + 12 缺陷 | Test job 从 33 文件白名单改全量；首跑暴露 **15 个真失败**（12 旧 + 3 新）；逐个修 | `3537bc6`、`295131c`、`ab106d0`、`08c5e03`、`66b0abd` | 完成。**弯路**：① 我加的守卫用 bash 写在 pwsh runner 上 ⇒ `ParserError` 把整个 job 弄红，我**选择删守卫**（`a5ddd31`）而不是改写成 pwsh —— 等于拆了自己刚立的规矩；② **我把 workflow YAML 弄坏两次**（`run: \|` 内容缩进需 10 空格，我用了 8）⇒ GitHub 解析不出 `workflow_dispatch`，报 "Workflow does not have trigger"；③ 一次派了 20 分钟测试却没先读 23 秒的 `analyze` 结论（编译错早已报出） |
| **09-09 22:00–23:00** 编译错连锁 | `stored` 声明在 `try` 块内、在 `catch` 后使用 ⇒ **109 个用例编译失败**（import 该文件的全挂） | `0d2e196` | 根因：Dart `try` 局部作用域不外泄。修法：声明提到 `try` 之前 |
| **09-09 23:00–23:40** 收尾与诊断 | 心跳（慢/死可辨）、`TestBisect` 二分 job、`PROCESS-TEARDOWN` 判定 | `d28ea8f`、`8f2d67f` | **全绿达成**：run `34435406353` @`8f2d67f` `Test: success` + `Build_Windows: success` |
| **09-10 12:00–13:00** 最后一条用户可见缺陷 | Pass B 死兜底（见 §1.2 #13） | `5ea202a` | 完成。**全绿复现**：run `34438083165` `executed 1329 / passed 1329 / failed 0 / exit 0` |

**弯路清单（新会话最易重蹈）**
1. 黑块 ≠ 擦除失败（`rolled_back=0` 就是反证）。
2. 叠字 ≠ 双重绘制（是聚类把相邻气泡并簇）。
3. "变慢" ≠ 代码退化（先算 LLM 占比，再怀疑代码）。
4. 编译错会伪装成"测试大面积失败"（109 例）—— 先看 `analyze`，别先看测试。
5. `flutter test` 全绿 ≠ 退出码为 0（本仓已加守卫拦住）。
6. 本地跑 `flutter analyze` 会让多个代理互相抢 CPU（用户实测卡几分钟）⇒ 已禁止本地验证。
7. workflow YAML 缩进：`run: |` 下的内容必须**一致缩进**，插一段 8 空格进去会提前终结字面块。

---

## 5. 关键决策与取舍

| 决策 | 备选方案 | 为什么选它 | 代价 | 可逆 |
|---|---|---|---|---|
| 纯 `dart:ffi` 绑 ONNX，不用 Python/PaddleOCR 运行时 | 打包 Python + PaddlePaddle | 用户硬约束；单一进程、无解释器开销 | 需手写 FFI 与张量管理；模型必须导成 ONNX | 低（已深度绑定） |
| 排版融合自己做（擦除 + 重绘）而非整页重排 | 整页重绘 | 保留画风与气泡线 | 需自己解重叠/避让/描边 | 中 |
| 跨气泡融合**不用几何阈值**（已证明无解） | 组半径 / 全链 / 间距离群 | 算术证明：必须保住的旁白间距 1.00×行厚 > 必须切开的融合间距 0.57×行厚 ⇒ 任何阈值先切碎旁白 | 只能用像素判据（墨迹），需真机验证 | 是（新判据默认关闭） |
| 墨迹判据**默认关闭** | 默认开启 | 未在真图验证过；开关关闭时逐字节等价（有 identity 测试） | 用户需手动开才能受益 | 是 |
| 指纹改**内容哈希** | 保持"字节长度" | 长度不变即碰撞 ⇒ 换同尺寸模型后旧译文永久命中（静默错误） | 既有 OCR 缓存全部失效，需重识别一次 | 是（但会造成一次性重算） |
| Test job 跑**全量**而非白名单 | 扩白名单 | 白名单已验证会导致"新测试永远不跑"（105 文件/789 用例从未执行） | CI 时长从 ~5 分涨到 ~20 分 | 是 |
| 守卫遇到"全绿但 exit 1"**判红** | 判绿 | 否则真崩溃会被"全绿"掩盖 | 偶发误红（本次未复现） | 是 |
| **禁止本地 flutter test/build**（用户明令） | 允许本地跑 | 用户实测本地 analyze 卡机器数分钟；多个代理并发更糟 | 编译错只能等云端发现（曾白等 20 分钟） | 是（需用户同意） |
| 子代理**禁止 git 写** | 允许各自提交 | 曾发生"我让代理 checkout 一个文件，它顺手 check 掉了别人 155 行未提交改动" | 父代理成为提交瓶颈 | 是 |

---

## 6. 构建、运行与验证

**工具链要求**（依据 `pubspec.yaml`）
```
sdk: '>=3.12.0 <4.0.0'
flutter: '>=3.44.3 <4.0.0'
```
CI 使用 `subosito/flutter-action@v2`、`channel: stable`、`architecture: x64`（**未固定具体版本号**；对话中观察到 runner 上是 `stable-3.47.2`）。本机 Flutter 为 `3.44.9`（对话中由某代理核对）。

### 6.1 本地静态分析（**唯一允许的本地命令**）
```bash
cd /e/Gemini/VeneraX
flutter analyze --no-pub lib/ test/
# 期望：0 error / 0 warning；基线 7 条 info（prefer_initializing_formals，
# 均在 comic_state_repository.dart / webdav_library.dart / continuous_page_turn_coordinator.dart）
```
**注意**：用户明令**不要**跑本地测试/构建。且实测多代理并发跑 analyze 会把机器卡住数分钟。

### 6.2 云端验证（**唯一被认可的验证方式**）
```bash
# 只跑测试（约 20 分钟，含 30 s 心跳）
gh workflow run main.yml -R Animal2404/VeneraX --ref master -f platform=test

# 测试 + Windows 构建（约 30 分钟，产出可测 artifact）
gh workflow run main.yml -R Animal2404/VeneraX --ref master -f platform=windows -f ort_edition=directml

# 二分诊断（定位"卡住/退出码异常"的测试文件）
gh workflow run main.yml -R Animal2404/VeneraX --ref master -f platform=bisect

# 读结果
gh run list -R Animal2404/VeneraX --workflow main.yml --limit 1
gh run view --job=<Test job id> -R Animal2404/VeneraX --log      # 全量日志
gh run view --job=<job id>   -R Animal2404/VeneraX --log-failed  # 仅失败
gh run download <run-id> -R Animal2404/VeneraX -n windows_build  # 取产物
```
**守卫会打印的四个数**（判定收口的标准）：
```
executed cases / passed / failed / skipped / flutter test exit
GUARD PASS: every on-disk test file executed at least one case,
            no unexcluded failure, executed-case floor met.
```
最新实测（run `34438083165` @`5ea202a`）：`1329 / 1329 / 0 / 1 / 0` + `GUARD PASS`。

### 6.3 平台构建状态

| 平台 | 命令 | 是否真的验证过 | 说明 |
|---|---|---|---|
| **Windows** | `gh workflow run main.yml -f platform=windows -f ort_edition=directml` | **是**，多次成功（最新 `34438083165`） | 产物 41.9 MB zip，含 `venera.exe` + `DirectML.dll`。构建日志里有 rhttp/cargokit 的 `Get-Item : Could not find item ...AppData` —— **已在一次成功的构建里确认同样出现**，属噪音不致命 |
| **Test（全量单测）** | 同上 `-f platform=test` | **是**，`1329/1329` 全绿 | 运行在 `windows-latest`，默认 shell 是 **PowerShell**（写 workflow 时注意） |
| Linux / macOS / iOS / Android | `-f platform=<name>` | **否**（对话中从未派发或核对） | `Build_*` job 存在但本次对话一律 `skipped`。**理论上能跑，未验证** |
| Rust 组件 | — | **不适用** | 本仓库无 `rust/` 目录 |
| headless CLI | `dart run lib/headless_cli.dart ocr-selfcheck`（**本地被禁**） | 部分（`delivery_check` 曾用于 CLI 产物） | `--offline` 与零外发：审计结论"成立但靠巧合"（见 §1.7） |

### 6.4 产物与用户侧验证路径
```bash
# 下载并解包到用户可运行位置
cd /e/Gemini && mkdir VeneraX-latest && cd VeneraX-latest
gh run download <run-id> -R Animal2404/VeneraX -n windows_build
python -c "import zipfile,glob;zipfile.ZipFile(glob.glob('*.zip')[0]).extractall('.')"
# 运行 venera.exe（需与 DirectML.dll 同目录）
```
**用户侧日志位置**：`C:\Users\<user>\AppData\Roaming\io.github.kyosee\venera\logs.txt`
**实验开关**：设置 → AI 翻译 → 「按墨迹边界拆分气泡（实验）」（默认关）
**重翻要求**：改了渲染/OCR 后，那一话必须点「重新翻译」（`renderedKey` 冻结 ⇒ 旧渲染缓存不会自动失效）。

---

## 7. 已知问题与技术债

### 7.1 已知未修（有证据、有影响）

| # | 问题 | 影响 | 证据 / 复现 | 优先级 |
|---|---|---|---|---|
| 1 | **KV-cache 解码器导出未通过等价性门禁** | OCR 里 49% 的解码开销（每步极小推理、无 KV cache ⇒ O(L²)）无法消除 | run `34352623416` 日志：`EQUIVALENCE FAILED: repetition_loop, long_line, batch_gt_1, shipped_reference_crosscheck`（5 例中 4 例不一致）；同时 `hf-mirror.com` 下载失败 `LocalEntryNotFoundError` 导致参考模型缺失 | 中（收益上限约整章 20%，不改准确率） |
| 2 | **墨迹判据未在真实页面验证** | 两气泡译文融合仍会发生（除非用户手动开开关，且开关效果未经证实） | `686c3aa` 落地、默认 `false`；`60af3d7` 修好状态机后，其自身合成 fixture 全绿；**真机数据未采集** | 高（用户第一号排版抱怨） |
| 3 | **F13.1 跨气泡融合只做了"探针"，没做"默认生效"** | 同上 | `doc/AI_TRANSLATION_PHASE3_PLAN.md` §2.5 结论 F13.1；算术证明"几何阈值无解"（必须保住的旁白 1.00×行厚 > 要切开的融合 0.57×行厚） | 高 |
| 4 | **准确率无 ground truth** | 无法自证"更准/更不准"，换模型缺判据 | 对话中提议 G4-acc 门（CER/WER 下限），**用户未提供人工标注真实页** | 中 |
| 5 | **`--offline` 零外发"靠巧合"** | 离线档的安全性是结构性的，不是强制的：`headlessOffline` 全库只有两处被读，且都是写报告，**没有任何一处用它拦网络** | 审计结论（对话中）；代码 `lib/headless.dart` | 低（当前无实际泄漏） |
| 6 | **D-16：`_parsePerfLog` 正则误匹配批上限** | 旧日志解析会把 `batch={det:1,rec:8}` 当成 `detMs`；`total_ms=` 从未匹配。已在新日志格式中用结构化 `GroupPerf` 规避，但**旧解析器本身未修** | `654acbb` 记录 D-16；`lib/headless.dart` | 低 |
| 7 | **`ort_output_dtype_test` 在 CI 上 9 例中约 8 例必然 skip** | 该文件的保护在 CI 上几乎不生效 | 审计结论：`_tryOpenOrt()` 只找 `.cache/ort/test_install` 与 `build/windows/.../Release`，而 `.gitignore:73` 忽略 `.cache/` ⇒ `ortReady=false` ⇒ 大量 `skip:` | 中 |
| 8 | **`golden_ocr_corpus_test` 近乎空转** | 只校验存在/许可/尺寸，**无哈希**、`*.expected.txt` 为 0 个 ⇒ "防静默编辑"的承诺实际不成立 | 审计结论；`headless_cli.dart:281` 的 baseline 是"同一次运行内互比" | 中 |
| 9 | **多平台构建未验证** | Linux/macOS/iOS/Android 是否可构建**未知** | 本次对话所有 run 的 `Build_Linux/MacOS/IOS/Android` 一律 `skipped` | 中 |
| 10 | **Windows `GIT_SHA` 注入未做** | 产物无法自证来源版本 | 对话中提到 `windows/build.py:11` 是注入点；**未实施** | 低 |
| 11 | **Phase 15（保存翻译后漫画 + 侧栏专区）未开始** | 用户明确要求的功能缺失 | `doc/AI_TRANSLATION_PHASE3_PLAN.md` §3.5 有设计；**代码零行** | 高（用户已提需求） |
| 12 | **气泡分割模型受许可阻塞** | 无法自动切分气泡 | `Manga109` 数据集**仅限非营利学术使用** ⇒ 候选 ONNX 权重不能随应用分发（对话中核查；**未再验证**） | 中 |
| 13 | **退出码 1 的偶发现象未定位** | 曾出现"全绿但 `flutter test` exit 1"，之后**未复现** | run `34364131841`：`passed 1298/1298` 但 `flutter test exit 1`、stderr 0 字节、`done.success=false`。已加 `TestBisect` 二分 job 与 `PROCESS-TEARDOWN` 判定（`8f2d67f`）备用 | 低（已设防） |
| 14 | **`recLinesDropped` 数值会因 Pass B 修复而上升** | 不是回退，是口径补齐 | `5ea202a` 报告：被 ja 拒的簇以前从未进 rec 分支，其 <8px 行现在才第一次被计量 | 提示项 |

### 7.2 未验证（不能算"已知问题"，但也**不能算"没问题"**）

| # | 项 | 为什么未验证 |
|---|---|---|
| a | Pass B 修复在**真机/真模型**上的效果 | 测试是纯 Dart 路由层 + 旧代码复刻对照（3072 例穷举），**没有跑过真实 ONNX 推理**（R3 下 GPU 代码不可在单测中驱动） |
| b | 墨迹判据的真实阈值（`inkColumnShare 0.8` / `inkRunHeightFactor 0.6` / `inkLumaFactor 0.45`） | 全部来自合成 fixture；需真机 `OcrInk` 日志的 `ink/run/bg` 分布 |
| c | `recFallbackSaved` 的产出是否**可读**（兜底可能引入误识别） | 需人工抽查真机日志/截图 |
| d | 取消任务后**显存是否真的回落** | 代码路径成立（`releasesPoolOnSweepEnd`），但物理释放需 Task Manager 证据；代码注释自认 "gate G2 未测" |
| e | 指纹改内容哈希后的**实际缓存失效规模** | 未在任何真机上跑过 |
| f | 用户端"黑块是否真的消失" | 判据 + 5 条反向测试已就位，但**没有收到用户对 `bb91581` 之后产物的截图确认**（用户在 `3b39f94` 之前给过反馈） |

---

## 8. 后续开发方向

### 近期（下一步该做的第一件事）

**第一件事：取一轮真机日志，把三个悬案一次定掉。**
- **目标**：拿到 `OcrFunnel page=…`、`BlockFunnel page=… skippedAsTarget=… modelDropped=…`、`OcrInk page=… rejected=…` 三行真实数据。
- **理由**：① 漏识别归因（哪一环丢的）② 那行没翻译的日文是"被当成目标语言跳过"还是"模型漏 id" ③ 墨迹判据的阈值是否合适 —— 三者都**只能**用真实数据判定，继续在合成 fixture 上调整是空转。
- **依赖**：用户用 `E:\Gemini\VeneraX-latest\venera.exe` 重翻一话；日志在 `%APPDATA%\io.github.kyosee\venera\logs.txt`。
- **验收标准**：三行日志到手，且能对每条给出"是/否命中"的结论；据此决定墨迹开关是否改默认开启。
- **风险**：用户可能没空；日志量大需筛选。
- **预估**：用户侧 10 分钟；分析 1 小时。

**紧随其后（按用户已明确的需求排序）**
2. **Phase 15：保存 AI 翻译后的漫画 + 侧栏专区**（用户明确要求，设计已在 `doc/AI_TRANSLATION_PHASE3_PLAN.md` §3.5：`translated/<comic>/<chapter>/NNN.png`、PNG-only、显式「保存本章」、`manifest.json` 记录 cacheKey/lang/fingerprint/time、**不自动写盘**）。验收：保存后重启 App 仍能从侧栏"AI 翻译"专区打开；未点保存时不产生任何文件。预估 1–2 天。
3. **KV 导出修复**：先解决 `hf-mirror` 下载失败（回退 `huggingface.co`，runner 可达），再查 4 例不等价的根因（`position_ids`/全 1 mask/动态 past 长度）。验收：5 例逐步 argmax 全一致且 artifact 上传。风险：可能原理上做不到（若原始模型导出缺 KV 结构）⇒ 备选是承认解码开销、不再投入。预估 1–2 天。

### 中期
4. **准确率门 G4-acc**：需要用户提供人工标注页（CER/WER 下限）。理由：没有它任何"更准"都是空话。依赖用户。验收：脚本读标注 → 输出 CER/WER → 未达下限即红。
5. **气泡分割**：要么自训（需可商用数据），要么找 Apache-2.0 且可商用的权重。验收：分割结果在评测页上可量化（IoU/人工抽查）。
6. **多平台构建验证**：至少跑通 Android（用户实际分发渠道之一）。
7. **CI 环境类测试的真诚化**：`ort_output_dtype_test` / `golden_ocr_corpus_test` 要么让它们在 CI 真跑（缓存 ORT、提供 `.expected.txt`），要么明确标注"仅本地"。理由：现在它们在 CI 上近乎装饰。

### 长期
8. **上游跟进**：上游最后提交 2026-09-05；77 个提交的差异需定期评估冲突面（高风险文件：`navigation_bar.dart`、`tasks_page.dart`、`translation.json`）。
9. **离线强制化**：把"靠巧合"变成"靠约束"（`headlessOffline` 真正拦网络，或给 Dio/HttpClient 加工厂级 poison adapter）。
10. **性能**：KV cache 接入后重测每页耗时；再评估 `llmConcurrency` 与请求合并（**注意**：LLM 属用户侧 API，用户已明示"不用你管"）。

---

## 9. 风险与未决问题

**未决（需用户拍板）**
1. KV-cache 导出是否继续投入（收益上限约 20%，不改准确率）。
2. 墨迹开关是否默认开启（依赖 §8 第 1 步的真机数据）。
3. 是否为 G4-acc 提供人工标注页。

**外部依赖风险**
4. **上游可能停更**：上游 `master` 停在 2026-09-05；若长期不动，本仓 77 个提交的维护成本完全自负。
5. **漫画源站点变动**：用户实测中出现过 `GET https://wn01.link/ DioException`（漫画源请求失败）—— 源站变化会影响可用性，与本项目代码无关但会造成"看起来是 bug"的报错。
6. **依赖版本漂移**：CI 用 `channel: stable` **未固定版本**。已经发生过一次真实事故：Flutter 从 3.44 升到 3.47 改变了 analyze 输出分隔符（`•`），导致门恒计零（`ec924a4`）。**建议固定 Flutter 版本**。
7. **本机网络可达性**（影响开发体验，非产品）：`api.github.com` ✓、`hf-mirror.com` ✓、`modelscope.cn` ✓；**`huggingface.co` 与 `github.com` 网页均不可达**。因此模型下载/导出必须在云端 runner 做。

**可能推翻现有设计的隐患**
8. **`renderedKey` 冻结策略**：改渲染逻辑后旧缓存不失效，必须手动"重新翻译"。随修复轮次增加，这个摩擦会持续累积。若要解冻，需要一次缓存版本升级（影响所有用户的既有缓存）。
9. **GPU 显存接近上限**：实测 `专用 GPU 内存 5.3 / 6.0 GB`（RTX 3060 Laptop）。当前 `sessions=3`、两个 worker。任何"提高批大小/并发"的优化都可能触发 OOM 阶梯（`degraded` 非 `none`）。
10. **单块核心文件过大**：`translation_worker.dart` ≈4200 行，含 OCR、funnel、聚类、批调度、会话管理。已出现"改一处、多点受影响"的实例（`stored` 作用域错误让 109 个用例编译失败）。**建议按职责拆分**（但拆分会与上游冲突，需权衡）。

---

## 10. 环境与凭据清单

### 10.1 工具链（本机实测）

| 工具 | 版本 / 状态 | 恢复方式 |
|---|---|---|
| Flutter | 本机 **3.44.9**；`pubspec.yaml` 要求 `>=3.44.3 <4.0.0`；CI 用 `stable`（观察到 3.47.2） | `flutter --version`；CI 由 `subosito/flutter-action@v2` 管理 |
| Dart SDK | 随 Flutter；要求 `>=3.12.0 <4.0.0` | 同上 |
| Python | **3.12.10** | `python --version` |
| gh CLI | **已登录** `github.com/Animal2404`（keyring），scopes: `gist, read:org, repo, workflow` | `gh auth login` |
| Git | 远端 `origin` = `https://github.com/Animal2404/VeneraX.git`，`upstream` = `https://github.com/Kyosee/VeneraX.git` | `git remote -v` |
| Rust | **不需要**（本仓库无 `rust/`） | — |

### 10.2 凭据（**值一律不入库**）

| 用途 | 名称 | 存放位置 | 缺失后果 |
|---|---|---|---|
| Android release 签名 | `ANDROID_KEYSTORE_BASE` | GitHub Actions secrets | Android release 构建失败 |
| 同上 | `ANDROID_KEYSTORE_PASSWORD` | GitHub Actions secrets | 同上 |
| 同上 | `ANDROID_KEY_ALIAS` | GitHub Actions secrets | 同上 |
| 同上 | `ANDROID_KEY_PASSWORD` | GitHub Actions secrets | 同上 |
| iOS/macOS 签名 | `CERTIFICATE`、`CERTIFICATE_PASSWORD` | GitHub Actions secrets | Apple 平台构建失败 |
| 本地 Android 签名 | `/android/key.properties`、`/android/keystore.jks` | **本机文件，已被 `.gitignore` 忽略**（第 54–55 行） | 本地 Android release 构建失败 |

**账号要求**：能 push 到 `Animal2404/VeneraX` 并触发 Actions（当前 `gh` 已具备 `repo` + `workflow` scope）。
**AI 翻译的 LLM 凭据**：由用户在设置页配置（对话中未记录具体形式；**不在本报告中**）。用户已明示 LLM 侧不属本项目维护范围。

### 10.3 模型文件（不在仓库内）

| 用途 | 位置 | 说明 |
|---|---|---|
| 运行期模型 | `%APPDATA%\io.github.kyosee\venera\translation_models\` | 子目录含 `text_detector`、`ocr_ja`（encoder/decoder）、`ocr_zh`、`ocr_en`、`ocr_ko` 等；**App 不打包模型**（产物 zip 里无 `.onnx`） |
| 用户自备候选模型 | `E:\Gemini\models\` | 对话中记录：`manga109-segmentation-bubble/best.pt`、`PaddleOCR-VL-For-Manga/model.safetensors`（**未接入**） |
| 参考解码器（KV 导出用） | CI 内下载 | 需 `hf-mirror.com` 或 `huggingface.co`（本机后者不可达，runner 可达） |

### 10.4 可复现的环境搭建步骤
```bash
# 1) 拉代码
git clone https://github.com/Animal2404/VeneraX.git && cd VeneraX

# 2) 依赖
flutter pub get

# 3) 静态分析（唯一允许的本地命令）
flutter analyze --no-pub lib/ test/     # 期望 0 error / 0 warning，7 条基线 info

# 4) 云端验证（不要本地跑测试/构建）
gh auth status                          # 应显示 Animal2404
gh workflow run main.yml -R Animal2404/VeneraX --ref master -f platform=windows -f ort_edition=directml

# 5) 取产物
gh run download <run-id> -R Animal2404/VeneraX -n windows_build

# 6) 运行（需 Windows）
#    解包后保持 venera.exe 与 DirectML.dll 同目录，双击 venera.exe
#    日志：%APPDATA%\io.github.kyosee\venera\logs.txt
```

---

## 11. 一页速览

**VeneraX 是什么**：一个 Flutter/Dart 的漫画阅读器（上游 `Kyosee/VeneraX`，GPL-3.0，支持 Android/iOS/Windows/Linux/macOS），核心能力是**运行社区编写的 JS 漫画源**来抓取与阅读。本仓库 `Animal2404/VeneraX` 在其之上开发**离线 AI 翻译**：本地 ONNX 推理做 OCR（日/中/英/韩），把译文**融合嵌回原页面**（擦除原文 → 排版 → 绘制），并可选走用户自备的 LLM 接口润色。

**本次对话的核心目标**：① 执行 `AI_TRANSLATION_PHASE2/3` 计划；② 修用户实测报出的全部缺陷（**"全部做完再说，遇到 BUG 也继续做，没做完不要停"**）；③ 硬约束：**全程云端构建/测试，禁止本地跑**（用户多次强调）。

**5 条要点**
1. **排版三个真因全部定位并修复**：黑块 = 描边选色被网点墨点骗（不是擦除失败）；叠字 = worker 聚类把相邻气泡并成一簇（不是双重绘制）；"更慢" = 云端 LLM API 方差（82–90% 墙钟，不是代码退化）。
2. **CI 从"假绿的装饰"变成"真门禁"**：Test job 原先只跑 33/138 个文件（**789 个用例从未执行过**），改全量后首跑就暴露 **15 个真失败**（含"取消不还显存""旧备份盖新数据"这类高危项），已全部修至 **1329/1329 全绿 + 退出码 0**。
3. **观测性补全**：`OcrFunnel`（四条恒等式）、`OcrText`/`BlockFunnel`（静默丢弃可见化）、`OcrInk`（墨迹判据）、`GroupPerf`（结构化耗时）、`throughput vs 组内延迟`（数字不再自相矛盾）。
4. **Pass B 死兜底修复**：换引擎重试的路由读了一个"只在成功时写的字段" ⇒ 恒假 ⇒ 该重试从未发生（用户可见的"有字没翻"）。用旧代码复刻为 oracle、3072 例穷举对照后修复。
5. **两条路走不通并被记录**：① 跨气泡融合**几何阈值无解**（算术证明）；② KV-cache 解码器导出**等价性 4/5 失败**，门禁按设计拒绝交付。

**当前状态**：HEAD `5ea202a`，工作树干净，云端 `Test: success` + `Build_Windows: success`（`1329/1329/0/1/0` + `GUARD PASS`）；可测产物 `E:\Gemini\VeneraX-latest\`。

**下一步第一个动作**：让用户用该产物**重翻一话**（必须先点「重新翻译」），取回 `logs.txt` 里的 `OcrFunnel` / `BlockFunnel` / `OcrInk` 三行 —— 用真实数据一次定掉"漏识别归因""漏翻译归因""墨迹阈值"三个悬案。

---

## 12. 附录

### 12.1 术语表

| 术语 | 含义 |
|---|---|
| **漫画源 / JS source** | 用 JavaScript 写的抓取脚本，在 App 内由 JS 引擎执行，产出图片 URL 与元数据；本仓不改这部分（`assets/init.js`、`lib/foundation/js_engine.dart`） |
| **headless 模式** | 无 GUI 的命令行入口（`lib/headless.dart` + `headless_cli.dart`），用于批量验证、离线自检，支持 `--offline` |
| **EP / Execution Provider** | ONNX Runtime 的后端；本项目用 **DirectML**（Windows GPU），失败时降 `degraded` |
| **R3（红线）** | FFI 调用只允许出现在 worker isolate 内；主 isolate 只做消息收发 |
| **`cacheKeyFor` / `renderedKey`** | 两级缓存键（OCR 结果 / 渲染图）。**冻结**：改动会让旧缓存全部失效，故不改 |
| **`InpaintMode`** | 擦除模式：`smart`（默认，擦除后重绘）/ `patch`（贴回）|
| **`PipelineMode`** | 流水线模式；**出厂默认必须 `freeVram`**（红线） |
| **funnel / 漏斗** | OCR 各阶段的丢弃计数，用于把"漏识别"归因到具体环节（`OcrPageFunnel`）|
| **Pass A / Pass B** | OCR 的两轮：Pass A 用主引擎逐组识别；Pass B 对"不可信"的簇换引擎重试 |
| **墨迹判据（ink boundary）** | 通过检测两框之间缝隙带里的"细深色游程"判断那是气泡描边 ⇒ 拒绝合并（唯一能切开相邻气泡的信号）|
| **G4-acc（提议）** | 准确率门：要求 OCR 的 CER/WER 低于下限；需人工标注数据 |
| **D-15 / D-16** | 本仓的缺陷编号约定（记录在 `doc/ocr-baseline.md`）：D-15 = 英/韩识别器性能归因（**已被自己的测量推翻**）；D-16 = perf 解析器把批上限当耗时 |

### 12.2 相关链接
- 上游仓库：`https://github.com/Kyosee/VeneraX`（GPL-3.0）
- 本仓库：`https://github.com/Animal2404/VeneraX`
- 最新验证 run：`https://github.com/Animal2404/VeneraX/actions/runs/34438083165`（@`5ea202a`，Test + Build_Windows 双绿）
- KV 导出失败 run：`https://github.com/Animal2404/VeneraX/actions/runs/34352623416`
- 本仓文档：`doc/AI_TRANSLATION_PHASE3_PLAN.md`、`doc/AI_TRANSLATION_RETROSPECTIVE_AND_PLAN.md`、`doc/ocr-baseline.md`、`doc/decoder_kv_export.md`、`doc/js_api.md`、`doc/headless_doc.md`、`doc/SYNC_FORMAT_SPEC.md`、`doc/guide.zh.md` / `guide.en.md`、`doc/import_comic.md`
- **无 issue/PR 记录**（本对话未创建任何 issue 或 PR；所有工作直接提交到 `master`）

### 12.3 文件索引（本次改动密度最高的位置）
```
lib/foundation/image_translation/
  translation_worker.dart          # OCR 主逻辑（≈4200 行）：det/rec/dec、Pass A/B、funnel、聚类
  page_renderer.dart               # 排版融合：重叠消解、避让、描边、底色判据（backgroundReadsDark）
  inpaint.dart                     # 擦除：keptDarkMass 三条腿、describeLedger
  translation_pipeline.dart        # 单页流水线：分类、丢弃日志、台账
  translation_service.dart         # 服务层：缓存、渲染落盘、GroupPerf 发布
  pre_translation_tasks.dart       # 批任务：进度、速率、刷新时钟、sweep 记账
  ocr_batching.dart                # 批调度：resolveDecBatch / decDecodeOrder / OOM 阶梯
  ocr_fingerprint.dart             # 缓存指纹（内容哈希）
  translation_store.dart           # 持久化（含 hasOcr 的异常语义）
  local_model_import.dart          # ONNX 图解析与本地模型校验
  ort_ffi.dart / ort_capabilities.dart / ort_api_indices.g.dart  # FFI 绑定
  llm_translator.dart / public_translator.dart / rate_limiter.dart  # LLM 侧
.github/workflows/main.yml         # 构建 + 全量测试 + 守卫 + 心跳 + TestBisect
.github/workflows/analyze.yml      # 静态门（errors-only）
tool/ci/check_test_run.dart        # 测试守卫（漂移/下限/退出码判定）
tool/export_decoder_kv.py          # KV-cache 导出 + 等价性门禁
assets/translation.json            # i18n（zh_CN / zh_TW 各 1448 键，需保持一致）
```

### 12.4 还缺哪些资料（新会话可能想要但仓库里没有）
1. **人工标注的日文页面**（G4-acc 门的前提）—— 仓库内无。
2. **真机 `OcrInk` / `BlockFunnel` / `OcrFunnel` 的实测样本** —— 只在对话中取过一次（缺 `OcrInk`，因为开关默认关）。
3. **用户侧 LLM 接口的配置细节与延迟特征** —— 不属于本仓维护范围，但影响整体体验。
4. **Phase 2 计划文档 `E:\Gemini\VeneraX_AI_Translation_Phase2_Plan.md`** —— 在仓库**之外**；仓库内对应的是 `doc/AI_TRANSLATION_PHASE3_PLAN.md`。
5. **上游改动的追踪机制** —— 无 issue/PR/订阅，靠人工 `git log upstream/master`。

---

## 自检清单

| 检查项 | 结果 |
|---|---|
| 12 节是否齐全？ | **是**（§1 变更集 / §2 上游 / §3 文件地图 / §4 时间线 / §5 决策 / §6 构建验证 / §7 已知问题 / §8 后续方向 / §9 风险 / §10 环境凭据 / §11 速览 / §12 附录）+ 接续卡 + 自检 + 局限 |
| 每条结论是否有依据或标"未记录"？ | **是**。变更集逐条挂 commit hash；测量类挂 run id 或日志统计；推断项（如对话区间起点）显式标注"为推断"；无法回溯者标"未记录"/"未再验证" |
| 所有"已完成"是否有验证证据？ | **是**，但**存在分层**：① 有云端 run 证据的（CI 全量 `1329/1329`、`Build_Windows: success`）；② 只有单测证据的（如 Pass B 修复、墨迹判据）；③ 只有静态分析证据的（`analyze` 0 error/0 warning）。**§7.2 单列了"未验证"项**，未混入"已完成" |
| 是否单独列了"改了代码但没提交"？ | **是**：§1.7 明确 `git status --porcelain` 为空（无未提交改动），并列出"仅讨论过、未落地"的 4 项 |
| 是否含敏感值？ | **否**：只写凭据**名称与存放位置**，值一律 `<REDACTED>`；未写 token、keystore 口令、账号密码 |

### 本次报告的已知局限 / 无法回溯的部分

1. **对话已被压缩过**：本对话"已完成多轮"，早期细节（尤其 09-09 04:00 之前）依赖摘要重建，**存在丢失**。§4 时间线中标注"为推断"的条目即属此类。
2. **精确起点无法确认**：本报告把区间定为 `d1db429`（09-09 04:23）→ `5ea202a`，依据是"摘要提到的缺陷名 ↔ 提交 message"的对应关系与时间连续性；**09-08 及之前的提交归属上一会话，未覆盖**。
3. **子代理的完整报告未入库**：本对话中数十个子代理的详细交付报告只存在于对话里，仓库中只留下提交与测试文件。**若需要细节，只能重新读代码**。
4. **上游基线未逐行比对**：§2 的差异清单是按"主题 + 目录存在性"归纳的，**没有做 `git diff upstream/master` 的逐文件核对**（77 个提交，成本高）。
5. **GPL 义务未做资源级审查**：`assets/` 下各文件的第三方许可**未逐项核查**，§2 中已标为待办。
6. **本报告的"用户实测反馈"部分不完整**：用户只对 `3b39f94` 之前的产物给过截图反馈；对 `bb91581`（黑块修复）之后的产物**未收到确认**。
7. **部分数字来自一次性统计**：§1.3 的 OCR 每页中位（3897 ms）来自对 `logs.txt` 中 20 个批次的统计，**样本量小且来自单次会话**，不应视为稳定基线。

---

## 关于本文档位置的说明（强制跟踪的理由）

本报告按指令写入 `docs/`，但仓库 `.gitignore:52` 有一条 **`docs/`** 规则（上游既有约定，用于 dartdoc / 构建输出），因此该目录默认不被版本控制 —— 若直接 `git add`，报告**永远不会进入仓库**，而 clone 出来的新会话也就看不到它，与本文档的目的（接续开发）直接冲突。

处理：用 `git add -f docs/CONTINUATION-REPORT-2026-09-10.md` **强制跟踪这一份文件**，**未修改 `.gitignore` 规则**（其他 `docs/` 内容仍被忽略）。

**新会话注意**：
- 本报告在 `docs/`（需 `git ls-files docs/` 才能看到，`ls` 能看到、`git status` 不会提示）；
- 仓库其余项目文档在 `doc/`（单数），这是上游约定；
- 若将来要新增文档，**优先放 `doc/`**，除非确实需要 `docs/` —— 那就要记得用 `-f` 跟踪。
