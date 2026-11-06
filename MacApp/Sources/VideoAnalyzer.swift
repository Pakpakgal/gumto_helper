@preconcurrency import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

enum VideoAnalyzer {
    private static let sampleFPS = 12.0
    private static let metricWidth = 160
    private static let visionWidth = 640
    /// Vision 좌표(좌하단 원점)의 하단 자막 띠.
    private static let lowerThirdRegion = CGRect(x: 0.08, y: 0.02, width: 0.84, height: 0.32)
    /// 좌상단 로고 제외 영역 (Vision 정규화 좌표: x 0~0.22, y 0.80~1.0 → 2560×1280 기준 약 560×256px).
    private static let logoExclusionRegion = CGRect(x: 0, y: 0.80, width: 0.22, height: 0.20)
    /// 스캔 띠: 화면 아래에서 3%~30% 구간. 화면 맨 아래에 붙은 자막(약 6~13%)과
    /// 1/4 지점(약 25%) 자막을 모두 포함한다.
    private static let lowerScanCenterFromBottom = 0.165
    private static let lowerScanHalfHeight = 0.135
    private static let lowerScanWidth = 640
    /// 스캔 라인 픽셀 중 크게 변한(밝기 차 > 30) 비율이 이 값을 넘으면 급격한 변화로 본다.
    private static let lowerSpikeThreshold = 0.010
    /// 직전 샘플 대비 변화 비율이 이 값 미만이면 화면이 안정된 것으로 본다.
    private static let lowerSettleThreshold = 0.004
    /// 급격한 변화 후 안정되지 않아도 이 샘플 수(≈1.5초) 뒤에는 OCR한다.
    private static let lowerMaxWait = 18
    /// 변화가 없어도 이 샘플 수(≈5초)마다 OCR을 새로 돌린다.
    private static let lowerRefreshInterval = 60
    private static let context = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: false])

    private struct Sample {
        let time: Double
        let difference: Double
        let histogramDifference: Double
        let textChanged: Bool
        let hasText: Bool
        let recognizedText: String?
        let lowerThirdTextChanged: Bool
        let lowerThirdHasText: Bool
        let lowerThirdRecognizedText: String?
        let sceneHash: UInt64
    }

    /// 같은 기도문의 연속 화면은 이 시간(초)까지 재판정 없이 유지한다.
    private static let prayerContinuationSeconds = 20.0

    static func analyze(
        url: URL,
        progress: @escaping @Sendable (AnalysisProgress) async -> Void
    ) async throws -> AnalysisReport {
        let asset = AVURLAsset(url: url)
        let durationTime = try await asset.load(.duration)
        let duration = durationTime.seconds
        guard duration.isFinite, duration > 0 else {
            throw AnalyzerError.cannotRead(reason: "유효하지 않은 영상 길이(\(duration)초)")
        }
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw AnalyzerError.noVideoTrack }
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let displayRect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let displayWidth = Int(abs(displayRect.width))
        let displayHeight = Int(abs(displayRect.height))

        async let loudnessTask = LoudnessAnalyzer.measure(url: url)
        let overallStart = Date()
        await progress(AnalysisProgress(fraction: 0.01, message: "영상 프레임을 읽는 중…", estimatedRemainingSeconds: nil, elapsedSeconds: 0))
        let samples = try await collectSamples(asset: asset, track: track, transform: transform, duration: duration, progress: progress, overallStart: overallStart)
        try Task.checkCancellation()
        await progress(AnalysisProgress(fraction: 0.85, message: "컷·디졸브·자막 후보를 분류하는 중…", estimatedRemainingSeconds: nil, elapsedSeconds: Date().timeIntervalSince(overallStart)))
        var events = classify(samples, duration: duration)
        events = try await generateThumbnails(asset: asset, url: url, events: events, duration: duration, progress: progress, overallStart: overallStart)
        await progress(AnalysisProgress(fraction: 0.99, message: "음량 분석을 마무리하는 중…", estimatedRemainingSeconds: nil, elapsedSeconds: Date().timeIntervalSince(overallStart)))
        let loudness = await loudnessTask

        let totalElapsed = Date().timeIntervalSince(overallStart)
        await progress(AnalysisProgress(fraction: 1.0, message: "분석 완료 · \(events.count)개 · \(formatTime(totalElapsed, includeTenths: false))", estimatedRemainingSeconds: 0, elapsedSeconds: totalElapsed))

        return AnalysisReport(
            videoName: url.deletingPathExtension().lastPathComponent,
            duration: duration,
            width: displayWidth,
            height: displayHeight,
            createdAt: Date(),
            events: events,
            loudness: loudness
        )
    }

    private static func collectSamples(
        asset: AVAsset,
        track: AVAssetTrack,
        transform: CGAffineTransform,
        duration: Double,
        progress: @escaping @Sendable (AnalysisProgress) async -> Void,
        overallStart: Date
    ) async throws -> [Sample] {
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw AnalyzerError.cannotRead(reason: "AVAssetReader에 비디오 트랙 출력을 연결할 수 없음")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? AnalyzerError.cannotRead(reason: "AVAssetReader 시작 실패")
        }

        var results: [Sample] = []
        var previousGray: [UInt8]?
        var previousHistogram: [Double]?
        var previousText = ""
        var previousRecognizedText: String?
        var previousHasText = false
        var lowerThirdCandidateText: String?
        var confirmedLowerThirdText: String?
        // 하단 1/4 지점 스캔 라인의 픽셀 변화로 하단 자막 등장/교체/소멸을 감지한다.
        var lowerRef: [UInt8]?          // 마지막으로 OCR한 시점의 스캔 라인
        var lowerLast: [UInt8]?         // 직전 샘플의 스캔 라인
        var lowerPendingSince: Int?     // 급격한 변화가 시작된 샘플 인덱스
        var lowerStable = 0             // 변화 이후 안정된 연속 샘플 수
        var lowerLastOCRIndex = -999
        var nextSampleTime = 0.0
        var sampleIndex = 0
        var lastReported = -1
        var consecutiveSimilar = 0
        var lastOCRIndex = -999

        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let timestamp = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            guard timestamp + 0.0001 >= nextSampleTime else { continue }
            nextSampleTime += 1.0 / sampleFPS
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { continue }

            let metricImage = normalizedImage(from: pixelBuffer, transform: transform, maxDimension: metricWidth)
            guard let metricImage else { continue }

            let gray = grayscale(image: metricImage, width: metricWidth)
            let histogram = makeHistogram(gray)
            let sceneHash = perceptualHash(gray, width: metricWidth)
            let difference = previousGray.map { meanDifference(gray, $0) } ?? 0
            let histogramDifference = previousHistogram.map { histogramDistance(histogram, $0) } ?? 0

            // 화면 변화가 감지될 때는 전체 프레임을 OCR한다.
            let needsOCR = shouldRunOCR(
                difference: difference,
                histogramDifference: histogramDifference,
                consecutiveSimilar: &consecutiveSimilar,
                lastOCRIndex: &lastOCRIndex,
                sampleIndex: sampleIndex
            )
            // 하단 1/4 지점 스캔 라인: 이전 OCR 시점 대비 픽셀이 급격히 튀면 자막 변화로 본다.
            // 페이드 인/아웃은 프레임당 변화가 작으므로 "마지막 OCR 시점"과 비교하고,
            // 변화가 끝나 화면이 안정된 시점(연속 2샘플)에 OCR한다.
            let strip = lowerStripPixels(from: pixelBuffer, transform: transform)
            var lowerTrigger = false
            if let strip {
                if let ref = lowerRef {
                    if changedFraction(strip, ref) > lowerSpikeThreshold {
                        if lowerPendingSince == nil { lowerPendingSince = sampleIndex }
                        if let last = lowerLast, changedFraction(strip, last) < lowerSettleThreshold {
                            lowerStable += 1
                        } else {
                            lowerStable = 0
                        }
                        if lowerStable >= 2 || sampleIndex - (lowerPendingSince ?? sampleIndex) >= lowerMaxWait {
                            lowerTrigger = true
                        }
                    } else {
                        lowerPendingSince = nil
                        lowerStable = 0
                    }
                } else {
                    lowerTrigger = true // 첫 샘플
                }
                // 변화가 없어도 주기적으로 한 번씩 확인한다.
                if sampleIndex - lowerLastOCRIndex >= lowerRefreshInterval { lowerTrigger = true }
                lowerLast = strip
            }
            let needsLowerFresh = lowerTrigger && !needsOCR
            let visionImage = (needsOCR || needsLowerFresh)
                ? normalizedImage(from: pixelBuffer, transform: transform, maxDimension: visionWidth)
                : nil

            var signature = previousText
            var hasText = previousHasText
            var recognizedText = previousRecognizedText
            var lowerReading: (hasText: Bool, text: String?)?
            if needsOCR, let visionImage {
                // 전체 OCR 결과에서 하단 띠 문구를 좌표로 추려 별도 OCR을 생략한다.
                let lines = ocrLines(visionImage)
                (signature, hasText, recognizedText) = makeSignature(from: lines)
                if lowerTrigger {
                    let lowerLines = lines.filter { lowerThirdRegion.contains(CGPoint(x: $0.box.midX, y: $0.box.midY)) }
                    let reading = makeSignature(from: lowerLines)
                    lowerReading = (reading.1, reading.2)
                }
            } else if needsLowerFresh, let visionImage {
                let reading = textSignature(visionImage, regionOfInterest: lowerThirdRegion)
                lowerReading = (reading.1, reading.2)
            }

            var lowerThirdTextChanged = false
            if let lowerReading, let strip {
                lowerRef = strip
                lowerLastOCRIndex = sampleIndex
                lowerPendingSince = nil
                lowerStable = 0
                let (hasCandidate, candidateText) = lowerReading
                if hasCandidate, let candidateText, !candidateText.isEmpty {
                    // 화면이 안정된 뒤 읽은 결과이므로 한 번의 판독으로 확정한다.
                    if confirmedLowerThirdText == nil ||
                        textSimilarity(normalizedText(confirmedLowerThirdText), normalizedText(candidateText)) < 0.72 {
                        confirmedLowerThirdText = candidateText
                        lowerThirdTextChanged = true
                    }
                } else {
                    // 자막이 사라진 뒤 같은 문구가 다시 나와도 새 후보로 기록한다.
                    confirmedLowerThirdText = nil
                }
            }

            // 첫 프레임부터 떠 있는 자막도 후보로 남긴다.
            let textChanged = signature != previousText && (hasText || previousHasText)
            results.append(Sample(
                time: timestamp,
                difference: difference,
                histogramDifference: histogramDifference,
                textChanged: textChanged,
                hasText: hasText,
                recognizedText: recognizedText,
                lowerThirdTextChanged: lowerThirdTextChanged,
                lowerThirdHasText: confirmedLowerThirdText != nil,
                lowerThirdRecognizedText: confirmedLowerThirdText,
                sceneHash: sceneHash
            ))
            previousGray = gray
            previousHistogram = histogram
            previousText = signature
            previousHasText = hasText
            previousRecognizedText = recognizedText
            sampleIndex += 1

            let percent = min(85, Int(timestamp / duration * 85))
            if percent != lastReported {
                lastReported = percent
                await progress(AnalysisProgress(fraction: Double(percent) / 100.0, message: "프레임 분석 중 · \(formatTime(timestamp, includeTenths: false)) / \(formatTime(duration, includeTenths: false))", estimatedRemainingSeconds: nil, elapsedSeconds: Date().timeIntervalSince(overallStart)))
            }
        }
        if reader.status == .failed {
            throw reader.error ?? AnalyzerError.cannotRead(reason: "프레임 읽기 도중 AVAssetReader 실패")
        }
        return results
    }

    /// 화면 변화가 감지되거나 주기적 타이밍에 OCR을 실행한다.
    private static func shouldRunOCR(
        difference: Double,
        histogramDifference: Double,
        consecutiveSimilar: inout Int,
        lastOCRIndex: inout Int,
        sampleIndex: Int
    ) -> Bool {
        let isSimilar = difference < 8 && histogramDifference < 0.12
        if isSimilar {
            consecutiveSimilar += 1
        } else {
            consecutiveSimilar = 0
        }

        let framesSinceLastOCR = sampleIndex - lastOCRIndex
        guard framesSinceLastOCR >= 6 else { return false } // 최소 0.5초 간격 유지

        // 1) 화면에 유의미한 변화가 감지되었을 때 즉시 OCR
        if !isSimilar && framesSinceLastOCR >= 12 {
            lastOCRIndex = sampleIndex
            return true
        }

        // 2) 주기적 OCR (변화가 없더라도 10초, 연속 유사 15초)
        let interval = (consecutiveSimilar >= 240) ? 180 : 120
        if framesSinceLastOCR >= interval {
            lastOCRIndex = sampleIndex
            return true
        }

        return false
    }

    private static func normalizedImage(from buffer: CVPixelBuffer, transform: CGAffineTransform, maxDimension: Int) -> CGImage? {
        var image = CIImage(cvPixelBuffer: buffer).transformed(by: transform)
        let extent = image.extent
        image = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let scale = CGFloat(maxDimension) / max(image.extent.width, image.extent.height)
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(image, from: image.extent.integral)
    }

    private static func grayscale(image: CGImage, width: Int) -> [UInt8] {
        let height = max(1, Int(Double(image.height) * Double(width) / Double(image.width)))
        var bytes = [UInt8](repeating: 0, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        bytes.withUnsafeMutableBytes { raw in
            if let ctx = CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) {
                ctx.interpolationQuality = .low
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        return bytes
    }

    private static func makeHistogram(_ pixels: [UInt8]) -> [Double] {
        var histogram = [Double](repeating: 0, count: 32)
        for value in pixels { histogram[min(31, Int(value) / 8)] += 1 }
        let count = Double(max(1, pixels.count))
        return histogram.map { $0 / count }
    }

    private static func meanDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var total = 0
        for i in a.indices { total += abs(Int(a[i]) - Int(b[i])) }
        return Double(total) / Double(a.count)
    }

    private static func histogramDistance(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) } / 2
    }

    /// 자막이 주로 위치하는 위·아래 영역을 제외한 중앙 장면의 8×8 지문.
    private static func perceptualHash(_ pixels: [UInt8], width: Int) -> UInt64 {
        guard width > 0, pixels.count >= width else { return 0 }
        let height = pixels.count / width
        let minY = height / 5
        let maxY = max(minY + 1, height * 4 / 5)
        var cells = [Double](repeating: 0, count: 64)
        var counts = [Int](repeating: 0, count: 64)
        for y in minY..<maxY {
            let cellY = min(7, (y - minY) * 8 / max(1, maxY - minY))
            for x in 0..<width {
                let cellX = min(7, x * 8 / width)
                let index = cellY * 8 + cellX
                cells[index] += Double(pixels[y * width + x])
                counts[index] += 1
            }
        }
        for index in cells.indices { cells[index] /= Double(max(1, counts[index])) }
        let mean = cells.reduce(0, +) / 64
        var hash: UInt64 = 0
        for index in cells.indices where cells[index] >= mean { hash |= UInt64(1) << UInt64(index) }
        return hash
    }

    private static func normalizedText(_ text: String?) -> String {
        (text ?? "").lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// 초반 이름·직책 소개 화면에 포함된 본문 표기는 검수 대상 구절이 아니다.
    private static func isOpeningReferenceCard(_ text: String, time: Double) -> Bool {
        guard time <= 20 else { return false }
        let introMarkers = ["목사", "복사", "강도사", "전도사", "교구", "선교", "장로", "집사", "본문", "설교"]
        return introMarkers.contains(where: text.contains) || (time <= 8 && text.count < 25)
    }

    private static func textSimilarity(_ lhs: String, _ rhs: String) -> Double {
        guard !lhs.isEmpty || !rhs.isEmpty else { return 1 }
        let a = Set(lhs)
        let b = Set(rhs)
        return Double(a.intersection(b).count) / Double(max(1, a.union(b).count))
    }

    // MARK: - Logo & Watermark Filtering

    private static func isLogoText(_ text: String) -> Bool {
        let pattern = #"(매\s*일\s*의?\s*묵\s*상|오\s*늘\s*의?\s*양\s*식|양\s*식\s*편)"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            let range = NSRange(text.startIndex..., in: text)
            if regex.firstMatch(in: text, options: [], range: range) != nil {
                return true
            }
        }
        return false
    }

    private static func isLogoObservation(_ observation: VNRecognizedTextObservation) -> Bool {
        // 좌상단 로고 영역(2560×1280 기준 x 0~560, y 0~256)은 OCR 결과에서 완전히 제외한다.
        // Vision 좌표는 좌하단 원점이라 위쪽은 y가 크다.
        let box = observation.boundingBox
        if box.midX < logoExclusionRegion.maxX && box.midY > logoExclusionRegion.minY { return true }

        guard let candidate = observation.topCandidates(1).first?.string else { return false }

        // 성경 책 이름이나 장/절 숫자가 들어있으면 로고가 아님
        let hasBibleBook = BibleReferenceParser.books.contains { book in
            book.aliases.contains { candidate.contains($0) }
        }
        if hasBibleBook { return false }

        // 텍스트에 "매일의 묵상", "오늘의 양식" 등 로고 키워드가 포함된 경우 제외
        if isLogoText(candidate) { return true }

        return false
    }

    private static func cleanLogoText(_ text: String) -> String {
        let patterns = [
            #"매\s*일\s*의?\s*묵\s*상[\s\d\-_.·•]*오\s*늘\s*의?\s*양\s*식(?:\s*편)?"#,
            #"매\s*일\s*의?\s*묵\s*상[\s\d\-_.·•]*"#,
            #"오\s*늘\s*의?\s*양\s*식(?:\s*편)?"#,
            #"양\s*식\s*편"#
        ]
        var result = text
        for pat in patterns {
            if let regex = try? NSRegularExpression(pattern: pat, options: .caseInsensitive) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: " ")
            }
        }
        return result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct OCRLine {
        let text: String
        let box: CGRect
    }

    /// 하단 1/4 지점 스캔 라인(가는 띠)의 회색조 픽셀.
    private static func lowerStripPixels(from buffer: CVPixelBuffer, transform: CGAffineTransform) -> [UInt8]? {
        var image = CIImage(cvPixelBuffer: buffer).transformed(by: transform)
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        image = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let scale = CGFloat(lowerScanWidth) / image.extent.width
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let h = image.extent.height
        let cropRect = CGRect(
            x: 0,
            y: h * (lowerScanCenterFromBottom - lowerScanHalfHeight),
            width: image.extent.width,
            height: max(2, h * lowerScanHalfHeight * 2)
        ).integral
        guard let cg = context.createCGImage(image.cropped(to: cropRect), from: cropRect) else { return nil }
        return grayscale(image: cg, width: lowerScanWidth)
    }

    /// 두 스캔 라인에서 밝기 차가 크게(> 30) 난 픽셀의 비율.
    private static func changedFraction(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var big = 0
        for i in a.indices where abs(Int(a[i]) - Int(b[i])) > 30 { big += 1 }
        return Double(big) / Double(a.count)
    }

    private static func textSignature(
        _ image: CGImage,
        regionOfInterest: CGRect? = nil
    ) -> (String, Bool, String?) {
        makeSignature(from: ocrLines(image, regionOfInterest: regionOfInterest))
    }

    /// OCR 결과를 (로고 제외) 위→아래, 좌→우 순의 줄 목록으로 반환한다.
    private static func ocrLines(_ image: CGImage, regionOfInterest: CGRect? = nil) -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        if let regionOfInterest { request.regionOfInterest = regionOfInterest }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["ko-KR", "en-US"]
        request.minimumTextHeight = 0.008
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        try? handler.perform([request])

        let observations = (request.results ?? []).filter { obs in
            guard obs.confidence > 0.25 else { return false }
            // 좌상단 로고 및 로고 텍스트는 OCR에서 완전 제외
            return !isLogoObservation(obs)
        }

        // 위에서 아래로, 같은 행이면 좌에서 우로 정렬 (Vision 좌표계: maxY 1.0이 맨 위)
        let sorted = observations.sorted { (a, b) -> Bool in
            let aY = a.boundingBox.midY
            let bY = b.boundingBox.midY
            if abs(aY - bY) > 0.04 {
                return aY > bY
            }
            return a.boundingBox.midX < b.boundingBox.midX
        }

        return sorted.compactMap { observation -> OCRLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let cleaned = cleanLogoText(candidate.string)
            return cleaned.isEmpty ? nil : OCRLine(text: cleaned, box: observation.boundingBox)
        }
    }

    private static func makeSignature(from lines: [OCRLine]) -> (String, Bool, String?) {
        let recognized = lines.map(\.text)
        let tokens = lines.compactMap { line -> String? in
            let normalized = line.text.lowercased().filter { $0.isLetter || $0.isNumber }
            guard normalized.count >= 2 else { return nil }
            let x = Int(line.box.midX * 10)
            let y = Int(line.box.midY * 10)
            return "\(x):\(y):\(normalized)"
        }
        let text = cleanLogoText(recognized.joined(separator: " "))
        let hasValidText = !tokens.isEmpty && !text.isEmpty
        return (tokens.joined(separator: "|"), hasValidText, text.isEmpty ? nil : text)
    }

    /// 고해상도 이미지(썸네일 프레임 등)에서 선명한 한글 텍스트를 정밀하게 추출합니다 (로고 제외).
    private static func extractHighResText(from image: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["ko-KR", "en-US"]
        request.minimumTextHeight = 0.006
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        try? handler.perform([request])

        let observations = (request.results ?? []).filter { obs in
            guard obs.confidence > 0.2 else { return false }
            return !isLogoObservation(obs)
        }
        guard !observations.isEmpty else { return nil }

        let sorted = observations.sorted { (a, b) -> Bool in
            let aY = a.boundingBox.midY
            let bY = b.boundingBox.midY
            if abs(aY - bY) > 0.035 {
                return aY > bY
            }
            return a.boundingBox.midX < b.boundingBox.midX
        }

        let lines = sorted.compactMap { obs -> String? in
            guard let candidate = obs.topCandidates(1).first?.string else { return nil }
            let cleaned = cleanLogoText(candidate)
            return cleaned.isEmpty ? nil : cleaned
        }
        let joined = lines.joined(separator: " ")
        let cleaned = cleanLogoText(joined)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private static func robust(_ values: [Double]) -> (Double, Double) {
        let m = median(values)
        return (m, max(0.000001, median(values.map { abs($0 - m) })))
    }

    private static func classify(_ samples: [Sample], duration: Double) -> [ReviewEvent] {
        guard samples.count > 3 else { return [] }
        let differences = Array(samples.dropFirst().map(\.difference))
        let histogramDifferences = Array(samples.dropFirst().map(\.histogramDifference))
        let (diffMedian, diffMAD) = robust(differences)
        let (histMedian, histMAD) = robust(histogramDifferences)
        let cutDiff = max(16, diffMedian + 7 * diffMAD)
        let cutHist = max(0.2, histMedian + 4.5 * histMAD)
        let moderate = max(4.5, diffMedian + 2.4 * diffMAD)

        var events: [ReviewEvent] = []
        var rawCuts: [Int] = []
        for index in 1..<samples.count where samples[index].difference >= cutDiff && samples[index].histogramDifference >= cutHist {
            rawCuts.append(index)
        }
        var groups: [[Int]] = []
        for index in rawCuts {
            if let last = groups.indices.last, index - groups[last].last! <= 1 { groups[last].append(index) }
            else { groups.append([index]) }
        }
        var occupied = Set<Int>()
        for group in groups {
            if group.count >= 2 {
                let start = samples[group.first!].time
                let end = samples[group.last!].time
                events.append(ReviewEvent(kind: .dissolve, label: "디졸브 후보", time: start, endTime: end, confidence: min(0.95, 0.62 + Double(group.count) * 0.07)))
                occupied.formUnion(group)
            } else if let index = group.first {
                let sample = samples[index]
                let confidence = min(0.99, 0.62 + 0.18 * sample.difference / cutDiff + 0.18 * sample.histogramDifference / cutHist)
                events.append(ReviewEvent(kind: .cut, label: "컷 전환", time: sample.time, confidence: confidence))
                occupied.insert(index)
            }
        }

        var runStart: Int?
        for index in 1..<samples.count {
            let sustained = samples[index].difference >= moderate && !occupied.contains(index)
            if sustained && runStart == nil { runStart = index }
            if (!sustained || index == samples.count - 1), let startIndex = runStart {
                let endIndex = sustained ? index : index - 1
                let segmentDuration = Double(endIndex - startIndex + 1) / sampleFPS
                if segmentDuration >= 0.5 && segmentDuration <= 3.0 {
                    events.append(ReviewEvent(
                        kind: .dissolve, label: "디졸브 후보",
                        time: samples[startIndex].time, endTime: samples[endIndex].time,
                        confidence: min(0.9, 0.48 + segmentDuration * 0.16)
                    ))
                }
                runStart = nil
            }
        }

        var acceptedSubtitles: [(hash: UInt64, text: String)] = []
        // 기도문은 화면 가운데 PRAY 라벨이 인식될 때만 판정한다.
        var lastPrayerTime: Double?

        let subtitleDetections: [(sample: Sample, text: String)] = samples.flatMap { sample -> [(sample: Sample, text: String)] in
            var detectedTexts: [String] = []
            if sample.textChanged && sample.hasText, let text = sample.recognizedText {
                detectedTexts.append(text)
            }
            if sample.lowerThirdTextChanged && sample.lowerThirdHasText,
               let text = sample.lowerThirdRecognizedText {
                detectedTexts.append(text)
            }
            return detectedTexts.map { (sample: sample, text: $0) }
        }

        for (sample, text) in subtitleDetections {
            let normalized = normalizedText(text)
            let isDuplicate = acceptedSubtitles.suffix(20).contains { previous in
                let sceneDistance = (previous.hash ^ sample.sceneHash).nonzeroBitCount
                return sceneDistance <= 8 && textSimilarity(previous.text, normalized) >= 0.72
            }
            if isDuplicate { continue }

            // 1. 기도문 판별: 화면 가운데 PRAY 라벨이 인식될 때만 진입한다.
            //    같은 기도문의 연속 화면은 20초까지 재판정 없이 유지한다.
            let hasPrayLabel = KoreanGrammarChecker.hasPrayLabel(text)
            let continuedPrayer = lastPrayerTime.map { sample.time - $0 <= Self.prayerContinuationSeconds } == true
            if hasPrayLabel || continuedPrayer {
                if hasPrayLabel { lastPrayerTime = sample.time }
                let suggestions = KoreanGrammarChecker.check(text)
                events.append(ReviewEvent(
                    kind: .subtitle,
                    label: "기도문 자막",
                    time: sample.time,
                    confidence: 0.82,
                    recognizedText: text,
                    bibleReferences: [],
                    bibleComparisons: [],
                    isPrayer: true,
                    grammarSuggestions: suggestions
                ))
                acceptedSubtitles.append((hash: sample.sceneHash, text: normalized))
                continue
            }

            // 2. 성경 구절 파싱 및 대조
            let parsedRefs = BibleReferenceParser.parse(text)
            let validatedRefs: [BibleReference]
            let comparisons: [BibleComparisonResult]
            var eventLabel = "화면 자막 변화"

            if !parsedRefs.isEmpty {
                // 초반 이름·직책 소개 자막에 적힌 본문 표기는 비교에서 제외한다.
                let isIntro = isOpeningReferenceCard(text, time: sample.time)

                if isIntro {
                    validatedRefs = parsedRefs
                    comparisons = parsedRefs.map { ref in
                        BibleComparisonResult(
                            reference: ref,
                            scriptureText: "",
                            subtitleText: text,
                            accuracy: 1.0,
                            status: .referenceOnly,
                            errors: [],
                            summary: "오늘의 본문 소개 (본문 검증 생략)"
                        )
                    }
                    let refNames = parsedRefs.map { $0.displayName }.joined(separator: ", ")
                    eventLabel = "오늘의 본문 안내 (\(refNames))"
                } else {
                    let result = BibleVerseChecker.analyze(
                        recognizedText: text,
                        references: parsedRefs
                    )
                    validatedRefs = result.references
                    comparisons = result.comparisons
                    let refNames = validatedRefs.map { $0.displayName }.joined(separator: ", ")
                    eventLabel = "말씀 자막 (\(refNames))"
                }
            } else {
                validatedRefs = []
                comparisons = []
            }

            events.append(ReviewEvent(
                kind: .subtitle,
                label: eventLabel,
                time: sample.time,
                confidence: 0.82,
                recognizedText: text,
                bibleReferences: validatedRefs,
                bibleComparisons: comparisons,
                isPrayer: false,
                grammarSuggestions: []
            ))
            acceptedSubtitles.append((hash: sample.sceneHash, text: normalized))
        }
        return merge(events).sorted { $0.time < $1.time }
    }

    private static func merge(_ source: [ReviewEvent]) -> [ReviewEvent] {
        var output: [ReviewEvent] = []
        for event in source.sorted(by: { ($0.kind.rawValue, $0.time) < ($1.kind.rawValue, $1.time) }) {
            if let last = output.last, last.kind == event.kind,
               event.time - (last.endTime ?? last.time) <= 0.75 {
                if event.kind == .dissolve {
                    output[output.count - 1] = ReviewEvent(
                        kind: .dissolve, label: last.label, time: last.time,
                        endTime: max(last.endTime ?? last.time, event.endTime ?? event.time),
                        confidence: max(last.confidence, event.confidence)
                    )
                } else if event.confidence > last.confidence {
                    output[output.count - 1] = event
                }
            } else {
                output.append(event)
            }
        }
        return output
    }

    private static func generateThumbnails(
        asset: AVAsset,
        url: URL,
        events: [ReviewEvent],
        duration: Double,
        progress: @escaping @Sendable (AnalysisProgress) async -> Void,
        overallStart: Date
    ) async throws -> [ReviewEvent] {
        guard !events.isEmpty else { return events }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 540)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.12, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.12, preferredTimescale: 600)
        let cacheRoot = try cacheDirectory(for: url)

        // AVAssetImageGenerator 하나에 동시 요청을 몰아넣으면 일부 영상에서
        // copyCGImage가 멈출 수 있다. 순차 처리하며 각 후보마다 진행률을 알린다.
        var results = events
        var lastPrayerTime: Double?

        for index in events.indices {
            try Task.checkCancellation()
            let time = CMTime(seconds: events[index].time, preferredTimescale: 600)
            if let image = try? generator.copyCGImage(at: time, actualTime: nil) {
                let target = cacheRoot.appendingPathComponent("\(events[index].id.uuidString).jpg")
                if writeJPEG(image, to: target) {
                    results[index].thumbnailPath = target.path
                }

                // 고해상도 썸네일 프레임에서 정밀 한글 OCR 및 말씀자막 검수
                if let highResText = extractHighResText(from: image) {
                    results[index].recognizedText = highResText

                    // 1. 기도문 구간 처리: 고해상도 프레임 가운데서 PRAY 라벨이 인식될 때만 판정한다.
                    //    이전 이벤트의 판정에 의존하지 않는다(20초 연속 유지 제외).
                    let hasPrayLabel = KoreanGrammarChecker.hasPrayLabel(highResText)
                    let continuedPrayer = lastPrayerTime.map { results[index].time - $0 <= Self.prayerContinuationSeconds } == true
                    if hasPrayLabel || continuedPrayer {
                        if hasPrayLabel { lastPrayerTime = results[index].time }
                        results[index].isPrayer = true
                        results[index].label = "기도문 자막"
                        results[index].bibleReferences = []
                        results[index].bibleComparisons = []
                        results[index].grammarSuggestions = KoreanGrammarChecker.check(highResText)
                        continue
                    }

                    // 1차 판정에서 기도문이었다가 고해상도 재판정에 걸리지 않으면 일반 자막으로 되돌린다.
                    if results[index].isPrayer {
                        results[index].isPrayer = false
                        results[index].label = "화면 자막 변화"
                        results[index].grammarSuggestions = []
                    }

                    // 2. 성경 말씀 자막 처리
                    let parsedRefs = BibleReferenceParser.parse(highResText)
                    if !parsedRefs.isEmpty {
                        // 초반 이름·직책 소개 자막의 본문 표기는 고해상도 비교에서도 제외한다.
                        let isIntro = isOpeningReferenceCard(highResText, time: results[index].time)

                        if isIntro {
                            results[index].bibleReferences = parsedRefs
                            results[index].bibleComparisons = parsedRefs.map { ref in
                                BibleComparisonResult(
                                    reference: ref,
                                    scriptureText: "",
                                    subtitleText: highResText,
                                    accuracy: 1.0,
                                    status: .referenceOnly,
                                    errors: [],
                                    summary: "오늘의 본문 소개 (본문 검증 생략)"
                                )
                            }
                            let refNames = parsedRefs.map { $0.displayName }.joined(separator: ", ")
                            results[index].label = "오늘의 본문 안내 (\(refNames))"
                        } else {
                            // 실제 설교 본문 자막 (골로새서 2:8, 고린도전서 1:22-25 등): 원문 대조 및 오탈자/누락 정밀 분석
                            let (validatedRefs, comparisons) = BibleVerseChecker.analyze(
                                recognizedText: highResText,
                                references: parsedRefs
                            )
                            results[index].bibleReferences = validatedRefs
                            results[index].bibleComparisons = comparisons
                            let refNames = validatedRefs.map { $0.displayName }.joined(separator: ", ")
                            results[index].label = "말씀 자막 (\(refNames))"
                        }
                    }
                }
            }
            if index % 4 == 0 || index == events.count - 1 {
                let fraction = 0.86 + 0.12 * Double(index + 1) / Double(events.count)
                await progress(AnalysisProgress(
                    fraction: fraction,
                    message: "썸네일 및 자막 정밀 분석 중 · \(index + 1) / \(events.count)",
                    estimatedRemainingSeconds: nil,
                    elapsedSeconds: Date().timeIntervalSince(overallStart)
                ))
            }
        }
        return results
    }

    private static func cacheDirectory(for url: URL) throws -> URL {
        let manager = FileManager.default
        let base = manager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.hcc.MaeMook", isDirectory: true)
        let attributes = try manager.attributesOfItem(atPath: url.path)
        let size = attributes[.size] as? NSNumber ?? 0
        let stamp = attributes[.modificationDate] as? Date ?? .distantPast
        let key = "\(url.lastPathComponent)-\(size)-\(Int(stamp.timeIntervalSince1970))"
            .data(using: .utf8)!.base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
        let directory = base.appendingPathComponent(String(key.prefix(80)), isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func writeJPEG(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }
}
