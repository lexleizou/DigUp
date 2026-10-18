# 窗口方案说明：为什么不需要额外的对齐模型

**日期**：2026-10-18
**分支**：`feat/asr-phase4`
**背景**：Qwen3-ASR 对整段音频只返回单段时间戳，没有内部 VAD 切分。这份文档说明这对 DigUp 为什么没有影响，以及在什么情况下才需要一个对齐模型。

---

## 1. 结论

**不需要替换 ASR 模型，也不需要额外的时间戳对齐模型。**

模型不切分，但 **DigUp 在送进去之前就切好了**：每个 30 秒窗口单独调用一次 ASR，返回值只需对应这一个窗口。单段时间戳的缺点在架构层面被消化掉，时间定位的精度由窗口步进（25 秒）决定，不由模型决定。

下一节是实测证据。

---

## 2. 实测：79 秒录音，三段互不相关的主题

### 2.1 测试材料

用 `say` 生成三段内容完全不相关的中文语音，每段之间插入 20 秒静音，拼成 79.1 秒的 WAV：

| 段落 | 内容 |
|---|---|
| 第一段 | 服务器机房的空调改造方案，需要增加两台风冷机组 |
| 第二段 | 网络安全等级保护测评，需要在月底前完成整改 |
| 第三段 | 员工食堂的供应商招标，下周三开标 |

插入静音是刻意的：它让三段主题在时间轴上明显分开，任何定位错误都会暴露。

### 2.2 索引结果

```
[1/1] audio  done  6.75s  长录音.wav  (3 windows, 79 s, 3 written down)
```

**3 个窗口，每个都写出了文字。** 数据库里的对应关系：

| 窗口 | 转写文本 |
|---|---|
| `0-30 s` | 第一部分，我们讨论服务器机房的空调改造方案，需要增加两台风冷机组。第二部分，关于网络安全等。 |
| `25-55 s` | 第二部分关于网络安全等级保护测评，需要在月底前完成整改。第三部分。 |
| `50-79 s` | 第三部分，员工食堂的供应商招标，下周三开标。 |

**每个窗口带自己的 `loc` 和 `loc_end`。** 模型返回的单段时间戳在窗口内部被丢弃，位置信息完全由窗口提供。

### 2.3 检索定位

| 查询 | 定位 | 正确? |
|---|---|---|
| 「空调改造」 | `[at 0:00 (sound)]` | ✅ 第一段 |
| 「网络安全」 | `[at 0:25 (sound)]` | ✅ 第二段 |
| 「整改」 | `[at 0:25 (sound)]` | ✅ 第二段 |
| 「食堂」 | `[at 0:50 (sound)]` | ✅ 第三段 |
| 「招标」 | `[at 0:50 (sound)]` | ✅ 第三段 |

**5 个查询全部落到正确的时间点。**

---

## 3. 两个可能被误认为问题的地方

### 3.1 静音窗口被跳过

`Media+Apple.swift:32` 有一行：

```swift
guard rms(slice) > 0.003 else { return }   // ≈ −50 dBFS: silence isn't worth a vector
```

79 秒音频理论上应产生 4 个窗口（`0-30`、`25-55`、`50-79`），实际只有 3 个，因为中间的静音窗口被跳过。

**这不是问题，是节省。** 静音没有内容可转写，跳过它省掉一次 HTTP 调用和一次模型推理。时间轴上的「洞」只存在于没有声音的地方，用户不会去那里找内容。

### 3.2 重叠窗口导致同一句话出现在两个窗口

窗口 30 秒、步进 25 秒，所以相邻窗口重叠 5 秒。实测中「网络安全」同时出现在 `0-30` 和 `25-55` 两个窗口里：

```
窗口 0-30 s   → …第二部分，关于网络安全等。          ← 被截断的半句
窗口 25-55 s  → 第二部分关于网络安全等级保护测评…   ← 完整的一句
```

**这不会造成结果重复。** DigUp 对每个文件只保留得分最高的那个 segment（`Searcher.swift` 的 `best[rowFile[row]]`），所以搜「网络安全」只返回一条：

```
1. audio  长录音.wav  [at 0:25 (sound)]   (z 1.1, words #1)
```

指向的是完整那句所在的窗口，而不是被截断的那个。

---

## 4. 精度上限是多少

| 参数 | 值 | 位置 |
|---|---|---|
| `audioWindow` | 30 秒 | `Model.swift:66` |
| `audioHop` | 25 秒 | `Model.swift:67` |

**最大误差约 25 秒**：一个时刻 T 会被起点在 `[T-25, T]` 范围内的某个窗口覆盖。换句话说，跳过去之后最多往回听 25 秒就能听到目标内容。

对「跳到那一刻开始听」这个用法，25 秒是可接受的：

| 场景 | 25 秒精度够用吗 |
|---|---|
| 2 小时会议录音，跳到讨论预算的那一段 | ✅ 够用 |
| 播客，跳到聊睡眠的那一分钟 | ✅ 够用 |
| 显示带时间轴的逐字稿，文字跟随音频滚动 | ❌ 不够，需要字级 |
| 生成字幕文件（SRT/ASS） | ❌ 不够，需要句级或字级 |

---

