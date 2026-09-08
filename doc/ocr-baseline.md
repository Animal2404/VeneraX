# OCR 性能与资源基线表

> 本文件是 `VeneraX_AI_Translation_Phase2_Plan.md` §3.9 规定的**唯一合法口径**。
> 任何"提速 X%""显存降 Y MB"的说法，若不能指向本表的**具体两行**（before / after），一律不予采信 —— 包括本文件自己的历史叙述。
> 在此之前，项目里流传的数字（`5~10 倍`、`+300%`、`1.2GB→400MB`、`提速 70%`）全部没有对应记录，已在规划 §1.1 判为 UNVERIFIABLE。

## 采样规程（强制）

1. 同一台机器、同一份语料（`test/fixtures/golden_ocr`，CC0，由 `tool/gen_golden_fixtures.py` 生成）、同一模型文件（SHA 记入表内）。**换机必须整表重测，禁止跨机比较。**
2. **冷启动单独一行**：首次加载模型 + DirectML 首次 shape binding 的成本不计入稳态。
3. `--repeat 3` 取**中位数**，同时记录最快/最慢（DML 形状重绑的抖动会被平均值掩盖）。
4. **一次只改一个变量**。禁止一个提交同时改桶宽 + batch + tier 再声称"净收益"。
5. 采样时关闭其它占用 GPU 的程序，并在"备注"里记录该前提（`nvidia-smi` 的 `memory.used` 是**整卡**读数，不是本进程）。
6. `runs/页`、`fetchMs`、`ocrMs` **必须同时看**：只报总时长的声明不予采信（可能只是取图变快而 GPU 反而变慢）。
7. 读数缺失写 `N/A` 并在"探针"列注明原因。**禁止写 0**（0 会被读成"已归还"，这正是 D-1 藏了这么久的原因）。

## 采集命令

```bash
# 1) 构建并换上 GPU 运行时
flutter build windows --release
python tool/fetch_ort_runtime.py --edition directml \
    --target-dir build/windows/x64/runner/Release --apply

# 2) 一致性 + 速度 + 资源三把尺子（一次跑完）
build/windows/x64/runner/Release/venera.exe --headless ocr-golden \
    --dir test/fixtures/golden_ocr \
    --batches 1,4,16,32 --tier fast --group 1 --repeat 3 --resource-probe --json \
    | tee doc/baseline/golden-$(git rev-parse --short HEAD).json

# 3) 运行时/EP/形状探测（含真实建会话）
build/windows/x64/runner/Release/venera.exe --headless ocr-selfcheck auto \
    --page test/fixtures/golden_ocr/02_zh_horizontal.png --repeat 3
```

## 表

| # | 日期 | gitsha | 机器 / GPU | ORT 版本 | active EP | tier | recBatch | 冷启动 | ocrMs/页(中位) | detMs | recMs | decMs | runs/页 | sessions峰值 | arena MB | GPU used MB(前→后) | 探针 | 文本一致率 | 备注 |
| :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- |
| B0 | 2026-09-08 | `2f6464f`+Phase6尺子 | RTX 3060 Laptop 6GB / 16 核 | 1.22.0 | dml | fast | 1 | | | | | | | | | | psapi+nvidia-smi | | 改造前基线（Phase 6 只加测量，未改推理） |
| B1 | | | | | | | | | | | | | | | | | | | Phase 7 后（真释放） |
| B2 | | | | | | | | | | | | | | | | | | | Phase 9 后 `throughput` |
| B3 | | | | | | | | | | | | | | | | | | | Phase 9 后 `freeVram` |

> **B0 行不许空着。** 它缺失时，B1–B3 全部失去意义（规划 附录 H 第 2 项）。

## 决策门读数（每次采样后填写）

| 门 | 判据 | 实测 | 结论 |
| :-- | :-- | :-- | :-- |
| G1 一致性 | 4 个 batch 档 × 5 页文本全等 | | |
| G2 释放 | `after ≤ before × 1.05` 且 `pause→resume×5` 斜率 ≈ 0 | | 决定 `PipelineMode` 出厂默认 |
| G3 收益 | `throughput ≤ freeVram × 0.85` | | |
| G4 CUDA 重启 | `decMs / ocrMs ≥ 0.5` | | 当前裁决 R-2 = 不接 CUDA |
| G5 资产 | FP16 误差 ≤ 2e-2 且金标零差异 | | 当前裁决 R-3 = 组件保持摘除 |

## B0 基线：**当前被 D-14 阻塞**（如实记录，不用估算填空）

`--headless` 在本机无法完成，因此 B0 行**没有数字**。已实测排除"我的改动导致"：

| 实验 | 命令 | 结果 |
| :-- | :-- | :-- |
| 新工具 | `venera.exe --headless ocr-golden --dir … --batches 1,4,16,32 --resource-probe` | 10 分钟无输出，进程存活 |
| **对照**（Phase 6 之前就存在的命令） | `venera.exe --headless ocr-selfcheck auto` | 同样 10 分钟无输出，进程存活 |
| 存活证据 | `Get-Process venera` → `CPU=3.73s`，工作集 119 MB，StartTime 13:46:40，观测时刻 13:56:33 | 墙钟 10 分钟 / CPU 3.7 秒 ⇒ **阻塞**，不是在算 |

推理链：`runHeadlessMode` 末尾无条件 `exit(0)`；进程 10 分钟仍在 ⇒ 从未走到末尾 ⇒ 阻塞在 `init()` / `App.initComponents()` 之前或之中。`ocr-selfcheck` 的符号探测本身是毫秒级，不可能耗时 10 分钟。

