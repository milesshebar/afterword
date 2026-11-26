import AppKit
import ImageIO
import ArchiveCore

/// Small image thumbnails for the thread view: decoded off the main thread at display size, held in memory, and (only
/// when the archive sits on a network volume such as a network share) also kept as small JPEGs under ~/Library/Caches so
/// scrolling a photo-heavy thread doesn't re-read originals over SMB.
final class Thumbnails: @unchecked Sendable {
    static let shared = Thumbnails()
    static let maxPixel = 480

    private let memory = NSCache<NSString, NSImage>()
    /// At most 4 decodes run at once; waiting requests are plain queued operations (no parked threads) and are
    /// cancelled when their row scrolls away.
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = Product.bundleIdentifier + ".thumbs"
        q.maxConcurrentOperationCount = 4
        q.qualityOfService = .userInitiated
        return q
    }()
    private let lock = NSLock()
    private var root: ArchiveRoot?
    private var diskDir: URL?

    init() { memory.countLimit = 800 }

    func configure(root: ArchiveRoot?, onNetwork: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.root = root
        memory.removeAllObjects()
        diskDir = nil
        if root != nil, onNetwork {
            let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(Product.bundleIdentifier + "/thumbs", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            diskDir = dir
        }
    }

    func cached(_ sha: String) -> NSImage? { memory.object(forKey: sha as NSString) }

    func url(for a: AttachmentInfo) -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard let root, !a.mediaPath.hasPrefix("/"), !a.mediaPath.contains("..") else { return nil }
        return root.resolve(relativePath: a.mediaPath)
    }

    /// Synchronous decode, for the snapshot runner and tests.
    func loadSync(_ a: AttachmentInfo) -> NSImage? {
        if let c = cached(a.sha256) { return c }
        guard let img = decode(a) else { return nil }
        memory.setObject(img, forKey: a.sha256 as NSString)
        return img
    }

    func load(_ a: AttachmentInfo) async -> NSImage? {
        if let c = cached(a.sha256) { return c }
        let once = ResumeOnce()
        let img: NSImage? = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<NSImage?, Never>) in
                once.set(cont)
                let op = BlockOperation()
                op.addExecutionBlock { [weak op, weak self] in
                    guard let self, let op, !op.isCancelled, !once.finished else { once.resume(nil); return }
                    once.resume(self.decode(a))
                }
                once.operation = op
                if Task.isCancelled { once.resume(nil); return }
                queue.addOperation(op)
            }
        } onCancel: {
            once.operation?.cancel()
            once.resume(nil)
        }
        if let img { memory.setObject(img, forKey: a.sha256 as NSString) }
        return img
    }

    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<NSImage?, Never>?
        private var done = false
        var operation: Operation?
        var finished: Bool { lock.lock(); defer { lock.unlock() }; return done }
        func set(_ c: CheckedContinuation<NSImage?, Never>) {
            lock.lock()
            if done { lock.unlock(); c.resume(returning: nil) } else { cont = c; lock.unlock() }
        }
        func resume(_ img: NSImage?) {
            lock.lock()
            if done { lock.unlock(); return }
            done = true
            let c = cont; cont = nil
            lock.unlock()
            c?.resume(returning: img)
        }
    }

    private func hasAlpha(_ cg: CGImage) -> Bool {
        switch cg.alphaInfo { case .none, .noneSkipFirst, .noneSkipLast: return false; default: return true }
    }

    private func decode(_ a: AttachmentInfo) -> NSImage? {
        lock.lock(); let disk = diskDir; lock.unlock()
        for ext in ["jpg", "png"] {
            if let f = disk?.appendingPathComponent(a.sha256 + "." + ext),
               let src = CGImageSourceCreateWithURL(f as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                return NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
            }
        }
        guard let url = url(for: a), let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        if let disk {
            // Images with transparency are cached as PNG so they don't come back with a black background.
            let png = hasAlpha(cg)
            let f = disk.appendingPathComponent(a.sha256 + (png ? ".png" : ".jpg"))
            if let dest = CGImageDestinationCreateWithURL(f as CFURL, (png ? "public.png" : "public.jpeg") as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, cg, png ? nil : [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
                CGImageDestinationFinalize(dest)
            }
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
    }
}
