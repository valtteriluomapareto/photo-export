import AppKit
import Combine
import SwiftUI

@testable import Photo_Export

// Leaf mirrors for values that failing expectations capture (issue #277).
//
// When `#expect(x.p)`, `#expect(!x.p)`, `#expect(x.f(...))` or a binary operand fails, Swift
// Testing reflects the captured value. swift-testing 6.0.3 (Xcode 16.2, the CI toolchain) removes
// an object from its seen set even on a repeated visit (fixed upstream by
// swiftlang/swift-testing#787, released in 6.1), so a graph whose objects reach each other more
// than once recurses until the main thread's stack overflows and the whole test process aborts.
// Combine subscriptions, `ExportManager`'s collaborator `host` back-references and SwiftUI's
// hosting internals all form such cycles.
//
// These conformances make those types reflect as leaves, so a failure prints the value's
// description instead of crashing the run. The protection is enumerative: a new cyclic type that
// is not reachable only through these leaves is caught by `ExpectationReflectionSafetyTests`
// when it is one of that suite's roots, not automatically. Remove this file once every pipeline
// builds tests with swift-testing 6.1 or later (Xcode 16.3+).

extension Published: @retroactive CustomReflectable {
  public var customMirror: Mirror { Mirror(self, children: [:]) }
}

extension ObservableObjectPublisher: @retroactive CustomReflectable {
  public var customMirror: Mirror { Mirror(self, children: [:]) }
}

extension CurrentValueSubject: @retroactive CustomReflectable {
  public var customMirror: Mirror { Mirror(self, children: [:]) }
}

extension PassthroughSubject: @retroactive CustomReflectable {
  public var customMirror: Mirror { Mirror(self, children: [:]) }
}

extension AnyCancellable: @retroactive CustomReflectable {
  public var customMirror: Mirror { Mirror(self, children: [:]) }
}

extension NSHostingView: @retroactive CustomReflectable {
  public var customMirror: Mirror { Mirror(self, children: [:]) }
}

extension ExportManager: @retroactive CustomReflectable {
  public nonisolated var customMirror: Mirror { Mirror(self, children: [:]) }
}
