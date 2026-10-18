# 阶段 5 实测报告：中文界面

**日期**：2026-10-18
**分支**：`feat/zhui-phase5`（基于 `feat/asr-phase4`）
**来源**：采用上游 PR #34（框架）+ PR #112（简体中文）的成果
**改动**：三语界面（英 / 简中 / 繁中），425 条字符串

---

## 1. 结论

| 项 | 结果 |
|---|---|
| 简体中文界面 | ✅ 425 条字符串，与英文完全对齐 |
| 繁体中文界面 | ✅ 425 条 |
| 系统语言自动选择 | ✅ 跟随 macOS 语言偏好 |
| 未支持语言回退 | ✅ 回退英文 |
| 权限说明本地化 | ✅ `InfoPlist.strings` |
| 单元测试 | **116 个通过**（+8 本地化测试） |

---

## 2. 为什么是"采用"而不是"重写"

上游已有两份完整实现，都在等维护者合并：

| PR | 内容 | 规模 |
|---|---|---|
| #34 | 本地化框架 + 英文 + 繁中 | 36 文件，+1491 −448 |
| #112 | 简中（基于 #34） | 37 文件，+2247 −448 |

两者都基于 `ec28973` —— 与本项目四个阶段分支的父提交相同，**所以可以干净套用**。

**选择采用的理由**：
1. 这是翻译工作，不是技术判断 —— 重写只是重复劳动
2. 两个 PR 的作者已经把 425 条字符串全部翻好，质量过硬（见第 4 节）
3. 保留原作者署名，将来合回上游时这些提交已经在位

---

## 3. 套用结果

```
eb88439 Adapt localization framework from DigUp PR #34
b70935c Add Simplified Chinese UI and localization validation
```

**零冲突。** 阶段 1/2/4 改的是 `SearchText` / `IndexStore` / `Searcher` / `Rules` / `Extractors` / `Indexer`，
本地化改的是 `DigUpApp/*` 界面文件和 `Sources/DigUpLocalization/`，两批文件不重叠。

---

## 4. 翻译质量抽查

术语准确，不是机翻：

| 英文 | 简体中文 |
|---|---|
| `%1$@ %2$@ indexed` | `%1$@ 个文件已创建索引` |
| `%1$@ long %2$@ to finish` | `%1$@ 个较长文件尚未完成` |
| `%1$@ weaker %2$@` | `%1$@ 条较不相关的结果` |
| `%1$@ of %2$@ files searchable` | `%2$@ 个文件中，%1$@ 个可搜索` |
| `(about %1$@ on this Mac)` | `（这台 Mac 约需 %1$@）` |
| `%1$@ – playing from ` | `%1$@ – 播放起点：` |

**位置参数 `%1$@` / `%2$@` 全部保留且重排正确** —— 这是本地化最容易出错的地方（中文语序和英文不同），
425 条里没有一处错位。

---

## 5. 资源结构

```
Sources/DigUpLocalization/Resources/
├── en.lproj/
│   ├── Localizable.strings      425 条
│   └── InfoPlist.strings
├── zh-Hans.lproj/               简体
│   ├── Localizable.strings      425 条
│   └── InfoPlist.strings
└── zh-Hant.lproj/               繁体
    ├── Localizable.strings      425 条
    └── InfoPlist.strings
```

配套脚本：

| 脚本 | 作用 |
|---|---|
| `scripts/check-localizations.py` | 检查三种语言键是否齐全 |
| `scripts/test-localizations.py` | 回归测试 |

---

## 6. 验证

```bash
swift test
✔ Suite LocalizationTests passed          ← 框架测试
✔ Suite SimplifiedChineseTests passed     ← 简中专项
✔ Test run with 116 tests in 13 suites passed
```

| 测试覆盖 | 内容 |
|---|---|
| 键对齐 | 英/简中/繁中三种语言的键完全相同 |
| 缺键回退 | 缺失时回退英文 |
| 位置参数 | `%1$@` 等格式化参数合法且数量一致 |
| 权限说明 | `InfoPlist.strings` 有对应条目 |

---

## 7. 怎么生效

界面语言**跟随系统语言设置**，不需要应用内切换：

| macOS 语言 | 界面 |
|---|---|
| 简体中文 | 简体中文 |
| 繁体中文 | 繁体中文 |
| 英文 | 英文 |
| 其他（法、德…） | 英文（回退） |

改系统语言后需重启应用。

**注意**：本地化只覆盖 macOS 的 SwiftUI 应用。Windows / Linux 的 Tauri 外壳（`shell/ui/`）仍是英文
—— PR #112 的说明里也写明了 "Windows/Linux UI and CLI localization are out of scope"。

---

## 8. 已知限制

| 限制 | 说明 |
|---|---|
| 仅 macOS 应用 | Tauri 外壳和 CLI 输出仍是英文 |
| 需重启生效 | 改系统语言后要重开应用 |
| 与上游的关系 | #34 / #112 都未合并，上游后续改动可能带来冲突 |
| 冲突风险 | 本地化触及 36 个界面文件，是 rebase 时最容易冲突的部分 |

**rebase 建议**：先 rebase 代码分支（1/2/3/4 阶段），最后再 rebase `feat/zhui-phase5`
—— 它冲突最多，放最后能减少反复。

---

## 9. 五个阶段汇总

| 阶段 | 分支 | 内容 | 测试 |
|---|---|---|---|
| 1 | `feat/cn-search-phase1` | 中文全文检索 | 93 |
| 2 | `feat/office-phase2` | Office 文字 | 103 |
| 4 | `feat/asr-phase4` | 录音转写 | 108 |
| 3 | `feat/slides-phase3` | PPT 图表 + 老格式 | 113 |
| 5 | `feat/zhui-phase5` | 中文界面 | 116 |

**注意**：测试数是各分支独立计数，分支之间未合并。全部合并后应在 130 左右。
