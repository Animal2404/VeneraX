# manga-ocr 解码器 KV cache ONNX 导出

本文件描述 `tool/export_decoder_kv.py` + `.github/workflows/export_decoder_kv.yml`：
**在 GitHub Actions 上**导出一个带 `past_key_values` 的 manga-ocr decoder ONNX，并在同一个 job 内
**自证**它与现有无 cache 导出逐步等价。

> 本轮只产出**资产与验证证据**。不改 `lib/`、不改注册表、不改既有 workflow。
> 接入由仓库维护者另行安排。

---

## 1. 为什么需要换导出

实测（`doc/ocr-baseline.md` 同口径，每页中位）：

| 阶段 | det | recGpu | **dec** | rest | 总计 |
| :--- | ---: | ---: | ---: | ---: | ---: |
| ms | 1060 | 907 | **1917** | 13.5 | 3897 |

解码占墙钟 **49%**。根因不是代码：现役 `decoder.onnx`
（`mayocream/manga-ocr-onnx/decoder_model.onnx`，SHA 见 `tool/model_export/ASSETS.md`）
图输入只有 `input_ids[batch,seq]` 与 `encoder_hidden_states[batch,seq,768]`，**没有 `past_key_values`**。
于是每一步都要重喂整段前缀（O(L²)），且每步都是一次极小推理（GPU 大量空转）。

`lib/foundation/image_translation/ocr_batching.dart` 的 `driveDecode` 注释把这件事写死了：

> …the shipped `decoder.onnx` exports exactly two graph inputs (`input_ids`,
> `encoder_hidden_states`) and one output (`logits`), with **no past_key_values**,
> so prefix re-feeding is forced by the model, not by a missed optimisation here.

所以必须换导出。本 workflow 干的就是这件事。

---

## 2. 机制依据：为什么带 cache 的导出与旧版等价

以下行号均为 **transformers `v4.44.2` `src/transformers/models/bert/modeling_bert.py`**（workflow 里 pin 的版本）。

### 2.1 模型是什么

`kha-white/manga-ocr-base/config.json`（经 `hf-mirror.com` 取回）：
顶层 `model_type: vision-encoder-decoder`；encoder `vit`，`image_size: 224` / `patch_size: 16`
⇒ 固定 196 个 patch token，`hidden_size: 768`；decoder `model_type: bert`，
`is_decoder: true`，`add_cross_attention: true`，`num_hidden_layers: 2`，
`num_attention_heads: 12`，`vocab_size: 6144`，`max_position_embeddings: 512`，`use_cache: true`。
token id：`pad=0`、`start=2`、`eos=3`（与 `MangaOcrTokens` 一致，`maxTokens=80`）。

即 decoder 就是一个**标准 `BertLMHeadModel`**，而 BERT 原生实现了增量 cache。这是本方案成立的唯一前提。

### 2.2 cache 的结构（决定 I/O 名字）

| 事实 | 出处 |
| :--- | :--- |
| 每层 cache 是 4 元组 `(self_k, self_v, cross_k, cross_v)` | `BertLayer.forward` L583 `past_key_value[:2]`、L609 `past_key_value[-2:]`、L624 `present_key_value + cross_attn_present_key_value` |
| 自注意力把新 K/V 拼到 past 后面 | `BertSelfAttention.forward` L283-284 `torch.cat([past_key_value[0], key_layer], dim=2)` |
| 位置 id 由 past 长度偏移 | `BertEmbeddings.forward` L195-196；`BertModel.forward` L1067 `past_key_values_length = past_key_values[0][0].shape[2]` |
| 输出 `logits` + `past_key_values` | `BertLMHeadModel.forward` L1387-1394 |

2 层 ⇒ 8 个 past 输入 / 8 个 present 输出，命名沿用 optimum 的 encoder-decoder 口径：
`past_key_values.{i}.decoder.{key,value}`（自注意力）与 `past_key_values.{i}.encoder.{key,value}`（交叉注意力）。

### 2.3 为什么是两张图，而不是一张"合并图"

`BertSelfAttention.forward` L271-275：

