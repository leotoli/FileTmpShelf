# MVP Backlog: FileTmpShelf — 开发任务分解

**Status**: Approved（已评审）
**Author**: Alex (PM)
**Last Updated**: 2026-08-11
**Version**: 1.0
**关联文档**: [[2026-08-10_FileTmpShelf_产品需求文档]] · [[2026-08-10_FileTmpShelf_技术Spike方案]] · [[2026-08-11_FileTmpShelf_技术设计细化]]
**代码基线**: 提交 `b5c9dde`（28 测试 0 失败，Spike + 验收全部闭环）

---

## 0. Backlog 使用说明

- 每个 Task 是 **opencode 可独立执行**的规格：目标 / 范围 / 验收标准 / 依赖。
- 执行方式：`opencode run` + Task 规格（由 PM 或接力代理提交），完成后**独立跑 `xcodebuild test` 验证**，不轻信 AI 自报。
- 每个 Task 结束后需提交 git，保持 main 始终可构建。
- 注意：`HotKeyManagerTests` 注册全局热键 ⌥C，跑测试前确认无其他 xcodebuild 进程占用热键。

---

## 1. MVP 范围冻结

**MVP 包含**（PRD V1 12 周目标）：
1. 菜单栏常驻 + ⌥C 全局热键唤出（✅ 已实现并验收）
2. 路径引用存储（零拷贝 + bookmark-less URL + 失效检测）（✅ 已实现）
3. 拖入挂载 + 拖出真实移动（Finder 优先）（✅ 已实现并验收）
4. 清空 / 清理失效 / 面板位置记忆 / 菜单栏角标（✅ 已实现）
5. **设置窗口**（快捷键自定义 / 开机启动 / 外观）（❌ 待开发）
6. **App 图标**（❌ 待开发）
7. **dmg 打包 + 公证**（❌ 待开发）
8. **文档与发布就绪**（❌ 待开发）

**MVP 不含**（明确不做，防范围蔓延）：
- 多货架 / 多窗口（V2）
- 跨卷真实移动（V2）
- Quick Look 编辑 / 文本暂存（V2+）
- 右键菜单 / 拖拽排序（V2+）

---

## 2. Task 依赖图

```
Task 1 (设置窗口) ──┬──▶ Task 3 (图标+dmg 打包)
                    │         ▲
Task 2 (设置持久化) ─┘         │
                              │
Task 4 (文档发布就绪) ◀────────┘
Task 5 (全量回归 + 手动验收终版)
```

- Task 1 → Task 3：设置窗口含"快捷键录制"，需要确认快捷键存储结构后才能稳定打包
- Task 2 可与 Task 1 并行（同一设置数据模型）
- Task 4 依赖 Task 3（dmg 产物 → 帮助文档可引用实际安装路径）
- Task 5 最后收口

---

## 3. Task 1 — 设置窗口完整实现

**目标**：把 `SettingsView` 占位符（现为纯文本）实现为可用设置窗口。

**范围**：
1. 快捷键自定义：录制 UI（点击"录制"→ 按下组合键 → 显示新快捷键）；存储到 UserDefaults；热键实时重注册
2. 开机启动：`SMAppService.mainApp`（macOS 13+ 推荐）或 Login Items API；开关切换
3. 外观：面板透明度滑块（0.5–1.0）、跟随系统/浅色/深色
4. 清空策略：清空确认阈值（默认 3，可改为 5/10/始终确认）
5. 菜单栏"设置…"入口已存在（AppEntry `openSettings`），保持 ⌘, 快捷键

**验收标准**：
- [ ] 打开设置窗口（菜单栏 → 设置 / ⌘,）显示完整表单
- [ ] 修改快捷键 → 立即生效（⌥C 换成新键），重启后保持
- [ ] 快捷键冲突时（另一应用占用）显示可读错误，不崩溃
- [ ] 开启"登录时启动" → 重启系统后自动启动（或至少 SMAppService 注册成功）
- [ ] 面板透明度滑块实时生效
- [ ] 新增设置项均有 XCTest 或逻辑单测覆盖（快捷键解析、存储 round-trip）
- [ ] `xcodebuild test` 全绿（基线 28 + 新增）

**涉及文件**：`Sources/App/AppEntry.swift`（SettingsView）、`Sources/Core/HotKeyManager.swift`（重注册支持）、`Sources/Core/SettingsStore.swift`（新建，UserDefaults 封装）

**估算**：2–3 天

---

## 4. Task 2 — 设置持久化与快捷键重注册

**目标**：将零散的 UserDefaults 访问收敛为统一 SettingsStore，支持热键变更后的运行时重注册。

**范围**：
1. `SettingsStore`（ObservableObject）：快捷键键码/修饰符、开机启动、面板透明度、清空阈值
2. HotKeyManager 支持 `update(keyCode:modifiers:)`：unregister 旧键 → register 新键
3. AppDelegate 监听 SettingsStore 变化，热键变化时重新注册
4. 迁移：读取现有散落的 UserDefaults key（`panelFrame` 保留、`showPanelOnLaunch` 保留为调试）

**验收标准**：
- [ ] SettingsStore 单测覆盖（默认值、读写 round-trip、非法值回退默认）
- [ ] 热键运行时切换：旧键失效、新键生效（真机或 CGEvent 测试）
- [ ] 已有 `panelFrame` / `showPanelOnLaunch` 键不破坏
- [ ] `xcodebuild test` 全绿

**涉及文件**：`Sources/Core/SettingsStore.swift`（新建）、`Sources/Core/HotKeyManager.swift`、`Sources/App/AppEntry.swift`

**估算**：1–2 天

---

## 5. Task 3 — App 图标 + dmg 打包 + 公证

