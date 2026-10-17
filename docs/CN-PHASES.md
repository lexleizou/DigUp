# 分阶段实施手册

每个阶段一个独立分支，可单独 rebase、单独验证、单独提交上游。

| 阶段 | 分支 | 内容 | 预估 | 状态 |
|---|---|---|---|---|
| 0 | — | 装官方 DigUp，索引核心目录 | 0.5 天 | 待做 |
| **1** | `feat/cn-search-phase1` | 中文全文检索 | 2 天 | **进行中** |
| 2 | `feat/office-phase2` | 合并 PR #86（pptx/xlsx 文字） | 1 天 | 待做 |
| 3 | `feat/render-phase3` | 幻灯片渲染 + doc/xls 转换 | 3 天 | 待做 |
| 4 | `feat/asr-phase4` | 录音转写挂载 | 3 天 | 待做 |
| 5 | `feat/polish-phase5` | 版本去重、评估集、UI 过滤 | 持续 | 待做 |

---

## 阶段 0：基线验证

**目的**：先确认官方版本在你的语料上表现如何，作为后续对比基准。

```bash
brew install --cask arahim3/tap/digup
```

### 索引范围（按成本排序）

| 优先级 | 目录 | 文档 | 体积 |
|---|---|---|---|
| 1 | `01. Customers 客户` | 39,607 | 96.5 GB |
| 2 | `03. Management 经营与团队` | 24,269 | 54.0 GB |
| 3 | `02. Knowledge 知识资产` | 2,315 | 47.0 GB |

**先只索引 `01. Customers`**，跑通再扩。首次全量 176 GB 在 M1 Max 上约 1–2 天。

### 验收

- [ ] `digup status` 显示索引文件数正常
- [ ] 搜「数字孪生」能找到 pdf/docx
- [ ] 搜「验收报告」**找不到**（这是阶段 1 要修的，作为对照）
- [ ] 记录 `digup speed --json` 的基线数据

---

## 阶段 1：中文全文检索

**分支**：`feat/cn-search-phase1`

### 改动

| 文件 | 改动 |
|---|---|
| `Sources/DigUpKit/SearchText.swift` | `joinsWords()` / `cutsInPairs()` / `indexable()`；`matches()` 前缀规则加 Han |
| `Sources/DigUpKit/IndexStore.swift` | `schemaVersion` 5→6；`keywordText()` 走 `indexable`；`indexed()`；`addNameRow` / `move` 统一；`migrateKeywordPairs()` |
| `Sources/DigUpKit/Searcher.swift` | `patterns()` 构造 Han 短语；中文停用词；中文 `kindWords` |
| `Tests/DigUpKitTests/SearchTextTests.swift` | 4 个新测试 |

### 构建

```bash
./scripts/build-llama.sh     # 首次，几分钟
swift build -c release
swift test
```

### 验证清单

- [ ] `SearchText.indexable("验收报告") == "验收 收报 报告"`
- [ ] `indexable("报") == "报"`（单字保留）
- [ ] `indexable("PDF报告") == "PDF报告 告"`（Han 从拉丁后开始）
- [ ] 搜「验收报告」命中含该串的文件
- [ ] 搜「报告验收」不命中（顺序敏感）
- [ ] 搜「验收」命中文件名 `项目验收报告.pdf`
- [ ] 高亮：`matches` 标出「验收报告」
- [ ] schema 5 索引能迁移到 6

### 回归（必跑）

```bash
.build/release/digup eval evals/synthetic.json
.build/release/digup eval evals/code.json
.build/release/digup eval evals/multilingual.json
```

**判据**：`synthetic` / `code` 的 R@1 与改动前完全一致。`multilingual`（孟/阿）不变。

### 提交

