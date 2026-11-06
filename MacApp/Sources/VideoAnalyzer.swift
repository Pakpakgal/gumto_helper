@preconcurrency import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

enum VideoAnalyzer {
    private static let sampleFPS = 12.0
    private static let metricWidth = 160
    /// Vision 좌표(좌하단 원점)의 하단 자막 띠.
    private static let lowerThirdRegion = CGRect(x: 0.08, y: 0.02, width: 0.84, height: 0.32)
    /// 좌상단 로고 제외 영역 (Vision 정규화 좌표: x 0~0.22, y 0.80~1.0 → 2560×1280 기준 약 560×256px).
    private static let logoExclusionRegion = CGRect(x: 0, y: 0.80, width: 0.22, height: 0.20)
    /// 스캔 띠: 화면 아래에서 3%~30% 구간. 화면 맨 아래에 붙은 자막(약 6~13%)과
    /// 1/4 지점(약 25%) 자막을 모두 포함한다.
    private static let lowerScanCenterFromBottom = 0.165
    private static let lowerScanHalfHeight = 0.135
    private static let lowerScanWidth = 640
    private static let lowerScanRows = 36
    /// 스캔 라인 픽셀 중 크게 변한(밝기 차 > 30) 비율이 이 값을 넘으면 급격한 변화로 본다.
    private static let lowerSpikeThreshold = 0.010
    /// 직전 샘플 대비 변화 비율이 이 값 미만이면 화면이 안정된 것으로 본다.
    private static let lowerSettleThreshold = 0.004
    /// 급격한 변화 후 안정되지 않아도 이 샘플 수(≈1.5초) 뒤에는 OCR한다.
    private static let lowerMaxWait = 18
    /// 변화가 없어도 이 샘플 수(≈5초)마다 OCR을 새로 돌린다.
    private static let lowerRefreshInterval = 60
    private static let context = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: false])

    private struct Sample: Sendable {
        let time: Double
        let difference: Double
        let histogramDifference: Double
        var textChanged: Bool
        var hasText: Bool
        var recognizedText: String?
        var lowerThirdTextChanged: Bool
        var lowerThirdHasText: Bool
        var lowerThirdRecognizedText: String?
        let sceneHash: UInt64
    }

    private struct OCRJob: @unchecked Sendable {
        let sampleIndex: Int
        let time: Double
        let pixelBuffer: CVPixelBuffer
        let orientation: CGImagePropertyOrientation
        let needsFullOCR: Bool
        let needsLowerOCR: Bool
    }

    private struct OCRJobOutput: Sendable {
        let sampleIndex: Int
        let fullReading: (signature: String, hasText: Bool, text: String?)?
        let lowerReading: (hasText: Bool, text: String?)?
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
        let orientation = cgImageOrientation(for: transform)

        async let loudnessTask = LoudnessAnalyzer.measure(url: url)
        let overallStart = Date()
        let cacheRoot = try cacheDirectory(for: url)

        await progress(AnalysisProgress(fraction: 0.01, message: "영상 프레임 디코딩 및 병렬 OCR 준비 중…", estimatedRemainingSeconds: nil, elapsedSeconds: 0))

        let (samples, retainedBuffers) = try await collectSamples(
            asset: asset,
            track: track,
            orientation: orientation,
            duration: duration,
            progress: progress,
            overallStart: overallStart
        )
        try Task.checkCancellation()

        await progress(AnalysisProgress(fraction: 0.86, message: "컷·디졸브·자막 후보를 분류하는 중…", estimatedRemainingSeconds: nil, elapsedSeconds: Date().timeIntervalSince(overallStart)))
        var events = classify(samples, duration: duration)

        events = try await finalizeEventsWithThumbnails(
            asset: asset,
            transform: transform,
            orientation: orientation,
            cacheRoot: cacheRoot,
            events: events,
            retainedBuffers: retainedBuffers,
            progress: progress,
            overallStart: overallStart
        )

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
        orientation: CGImagePropertyOrientation,
        duration: Double,
        progress: @escaping @Sendable (AnalysisProgress) async -> Void,
        overallStart: Date
    ) async throws -> ([Sample], [Int: CVPixelBuffer]) {
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
        var retainedBuffers: [Int: CVPixelBuffer] = [:]
        var ocrJobs: [OCRJob] = []

        var previousGray: [UInt8]?
        var previousHistogram: [Double]?
        var lowerRef: [UInt8]?
        var lowerLast: [UInt8]?
        var lowerPendingSince: Int?
        var lowerStable = 0
        var lowerLastOCRIndex = -999
        var nextSampleTime = 0.0
        var sampleIndex = 0
        var lastReported = -1
        var consecutiveSimilar = 0
        var lastOCRIndex = -999

        // 1단계: Zero-Copy CVPixelBuffer 직접 샘플링으로 초고속 컷/디졸브/스캔라인 변화 수집
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let timestamp = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            guard timestamp + 0.0001 >= nextSampleTime else { continue }
            nextSampleTime += 1.0 / sampleFPS
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { continue }

            let (gray, strip) = extractGrayAndLowerStrip(from: pixelBuffer, metricWidth: metricWidth)
            guard !gray.isEmpty else { continue }

            let histogram = makeHistogram(gray)
            let sceneHash = perceptualHash(gray, width: metricWidth)
            let difference = previousGray.map { meanDifference(gray, $0) } ?? 0
            let histogramDifference = previousHistogram.map { histogramDistance(histogram, $0) } ?? 0

            let needsOCR = shouldRunOCR(
                difference: difference,
                histogramDifference: histogramDifference,
                consecutiveSimilar: &consecutiveSimilar,
                lastOCRIndex: &lastOCRIndex,
                sampleIndex: sampleIndex
            )

            var lowerTrigger = false
            if !strip.isEmpty {
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
                    lowerTrigger = true
                }
                if sampleIndex - lowerLastOCRIndex >= lowerRefreshInterval { lowerTrigger = true }
                lowerLast = strip
            }

            if lowerTrigger {
                lowerRef = strip
                lowerLastOCRIndex = sampleIndex
                lowerPendingSince = nil
                lowerStable = 0
            }

            let isLikelyTransition = difference >= 12.0 || histogramDifference >= 0.14
            if needsOCR || lowerTrigger || isLikelyTransition {
                // AVAssetReader 버퍼 풀 고갈을 막기 위해 필요한 프레임만 가볍게 축소 복사본(960x540)으로 보관하거나
                // OCR 작업 큐에 넣는다.
                if let copied = copyPixelBuffer(pixelBuffer) {
                    retainedBuffers[sampleIndex] = copied
                    if needsOCR || lowerTrigger {
                        ocrJobs.append(OCRJob(
                            sampleIndex: sampleIndex,
                            time: timestamp,
                            pixelBuffer: copied,
                            orientation: orientation,
                            needsFullOCR: needsOCR,
                            needsLowerOCR: lowerTrigger
                        ))
                    }
                }
            }

            results.append(Sample(
                time: timestamp,
                difference: difference,
                histogramDifference: histogramDifference,
                textChanged: false,
                hasText: false,
                recognizedText: nil,
                lowerThirdTextChanged: false,
                lowerThirdHasText: false,
                lowerThirdRecognizedText: nil,
                sceneHash: sceneHash
            ))

            previousGray = gray
            previousHistogram = histogram
            sampleIndex += 1

            let percent = min(45, Int(timestamp / duration * 45))
            if percent != lastReported {
                lastReported = percent
                let elapsed = Date().timeIntervalSince(overallStart)
                await progress(AnalysisProgress(
                    fraction: Double(percent) / 100.0,
                    message: "고속 프레임 스캔 중 · \(formatTime(timestamp, includeTenths: false)) / \(formatTime(duration, includeTenths: false))",
                    estimatedRemainingSeconds: nil,
                    elapsedSeconds: elapsed
                ))
            }
        }

        if reader.status == .failed {
            throw reader.error ?? AnalyzerError.cannotRead(reason: "프레임 읽기 도중 AVAssetReader 실패")
        }

        // 2단계: 수집된 키 프레임들에 대해 Apple Silicon 멀티코어/Neural Engine 병렬 OCR 수행
        let totalOCR = max(1, ocrJobs.count)
        var ocrOutputs = [Int: OCRJobOutput](minimumCapacity: ocrJobs.count)
        let maxConcurrency = 4

        try await withThrowingTaskGroup(of: OCRJobOutput.self) { group in
            var nextJobIndex = 0
            var completed = 0

            while nextJobIndex < min(maxConcurrency, ocrJobs.count) {
                let job = ocrJobs[nextJobIndex]
                nextJobIndex += 1
                group.addTask {
                    try Task.checkCancellation()
                    return executeOCRJob(job)
                }
            }

            while let output = try await group.next() {
                try Task.checkCancellation()
                ocrOutputs[output.sampleIndex] = output
                completed += 1

                if nextJobIndex < ocrJobs.count {
                    let job = ocrJobs[nextJobIndex]
                    nextJobIndex += 1
                    group.addTask {
                        try Task.checkCancellation()
                        return executeOCRJob(job)
                    }
                }

                if completed % 3 == 0 || completed == totalOCR {
                    let fraction = 0.45 + 0.40 * (Double(completed) / Double(totalOCR))
                    let elapsed = Date().timeIntervalSince(overallStart)
                    let remaining = fraction > 0.1 ? elapsed * (1.0 - fraction) / fraction : nil
                    await progress(AnalysisProgress(
                        fraction: fraction,
                        message: "병렬 자막·말씀 OCR 분석 중 · \(completed) / \(totalOCR)",
                        estimatedRemainingSeconds: remaining,
                        elapsedSeconds: elapsed
                    ))
                }
            }
        }

        // 3단계: 시간순으로 OCR 결과 병합 (기존 시계열 상태 전이 100% 보존)
        var previousText = ""
        var previousHasText = false
        var previousRecognizedText: String?
        var confirmedLowerThirdText: String?

        for idx in results.indices {
            var signature = previousText
            var hasText = previousHasText
            var recognizedText = previousRecognizedText
            var lowerThirdTextChanged = false

            if let ocr = ocrOutputs[idx] {
                if let full = ocr.fullReading {
                    signature = full.signature
                    hasText = full.hasText
                    recognizedText = full.text
                }
                if let lower = ocr.lowerReading {
                    if lower.hasText, let candidateText = lower.text, !candidateText.isEmpty {
                        if confirmedLowerThirdText == nil ||
                            textSimilarity(normalizedText(confirmedLowerThirdText), normalizedText(candidateText)) < 0.72 {
                            confirmedLowerThirdText = candidateText
                            lowerThirdTextChanged = true
                        }
                    } else {
                        confirmedLowerThirdText = nil
                        // 전체 화면 OCR이 돌지 않은 프레임에서 하단 자막이 사라졌다면 이전 전체 텍스트가 하단 자막이었던 경우도 함께 해제
                        if ocr.fullReading == nil, let prevText = previousRecognizedText,
                           textSimilarity(normalizedText(prevText), normalizedText(results.indices.contains(idx - 1) ? results[idx - 1].lowerThirdRecognizedText : nil)) >= 0.65 {
                            hasText = false
                            recognizedText = nil
                            signature = ""
                        }
                    }
                }
            }

            let textChanged = signature != previousText && (hasText || previousHasText)
            results[idx].textChanged = textChanged
            results[idx].hasText = hasText
            results[idx].recognizedText = recognizedText
            results[idx].lowerThirdTextChanged = lowerThirdTextChanged
            results[idx].lowerThirdHasText = confirmedLowerThirdText != nil
            results[idx].lowerThirdRecognizedText = confirmedLowerThirdText

            previousText = signature
            previousHasText = hasText
            previousRecognizedText = recognizedText
        }

        return (results, retainedBuffers)
    }

    private static func executeOCRJob(_ job: OCRJob) -> OCRJobOutput {
        if job.needsFullOCR {
            let lines = ocrLines(pixelBuffer: job.pixelBuffer, orientation: job.orientation, regionOfInterest: nil)
            let full = makeSignature(from: lines)
            var lower: (hasText: Bool, text: String?)?
            if job.needsLowerOCR {
                let lowerLines = lines.filter { lowerThirdRegion.contains(CGPoint(x: $0.box.midX, y: $0.box.midY)) }
                let reading = makeSignature(from: lowerLines)
                lower = (reading.1, reading.2)
            }
            return OCRJobOutput(sampleIndex: job.sampleIndex, fullReading: full, lowerReading: lower)
        } else {
            let lines = ocrLines(pixelBuffer: job.pixelBuffer, orientation: job.orientation, regionOfInterest: lowerThirdRegion)
            let reading = makeSignature(from: lines)
            return OCRJobOutput(sampleIndex: job.sampleIndex, fullReading: nil, lowerReading: (reading.1, reading.2))
        }
    }

    // MARK: - Zero-Copy PixelBuffer Processing

    /// CIImage/CGImage 변환 없이 CVPixelBuffer의 BGRA 메모리에서 직접 저해상도 회색조와 하단 스캔띠를 한 번에 추출합니다.
    private static func extractGrayAndLowerStrip(
        from pixelBuffer: CVPixelBuffer,
        metricWidth: Int
    ) -> (gray: [UInt8], strip: [UInt8]) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard srcW > 0, srcH > 0, let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return ([], [])
        }

        let ptr = baseAddress.assumingMemoryBound(to: UInt8.self)
        let metricHeight = max(1, Int(Double(srcH) * Double(metricWidth) / Double(srcW)))
        var gray = [UInt8](repeating: 0, count: metricWidth * metricHeight)

        for dy in 0..<metricHeight {
            let sy = min(srcH - 1, dy * srcH / metricHeight)
            let rowPtr = ptr + sy * bytesPerRow
            let dstRowOffset = dy * metricWidth
            for dx in 0..<metricWidth {
                let sx = min(srcW - 1, dx * srcW / metricWidth)
                let px = rowPtr + (sx << 2)
                let b = Int(px[0])
                let g = Int(px[1])
                let r = Int(px[2])
                // ITU-R BT.601 정수 근사: (77*R + 150*G + 29*B) >> 8
                gray[dstRowOffset + dx] = UInt8((77 * r + 150 * g + 29 * b) >> 8)
            }
        }

        // 하단 3%~30% 스캔띠 추출 (좌상단 원점 기준 y: 70% ~ 97%)
        let topFrac = 1.0 - (lowerScanCenterFromBottom + lowerScanHalfHeight)
        let botFrac = 1.0 - (lowerScanCenterFromBottom - lowerScanHalfHeight)
        let startY = max(0, min(srcH - 1, Int(Double(srcH) * topFrac)))
        let endY = max(startY + 1, min(srcH, Int(Double(srcH) * botFrac)))
        let spanH = max(1, endY - startY)

        var strip = [UInt8](repeating: 0, count: lowerScanWidth * lowerScanRows)
        for ry in 0..<lowerScanRows {
            let sy = min(srcH - 1, startY + ry * spanH / lowerScanRows)
            let rowPtr = ptr + sy * bytesPerRow
            let dstRowOffset = ry * lowerScanWidth
            for dx in 0..<lowerScanWidth {
                let sx = min(srcW - 1, dx * srcW / lowerScanWidth)
                let px = rowPtr + (sx << 2)
                let b = Int(px[0])
                let g = Int(px[1])
                let r = Int(px[2])
                strip[dstRowOffset + dx] = UInt8((77 * r + 150 * g + 29 * b) >> 8)
            }
        }

        return (gray, strip)
    }

    /// AVAssetReader의 버퍼 풀을 잡아두지 않도록 필요한 프레임만 독립된 메모리에 복사합니다.
    private static func copyPixelBuffer(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(src)
        let height = CVPixelBufferGetHeight(src)
        let format = CVPixelBufferGetPixelFormatType(src)
        var dst: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            format,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
            &dst
        )
        guard status == kCVReturnSuccess, let dst else { return nil }

        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }

        guard let srcBase = CVPixelBufferGetBaseAddress(src),
              let dstBase = CVPixelBufferGetBaseAddress(dst) else { return nil }

        let srcBPR = CVPixelBufferGetBytesPerRow(src)
        let dstBPR = CVPixelBufferGetBytesPerRow(dst)
        let copyBytes = min(srcBPR, dstBPR)
        for row in 0..<height {
            memcpy(dstBase.advanced(by: row * dstBPR), srcBase.advanced(by: row * srcBPR), copyBytes)
        }
        return dst
    }

    private static func cgImageOrientation(for transform: CGAffineTransform) -> CGImagePropertyOrientation {
        let angle = atan2(transform.b, transform.a)
        let degrees = Int(round(angle * 180 / .pi))
        switch (degrees + 360) % 360 {
        case 90: return .right
        case 180: return .down
        case 270: return .left
        default: return .up
        }
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
        let candidates: [String]
        let box: CGRect
    }

    /// 두 스캔 라인에서 밝기 차가 크게(> 30) 난 픽셀의 비율.
    private static func changedFraction(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var big = 0
        for i in a.indices where abs(Int(a[i]) - Int(b[i])) > 30 { big += 1 }
        return Double(big) / Double(a.count)
    }

    /// Zero-Copy CVPixelBuffer 기반 정밀 OCR.
    /// 성경 구절이 감지된 경우 topCandidates(3) 중에서 원문과 일치하는 후보가 있으면 우선 채택해 OCR 오인식을 줄이고,
    /// 실제 자막 오타는 usesLanguageCorrection = false로 그대로 잡아낸다.
    private static func ocrLines(
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        regionOfInterest: CGRect? = nil
    ) -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        if let regionOfInterest { request.regionOfInterest = regionOfInterest }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["ko-KR", "en-US"]
        request.customWords = BibleReferenceParser.allCustomWords
        request.minimumTextHeight = 0.005

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)
        try? handler.perform([request])

        let observations = (request.results ?? []).filter { obs in
            guard obs.confidence > 0.20 else { return false }
            return !isLogoObservation(obs)
        }
        guard !observations.isEmpty else { return [] }

        let sorted = observations.sorted { (a, b) -> Bool in
            let aY = a.boundingBox.midY
            let bY = b.boundingBox.midY
            if abs(aY - bY) > 0.038 {
                return aY > bY
            }
            return a.boundingBox.midX < b.boundingBox.midX
        }

        var rawLines: [OCRLine] = sorted.compactMap { observation -> OCRLine? in
            let top = observation.topCandidates(3).compactMap { cand -> String? in
                let cleaned = cleanLogoText(cand.string)
                return cleaned.isEmpty ? nil : cleaned
            }
            guard let first = top.first else { return nil }
            let box: CGRect
            if let roi = regionOfInterest {
                box = CGRect(
                    x: roi.origin.x + observation.boundingBox.origin.x * roi.width,
                    y: roi.origin.y + observation.boundingBox.origin.y * roi.height,
                    width: observation.boundingBox.width * roi.width,
                    height: observation.boundingBox.height * roi.height
                )
            } else {
                box = observation.boundingBox
            }
            return OCRLine(text: first, candidates: top, box: box)
        }

        // 성경 구절이 포함된 자막이면 각 줄의 topCandidates(3) 중 원문에 정확히 포함되는 후보가 있을 때 보정한다.
        let combinedFirst = rawLines.map(\.text).joined(separator: " ")
        let refs = BibleReferenceParser.parse(combinedFirst)
        if !refs.isEmpty {
            let normScripture = BibleVerseChecker.normalizedScripture(for: refs)
            if !normScripture.isEmpty {
                for i in rawLines.indices where rawLines[i].candidates.count > 1 {
                    let firstNorm = normalizedText(rawLines[i].text)
                    if firstNorm.count >= 2 && !normScripture.contains(firstNorm) {
                        if let better = rawLines[i].candidates.dropFirst().first(where: { cand in
                            let candNorm = normalizedText(cand)
                            return candNorm.count >= 2 && normScripture.contains(candNorm)
                        }) {
                            rawLines[i] = OCRLine(text: better, candidates: rawLines[i].candidates, box: rawLines[i].box)
                        }
                    }
                }
            }
        }

        return rawLines
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
        var lastPrayerTime: Double?

        let subtitleDetections: [(sampleIndex: Int, sample: Sample, text: String, fromLowerThird: Bool)] = samples.enumerated().flatMap { (idx, sample) -> [(sampleIndex: Int, sample: Sample, text: String, fromLowerThird: Bool)] in
            var detected: [(sampleIndex: Int, sample: Sample, text: String, fromLowerThird: Bool)] = []
            if sample.textChanged && sample.hasText, let text = sample.recognizedText {
                detected.append((sampleIndex: idx, sample: sample, text: text, fromLowerThird: false))
            }
            if sample.lowerThirdTextChanged && sample.lowerThirdHasText,
               let text = sample.lowerThirdRecognizedText {
                detected.append((sampleIndex: idx, sample: sample, text: text, fromLowerThird: true))
            }
            return detected
        }

        for (startIndex, sample, text, fromLowerThird) in subtitleDetections {
            let normalized = normalizedText(text)
            let isDuplicate = acceptedSubtitles.suffix(20).contains { previous in
                let sceneDistance = (previous.hash ^ sample.sceneHash).nonzeroBitCount
                return sceneDistance <= 8 && textSimilarity(previous.text, normalized) >= 0.72
            }
            if isDuplicate { continue }

            // 자막이 화면에 유지되는 종료 시점(endTime) 계산
            var lastActiveIndex = startIndex
            for j in (startIndex + 1)..<samples.count {
                let candidateSample = samples[j]
                let lowerMatch = candidateSample.lowerThirdHasText &&
                    textSimilarity(normalizedText(candidateSample.lowerThirdRecognizedText), normalized) >= 0.68
                let fullMatch = candidateSample.hasText &&
                    textSimilarity(normalizedText(candidateSample.recognizedText), normalized) >= 0.68
                if fromLowerThird ? (lowerMatch || fullMatch) : (fullMatch || lowerMatch) {
                    lastActiveIndex = j
                } else {
                    break
                }
            }
            let frameDuration = 1.0 / sampleFPS
            let subtitleEndTime = min(duration, max(sample.time + max(0.5, frameDuration), samples[lastActiveIndex].time + frameDuration))

            let hasPrayLabel = KoreanGrammarChecker.hasPrayLabel(text)
            let continuedPrayer = lastPrayerTime.map { sample.time - $0 <= Self.prayerContinuationSeconds } == true
            if hasPrayLabel || continuedPrayer {
                if hasPrayLabel { lastPrayerTime = sample.time }
                let suggestions = KoreanGrammarChecker.check(text)
                events.append(ReviewEvent(
                    kind: .subtitle,
                    label: "기도문 자막",
                    time: sample.time,
                    endTime: subtitleEndTime,
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

            let parsedRefs = BibleReferenceParser.parse(text)
            let validatedRefs: [BibleReference]
            let comparisons: [BibleComparisonResult]
            var eventLabel = "화면 자막 변화"

            if !parsedRefs.isEmpty {
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
                endTime: subtitleEndTime,
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
            if let last = output.last, last.kind == event.kind {
                if event.kind == .dissolve, event.time - (last.endTime ?? last.time) <= 0.75 {
                    output[output.count - 1] = ReviewEvent(
                        kind: .dissolve, label: last.label, time: last.time,
                        endTime: max(last.endTime ?? last.time, event.endTime ?? event.time),
                        confidence: max(last.confidence, event.confidence)
                    )
                    continue
                } else if event.kind == .cut, event.time - last.time <= 0.75 {
                    if event.confidence > last.confidence {
                        output[output.count - 1] = event
                    }
                    continue
                } else if event.kind == .subtitle {
                    let sameText = textSimilarity(normalizedText(last.recognizedText), normalizedText(event.recognizedText)) >= 0.70
                    if event.time - last.time <= 0.75 || (sameText && event.time - (last.endTime ?? last.time) <= 0.75) {
                        let mergedEnd = max(last.endTime ?? last.time, event.endTime ?? event.time)
                        let base = event.confidence > last.confidence ? event : last
                        output[output.count - 1] = ReviewEvent(
                            kind: .subtitle,
                            label: base.label,
                            time: last.time,
                            endTime: mergedEnd,
                            confidence: max(last.confidence, event.confidence),
                            thumbnailPath: base.thumbnailPath,
                            recognizedText: base.recognizedText,
                            bibleReferences: base.bibleReferences,
                            bibleComparisons: base.bibleComparisons,
                            isPrayer: base.isPrayer,
                            grammarSuggestions: base.grammarSuggestions
                        )
                        continue
                    } else if let lastEnd = last.endTime, lastEnd > event.time {
                        // 다음 자막이 시작되면 이전 자막 구간의 끝을 다음 자막 시작 시점으로 깔끔하게 맞춤
                        output[output.count - 1] = ReviewEvent(
                            kind: last.kind,
                            label: last.label,
                            time: last.time,
                            endTime: max(last.time + 0.2, event.time),
                            confidence: last.confidence,
                            thumbnailPath: last.thumbnailPath,
                            recognizedText: last.recognizedText,
                            bibleReferences: last.bibleReferences,
                            bibleComparisons: last.bibleComparisons,
                            isPrayer: last.isPrayer,
                            grammarSuggestions: last.grammarSuggestions
                        )
                    }
                }
            }
            output.append(event)
        }
        return output
    }

    /// 1차 스캔 때 메모리에 보관된 CVPixelBuffer에서 즉시 썸네일을 생성하고,
    /// 버퍼가 없는 일부 디졸브/컷 후보에 대해서만 fallback으로 AVAssetImageGenerator를 사용합니다.
    private static func finalizeEventsWithThumbnails(
        asset: AVAsset,
        transform: CGAffineTransform,
        orientation: CGImagePropertyOrientation,
        cacheRoot: URL,
        events: [ReviewEvent],
        retainedBuffers: [Int: CVPixelBuffer],
        progress: @escaping @Sendable (AnalysisProgress) async -> Void,
        overallStart: Date
    ) async throws -> [ReviewEvent] {
        guard !events.isEmpty else { return events }

        var fallbackGenerator: AVAssetImageGenerator?
        var results = events

        for index in events.indices {
            try Task.checkCancellation()
            let sampleIdx = Int(round(events[index].time * sampleFPS))
            let target = cacheRoot.appendingPathComponent("\(events[index].id.uuidString).jpg")

            if let buffer = retainedBuffers[sampleIdx] ?? retainedBuffers[sampleIdx - 1] ?? retainedBuffers[sampleIdx + 1] {
                if let thumb = thumbnailCGImage(from: buffer, transform: transform, maxDimension: 960) {
                    if writeJPEG(thumb, to: target) {
                        results[index].thumbnailPath = target.path
                    }
                }
            } else {
                if fallbackGenerator == nil {
                    let gen = AVAssetImageGenerator(asset: asset)
                    gen.appliesPreferredTrackTransform = true
                    gen.maximumSize = CGSize(width: 960, height: 540)
                    gen.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
                    gen.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
                    fallbackGenerator = gen
                }
                let time = CMTime(seconds: events[index].time, preferredTimescale: 600)
                if let image = try? fallbackGenerator?.copyCGImage(at: time, actualTime: nil) {
                    if writeJPEG(image, to: target) {
                        results[index].thumbnailPath = target.path
                    }
                }
            }

            if index % 5 == 0 || index == events.count - 1 {
                let fraction = 0.87 + 0.11 * Double(index + 1) / Double(events.count)
                await progress(AnalysisProgress(
                    fraction: fraction,
                    message: "썸네일 저장 중 · \(index + 1) / \(events.count)",
                    estimatedRemainingSeconds: nil,
                    elapsedSeconds: Date().timeIntervalSince(overallStart)
                ))
            }
        }
        return results
    }

    private static func thumbnailCGImage(from buffer: CVPixelBuffer, transform: CGAffineTransform, maxDimension: Int) -> CGImage? {
        var image = CIImage(cvPixelBuffer: buffer).transformed(by: transform)
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        image = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let scale = min(1.0, CGFloat(maxDimension) / max(image.extent.width, image.extent.height))
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(image, from: image.extent.integral)
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
