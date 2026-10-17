# 阶段 1 实测报告：中文全文检索

**日期**：2026-10-17
**分支**：`feat/cn-search-phase1`
**机器**：Apple M1 Max，64 GB，macOS 26.7.1
**模型**：EmbeddingGemma 2 Q8_0（text 310 MB + mmproj 555 MB），llama.cpp b11461
**改动**：`SearchText.indexable` 把连续汉字切成重叠二元组；schema 5 → 6

---

## 1. 结论

| 项 | 结果 |
|---|---|
| 中文检索 | **提升**：R@1 0.75 → 0.79，R@5 0.88 → 0.92，R@10 0.92 → 0.96 |
| 拉丁文检索 | **零回归**：synthetic 0.92/1.00，code 1.00/1.00，与改前逐项相同 |
| 孟加拉语 / 阿拉伯语 | **零回归**：multilingual 0.83/0.98，与改前逐项相同 |
| 单元测试 | 93 个通过，0 失败（含 ReferenceVectorTests 参考向量比对） |

---

## 2. 测量方法

### 语料

`~/DigUpTestbed`，由 `scripts/make-testbed.sh` 生成（288 MB）：

| 部分 | 内容 |
|---|---|
| `real/` | 用户真实文件的 APFS 克隆样本（120 图、25 PDF、15 文档、2 视频、6 音频），不额外占盘 |
| `synthetic/` | 生成媒体，内容已知，作为 eval 的 ground truth |
| `traps/` | 爬虫必须处理正确的边界情况 |
| `code/` | 5 个小型 git 仓库，124 个文件，供代码检索 eval |

### 对照方式

在 `/tmp` 建上游 `ec28973` 的 worktree，与改造分支**各建一份独立索引**（`.index-base` / `.index`），用同一份语料、同一个模型、同一批查询跑 eval。两次测量完全独立，排除索引状态干扰。

### 命令

```bash
# 索引（两份，分别用基线版本和改造版本）
DIGUP_MODELS=<模型目录> digup index ~/DigUpTestbed --index <索引目录>

# 评估
DIGUP_MODELS=<模型目录> digup eval evals/<name>.json --index <索引目录>
```

---

## 3. 总体结果

| eval | 查询数 | 改前 R@1 / R@5 / R@10 | 改后 R@1 / R@5 / R@10 | MRR 改前 → 改后 |
|---|---|---|---|---|
| **chinese** | 24 | 0.75 / 0.88 / 0.92 | **0.79 / 0.92 / 0.96** | 0.81 → 0.86 |
| synthetic | 37 | 0.92 / 1.00 / 1.00 | 0.92 / 1.00 / 1.00 | 0.96 → 0.96 |
| multilingual | 48 | 0.83 / 0.98 / 0.98 | 0.83 / 0.98 / 0.98 | 0.90 → 0.90 |
| code | 41 | 1.00 / 1.00 / 1.00 | 1.00 / 1.00 / 1.00 | 1.00 → 1.00 |

---

## 4. 逐标签对照

### 4.1 chinese（新增）

| tag | n | 改前 R@1 | 改后 R@1 | 改前 R@5 | 改后 R@5 | 变化 |
|---|---|---|---|---|---|---|
| `zh-doc` | 16 | 0.75 | 0.75 | 0.94 | 0.94 | 持平 |
| `zh-word` | 2 | **0.50** | **1.00** | 0.50 | **1.00** | **+0.50** |
| `zh-exact` | 1 | 1.00 | 1.00 | 1.00 | 1.00 | 持平 |
| `zh-kind` | 1 | 1.00 | 1.00 | 1.00 | 1.00 | 持平 |
| `en→zh` | 4 | 0.75 | 0.75 | 0.75 | 0.75 | 持平 |
| **ALL** | **24** | **0.75** | **0.79** | **0.88** | **0.92** | **+0.04 / +0.04** |

`zh-word`（整词查询）从 0.50 提升到 1.00，是这次改动的核心收益。

### 4.2 synthetic（拉丁文，验证零回归）

| tag | n | 改前 R@1 / R@5 | 改后 R@1 / R@5 |
|---|---|---|---|
| audio | 3 | 1.00 / 1.00 | 1.00 / 1.00 |
| doc | 2 | 1.00 / 1.00 | 1.00 / 1.00 |
| exact | 5 | 1.00 / 1.00 | 1.00 / 1.00 |
| image | 9 | 0.78 / 1.00 | 0.78 / 1.00 |
| long | 4 | 1.00 / 1.00 | 1.00 / 1.00 |
| long-exact | 2 | 1.00 / 1.00 | 1.00 / 1.00 |
| pdf-page | 4 | 0.75 / 1.00 | 0.75 / 1.00 |
| screenshot | 6 | 1.00 / 1.00 | 1.00 / 1.00 |
| video-moment | 2 | 1.00 / 1.00 | 1.00 / 1.00 |
| **ALL** | **37** | **0.92 / 1.00** | **0.92 / 1.00** |

