# 技术设计细化: FileTmpShelf 使用体验改进

**Status**: Draft（待评审）
**Author**: Alex (PM)
**Last Updated**: 2026-08-11
**Version**: 0.1
**关联文档**: [[2026-08-10_FileTmpShelf_产品需求文档]] · [[2026-08-10_FileTmpShelf_技术Spike方案]]
**代码基线**: 提交 `7edf0ca`（Spike S1–S4 全部代码层验证通过，25 测试 0 失败）

---

## 1. 本次细化目标

Spike 阶段验证了 4 个核心风险点，但**使用体验层面存在 2 个明确缺陷**，另有 4 个体验增强项待落地。本文档给出每个问题的根因、方案与验收标准，随后进入 MVP 开发。

---

## 2. 体验缺陷修复（P0，本次必须）

### 2.1 缺陷 1：拖出文件时暂存框跟随移动

**现象**：用户按住货架条目往外拖（发起文件拖拽）时，整个浮动面板也跟着移动，拖完发现面板位置被改变了。

**根因**（已定位）：
- `ShelfPanelController.createPanel()` 设置了 `newPanel.isMovableByWindowBackground = true`（S4 为支持"拖动面板换位置"而加）
- `FilePromiseDragView`（拖拽发起视图）**未重写 `mouseDownCanMoveWindow`**——NSView 默认返回 `true`，意味着鼠标落在该视图上拖动时，事件同时被窗口解释为"移动窗口"
- 结果：条目拖拽（10pt 阈值后发起 NSDraggingSession）与窗口移动（无阈值，立即响应）**竞争**，窗口先动了

**方案 A（推荐，最小侵入）**：
- `FilePromiseDragView.mouseDownCanMoveWindow` 重写为 `false`
- 效果：鼠标落在**条目区域**时拖动 = 纯文件拖拽，面板不动；鼠标落在**面板空白区域**（背景）拖动 = 面板移动（保留 S4 的多显示器移动能力）

**方案 B（更强，备选）**：
- 在 `mouseDragged` 发起 `beginDraggingSession` 的瞬间，记录面板位置并 `setFrameOrigin` 锁定（拖拽会话期间禁止移动）
- 代价：需要监听拖拽会话结束恢复，复杂度高，且方案 A 已覆盖主路径

**决策**：采用方案 A；若真机验收发现空白区与条目区边界手感问题，再叠加方案 B。

**验收标准**：
- [ ] 从条目区域发起文件拖拽时，面板位置不变（自动化：单测断言 `mouseDownCanMoveWindow == false`；真机按 MANUAL_CHECK 清单）
- [ ] 从面板空白区域拖动时，面板仍可移动（不回归 S4 能力）

---

### 2.2 缺陷 2：暂存框缺少清空功能

**现象**：货架条目只能一条条拖出/等待失效，无法一键清空；`ShelfStore.removeAll()` 已存在但无 UI 入口。

**方案**（双入口，覆盖不同场景）：
1. **面板内清空按钮**：面板右上角常驻垃圾桶图标（仅在 `items.count > 0` 时显示），点击清空
2. **菜单栏"清空货架"项**：菜单栏下拉菜单增加「清空货架」，带确认对话框（防误触）

**确认策略**：
- 条目数 ≤ 3：直接清空（低风险）
- 条目数 > 3：弹出确认对话框「确定清空 N 个文件？这只是移除货架条目，不会删除源文件」

**验收标准**：
- [ ] 面板有条目时显示清空按钮，空货架隐藏
- [ ] 点击清空：≤3 条直接清空，>3 条弹确认
- [ ] 菜单栏「清空货架」同样生效
- [ ] 清空只移除引用，源文件不受影响（零拷贝模型下天然成立，用测试断言）

---

## 3. 体验增强项（P1，本次一并落地）

### 3.1 拖拽反馈：拖出时条目视觉跟手

**现状**：`FilePromiseDragView` 用 `snapshotImage()` 生成拖拽缩略图，但无拖动中的高亮/半透明反馈。
**方案**：拖拽会话进行中（`draggingSession(_:willBeginAt:)` → `endedAt`），条目视图透明度降至 0.5；结束后恢复。拖拽失败（未 drop 成功）时条目恢复原状。

### 3.2 失效条目一键清理

**现状**：源文件被删除/移动后，条目标记"不可达"但无法批量清除。
**方案**：面板清空按钮旁增加"清理失效"（扫把图标，仅在有失效条目时显示）；点击移除所有 `isReachable == false` 的条目，无需确认（无数据风险）。

### 3.3 面板位置记忆

**现状**：`createPanel()` 每次都在主屏右上角创建，用户拖到副屏后下次又回到右上角。
**方案**：`NSPanel` 的 `frame` 在每次移动结束时（`NSWindow.didMoveNotification`）持久化到 `UserDefaults`；下次创建时恢复。多显示器坐标用 `NSScreen` 保存时校验屏幕仍在（分辨率变化时回退默认位置）。

### 3.4 菜单栏条目数角标

**现状**：菜单栏图标恒定 `tray.full`，无法一眼看出货架是否为空。
**方案**：图标叠加条目数 badge（`NSStatusItem` 支持 `button.title` 或自定义 view）。条目数为 0 显示普通图标；>0 显示数字角标。货架状态变化时由 `ShelfPanelModel` 通知更新。

---

## 4. 涉及文件与改动点

| 文件 | 改动 | 对应项 |
|------|------|--------|
| `Sources/UI/FilePromiseDragView.swift` | 重写 `mouseDownCanMoveWindow = false`；拖拽会话中透明度反馈 | 2.1 / 3.1 |
| `Sources/UI/ShelfPanel.swift` | 面板头部增加清空/清理失效按钮；清空确认对话框 | 2.2 / 3.2 |
| `Sources/App/AppEntry.swift` | 菜单栏增加「清空货架」+ 条目数角标 | 2.2 / 3.4 |
| `Sources/Core/ShelfStore.swift` | 增加 `countUnreachable()`（或复用 `all().filter`） | 3.2 |
| `Tests/ShelfPanelModelTests.swift`（新增） | 清空逻辑、失效清理逻辑单测 | 2.2 / 3.2 |

## 5. 不做的事（本次范围外）

- 不重设计面板视觉（圆角/毛玻璃/尺寸保持现状）
- 不做条目拖拽排序（V2）
- 不做多货架（V2）
- 不做右键菜单（在 Finder 中显示等，V2）

## 6. 验证计划

1. **单测**：`mouseDownCanMoveWindow == false`、清空调用 `removeAll`、失效清理只移除不可达条目、菜单栏角标计数
2. **构建**：`xcodebuild build` + `xcodebuild test` 全绿（基线 25 测试 + 新增）
3. **真机人工验收**：更新 `docs/MANUAL_CHECK_S4.md`，增加「拖出时面板不动」「清空确认」「面板位置记忆」三个用例

---

## 附：给评审的问题

1. 方案 A（mouseDownCanMoveWindow=false）是否足够？是否需要在拖拽会话期间额外锁定面板位置（方案 B）？
2. 清空确认阈值 3 条是否合理？（可改为 5）
3. 菜单栏角标是否必要？还是保持图标简洁、仅工具提示显示条数？
