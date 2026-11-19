import Foundation

/// Lets the engine cancel a running child process.
public final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    func set(_ p: Process?) { lock.lock(); process = p; lock.unlock() }
    public func terminate() { lock.lock(); let p = process; lock.unlock(); p?.terminate() }
}

private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private let onLine: @Sendable (String) -> Void
    init(_ onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }

    func feed(_ d: Data) {
        lock.lock(); pending.append(d)
        var lines: [String] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            let chunk = pending.subdata(in: pending.startIndex..<nl)
            pending.removeSubrange(pending.startIndex...nl)
            lines.append(String(decoding: chunk, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
        }
        lock.unlock()
        lines.forEach(onLine)
    }
    func flush() {
        lock.lock(); let rest = pending; pending = Data(); lock.unlock()
        if !rest.isEmpty { onLine(String(decoding: rest, as: UTF8.self)) }
    }
}

public enum ProcessRunner {
    /// Runs an executable, streaming stdout+stderr line by line. Returns the exit status.
    @discardableResult
    public static func run(_ exe: URL, _ args: [String], box: ProcessBox? = nil,
                           onLine: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        // GUI/launchd apps get a minimal PATH; make Homebrew tools (ffmpeg, deno) findable.
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let buffer = LineBuffer(onLine)
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { buffer.feed(d) }
        }
        box?.set(p)
        defer { box?.set(nil) }
        return try await withCheckedThrowingContinuation { cont in
            p.terminationHandler = { proc in
                handle.readabilityHandler = nil
                let rest = handle.readDataToEndOfFile()
                if !rest.isEmpty { buffer.feed(rest) }
                buffer.flush()
                cont.resume(returning: proc.terminationStatus)
            }
            do { try p.run() } catch {
                handle.readabilityHandler = nil
                cont.resume(throwing: error)
            }
        }
    }

    /// Convenience: run and collect all output lines.
    public static func capture(_ exe: URL, _ args: [String]) async throws -> (status: Int32, lines: [String]) {
        let sink = LineSink()
        let status = try await run(exe, args) { sink.add($0) }
        return (status, sink.lines)
    }
}

public final class LineSink: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    public init() {}
    public func add(_ s: String) { lock.lock(); _lines.append(s); lock.unlock() }
    public var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
}