```bash
git add -A
git commit -m "Search Chinese text by its pairs, not as one word

The tokenizer splits on spaces, so a run of Han characters reached it as one
word and a search for part of it found nothing. Text is now stored as
overlapping pairs (验收报告 → 验收 收报 报告) and a query becomes the phrase
of its own pairs, which matches only where they sit together and in order.

Schema 5 → 6 rebuilds the words from what's stored. Rows that kept only the
cut-up body are read again.

Latin, Bengali and Arabic are unaffected: the tokenizer and inflects are
unchanged."
```

### 已知问题

| 问题 | 处理 |
|---|---|
| 单字查询不命中 | 接受。`terms()` 两字符门槛已挡 |
| 迁移需重读部分文件 | 只针对 `original IS NULL` 且有 Han 的行 |
| 索引体积增大 | Han 部分约 5.7×，英文不变 |

---

## 阶段 2：Office 文字

**分支**：`feat/office-phase2`（基于阶段 1）

### 改动

```bash
git cherry-pick <PR#86 的 commit>
# 或
git fetch upstream pull/86/head:pr86 && git cherry-pick pr86
```

PR #86 提供：
- `Sources/DigUpKit/OfficeText.swift`（+480 行）：xlsx/ods 按行、pptx/odp 按页+备注
- `Sources/DigUpKit/Platform/Apple/Zip+Apple.swift`（+80 行）
- `Tests/DigUpKitTests/OfficeTests.swift`（+344 行）

### 需要额外做的

1. **`Rules.docExtensions` 加扩展名**：`pptx`, `pptm`, `xlsx`, `xlsm`, `odp`, `ods`
2. **schema 7**：已有索引里的 pptx/xlsx 是 `skip`，需要重新分类
   ```swift
   // 迁移：把之前忽略的 Office 文件标为 pending
   UPDATE files SET state = 'pending' WHERE path LIKE '%.pptx' OR path LIKE '%.xlsx' ...
   ```
3. **`FileKind` 是否加 `.slides` / `.sheet`**：建议不加，复用 `.doc`，避免改 UI 和 SQL 排序

### 验证

- [ ] `项目验收报告.pptx` 能被搜到
- [ ] 演讲者备注能被搜到
- [ ] xlsx 的单元格文字能被搜到
- [ ] 中文 pptx 搜「验收」命中

### 风险

| 风险 | 应对 |
|---|---|
| Excel 全行入库体积爆炸 | 设 `maxChunks`，只索引前 N 行 |
| PPT 备注格式多样 | 先只取 `<a:t>`，不解析复杂结构 |

---

## 阶段 3：渲染与转换

**分支**：`feat/render-phase3`

### 3a. 幻灯片渲染

新增 `SlideRenderer`，把 pptx 每页渲染成图，走现有 `pageImage` 路径。

| 方案 | 优点 | 缺点 |
|---|---|---|
| **QuickLook 缩略图** | 零依赖，系统自带 | 只有首页，分辨率低 |
| **PowerPoint AppleScript 导 PDF** | 保真度最高 | 慢，需 UI 授权，不适合批量 |
| **LibreOffice 无头** | 批量稳定，跨平台 | 需装 1.5 GB，中文字体要配 |

**推荐 LibreOffice**，作为后台低优先级任务。

```bash
brew install --cask libreoffice
soffice --headless --convert-to pdf --outdir <tmp> <file.pptx>
```

然后复用现有 PDF 管道（`PDFExtractor.pages`）—— 文字、渲染图、OCR 全部现成。

### 3b. doc / xls 转换

同一条 LibreOffice 路径，`.doc` → PDF，`.xls` → 暂不转（表格无渲染价值，等阶段 2 的 OfficeText 支持 .xls 二进制格式则另说）。

### 3c. docx 内嵌图片

`docx` 的 `word/media/` 里的图片单独抽出来，走 `image` 路径。

### 验证

- [ ] pptx 里的甘特图能被「项目进度」搜到
- [ ] pptx 里的架构图能被「网络拓扑」搜到
- [ ] 老 .doc 能被搜到