## 5. 什么情况下才需要对齐模型

如果真的需要字级时间戳，官方同家族有现成的，**不用换 ASR 模型**：

### Qwen3-ForcedAligner-0.6B

官方仓库原文：

> We introduce **Qwen3-ForcedAligner-0.6B**, which supports timestamp prediction for **arbitrary units within up to 5 minutes of speech in 11 languages**. Evaluations show its timestamp accuracy surpasses E2E based forced-alignment models.

| 项 | 说明 |
|---|---|
| 类型 | 非自回归专用对齐模型（NAR） |
| 能力 | 5 分钟语音内**任意粒度**时间戳（词级 / 字级） |
| 语言 | 中文、英文、粤语、法、德、意、日、韩、葡、俄、西（**11 种，含中文**） |
| 输入 | ASR 出的文字 + 原音频，两步走 |
| 体积 | MLX 版 `bf16` 1.84 GB / `8bit` 1.28 GB |
| 获取 | `mlx-community/Qwen3-ForcedAligner-0.6B-bf16` |

**注意它也有上限**：单次最多 5 分钟。所以它仍然要配合窗口使用 —— 把 30 秒窗口的音频和该窗口的转写文字一起送进去，得到窗口内的字级时间轴。

### 替代方案（不推荐）

| 方案 | 为什么不选 |
|---|---|
| Whisper large-v3 / turbo | 换成它等于换掉整个 ASR 模型。中文精度不如 Qwen3-ASR，还要重新配一套推理 |
| WhisperX | 基于 Whisper，同上；且依赖 PyTorch 生态，与 DigUp 的 Swift 栈不搭 |
| SenseVoice / Paraformer | 中文不错，但同样是要换模型，而当前模型没有问题 |

**关键判断：时间戳不够细是「缺一个配套件」，不是「选错了模型」。**

---

## 6. 如果要做，大概多少工作量

留给将来的自己：

| 改动 | 位置 | 说明 |
|---|---|---|
| `ForcedAligner` 客户端 | 新增 `Sources/DigUpKit/Align.swift` | 与 `Transcript.swift` 同构，HTTP 调用 |
| `Aligner` 协议 + 环境变量 | `DIGUP_ALIGN_URL` / `DIGUP_ALIGN_MODEL` | 与 `DIGUP_ASR_URL` 同样默认关闭 |
| 索引期调用 | `Indexer.audio()` | 转写后对同一窗口调一次对齐，得到 `[(word, start, end)]` |
| 存储 | **需要 schema 7** | 字级时间轴存不进现有的 `fts` 一行，需要一个新表或 JSON 列 |
| UI | `SearchPanelView` / `Preview` | 结果页展示带时间轴的逐字稿 |

**约 150–250 行 + 一次 schema 迁移。** 相比阶段 4 的 200 行，成本相当，但收益只在「显示逐字稿」这一个场景。

---

## 7. 建议

**保持现状，不加对齐模型。**

理由：

1. 实测证明当前的时间定位是准确的 —— 79 秒三段主题，五个查询全部落对
2. 对齐模型的收益只在「字级逐字稿」这一个场景，而 DigUp 的结果页显示的是 `[at 0:25 (sound)]`
3. 1.3 GB 额外模型 + schema 迁移，换 25 秒 → 1 秒的精度提升，投入产出比不对

**什么时候改口**：如果要做「会议录音逐字稿」视图，让文字随音频滚动高亮 —— 那时对齐模型是必需件。

---

## 附：复现

```bash
# 1. 生成测试音频（三段主题 + 20 秒静音间隔）
cd ~/AgentScratch/20261017-digup-i18n && mkdir -p window-test && cd window-test
say -v Tingting -o p1.aiff "第一部分，我们讨论服务器机房的空调改造方案，需要增加两台风冷机组。"
say -v Tingting -o p2.aiff "第二部分，关于网络安全等级保护测评，需要在月底前完成整改。"
say -v Tingting -o p3.aiff "第三部分，员工食堂的供应商招标，下周三开标。"
for f in p1 p2 p3; do afconvert -f WAVE -d LEI16@16000 -c 1 $f.aiff $f.wav; done
# （拼接脚本见 CN-PHASE4-RESULTS.md 的实测章节）

# 2. 打开转写后索引
export DIGUP_MODELS="$HOME/Library/Application Support/me.dotenv.LokalBot/models"
export DIGUP_ASR_URL="http://127.0.0.1:8000/v1/audio/transcriptions"
export DIGUP_ASR_MODEL="Qwen3-ASR-1.7B-bf16"

# 3. 看每个窗口的定位
.build/release/digup index window-test --index window-test/.index
sqlite3 -separator ' | ' window-test/.index/index.sqlite "
  SELECT printf('%.0f-%.0f s', s.loc, s.loc_end), substr(coalesce(fts.original, fts.body), 1, 60)
  FROM segments s JOIN fts ON fts.rowid = s.id WHERE s.kind = 'audio' ORDER BY s.loc;"
```

来源：
- https://github.com/QwenLM/Qwen3-ASR（ForcedAligner 能力与语言列表）
- https://huggingface.co/mlx-community/Qwen3-ForcedAligner-0.6B-bf16
