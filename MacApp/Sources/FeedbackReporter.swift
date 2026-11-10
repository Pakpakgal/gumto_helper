import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 첨부 이미지 모델

struct FeedbackAttachment: Identifiable, Equatable {
    let id = UUID()
    var data: Data        // 최종 업로드 바이트(PNG 또는 JPEG)
    var name: String

    static func == (lhs: FeedbackAttachment, rhs: FeedbackAttachment) -> Bool { lhs.id == rhs.id }
}

enum FeedbackSubmitState: Equatable {
    case idle
    case submitting
    case success(String)      // 생성된 이슈 URL
    case browserFallback      // 토큰 없이 브라우저 이슈 양식으로 전달
    case failure(String)
}

// MARK: - 피드백 모델

@MainActor
final class FeedbackModel: ObservableObject {
    static let shared = FeedbackModel()

    @Published var explanation = ""
    @Published var attachments: [FeedbackAttachment] = []
    @Published var state: FeedbackSubmitState = .idle
    @Published var showSheet = false
    @Published var tokenInput = ""
    @Published var tokenSavedMessage: String?

    private static let tokenKey = "com.hcc.MaeMook.feedback.token"
    private static let maxAttachments = 10
    private static let maxEdge: CGFloat = 1920

    var githubOwner: String { UpdateChecker.shared.githubOwner }
    var githubRepo: String { UpdateChecker.shared.githubRepo }

