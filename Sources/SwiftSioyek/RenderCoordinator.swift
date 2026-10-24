import AppKit
import ReaderCore
import PDFServices

@MainActor
final class RenderCoordinator {
    private struct Waiter { var owner: UUID; var completion: (Result<RenderedTile, Error>) -> Void }
    private struct Job { var request: RenderRequest; var waiters: [Waiter]; var serial: UInt64 }
    private var cache = CostCache<RenderKey, RenderedTile>(limit: 256 * 1024 * 1024)
    private let workers = [RasterWorker(), RasterWorker()]
    private var busy = [false, false]
    private var jobs: [RenderKey: Job] = [:]
    private var running: [RenderKey: Job] = [:]
    private var sources: [DocumentIdentity: DocumentSource] = [:]
    private var serial: UInt64 = 0
    private var pressure: DispatchSourceMemoryPressure?
    private(set) var renderedCount = 0
    var cacheBytes: Int { cache.cost }
    init() {
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.trim() }
        }
        pressure.resume(); self.pressure = pressure
    }
    func register(_ source: DocumentSource) { sources[source.identity] = source }
    func request(_ request: RenderRequest, owner: UUID, completion: @escaping (Result<RenderedTile, Error>) -> Void) {
        if let tile = cache.value(for: request.key) { completion(.success(tile)); return }
        let waiter = Waiter(owner: owner, completion: completion)
        if var job = running[request.key] { if !job.waiters.contains(where: { $0.owner == owner }) { job.waiters.append(waiter) }; running[request.key] = job; return }
        if var job = jobs[request.key] {
            job.request.priority = min(job.request.priority, request.priority)
            if !job.waiters.contains(where: { $0.owner == owner }) { job.waiters.append(waiter) }; jobs[request.key] = job
        } else { serial &+= 1; jobs[request.key] = Job(request: request, waiters: [waiter], serial: serial) }
        pump()
    }
    func cancel(owner: UUID) {
        for key in Array(jobs.keys) { jobs[key]?.waiters.removeAll { $0.owner == owner }; if jobs[key]?.waiters.isEmpty == true { jobs.removeValue(forKey: key) } }
        for key in Array(running.keys) { running[key]?.waiters.removeAll { $0.owner == owner } }
    }
    func trim() { cache.removeAll(); PDFTextService.trimSharedCache(); for key in Array(jobs.keys) where jobs[key]!.request.priority > 1 { jobs.removeValue(forKey: key) }; Task { for worker in workers { await worker.clear() } } }
    private func pump() {
        for index in workers.indices where !busy[index] {
            guard let next = jobs.min(by: { a, b in a.value.request.priority == b.value.request.priority ? a.value.serial < b.value.serial : a.value.request.priority < b.value.request.priority }) else { return }
            let key = next.key, job = next.value
            jobs.removeValue(forKey: key)
            guard let source = sources[key.document] else { job.waiters.forEach { $0.completion(.failure(PDFServiceError.unreadable)) }; continue }
            running[key] = job; busy[index] = true
            let worker = workers[index]
            Task {
                let result: Result<RenderedTile, Error>
                do { result = .success(try await worker.render(job.request, source: source)) } catch { result = .failure(error) }
                let listeners = running.removeValue(forKey: key)?.waiters ?? []
                if case .success(let tile) = result { cache.insert(tile, for: key, cost: tile.bytes); renderedCount += 1 }
                busy[index] = false
                for listener in listeners { listener.completion(result) }
                pump()
            }
        }
    }
}
