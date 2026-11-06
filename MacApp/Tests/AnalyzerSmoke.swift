import Foundation

@main
struct AnalyzerSmoke {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            fputs("usage: AnalyzerSmoke /path/to/video\n", stderr)
            exit(2)
        }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let report = try await VideoAnalyzer.analyze(url: url) { update in
            if Int(update.fraction * 100) % 20 == 0 {
                print("progress \(Int(update.fraction * 100))% \(update.message)")
            }
        }
        print("duration \(report.duration)")
        print("events \(report.events.count)")
        if let loudness = report.loudness {
            print(String(format: "loudness %.2f LUFS peak %.2f dBFS", loudness.integratedLUFS, loudness.samplePeakDBFS))
        } else {
            print("loudness unavailable")
        }
        for event in report.events {
            let references = event.bibleReferences.map(\.displayName).joined(separator: ", ")
            print("\(event.kind.rawValue) \(String(format: "%.2f", event.time)) \(event.label) text=\(event.recognizedText ?? "-") bible=\(references)")
        }
        let references = BibleReferenceParser.parse("요한복음 3:16-17 말씀과 시 23장 1절")
        precondition(references.contains { $0.osisCode == "JHN" && $0.chapter == 3 && $0.verse == 16 && $0.endVerse == 17 })
        precondition(references.contains { $0.osisCode == "PSA" && $0.chapter == 23 && $0.verse == 1 })
        print("bible parser \(references.map(\.displayName).joined(separator: ", "))")
    }
}
