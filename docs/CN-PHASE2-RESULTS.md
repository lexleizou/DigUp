# 阶段 2 实测报告：Office 文字抽取

**日期**：2026-10-18
**分支**：`feat/office-phase2`（基于 `feat/cn-search-phase1`）
**改动**：合并上游 PR #86 + 补宏格式变体

---

## 1. 结论

| 项 | 结果 |
|---|---|
| pptx 文字 + 讲稿备注 | ✅ 可抽取、可检索 |
| xlsx 按 sheet 逐行 | ✅ 可抽取、可检索 |
| 中文检索在 Office 文件上 | ✅ 与阶段 1 叠加正常 |
| 宏格式变体（xlsm/pptm/docm 等） | ✅ 已支持 |
| 单元测试 | **103 个通过**（+10 个 Office 测试） |
| schema 迁移 | **不需要** |

---

## 2. 合并来源

上游 PR #86「Read xlsx, pptx, ods and odp」（作者 njeanselme），基于 `ec28973`，与阶段 1 无冲突，`git cherry-pick` 直接通过。

| 文件 | 行数 | 内容 |
|---|---|---|
| `Sources/DigUpKit/OfficeText.swift` | +480 | OOXML / ODF 文字抽取 |
| `Sources/DigUpKit/Platform/Apple/Zip+Apple.swift` | +80 | macOS 上的 zip 读取 |
| `Sources/DigUpKit/Platform/Portable/Docs+Portable.swift` | +43 −16 | 跨平台 zip 复用 |
| `Tests/DigUpKitTests/OfficeTests.swift` | +344 | 10 个测试 |
| `Sources/DigUpKit/Rules.swift` | +3 −1 | 扩展名注册 |
| `Sources/DigUpKit/Extractors.swift` | +4 −2 | 分派 |

---

## 3. 本分支补充

### 3.1 宏格式变体

PR #86 只注册了 `xlsx / pptx / ods / odp`。实际语料里还有大量宏和模板变体（你的 OneDrive 有 2,124 个 `.xlsm`）。

这些文件**包结构完全相同**，只是多了 `vbaProject.bin` 或模板标志位，文字所在的 XML 一模一样。

补入：

| 类型 | 变体 |
|---|---|
| Excel | `xlsm`, `xltx`, `xltm` |
| PowerPoint | `pptm`, `potx`, `potm` |
| Word | `docm`, `dotx`, `dotm` |

### 3.2 修掉 macOS 上的一个真 bug

`Extractors+Apple.swift` 的 `richText` 原本：

```swift
case "docx": type = .officeOpenXML
default:     type = .rtf      // ← docm 掉到这里
```

`.docm` 会走 RTF 解析器，必然失败。改为：

```swift
case "docx", "docm", "dotx", "dotm": type = .officeOpenXML
```

### 3.3 不需要 schema 迁移

初看以为要迁移（旧索引里 pptx/xlsx 是被跳过的），但查证后发现：

`Crawler.swift` 对 `.ignore` 和 `.skip` 的文件**根本不写入 `files` 表**。所以旧索引里压根没有这些记录，重新扫描就会自动收录。

验证：

```sql
SELECT COUNT(*) FROM files WHERE path LIKE '%.pptx' OR path LIKE '%.xlsx';
-- 0
```

**结论：无需迁移，无需重读已有文件。**

---

## 4. 实测

### 4.1 构造样本

用 Python 生成最小但合法的 OOXML 包（2 页 pptx 带备注 + 2 sheet xlsx）。

### 4.2 抽取结果

pptx：

```
数字孪生二期 技术方案
整体架构包括数据采集层、平台层和应用层
讲稿备注：这一页重点强调数据采集层的实时性要求      ← 备注被抽出

网络拓扑设计
核心交换机采用冗余配置，接入层使用堆叠
```

xlsx：

```
设备清单
设备名称 型号 数量 单价
思科交换机 C9300-48P 2 18500
飞塔防火墙 FORTIGATE-200G 1 42000

报价明细
合计 102500
```

按 sheet 顺序、每行一条、单元格用 tab 分隔 —— 与 PR #86 描述一致。

### 4.3 检索验证

| 查询 | 结果 |
|---|---|
| 实时性要求（备注内容） | ✅ 述标方案.pptx |
| 网络拓扑 | ✅ 述标方案.pptx |
| 技术方案 | ✅ 述标方案.pptx |
| 数据采集层 | ✅ 述标方案.pptx |
| 思科交换机 | ✅ 设备报价.xlsx |
| C9300-48P | ✅ 设备报价.xlsx |
| 设备清单 | ✅ 设备报价.xlsx |
| 报价明细 | ✅ 设备报价.xlsx |
| 合计 | ✅ 设备报价.xlsx |

**中文检索在 Office 文件上完全生效**，说明阶段 1 的 bigram 切分对 Office 抽取的文本同样适用。

### 4.4 真实文件

用你 OneDrive 里的 `POS Deep Dive Review - Template .pptx`（17 MB，13 页）：

| 项 | 结果 |
|---|---|
| 索引耗时 | **1.4 秒** |
| 抽取字数 | 1,796 字 |
| 内容完整性 | ✅ 议程、DCR 表、PROMP 索赔表等全部抓取 |

对照之前统计的「0.035 字/MB」，17 MB 抽出 1,796 字符合预期。

---

## 5. 回归测试

在纯净语料（`synthetic` + `traps` + `zh`，无 `real/` 干扰）上：

| eval | 查询数 | R@1 | R@5 | 对比阶段 1 |
|---|---|---|---|---|
| synthetic | 37 | **0.95** | 1.00 | 0.92 → 0.95（↑） |
| multilingual | 48 | 0.90 | 0.98 | 0.90（持平） |
| chinese | 24 | **1.00** | 1.00 | 1.00（持平） |

synthetic 提升到 0.95，是因为纯净语料下真实文件干扰消失。

**注意**：chinese 在无 zh 目录的语料上跑会显示 0.00 —— 这正好验证了 eval 测量是有效的（找不到期望文件就判 miss）。

---

## 6. 已知限制

| 限制 | 说明 |
|---|---|
| 二进制 .ppt / .xls | 不读（PR #86 明确说明）。需 LibreOffice 转换，属阶段 3 |
| 幻灯片图表 | 只抽文字，读不到图片里的内容。需渲染，属阶段 3 |
| 定位锚 | 只有「part N」，没有「第 N 页」/「sheet X」。PR #86 作者说明是为保持改动小 |
| 公式 | 保留最后一次计算值，不保留公式本身 |
| 加密文件 | 识别为 `locked`，报错而非崩溃 |
| 字符上限 | 1000 万字符（`OfficeText.maxCharacters`），超出截断 |

---

## 7. 复现

```bash
git checkout feat/office-phase2
swift build -c release
swift test                                    # 103 通过

export DIGUP_MODELS=~/digup-models
.build/release/digup index <含 Office 文件的目录> --index <索引目录>
.build/release/digup search "关键词" --index <索引目录>
```

---

## 8. 下一步

阶段 3 需要解决阶段 2 留下的两个缺口：

| 缺口 | 方案 |
|---|---|
| PPT 图表读不到 | 幻灯片渲染成图 → 走 `pageImage` 路径 → 多模态嵌入 |
| 二进制 .ppt/.xls | LibreOffice 无头转换 → PDF |
