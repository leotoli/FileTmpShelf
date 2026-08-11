# 技术 Spike 方案: FileTmpShelf — 核心风险验证

**Status**: Draft（待评审）
**Author**: Alex (PM) / 工程负责人
**Last Updated**: 2026-08-10
**Version**: 0.1
**关联文档**: [[2026-08-10_FileTmpShelf_产品需求文档]]

---

## 1. 背景与目的

PRD v0.2 中有 4 个核心架构决策目前是**未经验证的假设**。正式开发（12 周 MVP）前，需要 2 周 Spike 把"能做、怎么做得对、边界在哪"验证清楚。Spike 产出的是**结论 + 决策门槛**，不是产品代码。

**验证主题与 PRD 决策的对应关系：**

| # | Spike 主题 | 对应 PRD 决策 | 核心疑问 |
|---|-----------|--------------|---------|
| S1 | 路径引用存储模型 | 决策 2（零拷贝挂载 + 来源路径） | 非沙盒下 bookmark 是否必要？iCloud 占位文件如何处理？ |
| S2 | file promise 拖出移动 | 决策 3（Finder 真实移动） | NSFilePromiseProvider 是否能在拖到 Finder 时可靠触发 moveItem？同卷/跨卷行为？ |
| S3 | 全局快捷键 ⌥X | 决策 4（快捷键唤醒） | Carbon 热键与 NSEvent 监听在 M 系上的延迟/冲突表现？⌥X 被占用怎么办？ |
| S4 | NSPanel 拖放行为 | 决策 2 + 3（拖入/拖出闭环） | 无边框浮动面板在拖入（接收拖拽）与拖出（发起拖拽）时的系统行为是否顺畅？ |

**成功标准**：2 周内 4 个主题全部给出"可行 / 有条件可行 / 不可行 + 替代方案"的结论，且 S1–S4 的可行结论能在 1 个可运行的迷你原型（Prototype）中同时演示，供产品评审会拍板。

---

## 2. Spike 总体安排

| 阶段 | 时间 | 内容 | 产出 |
|------|------|------|------|
| Week 1 | Day 1–2 | S1 路径存储实验 | 存储模型结论 + 失效矩阵 |
| | Day 3–4 | S2 拖出移动实验 | 移动语义结论 + 同卷/跨卷行为表 |
| | Day 5 | S3 热键实验 | 热键方案结论 + 冲突检测结论 |
| Week 2 | Day 6–7 | S4 面板拖放实验 | 面板行为结论 |
| | Day 8–9 | 迷你原型整合（S1–S4 联动） | 可演示原型 + 录屏 |
| | Day 10 | 结论评审会 | Spike 报告 + 立项 Gate 决策 |

**资源**：1 名 macOS 工程师全职 + PM 半天/周。使用 arm64 Mac（M 系）真机，最低测试目标 macOS 13 (Ventura)，顺带验证 macOS 14/15。

---

## 3. Spike 1 — 路径引用存储模型（零拷贝挂载）

### 3.1 假设

- 非沙盒（dmg 分发）下，应用对用户可见文件有完全访问权限，**可能不需要 security-scoped bookmark**，直接存 `URL` 即可跨重启解析。
- 即使需要 bookmark，对 iCloud Drive 中"未下载到本地"的占位文件（`.icloud` 扩展名）需要特殊处理。
- 挂载 100 个文件应远低于 1.5s（纯 URL 记录）。

### 3.2 实验步骤

1. **基线测试**：写一个最小 Swift app（非沙盒），将 100 个文件（含 1 个大文件 20GB、若干文件夹、iCloud 占位文件）拖入面板，记录总耗时与磁盘增量。
2. **bookmark 必要性**：
   - 场景 A：直接存 URL，重启 app 后逐条验证文件可达性。
   - 场景 B：存 `bookmarkData(options: .withSecurityScope)`，重启后 `startAccessingSecurityScopedResource` 验证。
   - 对比两个场景在「本地磁盘 / iCloud / 外置盘 / 网络卷（SMB）」4 种源位置上的可达性差异。
3. **失效矩阵**：模拟文件被外部删除、外置盘拔出、iCloud 占位（未下载）、iCloud 驱逐（本地副本被系统回收）4 种失效，记录检测方式（`FileManager.fileExists` / `URLResourceValues.isUbiquitousItem`）与耗时。
4. **来源路径显示**：验证获取父目录路径展示的性能与 UI 无卡顿（100 条目滚动）。

