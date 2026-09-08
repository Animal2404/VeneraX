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

## 探针可用性记录（诚实声明）

| 探针 | 状态 | 说明 |
| :-- | :-- | :-- |
| `psapi!K32GetProcessMemoryInfo` | 可用 | 实测：分配 64 MB 后工作集 +68~70 MB，能反映真实驻留 |
| `nvidia-smi --query-gpu=memory.used` | 可用（整卡粒度） | 实测 1781/6144 MB；**不是本进程**，故采样需关闭其它 GPU 程序 |
| `nvidia-smi --query-compute-apps` | 本机不可用 | 本进程走图形引擎而非 compute 引擎，故不在列表中 → 记 `N/A`，不记 0 |
| `IDXGIAdapter3::QueryVideoMemoryInfo` | **未采用** | 本 SDK（10.0.26100.0）的 `IDXGIFactory1Vtbl` 头文件缺少 `GetSharedResourceAdapterLuid`（声明在未随包发布的 `dxgi1_1.h`），按头文件数出的槽位与真实 vtable 差一位：实测 slot12 返回 S_OK 却不写输出（它把 LUID 写进了我当作 riid 的缓冲区），slot13 返回 1（`IsCurrent()`）。**未经验证的 COM 槽位不得进产品代码** —— 误调不是降级而是访问违例（已实测崩溃）。详见 `process_diagnostics.dart` 的 P-2 注释 |
