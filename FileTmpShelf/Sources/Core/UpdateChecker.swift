import Foundation

/// 语义版本号（三段式 major.minor.patch），支持与 GitHub Release `tag_name` 比较。
struct SemVer: Equatable, Comparable {
    let major: Int
    let minor: Int
    let patch: Int

    /// 从字符串解析：容忍 `v`/`V` 前缀（如 `v0.2.0`），失败返回 nil（非法/不足三段）。
    static func parse(_ string: String) -> SemVer? {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") {
            s.removeFirst()
        }
        let parts = s.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 3 else { return nil }
        return SemVer(major: parts[0], minor: parts[1], patch: parts[2])
    }

    static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

/// GitHub Releases API 的最小解析模型（只关心版本号 + 页面 URL）。
struct ReleaseInfo: Decodable, Equatable {
    let tagName: String
    let htmlURL: URL

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}

/// 手动更新检查器（V4-1）：请求 GitHub Releases API，SemVer 比较，返回检查结果。
/// 决策（2026-08-13）：手动更新、菜单栏静默提醒、「前往下载」打开 Releases 网页。
enum UpdateChecker {
    /// 检查结果
    enum CheckResult: Equatable {
        /// 已是最新
        case upToDate(current: String)
        /// 有新版本可用
        case updateAvailable(current: String, latest: String, releaseURL: URL)
        /// 检查失败（网络错误 / 无 Release / 解析失败 / 版本格式无法比较）
        case failed(String)
    }

    /// Releases API 端点（仓库 public → 匿名可读，无需 token）。
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/leotoli/FileTmpShelf/releases/latest")!

    /// Releases 网页（「前往下载」打开用）。
    static let releasesPageURL = URL(string: "https://github.com/leotoli/FileTmpShelf/releases/latest")!

    /// 解析 Releases API 响应并比较版本（纯逻辑，注入 data 即可单测，无需网络）。
    /// - 无 Release（404 由调用方判断，此处按「解析失败」处理）
    /// - `tag_name` 非法/无法比较 → `.failed`（不误报更新）
    static func evaluate(data: Data, currentVersion: String) -> CheckResult {
        guard let release = try? JSONDecoder().decode(ReleaseInfo.self, from: data) else {
            return .failed("无法解析版本信息")
        }
        guard let current = SemVer.parse(currentVersion) else {
            return .failed("当前版本号格式无效：\(currentVersion)")
        }
        guard let latest = SemVer.parse(release.tagName) else {
            return .failed("远端版本号格式无效：\(release.tagName)")
        }
        if latest > current {
            return .updateAvailable(
                current: currentVersion,
                latest: release.tagName,
                releaseURL: release.htmlURL
            )
        }
        return .upToDate(current: currentVersion)
    }

    /// 网络检查更新（异步）：请求 Releases API，处理 HTTP 状态码与网络错误。
    static func check(
        currentVersion: String,
        session: URLSession = .shared
    ) async -> CheckResult {
        var request = URLRequest(url: latestReleaseURL)
        request.timeoutInterval = 10
        // GitHub API 建议带 User-Agent，缺失会被拒绝（403）
        request.setValue("FileTmpShelf", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed("无效响应")
            }
            switch http.statusCode {
            case 200:
                return evaluate(data: data, currentVersion: currentVersion)
            case 404:
                // 仓库尚未发布任何 Release → 视为「无法检查」（不是错误，也不误报更新）
                return .failed("尚未发布版本")
            case 403, 429:
                return .failed("GitHub API 限流")
            default:
                return .failed("服务器错误（HTTP \(http.statusCode)）")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