**目标**：产出可分发、可安装的 dmg。

**范围**：
1. App 图标：创建 `Assets.xcassets` + `AppIcon.appiconset`（macOS 16×16 到 1024×1024 全套）；用 SF Symbol 或简单图形生成基础图标（如托盘/抽屉图形）
2. project.yml 更新：`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`（当前缺失）
3. 打包脚本 `scripts/build-dmg.sh`：
   - Release 构建（arm64）
   - `ditto` 打包 .app → 拖拽安装 dmg（AppleScript / create-dmg）
   - `codesign --options runtime` + `notarytool submit` + `stapler`
4. 文档：`docs/RELEASE.md` 记录发布步骤

**验收标准**：
- [ ] app 图标在 Finder/Dock/菜单栏显示正常
- [ ] `scripts/build-dmg.sh` 产出可挂载 dmg，拖拽安装后 app 可启动
- [ ] 公证命令可执行（需要 Developer ID 证书，若未配置则脚本留占位并记录前置条件）
- [ ] 项目构建不因新增 xcassets 破坏（`xcodegen generate` + build 通过）

**涉及文件**：`FileTmpShelf/Assets.xcassets/`（新建）、`project.yml`、`scripts/build-dmg.sh`（新建）、`docs/RELEASE.md`（新建）

**估算**：2–3 天（不含 Apple 证书申请等待）

---

## 6. Task 4 — 文档与发布就绪

**目标**：发布就绪度 100%（PRD §发布就绪度指标）。

**范围**：
1. 帮助文档（帮助中心/README）：安装、使用（⌥C 唤出、拖入、拖出移动、清空）、FAQ
2. 常见问题 FAQ：跨卷复制说明、失效条目说明、iCloud 占位提示
3. Release Notes 模板 + v0.1.0 初始版本说明
4. 更新 `docs/MANUAL_CHECK_S4.md` 为发布前完整验收清单（含设置项）

**验收标准**：
- [ ] README 或帮助文档覆盖全部核心功能与 FAQ
- [ ] 客服/支持 FAQ 文档存在（可被 CS/支持团队直接使用）
- [ ] Release Notes v0.1.0 已撰写
- [ ] 手动验收清单终版（含设置窗口、图标、dmg 安装）

**涉及文件**：`README.md`（新建/完善）、`docs/FAQ.md`（新建）、`docs/RELEASE_NOTES.md`（新建）、`docs/MANUAL_CHECK_S4.md`（更新）

**估算**：1–2 天

---

## 7. Task 5 — 全量回归 + 手动验收终版

**目标**：MVP 发布前最终质量门。

**范围**：
1. 全量测试回归：`xcodebuild test`（预期 30+ 测试）
2. 全量手动验收：按终版 MANUAL_CHECK 逐项执行（含 dmg 安装后的干净环境验收）
3. 缺陷修复：验收发现的问题（P0/P1）修复并复验
4. 发布候选构建：`scripts/build-dmg.sh` 产出 RC 版本

**验收标准（发布 Gate）**：
- [ ] 全部测试通过（0 失败，集成测试按设计跳过）
- [ ] 手动验收清单 100% 通过
- [ ] 无未关闭 P0/P1 缺陷
- [ ] dmg RC 可安装、可启动、核心流程可用
- [ ] 文档与 FAQ 与实际行为一致

**估算**：2–3 天

---

## 8. 发布后度量（30/60/90 天）

对照 PRD §2 成功指标：
- 闭环成功率 ≥ 98%（发布后 30 天，通过埋点/日志）
- 唤醒效率 < 300ms（发布后 30 天，性能采样）
- NPS ≥ 40（60 天用户调研）
- 留存（30 天回访）≥ 60%（90 天）

**度量方式**：V1 无遥测 → 通过手动用户调研 + TestFlight/官网下载渠道统计 + GitHub Issues/邮件反馈定性信号。V2 考虑加入匿名统计（需在 PRD 增加隐私说明）。

---

## 9. 风险与缓解（MVP 阶段新增）

| 风险 | 可能性 | 影响 | 缓解 |
|------|--------|------|------|
| Developer ID 证书未配置 | Med | 高（阻塞公证） | Task 3 脚本留占位；提前申请证书（Apple Developer 账号） |
| SMAppService 开机启动在未签名 app 上不可用 | High | 中 | 开发期验证逻辑，正式依赖签名后确认 |
| 快捷键录制 UI 与系统修饰键冲突 | Med | 中 | 录制时禁止纯修饰键；冲突检测提示 |
| 设置窗口与面板同属一个 app，焦点切换复杂 | Low | 中 | 设置窗口用标准 NSWindow，独立于 NSPanel |

---

## 10. 执行记录（实时更新）

| Task | 状态 | 提交 | 备注 |
|------|------|------|------|
| Task 1 设置窗口 | ⏳ 待开发 | — | — |
| Task 2 设置持久化 | ⏳ 待开发 | — | — |
| Task 3 图标+dmg | ⏳ 待开发 | — | — |
| Task 4 文档发布就绪 | ⏳ 待开发 | — | — |
| Task 5 回归+验收终版 | ⏳ 待开发 | — | — |

---

## 附：给评审的问题

1. 设置窗口用 **SwiftUI Settings Scene**（`Settings` 场景，标准系统设置窗口）还是自定义 NSWindow？——建议前者，系统一致性更好
2. 开机启动用 **SMAppService**（macOS 13+，需签名）还是旧 LoginItems API？——建议 SMAppService，符合 M 系列专属定位
3. 是否需要 V1 就加入**匿名使用统计**（影响 PRD 隐私条款）？——默认不加，V2 再议