    var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }
    var appBuild: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "1"
    }

    /// 저장된 GitHub 토큰: 앱 설정(UserDefaults) → Info.plist 기본값 순으로 탐색.
    var storedToken: String {
        let stored = UserDefaults.standard.string(forKey: Self.tokenKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !stored.isEmpty { return stored }
        return (Bundle.main.object(forInfoDictionaryKey: "MaeMookGitHubToken") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var hasToken: Bool { !storedToken.isEmpty }

    func saveToken(_ token: String) {
        UserDefaults.standard.set(token.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.tokenKey)
        tokenSavedMessage = token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "토큰을 지웠습니다. 토큰 없이 제출하면 브라우저 이슈 양식으로 전달됩니다."
            : "토큰을 저장했습니다. 이제 이미지 첨부까지 자동 업로드됩니다."
        objectWillChange.send()
    }

    // MARK: 이미지 입력 경로 (드래그 & 드롭 / 붙여넣기)

    func addImage(data: Data, suggestedName: String? = nil) {
        guard attachments.count < Self.maxAttachments else {
            state = .failure("이미지는 최대 \(Self.maxAttachments)장까지 첨부할 수 있습니다.")
            return
        }
        guard let normalized = Self.normalizedImageData(from: data) else { return }
        let ext = normalized.1
        let name = suggestedName ?? "screenshot-\(Int(Date().timeIntervalSince1970)).\(ext)"
        attachments.append(FeedbackAttachment(data: normalized.0, name: name))
        if case .failure = state { state = .idle }
    }

    /// NSItemProvider(Finder·앱 간 드래그)에서 이미지를 뽑아 첨부한다. 하나라도 처리되면 true.
    @discardableResult
    func addImages(from providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    var url: URL?
                    if let u = item as? URL { url = u }
                    else if let u = item as? NSURL { url = u as URL }
                    else if let s = item as? String { url = URL(string: s) }
                    guard let url, let data = try? Data(contentsOf: url) else { return }
                    let name = url.lastPathComponent
                    Task { @MainActor in self.addImage(data: data, suggestedName: name) }
                }
                continue
            }
            for type in [UTType.png.identifier, UTType.tiff.identifier, UTType.jpeg.identifier, UTType.image.identifier] {
                if provider.hasItemConformingToTypeIdentifier(type) {
                    handled = true
                    provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                        guard let data else { return }
                        Task { @MainActor in self.addImage(data: data) }
                    }
                    break
                }
            }
        }
        return handled
    }

    /// 클립보드에서 이미지(또는 이미지 파일)를 읽어 첨부한다.
    @discardableResult
    func pasteFromClipboard() -> Bool {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            var added = false
            for url in urls {
                let ext = url.pathExtension.lowercased()
                guard ["png", "jpg", "jpeg", "gif", "webp", "tiff", "tif", "bmp", "heic", "heif"].contains(ext),
                      let data = try? Data(contentsOf: url) else { continue }
                addImage(data: data, suggestedName: url.lastPathComponent)
                added = true
            }
            if added { return true }
        }
        if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage], !images.isEmpty {
            var added = false
            for image in images {
                guard let tiff = image.tiffRepresentation, let normalized = Self.normalizedImageData(from: tiff) else { continue }
                attachments.append(FeedbackAttachment(data: normalized.0, name: "paste-\(Int(Date().timeIntervalSince1970)).\(normalized.1)"))
                added = true
                if attachments.count >= Self.maxAttachments { break }
            }
            if case .failure = state { state = .idle }
            return added
        }
        return false
    }

    func remove(_ attachment: FeedbackAttachment) {
        attachments.removeAll { $0.id == attachment.id }
    }

    func resetForNewSession() {
        if case .success = state {
            explanation = ""
            attachments = []
            state = .idle
            tokenSavedMessage = nil
        }
        if case .browserFallback = state {
            state = .idle
        }
    }

    // MARK: 제출

    func submit() {
        let trimmed = explanation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else {
            state = .failure("상황을 설명해 주세요. (이미지 첨부만도 가능합니다)")
            return
        }
        state = .submitting
        Task {
            do {
                if hasToken {
                    let issueURL = try await submitViaAPI(text: trimmed)
                    state = .success(issueURL)
                    NSWorkspace.shared.open(URL(string: issueURL)!)
                } else {
                    submitViaBrowser(text: trimmed)
                    state = .browserFallback
                }
            } catch {
                state = .failure(error.localizedDescription)
            }
        }
    }

    private func issueTitle(from text: String) -> String {
        let firstLine = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? ""
        let cleaned = firstLine
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "*", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "개선 요청" : cleaned
        return String(base.prefix(70))
    }

    private func issueBody(text: String, imageMarkdown: String) -> String {
        var body = "## 상황 설명\n\n\(text.isEmpty ? "(이미지 첨부만 포함)" : text)\n"
        if !imageMarkdown.isEmpty {
            body += "\n## 첨부 화면\n\(imageMarkdown)"
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        body += "\n---\n- 앱 버전: v\(appVersion) (빌드 \(appBuild))\n- macOS: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)\n- 제출 시각: \(df.string(from: Date()))\n"
        return body
    }

    private func submitViaAPI(text: String) async throws -> String {
        let token = storedToken
        var imageMarkdown = ""
        let stamp = Self.dateStamp()
        for (index, attachment) in attachments.enumerated() {
            let ext = attachment.name.hasSuffix(".jpg") || attachment.name.hasSuffix(".jpeg") ? "jpg" : "png"
            let path = "feedback/\(stamp)/\(Int(Date().timeIntervalSince1970))-\(index).\(ext)"
            let downloadURL = try await uploadContent(path: path, data: attachment.data, token: token)
            imageMarkdown += "\n![첨부 \(index + 1)](\(downloadURL))\n"
        }
        return try await createIssue(title: issueTitle(from: text), body: issueBody(text: text, imageMarkdown: imageMarkdown), token: token)
    }

    private func submitViaBrowser(text: String) {
        // 이미지를 클립보드에 넣어 브라우저 이슈 에디터에서 ⌘V로 붙여넣을 수 있게 한다.
        if !attachments.isEmpty {
            let pb = NSPasteboard.general
            pb.clearContents()
            let objects: [NSPasteboardItem] = attachments.compactMap { attachment in
                guard let image = NSImage(data: attachment.data) else { return nil }
                let item = NSPasteboardItem()
                if let tiff = image.tiffRepresentation {
                    item.setData(tiff, forType: .tiff)
                    item.setData(tiff, forType: NSPasteboard.PasteboardType("public.image"))
                }
                item.setData(attachment.data, forType: .png)
                return item
            }
            if !objects.isEmpty { pb.writeObjects(objects) }
        }
        var components = URLComponents(string: "https://github.com/\(githubOwner)/\(githubRepo)/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "title", value: issueTitle(from: text)),
            URLQueryItem(name: "body", value: issueBody(text: text, imageMarkdown: ""))
        ]
        if let url = components?.url { NSWorkspace.shared.open(url) }
    }

    // MARK: GitHub API

    private func githubRequest(path: String, method: String, token: String, json: [String: Any]) async throws -> Data {
        guard let url = URL(string: "https://api.github.com\(path)") else { throw URLError(.badURL) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("MaeMook/\(appVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200...299).contains(http.statusCode) else {
            var message = "GitHub API 오류 (HTTP \(http.statusCode))"
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let apiMessage = obj["message"] as? String {
                message += ": \(apiMessage)"
            }
            switch http.statusCode {
            case 401: message = "GitHub 토큰이 유효하지 않습니다. 토큰을 다시 확인해 주세요."
            case 403: message = "권한이 없거나 요청 제한입니다. 토큰에 issues:write / contents:write 권한이 있는지 확인해 주세요."
            case 404: message = "저장소를 찾을 수 없습니다: \(githubOwner)/\(githubRepo)"
            default: break
            }
            throw NSError(domain: "FeedbackReporter", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return data
    }

    private func uploadContent(path: String, data: Data, token: String) async throws -> String {
        let json: [String: Any] = [
            "message": "Add feedback screenshot (\(Self.dateStamp()))",
            "content": data.base64EncodedString()
        ]
        let response = try await githubRequest(
            path: "/repos/\(githubOwner)/\(githubRepo)/contents/\(path)",
            method: "PUT", token: token, json: json)
        guard let obj = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              let content = obj["content"] as? [String: Any],
              let downloadURL = content["download_url"] as? String, !downloadURL.isEmpty else {
            throw NSError(domain: "FeedbackReporter", code: -1, userInfo: [NSLocalizedDescriptionKey: "이미지 업로드 응답을 해석하지 못했습니다."])
        }
        return downloadURL
    }

    private func createIssue(title: String, body: String, token: String) async throws -> String {
        let json: [String: Any] = [
            "title": title,
            "body": body,
            "labels": ["개선 요청"]
        ]
        let response = try await githubRequest(
            path: "/repos/\(githubOwner)/\(githubRepo)/issues",
            method: "POST", token: token, json: json)
        guard let obj = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              let htmlURL = obj["html_url"] as? String, !htmlURL.isEmpty else {
            throw NSError(domain: "FeedbackReporter", code: -1, userInfo: [NSLocalizedDescriptionKey: "이슈 생성 응답을 해석하지 못했습니다."])
        }
        return htmlURL
    }

    // MARK: 이미지 정규화

    private static func dateStamp() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: Date())
    }

    /// 임의 이미지 바이트 → (최종 데이터, 확장자). 최대 변 1920px로 축소, PNG 3MB 초과 시 JPEG 전환.
    private static func normalizedImageData(from data: Data) -> (Data, String)? {
        guard let image = NSImage(data: data),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = CGFloat(cg.width), height = CGFloat(cg.height)
        guard width > 0, height > 0 else { return nil }

        let scale = min(1.0, maxEdge / max(width, height))
        let targetSize = CGSize(width: max(1, floor(width * scale)), height: max(1, floor(height * scale)))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(targetSize.width), pixelsHigh: Int(targetSize.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = targetSize

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: targetSize))
        NSGraphicsContext.restoreGraphicsState()

        if let png = rep.representation(using: .png, properties: [:]), png.count <= 3_000_000 {
            return (png, "png")
        }
        if let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
            return (jpeg, "jpg")
        }
        return rep.representation(using: .png, properties: [:]).map { ($0, "png") }
    }
}

