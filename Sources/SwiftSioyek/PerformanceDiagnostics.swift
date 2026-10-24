import AppKit
import Darwin

/// Opt-in development telemetry. Normal reader sessions enable no recording,
/// diagnostic timers, or writes. UI tests supply an isolated output URL.
@MainActor
final class PerformanceDiagnostics {
    static let shared = PerformanceDiagnostics()
    private let output: URL?
    private var openStart: UInt64?
    private var opens: [Double] = []
    private var frames: [Double] = []
    private var work: [Double] = []
    private var pixels = 0
    private var pageViews = 0
    private var motionRequests = 0
    private var viewVisible = false
    private var viewportFrame = CGRect.zero
    private init() { output = ProcessInfo.processInfo.environment["SWIFTSIOYEK_METRICS_OUTPUT"].map { URL(fileURLWithPath: $0) } }
    func beginOpen() { guard output != nil else { return }; openStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
    func beginMotion(viewport: ReaderViewport) {
        guard output != nil else { return }; motionRequests += 1; viewVisible = !viewport.isHiddenOrHasHiddenAncestor && viewport.window?.occlusionState.contains(.visible) == true; viewportFrame = viewport.frame
        flush(cacheBytes: viewport.renderer.cacheBytes, views: viewport.pageViews.count)
    }
    func firstPaint(cacheBytes: Int, views: Int) {
        guard output != nil, let openStart else { return }
        opens.append(Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - openStart) / 1_000_000); self.openStart = nil
        flush(cacheBytes: cacheBytes, views: views)
    }
    func frame(seconds: Double) { guard output != nil, frames.count < 60_000, seconds > 0 else { return }; frames.append(seconds * 1_000) }
    func scrollWork(nanoseconds: UInt64) { guard output != nil, work.count < 60_000 else { return }; work.append(Double(nanoseconds) / 1_000_000) }
    func flush(cacheBytes: Int, views: Int) {
        guard let output else { return }; pixels = max(pixels, cacheBytes); pageViews = max(pageViews, views)
        func percentile(_ values: [Double]) -> Double { guard !values.isEmpty else { return 0 }; return values.sorted()[Int(Double(values.count - 1) * 0.95)] }
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release"
        #endif
        let report = Report(configuration: configuration, firstPaintMilliseconds: opens, frameSamples: frames.count, frameP95Milliseconds: percentile(frames), scrollWorkP95Milliseconds: percentile(work), peakRasterCacheMiB: Double(pixels) / 1_048_576, maxActivePageViews: pageViews, peakProcessRSSMiB: Double(usage.ru_maxrss) / 1_048_576, displayMaximumFPS: NSScreen.main?.maximumFramesPerSecond ?? 0, motionRequests: motionRequests, viewVisible: viewVisible, viewportFrame: viewportFrame)
        Task.detached(priority: .utility) {
            do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; let data = try encoder.encode(report); try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true); try data.write(to: output, options: .atomic) }
            catch { NSLog("Performance diagnostics: %@", error.localizedDescription) }
        }
    }
    private struct Report: Codable, Sendable {
        var configuration: String; var firstPaintMilliseconds: [Double]; var frameSamples: Int; var frameP95Milliseconds: Double
        var scrollWorkP95Milliseconds: Double; var peakRasterCacheMiB: Double; var maxActivePageViews: Int; var peakProcessRSSMiB: Double; var displayMaximumFPS: Int
        var motionRequests: Int; var viewVisible: Bool; var viewportFrame: CGRect
        var note = "Frame cadence is sampled during display-linked keyboard motion. Raster timings and display frame intervals are separate measurements."
    }
}
