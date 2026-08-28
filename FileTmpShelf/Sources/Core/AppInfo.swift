import Foundation

/// App 静态元数据（关于页展示 + 测试可注入 infoDictionary）。
/// 版本号直接读 Bundle.main 在测试宿主下拿到的是测试 runner 的 Info.plist，
/// 故抽成纯函数，默认参数读 Bundle.main，测试可注入字典验证回退逻辑。
enum AppInfo {
    static let repoURL = URL(string: "https://github.com/leotoli/FileTmpShelf")!

    /// 版本号：优先读 CFBundleShortVersionString，缺失/为空时回退默认。
    /// 开发版标记：Debug 构建在版本号后追加 `-dev`（如 `0.1.1-dev`），
    /// 与签名发布的正式版（`0.1.1`）一眼区分——设置页「关于」可见。
    static func version(from info: [String: Any] = Bundle.main.infoDictionary ?? [:]) -> String {
        let base: String
        if let version = info["CFBundleShortVersionString"] as? String, !version.isEmpty {
            base = version
        } else {
            base = "0.1.1"
        }
        #if DEBUG
        return base + "-dev"
        #else
        return base
        #endif
    }
}