**逐标签完全一致**，证明汉字切分对拉丁文没有副作用。

### 4.3 multilingual（孟加拉语 / 阿拉伯语，验证零回归）

| tag | n | 改前 R@1 / R@5 | 改后 R@1 / R@5 |
|---|---|---|---|
| ar-audio | 1 | 1.00 / 1.00 | 1.00 / 1.00 |
| ar-doc | 4 | 1.00 / 1.00 | 1.00 / 1.00 |
| ar-pdf | 2 | 1.00 / 1.00 | 1.00 / 1.00 |
| ar-shot | 2 | 1.00 / 1.00 | 1.00 / 1.00 |
| ar-word | 4 | 1.00 / 1.00 | 1.00 / 1.00 |
| ar→en | 2 | 0.50 / 1.00 | 0.50 / 1.00 |
| ar→media | 3 | 1.00 / 1.00 | 1.00 / 1.00 |
| bn-audio | 1 | 1.00 / 1.00 | 1.00 / 1.00 |
| bn-doc | 4 | 1.00 / 1.00 | 1.00 / 1.00 |
| bn-pdf | 2 | 1.00 / 1.00 | 1.00 / 1.00 |
| bn-shot | 2 | 1.00 / 1.00 | 1.00 / 1.00 |
| bn-word | 3 | 0.67 / 1.00 | 0.67 / 1.00 |
| bn→en | 2 | 0.50 / 0.50 | 0.50 / 0.50 |
| bn→media | 3 | 0.67 / 1.00 | 0.67 / 1.00 |
| en→ar | 6 | 0.83 / 1.00 | 0.83 / 1.00 |
| en→bn | 7 | 0.57 / 1.00 | 0.57 / 1.00 |
| **ALL** | **48** | **0.83 / 0.98** | **0.83 / 0.98** |

**逐标签完全一致。** `inflects()` 的印地系/阿拉伯系前缀规则未被触碰。

---

## 5. 逐条变化（chinese）

24 条查询中，4 条发生变化：

| 查询 | 改前 | 改后 | 说明 |
|---|---|---|---|
| 「网络拓扑」 | miss | **#1 会议纪要.md** | 关键词命中，直接修复 |
| 「数字孪生」 | #2 | **#1 会议纪要.md** | 关键词加权后升到首位 |
| 「设备健康管理」 | #4 | **#2** | 名次上升 |
| 「质量追溯」 | #1 | #2 | 被真实 PDF 反超（语义竞争） |

**「网络拓扑」从完全查不到变为首位命中**，这是改动价值的直接体现。

---

## 6. 关键词检索的直接对照

在完整索引上，用改造前后各跑一次：

| 查询 | 改前 | 改后 |
|---|---|---|
| 押金条款 | 命中（**靠语义**，z 3.8） | 命中（**关键词 #1** + 语义） |
| 验收报告 | 命中（靠语义，z 4.8） | 命中（**关键词 #1** + 语义） |
| 张三 | 命中（关键词 #1） | 命中（关键词 #1） |
| 设备综合效率 | 命中（关键词 #1） | 命中（关键词 #1） |

改前「押金条款」能命中是**语义层的功劳**，不是关键词；改后变成关键词直接命中，路径更短、更可靠。在无向量的小语料上（只有 5 个文件），改前完全查不到，改后正常。

---

## 7. 单元测试

```
swift test
✔ Suite MeasuredCostsTests passed
✔ Suite RulesTests passed
✔ Suite SearchTextTests passed          ← 含 4 个新测试
✔ Suite VideoTests passed
✔ Suite CodeTests passed
✔ Suite LongFilesTests passed
✔ Suite IndexStoreTests passed          ← 含 schema 1 → 6 迁移
✔ Suite ReferenceVectorTests passed     ← 向量未变
✔ Test run with 93 tests in 10 suites passed
```

新增 4 个测试：

| 测试 | 验证内容 |
|---|---|
| `chineseIsStoredAsItsPairs` | 切分正确性：多字、单字、含空格、中英混排 |
| `aPartOfAChineseRunIsFound` | 检索：子串命中、顺序敏感、不存在的词不命中 |
| `chineseInAFileNameIsFound` | 文件名中的中文可检索 |
| `chineseMatchesAreMarkedInTheTextAsWritten` | 高亮标记与 snippet 输出 |

