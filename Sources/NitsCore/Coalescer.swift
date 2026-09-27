import Foundation

/// Latest-value-wins coalescing in front of a slow, blocking write.
///
/// A slider drag or a held key produces far more values than DDC can carry (a write
/// costs a few ms, a read over 100ms). A fixed debounce timer would add latency to
/// every change, including isolated ones. Instead this runs the write immediately on
/// a serial queue and, while that write is in flight, keeps only the *newest* pending
/// value — so a burst collapses to one trailing write with no artificial delay.
///
/// Intermediate values are intentionally dropped. For brightness and volume only the
/// final position matters, and dropping them is what keeps the UI responsive.
public final class CoalescingWriter<Value>: @unchecked Sendable {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pending: Value?
    private var draining = false
    private let write: (Value) -> Void

    public init(label: String, write: @escaping (Value) -> Void) {
        self.queue = DispatchQueue(label: label, qos: .userInitiated)
        self.write = write
    }

    /// Queues `value`, superseding any value not yet written.
    public func submit(_ value: Value) {
        lock.lock()
        pending = value
        let needsDrain = !draining
        if needsDrain { draining = true }
        lock.unlock()

        guard needsDrain else { return }
        queue.async { [weak self] in self?.drain() }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let value = pending else {
                draining = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()

            write(value)
        }
    }

    /// Blocks until every queued write has completed. For tests and shutdown.
    public func flush() {
        queue.sync {}
    }
}