```python
if is_cross_attention and past_key_value is not None:
    key_layer = past_key_value[0]      # 无条件复用，没有长度校验
    value_layer = past_key_value[1]
```

只要给了 cross cache，它就**当成真的 K/V 用**。所以"单图 + 第一步喂 0 长度 past"这种合并写法，
第一步会把空 cache 当交叉注意力 K/V ⇒ softmax 在空维上 ⇒ 输出无意义。
（v4.44.2 的 SDPA 分支 L404 有 `shape[2] == current_states.shape[1]` 校验，但 trace 时该 `if` 按样例形状定死，
仍不可依赖。）

⇒ 第一步必须是**独立图**（`past_key_values=None`），这也是 optimum 的
`decoder_model.onnx` + `decoder_with_past_model.onnx` 双图布局。

### 2.4 为什么 `position_ids` 是显式输入

L1067 的 `past_key_values_length` 是 **Python int**（来自 `.shape[2]`）。
TorchScript tracer 会把它固化成一个常量：位置切片 L196、因果 mask 构造都会写死成导出时的 past 长度，
运行时换一个 past 长度就错。这正是社区在 GPT-2 上遇到的同款问题
（[HF 论坛](https://discuss.huggingface.co/t/when-exporting-seq2seq-models-with-onnx-why-do-we-need-both-decoder-with-past-model-onnx-and-decoder_model-onnx/33354)：
"I had to add `position_ids` as inputs to have matching logits due to this logic"）。

本导出因此：

* `position_ids` 作为图输入（第 k 步喂 `[[k]]`）；
* 自注意力 mask 由 wrapper 内置一个形状恒为 `[1,1,1]` 的**全 1** mask。
  `get_extended_attention_mask` 对 3 维 mask 先 unsqueeze，再统一做
  `(1.0 - mask) * finfo.min`（`modeling_utils.py` L1131-1132 与 L1153-1154）——
  全 1 ⇒ 加性 0 ⇒ 所有 key 可见；形状与 batch / past 长度无关，天然可广播。
  （**注意**：这里必须是 1 而不是 0，写 0 会反演成 `-3.4e38`，把所有 key 屏蔽掉。）

### 2.5 等价性的定义与判定

导出与参考**同权重、同 eager attention、eval 模式**（dropout 关闭）：

* 参考 A（语义定义）：PyTorch `use_cache=False`，每步重喂整前缀——正是现役图 trace 的计算；
* 参考 B（现役产物）：`mayocream/manga-ocr-onnx/decoder_model.onnx` 本身，每步重喂整前缀；
* 被测：`step0` 图跑一步 + `kv` 图逐步喂 1 token + past。

**判定 = 每一步 argmax token 完全一致**（逐行、逐 step），并附 logits 最大绝对差。
任一步不一致 ⇒ 脚本 `exit 1` ⇒ job 失败。没有"只告警"的路径。

---

## 3. 怎么触发

### 手动（推荐）

```bash
gh workflow run export_decoder_kv.yml \
  -f fp16=false \
  -f max_steps=79 \
  -f model_id=kha-white/manga-ocr-base \
  -f hf_endpoint=https://hf-mirror.com \
  -f opset=17
gh run watch
```

Web：**Actions → Export manga-ocr decoder with KV cache → Run workflow**。

### 定时

`cron: 0 4 * * 1`（每周一 04:00 UTC）。定时运行只是回归哨兵：上游 torch/transformers/模型仓库漂移时，
等价性门禁会变红。注意 GitHub 会停用长期不活跃仓库的 schedule，此时手动触发即可。

### 输入

| 输入 | 默认 | 说明 |
| :--- | :--- | :--- |
| `fp16` | `false` | 额外导出 fp16（`keep_io_types=True`，复用 `tool/model_export/to_fp16.py`）并**重新跑同一套等价性**；不通过则 job 失败 |
| `max_steps` | `79` | 长行 case 的强制解码步数；`79` 正好对应 `MangaOcrTokens.maxTokens = 80` 的上限 |
| `model_id` | `kha-white/manga-ocr-base` | 源 PyTorch 权重 |
| `hf_endpoint` | `https://hf-mirror.com` | 主源；脚本失败后自动回退 `https://huggingface.co` |
| `opset` | `17` | ONNX opset |

---

## 4. job 每一步做什么

1. `actions/checkout@v4`（`fetch-depth: 1`）。
2. `actions/setup-python@v5`，Python 3.11 + pip cache。
3. `actions/cache@v4` 缓存 `~/.cache/huggingface`（源权重 ~460 MB + 参考 decoder ~117 MB）。
4. 安装 CPU 依赖：`torch==2.4.1`（`--index-url https://download.pytorch.org/whl/cpu`；失败则把该 index 作为
   `--extra-index-url` 重试，让纯 Python 依赖从 PyPI 解析）
   + `transformers==4.44.2` + `huggingface_hub==0.24.6` + `numpy==1.26.4` + `onnx==1.16.2`
   + `onnxruntime==1.19.2` + `onnxconverter-common==1.14.0` + `Pillow==10.4.0`。**不需要 GPU**。
5. `python -m py_compile tool/export_decoder_kv.py`（语法门，几秒）。
6. 跑 `tool/export_decoder_kv.py`：
   1. `snapshot_download`（mirror → 官方回退）；
   2. 加载 `VisionEncoderDecoderModel`，把**顶层** `config._attn_implementation` 设成 `"eager"`
      并**校验生效**（`VisionEncoderDecoderModel` 会把顶层值下发给 encoder/decoder，
      见 `modeling_vision_encoder_decoder.py` L193/L196 与 `modeling_utils.py` L1478-1485、L3826）；
   3. 语料：5 张 PIL 合成图（白底/黑底/横条/字块/噪声）过真 ViT encoder + `zeros` + 3 个随机张量，
      统一 `[1,196,768]`；
   4. 一次真实 forward 发现 cache 结构（层数 / 每层张量数 / 形状），据此生成 I/O 名与动态轴；
   5. 导出 `step0` 图与 `kv` 图（opset 17，`dynamo=False` 固定走 TorchScript tracer）；
   6. 下载现役 `decoder_model.onnx` 作为参考 B；
   7. 跑 5 个 case（见 §5）；
   8. 写 `meta.json` / `SHA256SUMS.txt` / `SUMMARY.md`，并追加到 job summary。
7. 打印 `dist/` 列表、`SHA256SUMS.txt`、`meta.json` 头部。
8. 上传诊断 artifact（`if: always()`）：`SUMMARY.md` + `meta.json` + `SHA256SUMS.txt`。
9. 上传 ONNX artifact（`if: success()`）：`dist/*.onnx`。**等价性失败时不会上传图**。

---

## 5. 等价性 case（全部为门禁，不一致即失败）

| case | 内容 | 覆盖要求 |
| :--- | :--- | :--- |
| `immediate_eos_single_step` | 每个语料只跑 1 步；再在 64 个随机输入里搜"第一步就 EOS"的样本 | 立即 EOS 的短行 |
| `repetition_loop` | 强制 48 步（忽略 EOS），按 `BatchDecodeState.hasRepetitionLoop` 的 4-gram / trigram 规则检测重复环 | 重复环 |
| `long_line` | 强制 79 步（= 应用上限 `maxTokens-1`），前缀长度从 1 涨到 80 | 长行 > 60 token |
| `batch_gt_1` | 3 行批处理 24 步，按应用的"完成行补 pad、所有行共享同一前缀长度"调度；再逐行与单行跑法比对 | 批量 > 1 + 批不变性 |
| `shipped_reference_crosscheck` | 现役 `decoder_model.onnx` vs PyTorch 旧路径（4 个语料 × 16 步） | 把"旧版"锚定在真实产物上 |

`long_line` 同时记录 CPU 上两种路径的耗时（仅供机制参考，**不是 GPU 提速结论**）。

---

## 6. 产物

| 文件 | 内容 |
| :--- | :--- |
| `manga_ocr_decoder_kv_step0.onnx` | 第一步图：`input_ids[batch,1]` + `encoder_hidden_states[batch,196,768]` → `logits[batch,1,6144]` + `present.*` |
| `manga_ocr_decoder_kv.onnx` | 增量图：`input_ids[batch,1]` + `encoder_hidden_states` + `position_ids[batch,1]` + `past_key_values.*` → `logits[batch,1,6144]` + `present.*` |
| `manga_ocr_decoder_kv.meta.json` | 注册表进料：字节数 / SHA256 / 每个张量的名字·dtype·形状 / opset / IR / 精度 / 版本 / 等价性结果 |
| `SHA256SUMS.txt` | `sha256sum` 格式 |
| `SUMMARY.md` | 人读版（与 job summary 同内容） |

### 取回产物

```bash
gh run list --workflow export_decoder_kv.yml --limit 5
gh run download <run-id> -n manga-ocr-decoder-kv-onnx -D dist/
# 诊断包（含 SUMMARY.md / meta.json / SHA256SUMS.txt）
gh run download <run-id> -n manga-ocr-decoder-kv-diagnostics -D dist-diag/
```

**注意**：只有等价性全 PASS 的运行才会产出 `manga-ocr-decoder-kv-onnx`；
失败的运行只有诊断包。

精度默认 **fp32**；`fp16=true` 时额外产出 `*_fp16.onnx`（I/O 仍为 fp32）。

**预期体积**：decoder 约 29.4 M 参数（含 tied embedding/lm_head），fp32 约 **117 MB 量级**
（现役 `decoder_model.onnx` 为 117,480,262 字节）；两张图权重相同，体积接近。
**具体字节数与 SHA256 以 job 输出为准**——opset / constant folding / initializer 布局都会影响最终文件，本文不预填。

`present.*` 形状：自注意力 `[batch,12,past_len+1,64]`（`past_len` 动态），
交叉注意力 `[batch,12,196,64]`（固定 196）。`encoder_hidden_states` 的第 1 维在导出时**固定为 196**，
batch 维动态——与 ViT 固定 224×224/16 的 196 个 patch 一致。

### 怎么用（伪代码）

```text
# 第 0 步（每行一次）
feed = { input_ids: [B,1] = start(2), encoder_hidden_states: [B,196,768] }
out  = step0.run(feed)                     # logits [B,1,6144], present.* 8 个张量
tok  = argmax(out.logits[:, -1, :])
step = 1

# 第 k 步（k = 1..79）
while not all_done and step < 80:
    feed = {
        input_ids: [B,1] = tok,            # 每步只喂 1 个 token
        encoder_hidden_states: [B,196,768],
        position_ids: [B,1] = step,        # 绝对位置，每行都等于 step
        past_key_values.*: present.*,      # 上一步的 8 个输出
    }
    out  = kv.run(feed)
    tok  = argmax(out.logits[:, -1, :])
    present.* = out.present.*
    step += 1
```

与现有 `BatchDecodeState` 的对应关系：
已完成的行继续喂 `pad(0)`（其 logits 丢弃），所有行共享同一个前缀长度 ⇒ 所有行的 `position_ids` 相同。
**注意**：`position_ids` 的值必须等于该步的 past 长度（第 k 步 = k），否则位置编码会错。

### 注册表进料模板

| 字段 | 取值 |
| :--- | :--- |
| Component ID | 建议 `ocr_ja` 新增子项，如 `decoder_kv` / `decoder_kv_step0` |
| File | `manga_ocr_decoder_kv.onnx` / `manga_ocr_decoder_kv_step0.onnx` |
| Source | 本仓库 Actions artifact `manga-ocr-decoder-kv-onnx`（由 `kha-white/manga-ocr-base` 导出） |
| Size (Bytes) | 取自 `meta.json.artifacts[].bytes` |
| SHA-256 | 取自 `meta.json.artifacts[].sha256` |
| I/O | 取自 `meta.json.artifacts[].inputs/outputs` |
| opset / IR / precision | 取自 `meta.json.artifacts[].opset / ir_version / precision` |
| token ids | `meta.json.token_ids`（pad 0 / start 2 / eos 3 / max 80） |
| encoder seq len | `meta.json.decoder.encoder_seq_len`（196） |

---

## 7. 如果导出失败：排查清单

按报错定位：

1. **下载阶段**
   * `could not download ... from any endpoint`：mirror 与官方都失败。检查 `model_id` 拼写、网络策略；
     私有/限流时设置 `HF_TOKEN` secret 后重跑。
   * 只拿到 `config.json` 没拿到权重：确认仓库里有 `pytorch_model.bin` 或 `model.safetensors`；
     本脚本用 `allow_patterns` 白名单，新增格式需同步。
   * `reference download ... failed`：参考 B 缺失**不会**让 job 失败，但 summary 会写明
     "old-path reference is PyTorch only"。要恢复交叉校验就重跑（缓存命中后很快）。
2. **依赖阶段**
   * torch CPU index 挂：workflow 已自动回退 PyPI 镜像；仍失败就手动指定版本。
   * `could not force eager attention (found BertSdpaSelfAttention)`：只设 decoder 子配置是**不够**的——
     `VisionEncoderDecoderModel` 用的是顶层 `config._attn_implementation`
     （`modeling_vision_encoder_decoder.py` L193/L196），而 `_from_config` 又让这个 kwarg 覆盖子配置
     （`modeling_utils.py` L1478-1485）。**不要**放它过去——SDPA 的 ONNX 分解
     会改变数值路径。先确认 pin 的 transformers 版本，再重跑。
   * `decoder is ... not a BERT decoder`：`model_id` 不是 manga-ocr（或其 decoder 已换架构）。
3. **结构发现阶段**
   * `cache has N layers, config says M` / `unexpected cache tuple arity`：上游改了 cache 结构。
     对照 §2.2 的 `BertLayer` 代码确认；本脚本对 2 元组/4 元组都支持，其他 arity 会显式报错。
4. **导出阶段**
   * `torch.onnx.export` 报不支持算子：确认走的是 TorchScript tracer（`dynamo=False`）；
     必要时调整 `--opset`（17→18）或核对 torch 版本。
   * 图能导出但 ORT 加载即报 shape 错：检查 `position_ids` / past 的维度；
     自注意力 past 的 `dim2` 必须等于 `position_ids` 的值。
5. **等价性失败**（最关键）
   * 看 `SUMMARY.md` 的 `Mismatches` 行，每行带 `ref_top2` / `new_top2`：
     * **top2 相同**、logits 差在 1e-6 量级而 argmax 不同 ⇒ 浮点平局（tie）。
       先重跑确认可复现；再用 `--no-shipped-check` 区分是"与现役产物"还是"与 PyTorch 参考"不一致。
     * **top2 不同**或 logits 差很大 ⇒ 真分歧。优先怀疑：`position_ids` 值错、
       全 1 mask 未生效（3 维 mask 路径）、cross cache 被当成自 cache（I/O 顺序错位）。
   * `batch_invariant=false` ⇒ 批处理路径的 pad / position 处理与单行不一致，对照 §6 伪代码。
6. **上传阶段**
   * artifact 体积：两张图各 ~117 MB。超限就拆成两个 artifact 或把 `compression-level` 调成 `0`。
   * 等价性失败时**没有** ONNX artifact（只有诊断 artifact），这是设计如此。

---

## 8. 本地未验证的部分（诚实清单）

本机 `huggingface.co` 不可达，且任务硬约束要求**不在本机安装/运行 torch、不导出、不跑测试、不构建**。
因此以下内容**没有在本地验证过**，全部由云端 job 自证：

* 脚本从未在本机执行（本地只有静态阅读；CI 里有 `py_compile` 语法门）；
* 两张图的实际字节数、SHA256、opset 落盘结果——以 `meta.json` / `SUMMARY.md` 为准；
* `position_ids` 显式输入 + `[1,1,1]` 全 1 mask 在**动态 past 长度**下的正确性——
  由 `long_line`（79 步）与 `batch_gt_1` 的逐步 argmax 一致性证明；
* 与现役 `decoder_model.onnx` 的一致性——由 `shipped_reference_crosscheck` 证明；
* 导出耗时、artifact 体积、fp16 路径（`fp16=true` 时才会走到）。

**已被 pinned 源码证实**（§2，行号可查）：cache 打包顺序、cross-attention 无条件复用、
位置偏移被常量化、输出结构、以及"必须双图"的结论。