### 风险

| 风险 | 应对 |
|---|---|
| 6,699 个 deck × 13 页 ≈ 87,000 张图 | 只渲染有图表的页；后台分批 |
| LibreOffice 中文字体 | 装 Source Han Sans / 确认 PingFang 可用 |
| 转换失败 | 记 `failed`，不阻塞 |

---

## 阶段 4：录音转写

**分支**：`feat/asr-phase4`

### 设计

复用 DigUp 已有的 30 秒窗口 / 25 秒步进（`AudioExtractor.windows`），每个窗口送 ASR，转写文本挂在**同一个 segment** 上：

```swift
try store.addSegment(file: file.id, kind: .audio, modality: .audio,
                     loc: piece.start, locEnd: piece.end,
                     text: transcript,          // ← 新增：进 FTS
                     vector: embedding.vector)
```

`addSegment` 已有 `text:` 参数，**不需要改 schema**。

### ASR 客户端

```swift
struct ASRClient {
    let endpoint = URL(string: "http://127.0.0.1:8000/v1/audio/transcriptions")!
    let model = "Qwen3-ASR-1.7B-bf16"

    func transcribe(_ wav: URL) async throws -> String {
        // multipart POST，读 JSON 的 .text 字段
    }
}
```

### 实测数据（2026-10-17，M1 Max）

| 音频时长 | 推理耗时 | 速度 |
|---|---|---|
| 12.6 s | 1.7 s | 7.4× |
| 55.3 s | 2.8 s | 19.7× |

准确率：中文短句完全正确。

### 限制

**Qwen3-ASR 对整段只返回单段时间戳**（`segments` 只有 1 个），没有内部 VAD。所以必须靠外部窗口切分 —— 正好复用 DigUp 的窗口逻辑。

### 降级

ASR 服务不可用时：

```swift
// 转写失败不阻塞索引：音频向量照常写入，只是没有 text
```

### 验证

- [ ] 搜「张三」命中含该人名的录音，定位到秒
- [ ] 搜「验收标准」命中相关录音片段
- [ ] 视频音轨同样可搜
- [ ] ASR 服务关闭时，音频仍能索引（只是不能关键词搜）

### 风险

| 风险 | 应对 |
|---|---|
| 50 GB 音视频转写耗时 | 估算 2–3 小时，后台跑 |
| 隐私 | oMLX 在 127.0.0.1，不出本机 |
| 中英混杂 | Qwen3-ASR 支持 code-switching |

---

## 阶段 5：打磨

**分支**：`feat/polish-phase5`

| 项 | 内容 |
|---|---|
| 版本去重 | 同名文件的 `-v1.0-20261017` / `Final` 归组，只显示最新 |
| 评估集 | 补中文用例到 `evals/multilingual.json` |
| UI 过滤 | `FileKind` 增加 pptx/xlsx 筛选 |
| 索引预算 | Excel 行数上限、PPT 渲染页数上限 |

### 中文评估集建议

```json
{"q": "验收报告", "expect": ["synthetic/lang/zh/项目验收报告.pdf@1-1"], "tag": "zh-doc"},
{"q": "押金条款", "expect": ["synthetic/lang/zh/租赁合同.pdf@3-3"], "tag": "zh-doc"},
{"q": "annual report 营收", "expect": ["synthetic/lang/zh/年报.md"], "tag": "zh-mixed"}
```

---

## 上游跟进节奏

```bash
# 每周
git fetch upstream
git log --oneline upstream/main -20        # 看有什么变化
git rebase upstream/main feat/cn-search-phase1
```

**rebase 冲突热点**：
- `IndexStore.swift` 的 `migrate()` 调度（每个新迁移都会改）
- `Searcher.swift` 的 `patterns()` 和 `terms()`
- `Rules.swift` 的 `docExtensions`

**原则**：每个阶段一个分支，冲突只影响单点，不牵连。
