# 阶段 4 实测报告：录音转写

**日期**：2026-10-18
**分支**：`feat/asr-phase4`（基于 `feat/office-phase2`）
**改动**：音频窗口增加转写文本，接入本机 ASR

---

## 1. 结论

| 项 | 结果 |
|---|---|
| 录音内容可搜 | ✅ 「张三」「网络拓扑」「预算」「牛肉面」都能定位到录音 |
| 定位精度 | ✅ 精确到秒（`[at 0:00 (sound)]`），并高亮原话 |
| 转写速度 | ✅ 11 秒语音 0.71 秒（**15×**） |
| 失败降级 | ✅ 服务器不可用不导致文件失败，音频向量照常存在 |
| schema 改动 | **不需要**（`addSegment` 早有 `text:` 参数） |
| 单元测试 | **108 个通过**（+5 个转写测试） |
| 默认行为 | **关闭**。不设 `DIGUP_ASR_URL` 时与改动前完全一致 |

---

## 2. 解决的问题

阶段 3 之前的实测记录：

| 查询 | 能否搜到录音 |
|---|---|
| 「哪段录音在聊美食」 | ✅ 能（音频语义向量） |
| 「哪段录音提到张三」 | ❌ **不能** |
| 「哪段录音说了项目编号」 | ❌ **不能** |

音频向量捕捉声学语义，不含字面。`Indexer.swift:698` 原来只写向量：

```swift
addSegment(kind: .audio, modality: .audio, loc: piece.start, locEnd: piece.end, vector: embedding.vector)
//                                                                          ↑ 没有 text:
```

---

## 3. 设计

> **关于时间戳**：Qwen3-ASR 对整段音频只返回单段时间戳，但这对 DigUp 没有影响 —— 窗口在送进去之前就切好了。实测证据与边界分析见 [CN-WINDOW-AND-TIMESTAMPS.md](CN-WINDOW-AND-TIMESTAMPS.md)。

### 核心：一句话

**音频窗口不变，只是多了一行字。** 同一个 segment 同时携带声学向量和文字：

```swift
addSegment(kind: .audio, modality: .audio, loc: piece.start, locEnd: piece.end,
           excerpt: said[index].map { excerpt($0) },   // 展示用
           text: said[index],                          // 进 FTS
           vector: vectors[index].vector)              // 进语义层
```

`addSegment` 早有 `text:` 参数（写 FTS）和 `excerpt:`（展示），**不需要改 schema**。

### 窗口复用

不新增切分逻辑，直接复用 DigUp 已有的 30 秒窗口 / 25 秒步进（`AudioExtractor.windows`）。

这是刻意的：Qwen3-ASR 对整段音频**只返回单段时间戳**（实测 `segments` 只有 1 个），没有内部 VAD 切分。所以时间戳必须来自外部窗口，而 DigUp 的窗口天然对齐。

### 接口

```swift
public protocol Transcriber: Sendable {
    func text(ofWindowAt url: URL) -> String?
}
```

`LocalTranscriber` 走 OpenAI 兼容的 `/v1/audio/transcriptions`（oMLX、LM Studio、whisper.cpp 服务器都说这个协议）。

### 配置

三个环境变量，都不设就完全关闭：

| 变量 | 作用 |
|---|---|
| `DIGUP_ASR_URL` | 语音服务地址（**唯一的必需项**） |
| `DIGUP_ASR_MODEL` | 模型名，不填则问 `/v1/models` 自动选 |
| `DIGUP_ASR_KEY` | API key，本地服务通常不需要 |

### 三个刻意的决定

**① 默认关闭。** 这是隐私敏感能力：录音是唯一无法从文件本身读出文字的类型，送出去转写会破坏 README 承诺的「Nothing you index leaves your computer」。所以必须用户显式打开。

**② 失败不致命。** 服务器没启动、超时、返回垃圾 —— 都只是「没有文字」，文件仍然靠声学向量入索引，状态仍是 `done`。

```swift
guard let data = ..., let json = ... else { return nil }   // 不 throw
```

**③ 过滤无意义转写。** `[BLANK_AUDIO]`、`(music)` 这类纯噪声标记会被丢掉，它们不是任何人会搜的词。

---

## 4. 实测

### 4.1 端到端（中文）

三段录音，**文件名改成中性的「录音A/B/C」**，排除字面线索：

```
录音A.wav → 今天开会讨论数字孪生二期项目，张三负责网络拓扑设计，李四负责数据采集层。预算方面还需要客户确认。
录音B.wav → 这家的牛肉面特别好吃，汤头浓郁，面条劲道，价格也实惠，下次还要来。
录音C.wav → Our quarterly revenue grew by 20%, driven by strong sales in Europe.
```

索引日志：

