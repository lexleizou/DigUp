# 阶段 3 实测报告：PPT 图表渲染与老 Office 格式

**日期**：2026-10-18
**分支**：`feat/slides-phase3`（基于 `feat/asr-phase4`）
**依赖**：LibreOffice 26.8（可选，不装则相关格式跳过）
**改动**：二进制 `.ppt`/`.xls` 经转换后读入；PPTX 幻灯片渲染成图

---

## 1. 结论

| 项 | 结果 |
|---|---|
| 二进制 `.ppt` 文字 | ✅ 分页抽取（4 页，含里程碑表） |
| 二进制 `.xls` 单元格 | ✅ 中文表格内容完整抽出 |
| PPTX 幻灯片画面 | ✅ 逐页渲染成图，可**语义检索**（「议程」→ 第 2 页） |
| 定位精度 | ✅ 文字和图像都带页号（`[p. N]`） |
| 无转换器时 | ✅ 明确跳过并给原因，不写入乱码 |
| 单元测试 | **127 个通过**（+5 转换测试，+14 本地化测试） |

---

## 2. 两个缺口

### 2.1 二进制格式完全读不到

`.ppt` / `.xls` 是 OLE 复合文档（`D0 CF 11 E0` 签名）。实测：

| 方法 | `.ppt` | `.xls` |
|---|---|---|
| Spotlight `kMDItemTextContent` | ❌ null | ❌ null |
| `textutil` | ❌ 格式错误 | ❌ 空 |
| `NSAttributedString` | ❌ 全部失败 | ❌ 全部失败 |

你 OneDrive 里有 **6,465 个 .xls**、以及未知数量的 .ppt —— 全部零覆盖。

### 2.2 PPT 的画面读不到

阶段 2 解决了 PPT 文字和备注，但实测发现：**201 MB 的 pptx 只有 74,782 字，97% 的体积是图片**。甘特图、架构图、拓扑图全在图片里，纯文本方案读不到。

---

## 3. 方案

### 3.1 转换器

```
.ppt  → LibreOffice → .pdf  → 复用现有 PDF 管道（文字 + 页面图 + OCR）
.xls  → LibreOffice → .xlsx → 复用 OfficeText
```

**为什么不用 AppleScript 驱动 PowerPoint**（本机已装 Office）：

| 方案 | 问题 |
|---|---|
| PowerPoint AppleScript | 需要 GUI 运行、弹窗阻塞、macOS 独有、批量不稳 |
| Excel AppleScript | 实测报 `-50 参数错误`，多次调整语法均失败 |
| **LibreOffice headless** | 跨平台、无 GUI、1–2 秒/文件、批量稳定 |

**转换是可选能力**，与 ASR 同样设计：

```bash
export DIGUP_SOFFICE=/opt/homebrew/bin/soffice    # 或让它在 PATH 上
```

不设则相关格式跳过 —— 不因为一个外部工具让整个应用无法使用。

### 3.2 幻灯片渲染

`.pptx` / `.pptm` / `.potx` / `.potm` / `.ppt` / `.odp` 在有转换器时，额外渲染每一页为 `pageImage` 段落，`loc` 是页号。

**为什么不直接抽 `ppt/media/*` 图片**：那会丢掉"这张图属于第几页、旁边写了什么"的上下文。渲染整页保留版式，而且 DigUp 的 `pageImage` 路径就是为这个设计的。

**成本控制**：`--slides N` 控制每份最多渲染页数，默认 60。`--slides 0` 关闭。

---

## 4. 实测

### 4.1 二进制 .ppt

样本：`Lvye-MES.ppt`（480 KB，绿叶制药 MES 项目）

```
[1/1] doc  done  2.07s  Lvye-MES.ppt  (4/4 pages, 0 as images)
```

抽出的分页内容：

| 页 | 内容 |
|---|---|
| p1 | 项目介绍、用户信息、项目目标、绿叶制药集团、山东烟台、四条生产线 |
| p2 | 项目范围、系统功能 |
| p3 | 关键里程碑 (更新)、绿叶制药集团 MES 项目 |
| p4 | 项目阶段工作内容、序号/时间/主要里程碑 |

**里程碑表格的数据都在。**

### 4.2 二进制 .xls

两个真实样本：

