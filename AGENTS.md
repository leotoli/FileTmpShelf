# AGENTS.md — hermes_FileDrop / FileTmpShelf

> Hermes 在每个会话自动加载本文件（`AGENTS.md` 链：git root → cwd）。

---

## 这是什么

macOS 原生应用 **FileTmpShelf**。Xcode 工程在 `FileTmpShelf/FileTmpShelf.xcodeproj`，dmg 产物在 `dist/`。

远程：`https://github.com/leotoli/FileTmpShelf.git`

---

## 发布 / 公证

- **公证凭据已存 Keychain profile `filetmpshelf`**，提交用：
  ```bash
  xcrun notarytool submit <dmg> --keychain-profile filetmpshelf --wait
  ```
- **私钥 `~/.config/filetmpshelf/DeveloperID` 不要提交到仓库**（已在 `.gitignore` 之外，勿手滑 `git add -f`）。