### 3.3 通过标准（全部满足才算 S1 通过）

- [ ] 非沙盒下直接 URL 方案在 4 种源位置重启后可达性 100%（iCloud 占位除外）
- [ ] 挂载 100 文件总耗时 < 1.5s，磁盘增量 < 1MB
- [ ] 4 种失效场景都能在启动时被检测并标记，无崩溃
- [ ] iCloud 占位文件：能识别 `isUbiquitousItem` 且未下载状态，条目标记"云端文件，需先下载"

### 3.4 风险与替代

- 若 bookmark 必要（如外置盘场景发现直接 URL 失效）→ 采用"URL 为主 + bookmark 兜底"双写，代价 +1 天。
- 若 iCloud 占位处理复杂 → V1 可降级为"占位文件显示云端状态，拖出前提示先下载"，不阻塞核心流程。

### 3.5 决策门槛

| 结果 | 决策 |
|------|------|
| 直接 URL 可行 | PRD 决策 2 微调：去掉"自动创建 bookmark"表述，改为"URL 存储 + 存在性检查" |
| 需要 bookmark | 保留决策 2 原文，技术成本 +1 天 |
| iCloud 占位降级 | Non-Goals 增加"V1 不支持 iCloud 占位文件拖出"，明确提示 |

---

## 4. Spike 2 — file promise 拖出移动（Finder 优先）

### 4.1 假设

- `NSFilePromiseProvider` 在拖到 Finder/桌面时，Finder 会调用 `filePromiseProvider(_:writePromiseTo:completionHandler:)`，在回调中执行 `FileManager.moveItem` 可完成"承诺交付 = 移动"。
- 同卷拖出为移动；跨卷系统行为可能为复制。
- 拖到第三方 App 时，file promise 可能不被支持，需要回退到 `public.file-url` pasteboard。

### 4.2 实验步骤

1. **最小实现**：面板条目注册 `NSFilePromiseProvider`，`fileType = UTType.fileURL.identifier`；回调中打印目标目录，尝试 `moveItem`。
2. **目标矩阵测试**（每目标 × 同卷/跨卷 × 单文件/文件夹）：
   - Finder 窗口 / 桌面 / 侧边栏收藏位置 / 打开对话框（如另存为）
   - 第三方 App：邮件附件、浏览器上传框（Safari/Chrome）、VS Code 侧栏、微信
   - 记录：是否触发 promise 回调、最终是移动还是复制、源文件残留情况、货架条目状态。
3. **取消/失败路径**：拖拽中途 Esc；目标位置权限拒绝；目标与源同名冲突——验证数据零丢失。
4. **性能**：20GB 文件 moveItem 在同卷时的耗时（预期为秒级重命名，跨卷为真实拷贝）。

### 4.3 通过标准（全部满足才算 S2 通过）

- [ ] Finder 窗口 + 桌面（同卷）：100% 触发真实移动，源文件消失、目标文件存在，货架条目自动移除
- [ ] 移动失败场景：无数据丢失，货架条目回滚保留
- [ ] 拖到第三方 App 的降级路径：file-url 引用正常，drop 后条目移除
- [ ] 跨卷行为记录清楚（预期复制），与 PRD §3 Non-Goals 一致
- [ ] 同名冲突行为明确（覆盖 or 重命名 or 失败提示）

### 4.4 风险与替代

- 若 Finder 不触发 promise 回调（历史上有过 file promise 行为不稳定的情况）→ **替代方案 A**：拖拽时注册普通 file-url pasteboard + 检测 drop 完成后主动删除源文件（风险：无法可靠得知 drop 是否完成）。**替代方案 B**：面板提供"移动到…"菜单（⌘⇧G 输入目标路径）作为兜底交互。Spike 必须给出 A/B 的可行性对比，供立项时拍板。

### 4.5 决策门槛

| 结果 | 决策 |
|------|------|
| promise 回调可靠触发移动 | 主方案确认，进入开发 |
| promise 不可靠 | 启用替代 A 或 B，交互与 PRD Story 3 需要调整（+评审） |

---

## 5. Spike 3 — 全局快捷键 ⌥X

