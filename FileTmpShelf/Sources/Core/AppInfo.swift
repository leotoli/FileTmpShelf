import Foundation

/// App 静态元数据（关于页展示 + 测试可注入 infoDictionary）。
/// 版本号直接读 Bundle.main 在测试宿主下拿到的是测试 runner 的 Info.plist，
/// 故抽成纯函数，默认参数读 Bundle.main，测试可注入字典验证回退逻辑。
enum AppInfo {
    static let repoURL = URL(string: "https://github.com/leotoli/FileTmpShelf")!

    /// 版本号：优先读 CFBundleShortVersionString，缺失/为空时回退默认。
    static func version(from info: [String: Any] = Bundle.main.infoDictionary ?? [:]) -> String {
        if let version = info["CFBundleShortVersionString"] as? String, !version.isEmpty {
            return version
        }
        return "0.1.1"
    }
}