`ReferenceVectorTests` 通过，说明**向量生成完全未变**，已有索引不会失效。

---

## 8. 复现步骤

```bash
# 1. 构建
git clone https://github.com/ARahim3/DigUp && cd DigUp
git checkout feat/cn-search-phase1
scripts/build-llama.sh
swift build -c release

# 2. 模型（两个文件，SHA-256 见 Sources/DigUpKit/ModelFiles.swift）
hf download ggml-org/embeddinggemma-2-GGUF \
  embeddinggemma-2-Q8_0.gguf mmproj-embeddinggemma-2-Q8_0.gguf \
  --revision bfcd298762cc34d0357ece5ebdd31791a3a374d8 \
  --local-dir ~/digup-models

# 3. 语料（需要 ffmpeg）
./scripts/make-testbed.sh          # → ~/DigUpTestbed

# 4. 索引与评估
export DIGUP_MODELS=~/digup-models
.build/release/digup index ~/DigUpTestbed --index ~/DigUpTestbed/.index
.build/release/digup eval evals/chinese.json --index ~/DigUpTestbed/.index

# 5. 对照（可选）：建上游 worktree，重复 4
git worktree add /tmp/base upstream/main
```

---

## 9. 与上游 0.92 的差异：语料污染，不是回归

上游 PR #85 的表格记录 `multilingual` 的 R@1 是 **0.92**，本地测到 **0.83**。查证结果：**测量语料不同，不是回归。**

### 三组隔离测试

| 语料组合 | R@1 | 与 0.92 的差 |
|---|---|---|
| 完整 testbed（`real/` + `synthetic/` + `traps/` + `zh/`） | 0.83 | −0.09 |
| 完整 testbed，去掉 `zh/` | 0.85 | −0.07 |
| `synthetic/` + `traps/`（无 `real/`） | **0.90** | −0.02 |
| 上游声称 | 0.92 | — |

### 两个污染源

**① `real/` 真实文件（−0.05，主因）**

`make-testbed.sh` 会从 Desktop/Documents/Downloads 采样真实文件（120 图、25 PDF、15 文档）。这些文件与 eval 期望答案语义高度相近，抢走首位：

- 「কফি শপের রসিদ」（咖啡店收据）→ 被**星巴克订单截图**抢走
- 「mobile wallet transfer failed」→ 被真实支付错误截图干扰

**② `zh/` 中文语料（−0.02，次因）**

中文文件与孟加拉语/阿拉伯语文件语义交叉：

- 「قائمة مشتريات البقالة」（杂货购物清单）→ 被**供应商清单.txt** 抢走
- 「apartment rent agreement」→ 被**租赁合同.txt** 抢走

### 关键证据

在**同一份含 `real/` + `zh/` 的语料**上，改前（基线 `ec28973`）R@1 也是 **0.83**，与改后完全相同。**证明差异来自语料，不来自改动。**

### 建议

上游的 0.92 是在**纯净的 `synthetic` + `traps`** 上测的。`real/` 是给人手动试用 testbed 的，不适合作为 eval 基准。

跑 eval 时应隔离：

```bash
# 只建 synthetic + traps，不采样真实文件
mkdir -p tb-clean && cp -R ~/DigUpTestbed/synthetic ~/DigUpTestbed/traps tb-clean/
DIGUP_TESTBED=tb-clean digup eval evals/multilingual.json --index <索引目录>
```

---

## 10. 已知限制

| 限制 | 说明 |
|---|---|
| 单字查询 | bigram 无 pair，无法命中。`terms()` 的两字符门槛已挡住 |
| 跨 bigram 边界 | 「扫描漏洞」查不到「扫描发现…漏洞」，因为中间的字不同。这是正确行为 |
| 假名 / 谚文 | 不切（`joinsWords` 只列 Han）。日文假名、韩文靠 `inflects` 的前缀匹配 |
| 旧索引迁移 | schema 6 迁移时，`original IS NULL` 且有汉字的行需重读文件 |
| 索引体积 | 汉字部分约 5.7×（700k 字实测 2 MB → 12 MB），拉丁文不变 |

---

## 11. 与上游 PR 的关系

| PR | 关系 |
|---|---|
| #111 | 同方向（Han 正文 FTS + schema 5→6）。本分支是其精简可审版本，并补上了 #111 未提的两点：FTS 的 `snippet()` 切分后输出垃圾必须绕开、`SearchText.matches` 的汉字高亮缺失 |
| #85 | 文件名专用的 Han 字面预筛，与本分支互补（本分支覆盖正文+文件名） |
| #86 | Office 文字抽取，阶段 2 复用 |
