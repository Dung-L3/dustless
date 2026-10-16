import Foundation

public final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    public func read() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&value)
    }
}

public final class RunningProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    /// How long a terminated engine gets to clean up before we force the kill.
    /// Time-boxed so a child that ignores SIGTERM cannot hold the deadline open.
    private let killGrace: TimeInterval = 2

    public func attach(_ process: Process) {
        lock.lock()
        let alreadyCancelled = cancelled
        if !alreadyCancelled { self.process = process }
        lock.unlock()
        if alreadyCancelled { stop(process) }
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        if let running { stop(running) }
    }

    public func finish() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    /// SIGTERM first, so the engine can clean up; then SIGKILL if it is still
    /// alive after `killGrace`. A child that ignores SIGTERM would otherwise
    /// outlive the deadline and hang the caller.
    private func stop(_ process: Process) {
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + killGrace) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}
