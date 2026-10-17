# DigUp 中文增强版

在 [ARahim3/DigUp](https://github.com/ARahim3/DigUp)（MIT）基础上扩展：中文全文检索、Office 文档读取、录音转写。

> 本仓库是 fork，上游保持只读跟踪。所有改动以分支形式维护，便于随时 rebase 到上游新版本。

---

## 1. 设计目标

| 目标 | 说明 |
|---|---|
| 覆盖日常文件类型 | pptx / docx / xlsx / pdf / md / 图片 / 音视频 / doc / xls |
| 中文可用 | 语义检索 + 精确关键词检索都要能搜中文 |
| 不换嵌入模型 | 继续用 EmbeddingGemma 2（768 维，Q8_0），保证已有索引不失效 |
| 上游可跟进 | 不侵入内核，改动集中在扩展点和中文层 |

### 非目标

- 不做 dwg / mpp / vsdx 解析（无成熟开源抽取方案）
- 不做中文界面本地化（独立议题，见 PR #34 / #112）
- 不改 Windows / Linux 外壳（只保证引擎层跨平台一致）

---

## 2. 三层架构

| 层 | 技术 | 职责 | 是否改动 |
|---|---|---|---|
| 语义层 | EmbeddingGemma 2（768 维，Q8_0 GGUF） | 「描述你要找的东西」 | ❌ 不动 |
| 关键词层 | SQLite FTS5（`porter unicode61`） | 精确字面：编号、人名、料号 | ✅ 补中文分词 |
| 转写层 | Qwen3-ASR-1.7B（本机 oMLX） | 录音 → 文字，喂给上面两层 | ➕ 新增 |

**关键约束**：`Vectors.dimension = 768` 是模型输出投影宽度，不能改。换模型会推翻全部索引。

---

## 3. 归一化原则

所有新格式都归一化成 DigUp 已支持的三种表示：

| 表示 | 用于 | 定位锚 |
|---|---|---|
| 文本块（`chunk`） | 文档正文、表格行、转写文本 | 块序号 / 页 / 秒 |
| 页面图（`pageImage`） | 幻灯片、扫描件 | 页号 |
| 时间窗（`audio` / `frame`） | 音视频 | 秒 |

**不新增表示类型，不新增 schema 表。** 新格式只是新的「抽取器」，产出上述三种之一。

---

## 4. 各类型处理方案

| 类型 | 方案 | 定位锚 | 阶段 |
|---|---|---|---|
| pdf / md / 图片 / 音视频 | DigUp 原生 | — | 已有 |
| **中文全文检索** | Han bigram 预处理 + schema 6 | — | **1** |
| **pptx** | OOXML 抽文字+备注（PR #86）；幻灯片渲染成图 | 页号 | 2 / 3 |
| **xlsx** | 每行文本进 FTS；表级摘要进语义层 | sheet+行 | 2 |
| doc / xls | LibreOffice 无头转换 → PDF | 页号 | 3 |
| docx | 原生；补抽 `word/media` 内嵌图 | 段落 | 3 |
| **录音 / 视频音轨** | ASR 转写挂在原时间窗上 | 秒 | 4 |
| msg / dwg / mpp / vsdx | 不做 | — | — |

### 关键取舍

**PPT 必须走「文字 + 渲染图」双路。** 实测 10 个样本：201 MB 的 pptx 只有 74,782 字（0.035 字/MB），97% 的检索价值在画面。

**Excel 不渲染。** 表格渲染成图无检索价值，且 18,664 个文件成本爆炸。查的是料号，纯 FTS 正好。

---

## 5. 阶段 1：中文全文检索

### 问题

`Searcher.terms()` 按非字母数字切词，中文字符属于字母，所以整句中文被当成一个 token：

```
terms("关于本项目验收报告的说明") → ["关于本项目验收报告的说明"]
```

FTS5 的 `unicode61` 分词器也只把连续 CJK 当一个词。结果：只有输入文件里的完整连续串才命中。

### 方案：Han bigram

不改分词器（`porter unicode61` 对拉丁文的行为完全不变），在写入时把连续 Han 字符切成重叠二元组：

```
"验收报告" → "验收 收报 报告"
```

查询时同样切分并作为**短语**匹配，天然保证顺序和相邻：

```sql
fts MATCH '"验收 收报 报告"'
```

| 特性 | 说明 |
|---|---|
| 子串召回 | 「验收」「验收报告」「收报」都能命中 |
| 顺序敏感 | 「报告验收」不命中 |
| 中英混合 | `"annual" AND "报告"` 正常 |
| 拉丁文零影响 | 只切 Han 字符，其余原样 |
| 索引成本 | Han 部分约 5.7×（700k 字实测 2 MB → 12 MB），英文不变 |

### 已知边界

| 限制 | 说明 |
|---|---|
| 单字查询 | bigram 无 pair，无法命中。`terms()` 的两字符门槛已挡住 |
| 假名 / 谚文 | 不切（`joinsWords` 只列 Han），靠 `inflects` 的前缀匹配 |
| 旧索引 | schema 6 迁移时，`original IS NULL` 且有 Han 的行需重读文件 |

### 改动清单

| 文件 | 改动 |
|---|---|
| `SearchText.swift` | `joinsWords()`、`cutsInPairs()`、`indexable()`；`matches()` 前缀规则加 Han |
| `IndexStore.swift` | `schemaVersion` 5→6；`keywordText()` 走 `indexable`；`indexed()` 辅助；`addNameRow` / `move` 统一；`migrateKeywordPairs()` |
| `Searcher.swift` | `patterns()` 对 Han 词构造短语；中文停用词；中文 `kindWords` |
| `SearchTextTests.swift` | 4 个新测试 |

---

## 6. 开发约定

```bash
# 首次
./scripts/build-llama.sh          # 构建 llama.cpp（几分钟）
swift build -c release

# 测试
swift test                         # 全量
swift test --filter SearchTextTests

# 检索质量回归（必跑）
.build/release/digup eval evals/multilingual.json
.build/release/digup eval evals/synthetic.json
.build/release/digup eval evals/code.json
```

### 回归判据

**改检索必须跑 evals，前后对比。** 阶段 1 的实测结果（2026-10-17，M1 Max，llama.cpp b11461，EmbeddingGemma 2 Q8_0）：

| eval | 查询数 | 改前 R@1 / R@5 | 改后 R@1 / R@5 | 判断 |
|---|---|---|---|---|
| `chinese`（新增） | 24 | 0.75 / 0.88 | **0.79 / 0.92** | 提升 |
| `synthetic` | 37 | 0.92 / 1.00 | 0.92 / 1.00 | 零回归 ✅ |
| `multilingual`（孟/阿） | 48 | 0.83 / 0.98 | 0.83 / 0.98 | 零回归 ✅ |
| `code` | 41 | 1.00 / 1.00 | 1.00 / 1.00 | 零回归 ✅ |

R@10：`chinese` 0.92 → 0.96，其余三项不变。

**关键验证**：中文关键词检索从「完全不可用」变为可用。改前搜「押金条款」查不到写着该条款的合同，改后 R@1 命中。

**完整数据**（逐标签、逐条变化、复现步骤）：[CN-PHASE1-RESULTS.md](CN-PHASE1-RESULTS.md)。

### 复现步骤

```bash
./scripts/make-testbed.sh              # 需要 ffmpeg，生成 ~/DigUpTestbed
DIGUP_MODELS=<模型目录> .build/release/digup index ~/DigUpTestbed --index <索引目录>
DIGUP_MODELS=<模型目录> .build/release/digup eval evals/chinese.json --index <索引目录>
```

模型目录需含 `embeddinggemma-2-Q8_0.gguf` 和 `mmproj-embeddinggemma-2-Q8_0.gguf`（`ModelFiles.swift` 里有 SHA-256）。

---

## 7. 上游跟进

上游 2026-10-08 创建，9 天 4,482 ⭐，100+ 待合并 PR，变化极快。

```bash
git fetch upstream
git rebase upstream/main feat/cn-search-phase1
```

分支划分原则：**每个阶段一个分支，可独立 rebase、独立提交上游。**

---

## 8. 与上游 PR 的关系

| PR | 内容 | 与本项目的关系 |
|---|---|---|
| #86 | 读 xlsx / pptx / ods / odp（+958 行） | 阶段 2 直接复用 |
| #85 | 两字以上 Han 文件名字面查找 | 与阶段 1 互补（阶段 1 覆盖正文+文件名） |
| #111 | Han 正文 FTS + schema 5→6 | 同方向，阶段 1 是其精简可审版本 |
| #34 / #112 | 中文界面本地化 | 独立议题，不做 |

阶段 1 相对 #111 的补充：**snippet 必须绕开 FTS 的 `snippet()`**（切分后输出垃圾）、`SearchText.matches` 的 Han 高亮。
