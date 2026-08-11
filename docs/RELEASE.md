# FileTmpShelf 发布指南（Release Checklist）

本文档记录从代码到可分发 dmg 的完整发布流程。构建、签名、公证、发布、回归五步走。

---

## 0. 前置条件

| 项 | 说明 | 状态 |
|----|------|------|
| Xcode 命令行工具 | `xcodebuild` / `xcodegen` / `hdiutil` / `codesign` / `xcrun notarytool` | ✅ |
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) | 生成 .xcodeproj | ✅ |
| **Developer ID Application 证书** | 在 Keychain 中可用（`security find-identity -v -p codesigning` 验证） | ⚠️ 未配置时跳过签名 |
| Apple ID + Team ID | appleid.apple.com 查看 | ⚠️ 未配置时跳过公证 |
| App 专用密码 | 用于 `notarytool`（"FileTmpShelf notarytool"） | ⚠️ 未配置时跳过公证 |

证书未就绪时构建与打包**不会失败**，脚本会打印提示并产出未签名 dmg（仅限本地测试，不可分发）。

---

## 1. 构建

```bash
# 由 project.yml 生成 .xcodeproj（项目变更后必跑）
cd FileTmpShelf && xcodegen generate

# Release 构建（脚本内部执行）
xcodebuild \
  -project FileTmpShelf/FileTmpShelf.xcodeproj \
  -scheme FileTmpShelf -configuration Release \
  -destination "platform=macOS" \
  -derivedDataPath FileTmpShelf/build/DerivedData \
  build
```

产物：`FileTmpShelf/build/DerivedData/Build/Products/Release/FileTmpShelf.app`

---

## 2. 打包 dmg

```bash
./scripts/build-dmg.sh
# 产物：dist/FileTmpShelf-<版本>.dmg（拖拽安装布局：App + Applications 快捷方式）
```

无证书时输出结尾会打印：
```
==> [签名] 未配置 Developer ID（设置环境变量 SIGN_IDENTITY），跳过签名。
==> [公证] 未配置 Developer ID 签名，跳过公证（未公证...）
```

### 本地验证（发布前必做）

```bash
hdiutil attach dist/FileTmpShelf-0.1.0.dmg
# 拖拽 FileTmpShelf.app 到 /Applications，启动并确认：菜单栏图标 / ⌥X 唤出 / 拖入拖出
hdiutil detach /Volumes/FileTmpShelf
```

---

## 3. 签名（需要 Developer ID）

```bash
# 先确认证书
security find-identity -v -p codesigning

# 签名 + 打包（SIGN_IDENTITY 即证书名，如 "Developer ID Application: Alex (XXXXXXXXXX)"）
SIGN_IDENTITY="Developer ID Application: Alex (XXXXXXXXXX)" ./scripts/build-dmg.sh
```

- 脚本使用 `codesign --options runtime`（hardened runtime，已匹配 project.yml 的 `ENABLE_HARDENED_RUNTIME=YES`）
- 签名后验证 `codesign --verify --deep --strict` 在脚本内自动执行

---

## 4. 公证 + 打票（需要凭据）

```bash
SIGN_IDENTITY="Developer ID Application: Alex (XXXXXXXXXX)" \
NOTARY_APPLE_ID="you@example.com" \
NOTARY_TEAM_ID="XXXXXXXXXX" \
NOTARY_PASSWORD="xxxx-xxxx-xxxx-xxxx" \
./scripts/build-dmg.sh
```

脚本自动执行：
1. `xcrun notarytool submit --wait` 提交并等待审批（通常 5–15 分钟）
2. `xcrun stapler staple` 将票据钉入 dmg
3. `xcrun stapler validate` 校验

> 提示：首次建议用 `--wait` 前的输出确认 Submission ID，也可用
> `xcrun notarytool log <submission-id> --apple-id ... --password ...` 查询详情。
> 若只签名不公证的 dmg，用户首次启动会有 Gatekeeper 拦截提示。

---

## 5. 发布清单（Publish Checklist）

发布前逐项确认：

- [ ] 测试全绿：`cd FileTmpShelf && xcodebuild test`（0 失败；注意 HotKeyManagerTests 占用 ⌥X，先确认无其他 xcodebuild 进程）
- [ ] 图标在 Finder / Dock / 菜单栏显示正常（Assets 无缺失警告）
- [ ] dmg 可挂载、可拖拽安装、启动后核心流程可用（菜单栏 / ⌥X / 拖入拖出 / 清空 / 设置）
- [ ] 已签名且已公证（`spctl -a -vv -t install dist/*.dmg` 返回 accepted）
- [ ] `git log` 确认发布版本提交已合入 main
- [ ] GitHub Releases / 官网上传 `dist/FileTmpShelf-<版本>.dmg`，注明 macOS 13+ / Apple Silicon（如同时支持 Intel 需单独构建）
- [ ] 更新 `docs/RELEASE_NOTES.md` 版本说明
- [ ] 已签名产物上抽查 Gatekeeper：干净环境（无开发者豁免）拖拽安装 → 启动无拦截

### 回滚

- 版本内容有误：打新 tag 重新走 1–4；**不要**复用同一版本号发布两次
- 公证被拒：看 `notarytool log` 具体原因（通常是未签名 dmg 或未启用 hardened runtime），修复后重跑

---

## 6. 常见问题（FAQ）

| 问题 | 处理 |
|------|------|
| `hdiutil create` 报 "resource busy" | 先 `hdiutil detach /Volumes/FileTmpShelf` 卸载已挂载的旧卷 |
| 公证报 "You must first sign the relevant contracts online" | 登录 developer.apple.com 同意最新协议 |
| 未签名 dmg 双击被拦 | 预期行为；右键→打开 可绕过（仅测试），正式分发必须签名+公证 |
| 首次提交公证慢 | `--wait` 最长约 30 分钟，可后台运行并轮询 log |
