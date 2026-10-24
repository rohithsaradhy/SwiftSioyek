import Foundation
import PDFServices
import ReaderCore
import ReaderPersistence
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Darwin

@main struct ReaderDiagnostics {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else { print("Usage: ReaderDiagnostics fixtures DIRECTORY [--quick] | benchmark DIRECTORY | render PDF OUTPUT.png [PAGE_INDEX] [ROTATION]"); return }
        switch command {
        case "fixtures":
            guard arguments.count > 1 else { throw DiagnosticError.arguments }
            let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
            try FixtureFactory.generate(in: directory, quick: arguments.contains("--quick")); print("Generated native PDF fixtures in \(directory.path)")
        case "render":
            guard arguments.count > 2 else { throw DiagnosticError.arguments }
            let url = URL(fileURLWithPath: arguments[1]), output = URL(fileURLWithPath: arguments[2])
            let source = DocumentSource(identity: DocumentIdentity(id: UUID(), revision: try FileIdentity.revision(of: url)), url: url)
            let service = PDFTextService(); _ = try await service.open(source)
            let index = arguments.count > 3 ? Int(arguments[3]) ?? 0 : 0, rotation = arguments.count > 4 ? Int(arguments[4]) ?? 0 : 0
            let geometry = try await service.geometry(pages: index..<(index + 1))[0]
            let key = RenderKey(document: source.identity, pageIndex: index, rotation: rotation, scaleStep: 0, preview: true)
            let tile = try await RasterWorker().render(RenderRequest(key: key, rect: CGRect(origin: .zero, size: geometry.size(adding: rotation)), priority: 0), source: source)
            try save(tile.image, to: output); print(output.path)
        case "benchmark":
            guard arguments.count > 1 else { throw DiagnosticError.arguments }
            let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
            var reports: [Benchmark] = []
            for name in ["paper", "textbook", "scans"] { reports.append(try await benchmark(directory.appendingPathComponent(name + ".pdf"))) }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; let data = try encoder.encode(reports)
            try data.write(to: directory.appendingPathComponent("benchmark.json"), options: .atomic); print(String(decoding: data, as: UTF8.self))
        default: throw DiagnosticError.arguments
        }
    }
    enum DiagnosticError: Error { case arguments, image }
    struct Benchmark: Codable {
        var file: String; var pages: Int; var openMilliseconds: Double; var firstPreviewMilliseconds: Double
        var coldTileP95Milliseconds: Double; var warmTileP95Milliseconds: Double; var peakRSSMiB: Double
        var note = "Service timings, not display frame intervals. Cold means a fresh PDF worker; OS filesystem cache is not flushed."
    }
    static func milliseconds(_ start: UInt64) -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1_000_000 }
    static func benchmark(_ url: URL) async throws -> Benchmark {
        let source = DocumentSource(identity: DocumentIdentity(id: UUID(), revision: try FileIdentity.revision(of: url)), url: url)
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW), service = PDFTextService()
        let info = try await service.open(source), openTime = milliseconds(start)
        let first = try await service.geometry(pages: 0..<1)[0], workers = [RasterWorker(), RasterWorker()]
        let previewKey = RenderKey(document: source.identity, pageIndex: 0, rotation: 0, scaleStep: -4, preview: true)
        _ = try await workers[0].render(RenderRequest(key: previewKey, rect: CGRect(origin: .zero, size: first.size()), priority: 0), source: source)
        let firstPaint = milliseconds(start)
        let pageCount = min(info.pageCount, 160)
        var cold: [Double] = [], warm: [Double] = []
        for pass in 0..<2 {
            for page in 0..<pageCount {
                let geometry = try await service.geometry(pages: page..<(page + 1))[0]
                let key = RenderKey(document: source.identity, pageIndex: page, rotation: 0, scaleStep: 2)
                let request = RenderRequest(key: key, rect: CGRect(x: 0, y: 0, width: min(256, geometry.size().width), height: min(256, geometry.size().height)), priority: 0)
                let tileStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                _ = try await workers[page % 2].render(request, source: source)
                if pass == 0 { cold.append(milliseconds(tileStart)) } else { warm.append(milliseconds(tileStart)) }
            }
        }
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        func p95(_ values: [Double]) -> Double { values.sorted()[Int(Double(values.count - 1) * 0.95)] }
        return Benchmark(file: url.lastPathComponent, pages: info.pageCount, openMilliseconds: openTime, firstPreviewMilliseconds: firstPaint, coldTileP95Milliseconds: p95(cold), warmTileP95Milliseconds: p95(warm), peakRSSMiB: Double(usage.ru_maxrss) / 1_048_576)
    }
    static func save(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw DiagnosticError.image }
        CGImageDestinationAddImage(destination, image, nil); guard CGImageDestinationFinalize(destination) else { throw DiagnosticError.image }
    }
}