| 文件 | 大小 | 耗时 | 抽取内容 |
|---|---|---|---|
| `PAS与工艺设备自控整合方式 - Rockwell.xls` | 28 KB | 2.75 s | 完整的工艺设备自控方案说明（方式 A / 方式 B） |
| `Purchase Request for ISPB 20211207.xls` | 118 KB | 0.85 s | 采购申请表头、项目编号、表头行 |

### 4.3 PPTX 幻灯片渲染

样本：`POS Deep Dive Review - Template .pptx`（16.9 MB，13 页）

```
[2/2] doc  done  14.38s  POS Deep Dive Review - Template .pptx  (2 chunks)
```

数据库：

```
page_image 段落: 13 个，页号 1–13
```

**语义检索验证**（这些是图像命中，不是文字命中）：

| 查询 | 结果 | 说明 |
|---|---|---|
| 「议程」 | `[p. 2]` (z 2.1) | 议程页是纯排版，文字层拿不到 |
| 「风险问题清单」 | `[p. 8]` (z 2.2) | 表格页 |
| 「发票付款状态」 | `[p. 10]` (z 2.9) | 表格页 |
| 「项目进度」 | `[part 1]` | 这个走文字层 |

**「议程」「风险问题清单」这些查询，阶段 2 是查不到的** —— 现在靠画面命中了。

---

## 5. 修掉的一个隐患

`.ppt` 加入 `docExtensions` 后，**无转换器时会走 `readText` 兜底**，把二进制字节当 Latin-1 文本读进索引 —— 全是乱码噪音。

修正为显式跳过：

```swift
guard let converter else {
    prepared.outcomes[0] = Outcome(state: "skipped", detail: "a .\(ext) needs a converter")
    prepared.payload = .nothing
    return prepared
}
```

单元测试 `aBinaryFileIsSkippedWhenNothingCanConvertIt` 断言：无转换器时该文件关键字索引里**零文字**。

---

## 6. 新增测试

| 测试 | 验证内容 |
|---|---|
| `binaryOfficeFilesAreDocumentsNow` | `.ppt` / `.xls` 被分类为文档 |
| `whatEachFormatBecomes` | 每种格式转换目标；macOS 上 `.doc` 不转换 |
| `noConverterUnlessOneIsNamed` | 不可执行路径不构成转换器 |
| `aBinaryFileIsSkippedWhenNothingCanConvertIt` | 无转换器时跳过，不写乱码 |
| `aConverterThatIsThereConverts` | 有转换器时真能转出 PDF |

---

## 7. 使用方式

```bash
# 装 LibreOffice（约 805 MB）
brew install --cask libreoffice

# 自动检测，或显式指定
export DIGUP_SOFFICE=/opt/homebrew/bin/soffice

# 渲染每份最多 20 页幻灯片（默认 60，0 关闭）
.build/release/digup index <目录> --index <索引目录> --slides 20
```

**成本参考**（你 6,699 个 pptx）：

| 项 | 单文件 | 全量估算 |
|---|---|---|
| 转换 + 渲染 | ~14 秒（13 页 deck） | 约 26 小时 |
| 图像嵌入 | 13 个向量 | 约 87,000 个向量 |

**建议先小范围试**：`--slides 10` 只渲染前 10 页，或先只索引一个客户目录。

---

## 8. 已知限制

| 限制 | 说明 |
|---|---|
| 转换依赖 | 不装 LibreOffice 时，`.ppt` / `.xls` 仍读不到 |
| 转换耗时 | 1–14 秒/文件，全量是小时级 |
| 中文字体 | LibreOffice 用系统字体，PingFang 可用；特殊字体可能替换 |
| 只有页号 | 没有「第 3 张幻灯片」的语义标签，`[p. 3]` 就是页序号 |
| 不渲染表格 | `.xlsx` 不渲染成图 —— 表格渲染无检索价值，成本却高 |
| 旧索引 | 已索引的 pptx 需重新索引才有幻灯片图；`maxSlidePages` 不进 fingerprint |

---

## 9. 与阶段 5 的关系

阶段 3 与阶段 5（中文界面）**互不影响**，各自一个分支：

| 分支 | 内容 |
|---|---|
| `feat/slides-phase3` | 本阶段 |
| `feat/zhui-phase5` | 中文界面 |
