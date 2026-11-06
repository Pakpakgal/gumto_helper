import AppKit
import Foundation
import SwiftUI

struct AppUpdateInfo: Identifiable, Sendable {
    var id: String { latestVersion }
    let currentVersion: String
    let latestVersion: String
    let releaseTitle: String
    let releaseNotes: String
    let downloadURL: URL
    let releasePageURL: URL
    let publishedAt: Date?
}

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published var availableUpdate: AppUpdateInfo?
    @Published var isChecking = false
    @Published var showUpToDateAlert = false
    @Published var showUpdateAlert = false
    @Published var checkErrorMessage: String?
    @Published var showSourceConfigSheet = false

    private static let repoOwnerKey = "com.hcc.MaeMook.update.githubOwner"
    private static let repoNameKey = "com.hcc.MaeMook.update.githubRepo"
    private static let customFeedURLKey = "com.hcc.MaeMook.update.customFeedURL"
    private static let skippedVersionKey = "com.hcc.MaeMook.update.skippedVersion"

    var githubOwner: String {
        get {
            let stored = UserDefaults.standard.string(forKey: Self.repoOwnerKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let stored, !stored.isEmpty { return stored }
            return (Bundle.main.object(forInfoDictionaryKey: "MaeMookGitHubOwner") as? String) ?? "Pakpakgal"
        }
        set {
            UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.repoOwnerKey)
            objectWillChange.send()
        }
    }

    var githubRepo: String {
        get {
            let stored = UserDefaults.standard.string(forKey: Self.repoNameKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let stored, !stored.isEmpty { return stored }
            return (Bundle.main.object(forInfoDictionaryKey: "MaeMookGitHubRepo") as? String) ?? "gumto_helper"
        }
        set {
            UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.repoNameKey)
            objectWillChange.send()
        }
    }

    /// 선택 사항: 사내/NAS 공유 폴더의 version.json 경로(file:// 또는 /Volumes/...) 또는 커스텀 JSON URL
    var customFeedURLString: String {
        get {
            let stored = UserDefaults.standard.string(forKey: Self.customFeedURLKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let stored, !stored.isEmpty { return stored }
            return (Bundle.main.object(forInfoDictionaryKey: "MaeMookUpdateFeedURL") as? String) ?? ""
        }
        set {
            UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.customFeedURLKey)
            objectWillChange.send()
        }
    }

    var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }

    var currentBuild: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "1"
    }

    private init() {}

    func checkForUpdates(userInitiated: Bool) {
        guard !isChecking else { return }
        isChecking = true
        checkErrorMessage = nil

        Task {
            defer { self.isChecking = false }
            do {
                let info = try await fetchLatestRelease()
                let skipped = UserDefaults.standard.string(forKey: Self.skippedVersionKey)
                if Self.isVersion(info.latestVersion, newerThan: currentVersion) {
                    self.availableUpdate = info
                    if userInitiated || skipped != info.latestVersion {
                        self.showUpdateAlert = true
                    }
                } else {
                    self.availableUpdate = nil
                    if userInitiated {
                        self.showUpToDateAlert = true
                    }
                }
            } catch {
                AppLogger.shared.record(
                    level: userInitiated ? .error : .warning,
                    category: "업데이트 확인",
                    message: "최신 버전 정보를 확인하지 못했습니다.",
                    error: error,
                    details: "GitHub: \(githubOwner)/\(githubRepo)\nCustom Feed: \(customFeedURLString.isEmpty ? "없음" : customFeedURLString)"
                )
                if userInitiated {
                    self.checkErrorMessage = "업데이트 확인에 실패했습니다: \(error.localizedDescription)\n\nGitHub 저장소(\(githubOwner)/\(githubRepo))에 게시된 Release가 있는지 또는 네트워크 연결을 확인해 주세요."
                }
            }
        }
    }

    func openDownload(_ info: AppUpdateInfo) {
        NSWorkspace.shared.open(info.downloadURL)
    }

    func openReleasePage(_ info: AppUpdateInfo) {
        NSWorkspace.shared.open(info.releasePageURL)
    }

    func skipVersion(_ version: String) {
        UserDefaults.standard.set(version, forKey: Self.skippedVersionKey)
        showUpdateAlert = false
    }

    // MARK: - Networking & Parsing

    private struct GitHubReleaseResponse: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
        let tag_name: String
        let name: String?
        let body: String?
        let html_url: String
        let published_at: String?
        let assets: [Asset]
    }

    private struct CustomVersionManifest: Decodable {
        let version: String
        let title: String?
        let notes: String?
        let downloadURL: String
        let pageURL: String?
    }

    private func fetchLatestRelease() async throws -> AppUpdateInfo {
        let customFeed = customFeedURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !customFeed.isEmpty {
            return try await fetchFromCustomFeed(customFeed)
        }
        return try await fetchFromGitHub(owner: githubOwner, repo: githubRepo)
    }

    private func fetchFromCustomFeed(_ feedString: String) async throws -> AppUpdateInfo {
        let url: URL
        if feedString.hasPrefix("/") {
            url = URL(fileURLWithPath: feedString)
        } else if let parsed = URL(string: feedString) {
            url = parsed
        } else {
            throw URLError(.badURL)
        }

        let data: Data
        if url.isFileURL {
            data = try Data(contentsOf: url)
        } else {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
            request.setValue("MaeMook/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (fetched, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw NSError(domain: "UpdateChecker", code: http.statusCode, userInfo: [
                    NSLocalizedDescriptionKey: "서버가 HTTP \(http.statusCode) 상태를 반환했습니다."
                ])
            }
            data = fetched
        }

        let manifest = try JSONDecoder().decode(CustomVersionManifest.self, from: data)
        let cleanVersion = Self.normalizeVersion(manifest.version)
        let downloadURL: URL
        if manifest.downloadURL.hasPrefix("/") {
            downloadURL = URL(fileURLWithPath: manifest.downloadURL)
        } else if let parsed = URL(string: manifest.downloadURL) {
            downloadURL = parsed
        } else {
            downloadURL = url
        }
        let pageURL = manifest.pageURL.flatMap(URL.init(string:)) ?? downloadURL
        return AppUpdateInfo(
            currentVersion: currentVersion,
            latestVersion: cleanVersion,
            releaseTitle: manifest.title ?? "영상 검수 도우미 v\(cleanVersion)",
            releaseNotes: manifest.notes ?? "새로운 업데이트가 배포되었습니다.",
            downloadURL: downloadURL,
            releasePageURL: pageURL,
            publishedAt: nil
        )
    }

    private func fetchFromGitHub(owner: String, repo: String) async throws -> AppUpdateInfo {
        guard !owner.isEmpty, !repo.isEmpty,
              let apiURL = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: apiURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MaeMook/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let reason = http.statusCode == 404
                ? "GitHub 저장소(\(owner)/\(repo)) 또는 게시된 Release를 찾을 수 없습니다 (HTTP 404)."
                : "GitHub API가 HTTP \(http.statusCode) 상태를 반환했습니다."
            throw NSError(domain: "UpdateChecker.GitHub", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: reason
            ])
        }

        let release = try JSONDecoder().decode(GitHubReleaseResponse.self, from: data)
        let latestVersion = Self.normalizeVersion(release.tag_name)
        let pageURL = URL(string: release.html_url) ?? apiURL

        // DMG 또는 ZIP 에셋이 있으면 우선 연결하고, 없으면 릴리스 페이지로 연결
        let dmgAsset = release.assets.first { $0.name.lowercased().hasSuffix(".dmg") }
            ?? release.assets.first { $0.name.lowercased().hasSuffix(".zip") }
            ?? release.assets.first
        let downloadURL = dmgAsset.flatMap { URL(string: $0.browser_download_url) } ?? pageURL

        let publishedDate = release.published_at.flatMap { ISO8601DateFormatter().date(from: $0) }
        return AppUpdateInfo(
            currentVersion: currentVersion,
            latestVersion: latestVersion,
            releaseTitle: (release.name?.isEmpty == false ? release.name! : "v\(latestVersion)"),
            releaseNotes: (release.body?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                           ? release.body!
                           : "새로운 버전(v\(latestVersion))이 배포되었습니다."),
            downloadURL: downloadURL,
            releasePageURL: pageURL,
            publishedAt: publishedDate
        )
    }

    static func normalizeVersion(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.lowercased().hasPrefix("v") {
            trimmed.removeFirst()
        }
        return trimmed
    }

    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let lhs = normalizeVersion(candidate).split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        let rhs = normalizeVersion(current).split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let l = index < lhs.count ? lhs[index] : 0
            let r = index < rhs.count ? rhs[index] : 0
            if l != r { return l > r }
        }
        return false
    }
}