### D-14 定位线索（下一步从这里查）
1. 最可疑：**平台通道回包无人泵送**。`WidgetsFlutterBinding.ensureInitialized()` 之后直接 `await init()`，而 Windows runner 的 C++ 侧在 Dart `main()` 返回前不跑消息泵 ⇒ 任何依赖 plugin 的 await（`path_provider` 取 `App.dataPath`、`shared_preferences`、`webview` 初始化）永不完成。
2. 验证方法（成本从低到高）：
   - 在 `runHeadlessMode` 每个 await 前加一行 `stderr.writeln('step N')`（stderr 同样可能被吞，故同时 `File('C:/tmp/hl.log').writeAsStringSync(..., mode: append)`），跑一次看停在第几步；
   - 或临时把 `init()` / `App.initComponents()` 逐个注释掉跑 `ocr-selfcheck`，二分定位；
   - 若确认是消息泵：headless 分支改为 `WidgetsFlutterBinding.ensureInitialized()` 后**不依赖 plugin** 地解析数据目录（Windows 下用 `Platform.environment['APPDATA']` + 固定子目录，与现有 `App.dataPath` 结果一致），并把网络型初始化（更新检查、漫画源拉取、DataSync）从 headless 路径剥离。
3. **D-14 修好之前，G1/G2/G3 三个门都无法判定** —— 因此 `PipelineMode` 出厂默认必须保持 `freeVram`（规划 R-4 的前置条件），Phase 9 的吞吐改动不得合入默认值切换。

### 一旦解除阻塞，按此顺序补数据
```bash
python tool/gen_golden_fixtures.py                 # 语料（已生成，可重跑校验确定性）
flutter build windows --release
python tool/fetch_ort_runtime.py --edition directml \
    --target-dir build/windows/x64/runner/Release --apply
build/windows/x64/runner/Release/venera.exe --headless ocr-golden \
    --dir test/fixtures/golden_ocr --batches 1,4,16,32 --tier fast \
    --repeat 3 --resource-probe --json > /tmp/golden_b0.json
dart run tool/ocr_run_stats.dart /tmp/golden_b0.json   # 直接吐出可粘贴的 B0 行
```

## D-15：DirectML 在 en/ko 识别器的 `Softmax_0` 节点返回 E_INVALIDARG（挡住 G1）

D-14 修好后的第一次真实测量（**云端产物** `windows_build` @ `c842b2e`，本机 RTX 3060）在跑到英文/韩文页时崩溃：

```
[E:onnxruntime] sequential_executor.cc:572 ExecuteKernel
  Non-zero status code returned while running Softmax node. Name:'Softmax_0'
  Status Message: ...DmlExecutionProvider...MLOperatorAuthorImpl.cpp(2851)... 80070057   <- E_INVALIDARG
```

### 归属离线确定（不靠猜）
扫描本机已下载模型的节点名字符串：`ocr_enec.onnx` 与 `ocr_koec.onnx` **含** `Softmax_0`；
`ocr_zhec.onnx`、`ocr_ja\{encoder,decoder}.onnx` 无此名；两个检测模型完全无 Softmax。
=> 崩的是 **PP-OCRv3 英文 / PP-OCRv1 韩文识别器**。也就是说：DirectML 后端下，英/韩 OCR 至少在语料遇到的某个形状上不可用。
这正是 §9.2.5「改变主意触发条件 ②（DML 算子不支持）」的真实样本 —— 但结论不该是"回去接 CUDA"，
而应先查清形状触发条件（这三条模型此前从未被新的 rec 桶化/批量喂过）。

### 同时修掉一个"吞错误"缺陷（已提交）
`OrtRuntime._check` 原先对 ORT 状态文本用**严格** UTF-8 解码；驱动错误块含非法字节时它抛
`FormatException: Unexpected extension byte (at offset 286)`，于是**真正的 ORT 错误被丢弃**，
看到的是一条与 GPU 无关的解码异常。已改为扫描终止符 + `allowMalformed` 解码，解码器不再反客为主。
没有这个修复，D-15 无法定位。

### 下一步（顺序固定）
1. 以 `--batches 1`（等价改造前的逐条路径）单独跑 en/ko 两页，区分「批量/pad 形状触发」与「本 DML 版本不支持该算子」；
2. 前者→收紧 en/ko 的 `planRecBatch` 桶分配；后者→该算子走 CPU 回退并在 `LOCK.md` 记为 DML 已知不支持项；
3. **在此之前 B0 的 en/ko 两列留空，G1 不得宣布通过。**

## 探针可用性记录（诚实声明）

| 探针 | 状态 | 说明 |
| :-- | :-- | :-- |
| `psapi!K32GetProcessMemoryInfo` | 可用 | 实测：分配 64 MB 后工作集 +68~70 MB，能反映真实驻留 |
| `nvidia-smi --query-gpu=memory.used` | 可用（整卡粒度） | 实测 1781/6144 MB；**不是本进程**，故采样需关闭其它 GPU 程序 |
| `nvidia-smi --query-compute-apps` | 本机不可用 | 本进程走图形引擎而非 compute 引擎，故不在列表中 → 记 `N/A`，不记 0 |
| `IDXGIAdapter3::QueryVideoMemoryInfo` | **未采用** | 本 SDK（10.0.26100.0）的 `IDXGIFactory1Vtbl` 头文件缺少 `GetSharedResourceAdapterLuid`（声明在未随包发布的 `dxgi1_1.h`），按头文件数出的槽位与真实 vtable 差一位：实测 slot12 返回 S_OK 却不写输出（它把 LUID 写进了我当作 riid 的缓冲区），slot13 返回 1（`IsCurrent()`）。**未经验证的 COM 槽位不得进产品代码** —— 误调不是降级而是访问违例（已实测崩溃）。详见 `process_diagnostics.dart` 的 P-2 注释 |
