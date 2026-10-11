import Foundation

final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func read() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&value)
    }
}

final class RunningProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func attach(_ process: Process) {
        lock.lock()
        let alreadyCancelled = cancelled
        if !alreadyCancelled { self.process = process }
        lock.unlock()
        if alreadyCancelled { process.terminate() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        running?.terminate()
    }

    func finish() {
        lock.lock()
        process = nil
        lock.unlock()
    }
}