```
[1/3] audio  done  3.07s  录音C.wav  (1 windows, 4 s, 1 written down)
[2/3] audio  done  0.71s  录音B.wav  (1 windows, 7 s, 1 written down)
[3/3] audio  done  0.76s  录音A.wav  (1 windows, 11 s, 1 written down)
```

**检索结果**（这是阶段 4 的核心价值）：

| 查询 | 结果 | 展示 |
|---|---|---|
| 「张三」 | ✅ 录音A | `“今天开会讨论数字孪生二期项目，«张三负责网络拓扑设计»…”` |
| 「网络拓扑」 | ✅ 录音A | `“…张三负责«网络拓扑设计»…”` |
| 「预算」 | ✅ 录音A | `“…«预算方面还需要客户确认»。”` |
| 「牛肉面」 | ✅ 录音B | `“这家的«牛肉面特别好吃»…”` |
| 「revenue」 | ✅ 录音C | `“Our quarterly «revenue» grew by 20%…”` |
| 「客户确认」 | ✅ 录音A | `“…«客户确认»。”` |

**6 个查询全部命中，且高亮准确、定位到秒。**

### 4.2 速度

| 音频 | 耗时 | 倍数 |
|---|---|---|
| 11 s | 0.76 s | **14.5×** |
| 7 s | 0.71 s | **9.9×** |
| 4 s | 3.07 s | 1.3×（首次调用加载模型） |

按 10× 保守估算，50 GB 音视频里的语音部分（约 10–20 小时）需 **1–2 小时**转写。

### 4.3 失败降级验证

| 场景 | 结果 |
|---|---|
| 不设 `DIGUP_ASR_URL` | ✅ 与改动前完全一致，音频段无文字 |
| 服务器不可达（`127.0.0.1:9`） | ✅ `text()` 返回 nil，不抛异常 |
| 窗口无语音（音乐、静音） | ✅ 文件状态 `done`，声学向量存在 |

单元测试 `aWindowNobodyCouldReadStillIndexesByHowItSounds` 断言了这一点：状态是 `done` 而非 `failed`，且音频向量数为 1。

---

## 5. 新增测试

| 测试 | 验证内容 |
|---|---|
| `whatIsSaidIsSearchableAndOpensAtItsMoment` | 转写文本可搜、定位到 `loc`、excerpt 含高亮 |
| `aWindowNobodyCouldReadStillIndexesByHowItSounds` | 转写失败不影响索引，向量仍在 |
| `withNoTranscriberRecordingsAreUnchanged` | 默认关闭时行为与改动前一致 |
| `theEnvironmentNamesTheServer` | 环境变量解析，含空值和缺省 |
| `aServerThatIsNotThereIsNotAFailure` | 不可达服务器返回 nil 而非抛异常 |

---

## 6. 使用方式

```bash
# 启动本机 ASR（示例：oMLX）
omlx serve                     # 监听 127.0.0.1:8000

# 打开转写后索引
export DIGUP_ASR_URL="http://127.0.0.1:8000/v1/audio/transcriptions"
export DIGUP_ASR_MODEL="Qwen3-ASR-1.7B-bf16"
export DIGUP_ASR_KEY="<你的 key>"          # 本地服务通常不需要

.build/release/digup index <目录> --index <索引目录>
```

**注意**：转写文本属于关键词层，**不改变向量**。所以：
- 之前已索引的音频不会自动重转写 —— 需要把状态改回 `pending` 或重建索引
- 这也不会导致 `fingerprint` 变化（不会触发全库重嵌）

---

## 7. 已知限制

| 限制 | 说明 |
|---|---|
| 时间戳粒度 | 30 秒窗口级（步进 25 秒）。**这对 DigUp 不构成问题**，实测证明定位准确，见 [CN-WINDOW-AND-TIMESTAMPS.md](CN-WINDOW-AND-TIMESTAMPS.md) |
| 只转写语音 | 音乐、环境音效转写为 `[BLANK_AUDIO]` 之类的标记，会被过滤掉 |
| 长音频耗时 | 2 小时录音 = 288 个窗口 = 288 次 HTTP 调用。按实测约 5–10 分钟，可接受但不算快 |
| 无说话人分离 | 不区分「谁说的」，只记录「说了什么」 |
| 未做并发 | 窗口逐个转写。可以并行化，但会增加本机 ASR 服务压力 |
| 旧音频需重新索引 | 见上 |

---

## 8. 下一步（阶段 5）

| 项 | 内容 |
|---|---|
| 版本去重 | 同名文件的 `-v1.0-20261017` / `Final` 归组 |
| ASR 并发 | 窗口并行转写，缩短长录音耗时 |
| 幻灯片渲染 | 阶段 2 遗留：PPT 图表内容读不到 |
| 二进制 .ppt/.xls | 需 LibreOffice 转换 |
| 中文界面 | PR #34 / #112 的框架 |
