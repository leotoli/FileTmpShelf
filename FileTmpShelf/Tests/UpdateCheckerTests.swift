import XCTest
@testable import FileTmpShelf

final class UpdateCheckerTests: XCTestCase {

    // MARK: - SemVer 解析

    func testSemVerParsePlain() {
        XCTAssertEqual(SemVer.parse("0.1.0"), SemVer(major: 0, minor: 1, patch: 0))
        XCTAssertEqual(SemVer.parse("1.2.3"), SemVer(major: 1, minor: 2, patch: 3))
    }

    func testSemVerParseVPrefix() {
        XCTAssertEqual(SemVer.parse("v0.2.0"), SemVer(major: 0, minor: 2, patch: 0))
        XCTAssertEqual(SemVer.parse("V1.0.0"), SemVer(major: 1, minor: 0, patch: 0))
    }

    func testSemVerParseInvalid() {
        XCTAssertNil(SemVer.parse(""))
        XCTAssertNil(SemVer.parse("not-a-version"))
        XCTAssertNil(SemVer.parse("1.0"))        // 不足三段
        XCTAssertNil(SemVer.parse("v1.0"))       // v 前缀 + 不足三段
        XCTAssertNil(SemVer.parse("1.0.x"))      // 非数字段
    }

    // MARK: - SemVer 比较

    func testSemVerComparison() {
        let v010 = SemVer(major: 0, minor: 1, patch: 0)
        let v020 = SemVer(major: 0, minor: 2, patch: 0)
        let v100 = SemVer(major: 1, minor: 0, patch: 0)
        let v101 = SemVer(major: 1, minor: 0, patch: 1)

        XCTAssertTrue(v010 < v020, "minor 递增应更大")
        XCTAssertTrue(v020 < v100, "major 递增应更大")
        XCTAssertTrue(v100 < v101, "patch 递增应更大")
        XCTAssertFalse(v020 < v010)
        XCTAssertEqual(v010, SemVer(major: 0, minor: 1, patch: 0))
    }

    // MARK: - evaluate（解析 + 比较）

    private func releaseJSON(tag: String, url: String = "https://github.com/leotoli/FileTmpShelf/releases/tag/x") -> Data {
        let json = #"{"tag_name":"\#(tag)","html_url":"\#(url)"}"#
        return Data(json.utf8)
    }

    func testEvaluateUpdateAvailable() {
        let data = releaseJSON(tag: "v0.2.0")
        let result = UpdateChecker.evaluate(data: data, currentVersion: "0.1.0")
        guard case .updateAvailable(let current, let latest, _) = result else {
            return XCTFail("应判定有更新，实际 \(result)")
        }
        XCTAssertEqual(current, "0.1.0")
        XCTAssertEqual(latest, "v0.2.0")
    }

    func testEvaluateUpToDate() {
        let data = releaseJSON(tag: "v0.1.0")
        let result = UpdateChecker.evaluate(data: data, currentVersion: "0.1.0")
        XCTAssertEqual(result, .upToDate(current: "0.1.0"))
    }

    func testEvaluateCurrentNewerThanLatest() {
        // 本地 0.2.0 > 远端 v0.1.0 → 已是最新（不误报）
        let data = releaseJSON(tag: "v0.1.0")
        let result = UpdateChecker.evaluate(data: data, currentVersion: "0.2.0")
        XCTAssertEqual(result, .upToDate(current: "0.2.0"))
    }

    func testEvaluateMalformedJSON() {
        let data = Data("not json".utf8)
        let result = UpdateChecker.evaluate(data: data, currentVersion: "0.1.0")
        guard case .failed = result else {
            return XCTFail("JSON 解析失败应返回 failed，实际 \(result)")
        }
    }

    func testEvaluateInvalidRemoteTag() {
        // 远端 tag 不是合法 SemVer → failed（不误报更新）
        let data = releaseJSON(tag: "latest")
        let result = UpdateChecker.evaluate(data: data, currentVersion: "0.1.0")
        guard case .failed = result else {
            return XCTFail("远端 tag 非法应 failed，实际 \(result)")
        }
    }

    func testEvaluateInvalidCurrentVersion() {
        let data = releaseJSON(tag: "v0.2.0")
        let result = UpdateChecker.evaluate(data: data, currentVersion: "dev")
        guard case .failed = result else {
            return XCTFail("当前版本非法应 failed，实际 \(result)")
        }
    }

    func testEvaluateReleaseURLPreserved() {
        let url = "https://github.com/leotoli/FileTmpShelf/releases/tag/v0.2.0"
        let data = releaseJSON(tag: "v0.2.0", url: url)
        let result = UpdateChecker.evaluate(data: data, currentVersion: "0.1.0")
        guard case .updateAvailable(_, _, let releaseURL) = result else {
            return XCTFail("应有更新，实际 \(result)")
        }
        XCTAssertEqual(releaseURL.absoluteString, url)
    }
}
