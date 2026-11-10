import SwiftUI

@main
struct MaeMookApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var logger = AppLogger.shared
    @StateObject private var updater = UpdateChecker.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup("매묵 영상 검수 도우미") {
            ContentView()
                .uiFont(.body)
                .environmentObject(model)
                .environmentObject(logger)
                .environmentObject(updater)
                .frame(minWidth: 1050, minHeight: 680)
        }
        .windowStyle(.titleBar)

        Window("분석 상태", id: "analysis-status") {
            AnalysisStatusView()
                .uiFont(.body)
                .environmentObject(model)
                .environmentObject(logger)
                .frame(minWidth: 560, minHeight: 360)
        }

        Window("에러 로그", id: "error-log") {
            ErrorLogView()
                .uiFont(.body)
                .environmentObject(logger)
                .frame(minWidth: 680, minHeight: 440)
        }

        Window("분석 결과 로그 (오탐 리포트)", id: "analysis-log") {
            AnalysisLogView()
                .uiFont(.body)
                .environmentObject(model)
                .frame(minWidth: 780, minHeight: 500)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("업데이트 확인…") {
                    updater.checkForUpdates(userInitiated: true)
                }
                Button("업데이트 배포 경로 설정…") {
                    updater.showSourceConfigSheet = true
                }
                Divider()
                Button("분석 결과 로그 (오탐 리포트)…") {
                    openWindow(id: "analysis-log")
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("에러 로그 보기…") {
                    openWindow(id: "error-log")
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                Divider()
                Button("개선 요청…") {
                    FeedbackModel.shared.showSheet = true
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .newItem) {
                Button("영상 추가…") { model.chooseVideo() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("글자 크게") { UIScale.bigger() }
                    .keyboardShortcut("+", modifiers: .command)
                Button("글자 크게 (⌘=)") { UIScale.bigger() }
                    .keyboardShortcut("=", modifiers: .command)
                Button("글자 작게") { UIScale.smaller() }
                    .keyboardShortcut("-", modifiers: .command)
                Button("글자 기본 크기") { UIScale.reset() }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }
    }
}