### 5.1 假设

- Carbon `RegisterEventHotKey` 在 M 系上延迟低（< 300ms 目标）、无需辅助功能权限，是最优方案。
- ⌥X 可能与其他应用（输入法、剪贴板工具、IDE）冲突，需要冲突检测与提示。

### 5.2 实验步骤

1. **方案对比**：实现 Carbon 热键 + `NSEvent.addGlobalMonitorForEvents(matching: .keyDown)` 两套，测量：面板唤起延迟（10 次取中位数）、app 处于后台/全屏时是否触发、是否与系统"显示桌面"等手势冲突。
2. **冲突检测**：热键注册失败时，Carbon 返回的错误码（`eventHotKeyExistsErr`）能否可靠识别冲突；补充方案：尝试调用 `CGEventSource` 或使用第三方库（如 HotKey 库）的冲突检测。
3. **录制 UI**：验证 `KeyboardShortcuts` 库（sindresorhus）在 M 系上的可用性，还是自绘录制视图。
4. **菜单栏双入口**：验证 menu bar 图标点击唤出与热键唤出行为一致。

### 5.3 通过标准（全部满足才算 S3 通过）

- [ ] Carbon 方案在后台/全屏下延迟 < 300ms（中位数）
- [ ] 冲突时可检测并给出可读提示，用户可改键后立即生效
- [ ] 无需辅助功能权限（系统设置中不出现"输入监控"授权要求）—— 这是 dmg 分发的体验底线
- [ ] 录制 UI 可用性确认

### 5.5 Spike 执行记录（实时更新）

| Spike | 状态 | 结论 | 执行记录 |
|-------|------|------|---------|
| S3 热键 | ✅ 已验证（2026-08-10） | **Carbon 方案可行**：注册/冲突检测/unregister 重注册全部通过；CGEvent 模拟 ⌥X 真实触发回调（当前环境有辅助功能权限）；无权限环境测试安全跳过不挂起 | 提交 `d5d0736`，10/10 测试通过。register() 原子化（失败回滚）、eventHotKeyExistsErr → hotKeyExists 映射、AppEntry 冲突提示到菜单标题 |
| S1 存储 | ✅ 已验证（2026-08-10） | **直接 URL 方案成立，bookmark 不必要**：非沙盒下 URL + fileExists 即够；移动/删除源文件后 isReachable 可靠变 false；100 文件挂载实测 0.004s（远低于 1.5s）；chmod 000/文件夹/符号链接/悬空链接均正常 | 提交 `3263ed8`，16/16 测试通过（连续 2 次）。修复：iCloud 占位判定 `.notDownloaded`、目录 fileSize=0、符号链接解析目标大小、addBatch 返回 skipped；PM 修复 CGEvent flaky（run loop 排水+重试） |
| S2 拖出移动 | ✅ 代码层已验证（2026-08-11） | **NSFilePromiseProvider 方案可行**：writePromiseToURL 回调执行 moveItem 实现"承诺交付=移动"；成功才通知货架移除、失败源保留（数据零丢失）；成功/失败/文件夹/冲突 9 个单测全绿；**Finder 真实拖出需人工验收** | 提交（S2 系列），FilePromiseDragManager + FilePromiseDragView（SwiftUI .onDrag 无法承载 file promise，用 AppKit NSDraggingItem 发起）。PM 修复：动态 UTI 过滤、public.directory 期望值、集成测试环境变量控制。25 测试 0 失败 |
| S4 面板拖放 | ✅ 代码层已验证（2026-08-10） | 配置完善：`becomesKeyOnlyIfNeeded=true`（不抢键焦点）+ `isMovableByWindowBackground`；drop 异步化修复主线程死锁；条目可拖出（NSItemProvider file URL）；**真机焦点行为待 MANUAL_CHECK_S4.md 人工验收** | 提交 `d90959f`，16/16 测试通过。真机验收清单见 docs/MANUAL_CHECK_S4.md |

---

## 6. Spike 4 — NSPanel 拖放行为

### 6.1 假设

- `NSPanel`（无边框、`nonactivatingPanel`、`floating`）可以同时作为拖入目标（`registerForDraggedTypes`）和拖出源（发起 NSDraggingSession），且不会抢焦点。
- 面板半透明毛玻璃下拖放命中区域正常。