// MARK: - ⌘V 붙여넣기를 받아내는 NSView

final class FeedbackPasteCatcherView: NSView {
    var onPaste: (() -> Bool)?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "v" {
            return onPaste?() ?? false
        }
        return super.performKeyEquivalent(with: event)
    }
}

struct FeedbackPasteCatcher: NSViewRepresentable {
    var onPaste: () -> Bool

    func makeNSView(context: Context) -> FeedbackPasteCatcherView {
        let view = FeedbackPasteCatcherView()
        view.onPaste = onPaste
        return view
    }

    func updateNSView(_ nsView: FeedbackPasteCatcherView, context: Context) {
        nsView.onPaste = onPaste
    }
}

// MARK: - 개선 요청 시트

struct FeedbackSheet: View {
    @ObservedObject var model: FeedbackModel
    @Environment(\.dismiss) private var dismiss
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            descriptionEditor
            attachmentWell
            tokenSection
            footer
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { model.resetForNewSession() }
    }

    private var header: some View {
        HStack {
            Image(systemName: "lightbulb.fill")
                .foregroundStyle(.yellow)
                .uiFont(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text("개선 요청 · 버그 신고").uiFont(.headline)
                Text("입력한 내용은 GitHub 저장소(\(model.githubOwner)/\(model.githubRepo))의 새 이슈로 등록됩니다.")
                    .uiFont(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
        }
    }

    private var descriptionEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("상황을 설명해주세요").uiFont(.caption.weight(.semibold))
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.explanation)
                    .uiFont(.body)
                    .frame(minHeight: 140, maxHeight: 200)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                if model.explanation.isEmpty {
                    Text("어떤 상황에서 무엇이 어떻게 되었는지 자유롭게 적어주세요.\n(예: 기도문 자막 구간에서 자막이 깨져 보입니다…)")
                        .uiFont(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 12)
                        .padding(.leading, 12)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private var attachmentWell: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("첨부 화면").uiFont(.caption.weight(.semibold))
                Text("드래그 & 드롭 · 이미지를 클릭한 뒤 ⌘V · 클립보드 붙여넣기")
                    .uiFont(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("클립보드 붙여넣기") {
                    if !model.pasteFromClipboard() {
                        if case .idle = model.state {
                            model.state = .failure("클립보드에 붙여넣을 이미지가 없습니다. 스크린샷(⇧⌘4/⇧⌘5) 후 다시 시도해 주세요.")
                        }
                    }
                }
                .controlSize(.small)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                    .foregroundStyle(isDropTargeted ? Color.blue : Color.secondary.opacity(0.4))
                    .background(RoundedRectangle(cornerRadius: 8).fill(isDropTargeted ? Color.blue.opacity(0.08) : Color.clear))

                if model.attachments.isEmpty {
                    FeedbackPasteCatcher { model.pasteFromClipboard() }
                        .frame(maxWidth: .infinity)
                    VStack(spacing: 6) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 24))
                            .foregroundStyle(.secondary)
                        Text("여기에 스크린샷을 끌어다 놓거나\n⌘V로 붙여넣으세요")
                            .uiFont(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .allowsHitTesting(false)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(model.attachments) { attachment in
                                thumbnail(for: attachment)
                            }
                            FeedbackPasteCatcher { model.pasteFromClipboard() }
                                .frame(width: 44, height: 84)
                        }
                        .padding(8)
                    }
                }
            }
            .frame(height: model.attachments.isEmpty ? 110 : 100)
            .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
                model.addImages(from: providers)
            }
        }
    }

    private func thumbnail(for attachment: FeedbackAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image = NSImage(data: attachment.data) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.gray.opacity(0.3)
                }
            }
            .frame(width: 110, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

            Button {
                model.remove(attachment)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .padding(4)
        }
    }

    @ViewBuilder
    private var tokenSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    if model.hasToken {
                        Label("토큰이 설정되어 있습니다. 제출 시 이미지까지 GitHub에 자동 업로드됩니다.", systemImage: "checkmark.circle.fill")
                            .uiFont(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Label("토큰이 없어 제출 시 브라우저 이슈 양식이 열리고, 이미지는 클립보드로 전달됩니다. ⌘V로 붙여넣으면 됩니다.", systemImage: "info.circle")
                            .uiFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        SecureField("GitHub fine-grained PAT (issues:write, contents:write)", text: $model.tokenInput)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                        Button("저장") {
                            model.saveToken(model.tokenInput)
                            model.tokenInput = ""
                        }
                        .controlSize(.small)
                        if model.hasToken {
                            Button("삭제") { model.saveToken("") }
                                .controlSize(.small)
                        }
                    }
                    if let message = model.tokenSavedMessage {
                        Text(message).uiFont(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 4)
            } label: {
                HStack(spacing: 4) {
                    Text("GitHub 연결 (자동 발행 설정)").uiFont(.caption.weight(.semibold))
                    Image(systemName: model.hasToken ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(model.hasToken ? .green : .orange)
                        .uiFont(.caption)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            switch model.state {
            case .submitting:
                ProgressView().controlSize(.small)
                Text("GitHub에 올리는 중…").uiFont(.caption).foregroundStyle(.secondary)
            case .success(let url):
                Label("이슈가 등록되었습니다.", systemImage: "checkmark.circle.fill")
                    .uiFont(.caption).foregroundStyle(.green)
                Button("이슈 열기") { NSWorkspace.shared.open(URL(string: url)!) }
                    .controlSize(.small)
            case .browserFallback:
                Label("브라우저에서 이슈를 확인한 뒤 이미지를 ⌘V로 붙여넣어 주세요.", systemImage: "arrow.up.right.square")
                    .uiFont(.caption).foregroundStyle(.secondary)
            case .failure(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .uiFont(.caption).foregroundStyle(.red)
                    .lineLimit(3)
            case .idle:
                EmptyView()
            }
            Spacer()
            Button("취소", role: .cancel) { dismiss() }
                .disabled(model.state == .submitting)
            Button {
                model.submit()
            } label: {
                Label("GitHub에 이슈 올리기", systemImage: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.state == .submitting)
            .keyboardShortcut(.return, modifiers: .command)
        }
    }
}