struct UpdateSourceSettingsSheet: View {
    @ObservedObject var checker: UpdateChecker
    @Environment(\.dismiss) private var dismiss
    @State private var owner: String = ""
    @State private var repo: String = ""
    @State private var customFeed: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("업데이트 배포 경로 설정")
                .uiFont(.headline)

            Text("기본적으로 GitHub Releases에서 최신 버전을 확인합니다. 사내/교회 공유 폴더나 별도 웹 서버를 쓰는 경우 아래 커스텀 경로를 지정할 수 있습니다.")
                .uiFont(.caption)
                .foregroundStyle(.secondary)

            GroupBox("GitHub Releases") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("소유자 (Owner)").frame(width: 110, alignment: .leading)
                        TextField("예: Pakpakgal", text: $owner)
                            .textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        Text("저장소 (Repo)").frame(width: 110, alignment: .leading)
                        TextField("예: gumto_helper", text: $repo)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(6)
            }

            GroupBox("커스텀 배포 주소 (선택 사항 · 입력 시 우선 사용)") {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("예: https://.../version.json 또는 /Volumes/Shared/version.json", text: $customFeed)
                        .textFieldStyle(.roundedBorder)
                    Text("비워두면 위의 GitHub Releases(`https://api.github.com/repos/소유자/저장소/releases/latest`)를 사용합니다.")
                        .uiFont(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(6)
            }

            HStack {
                Text("현재 앱 버전: v\(checker.currentVersion) (빌드 \(checker.currentBuild))")
                    .uiFont(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("취소", role: .cancel) { dismiss() }
                Button("저장 후 확인") {
                    checker.githubOwner = owner
                    checker.githubRepo = repo
                    checker.customFeedURLString = customFeed
                    dismiss()
                    checker.checkForUpdates(userInitiated: true)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            owner = checker.githubOwner
            repo = checker.githubRepo
            customFeed = checker.customFeedURLString
        }
    }
}