### 6.2 实验步骤

1. 面板类型验证：`NSPanel` vs `NSWindow` 对比——是否接受拖入、是否抢走前台应用焦点（关键：拖入时不应激活 app，否则打断用户当前工作）。
2. 拖入：从 Finder 拖文件到面板 → 判断 `performDragOperation` 是否触发、是否影响前台应用。
3. 拖出：从面板条目发起 dragging session → 判断与 S2 的 promise 集成是否正常、拖出时面板是否保持置顶不消失。
4. 多显示器：面板跨屏拖出行为（副屏 Finder 窗口）。
5. 性能：面板 100 条目时拖入/拖出响应无卡顿。

### 6.3 通过标准（全部满足才算 S4 通过）

- [ ] 拖入不激活 FileTmpShelf、不打断前台应用（重点验收项）
- [ ] 拖入/拖出在 Finder 与第三方 App 间双向正常
- [ ] 面板在多显示器环境下行为正确
- [ ] 100 条目下交互流畅（无卡顿）

### 6.4 决策门槛

| 结果 | 决策 |
|------|------|
| 面板不抢焦点 | 决策确认 |
| 面板抢焦点 | 改用 `NSWindow.Level` 调整 + `becomesKeyOnlyIfNeeded`，技术成本 +1 天 |

---

## 7. 迷你原型（Prototype）整合

Spike 最后 2 天将 S1–S4 的可行结论整合为一个最小原型：

**范围**（与真实产品的最小闭环一致）：
- 菜单栏图标 + ⌥X 唤出浮动面板
- 拖入文件/文件夹 → 显示条目（名称/大小/来源路径）
- 拖出到 Finder/桌面 → 真实移动 + 条目移除
- 重启后货架恢复 + 失效标记
- 不含：设置窗口、图标设计、打包公证

**原型演示脚本**（评审会用，5 分钟）：
1. 在 Finder 创建 3 个分散测试文件 + 1 个 20GB 稀疏文件
2. ⌥X 唤出 → 逐个拖入 → 展示秒挂载（对照：如果复制会显示进度条）
3. 新建目标文件夹 → 拖出 → 展示源消失/目标出现/条目移除
4. 重启 app → 展示货架恢复
5. 删除一个源文件 → 展示失效标记

**原型通过门槛**：上述 5 步全通过，且全过程中无数据丢失、无 P0 卡死。

---

## 8. 立项 Gate（Gate Criteria）

Spike 结束后评审会需对以下问题做出明确决策，全部通过才进入 12 周 MVP 开发：

| Gate 问题 | 通过条件 |
|-----------|---------|
| 存储模型是否确认？ | S1 通过 或 替代方案已选 |
| 移动语义是否确认？ | S2 主方案或替代 A/B 已选，Story 3 验收标准同步更新 |
| 热键方案是否确认？ | S3 通过 或 PRD 决策 4 已更新 |
| 面板交互是否确认？ | S4 通过 |
| 原型是否演示成功？ | §7 门槛通过 |
| 风险清单是否更新？ | PRD §6.3 已知风险按 Spike 实测修订 |

---

## 9. 交付物清单

| # | 交付物 | 负责人 | 截止 |
|---|--------|--------|------|
| 1 | Spike 报告（4 主题结论 + 失效矩阵 + 行为表） | 工程 | Day 10 |
| 2 | 迷你原型（可运行，含源码仓库） | 工程 | Day 9 |
| 3 | 原型演示录屏（5 分钟脚本） | 工程 | Day 9 |
| 4 | PRD 更新（决策/风险/验收标准按 Spike 结果修订） | PM | 评审会 +2 天 |
| 5 | 立项 Gate 决策记录 | PM | 评审会当日 |

---

## 10. 附录

- 参考 API：`NSFilePromiseProvider`（Apple Docs）、`RegisterEventHotKey`（Carbon）、`URL.bookmarkData`、`NSPanel`、`NSFilePromiseReceiver`
- 备选开源库：`HotKey`（sindresorhus/HotKey，MIT）、`KeyboardShortcuts`（sindresorhus/KeyboardShortcuts，MIT）——Spike 3 中评估
- 参考实现：EasierDrop（Flutter 拖放，MIT）——对比 file promise 与 Flutter 拖放差异
