import Foundation
import Testing
@testable import Perch

/// The open/close state machine, tested directly. Synthetic `CGEvent`s do not
/// reliably drive SwiftUI's hover tracking from a test process, so the debounce
/// logic is verified here rather than through simulated pointer motion.
@Suite("Hover debounce")
@MainActor
struct HoverStateTests {
    /// Mirrors `PerchRootView.handleHover`.
    @MainActor
    final class Machine {
        private(set) var isExpanded = false
        private var collapseTask: Task<Void, Never>?
        let delay: Duration

        init(delay: Duration = .milliseconds(180)) { self.delay = delay }

        func hover(_ inside: Bool) {
            collapseTask?.cancel()
            if inside {
                isExpanded = true
            } else {
                collapseTask = Task { @MainActor [delay, weak self] in
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled else { return }
                    self?.isExpanded = false
                }
            }
        }
    }

    @Test("entering opens immediately")
    func opensOnEnter() {
        let machine = Machine()
        machine.hover(true)
        #expect(machine.isExpanded)
    }

    @Test("leaving does not close instantly")
    func closeIsDebounced() async {
        let machine = Machine()
        machine.hover(true)
        machine.hover(false)
        // Still open right after leaving: this is what stops the panel
        // flickering shut while the pointer crosses a gap.
        #expect(machine.isExpanded)
    }

    @Test("re-entering within the debounce keeps it open")
    func reentryCancelsClose() async throws {
        let machine = Machine()
        machine.hover(true)
        machine.hover(false)
        try await Task.sleep(for: .milliseconds(60))
        machine.hover(true)
        try await Task.sleep(for: .milliseconds(250))
        // Travelling from the notch into the panel must not close it.
        #expect(machine.isExpanded)
    }

    @Test("staying away closes after the debounce")
    func closesEventually() async throws {
        // A short debounce plus a generous margin: a fixed wait just over the
        // real 180ms is flaky when the test host is loaded.
        let machine = Machine(delay: .milliseconds(30))
        machine.hover(true)
        machine.hover(false)

        // Poll rather than sleeping once, so a slow scheduler delays the test
        // instead of failing it.
        for _ in 0 ..< 40 {
            if !machine.isExpanded { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(!machine.isExpanded)
    }
}
