import Combine
import Foundation
import Testing

/// Shows that `assertPublishedParity` accepts `@Published` and rejects the storage shapes a
/// migration could slip into. Each rejection must come from exactly the checks named: any other
/// issue is unmatched and fails the test, and every named check must fire.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PublishedParityHelperTests {
  @MainActor
  private final class Published1: ObservableObject {
    @Published var value = 0
  }

  /// Stores the value in the subject, so a sink reading the property sees the new value.
  @MainActor
  private final class SubjectBacked {
    let subject = CurrentValueSubject<Int, Never>(0)
    var value: Int {
      get { subject.value }
      set { subject.send(newValue) }
    }
  }

  /// Keeps the value in its own storage, delivers before storing, but replays from a
  /// `CurrentValueSubject`, whose value changes before it delivers.
  @MainActor
  private final class SubjectReplayBacked {
    let subject = CurrentValueSubject<Int, Never>(0)
    private var stored = 0
    var value: Int {
      get { stored }
      set {
        subject.send(newValue)
        stored = newValue
      }
    }
  }

  /// Separate storage, replayed through `prepend` onto a `PassthroughSubject`: the subscriber
  /// joins the subject only after the replay, and the subject keeps nothing for it.
  @MainActor
  private final class PrependBacked {
    let subject = PassthroughSubject<Int, Never>()
    private(set) var stored = 0
    var value: Int {
      get { stored }
      set {
        subject.send(newValue)
        stored = newValue
      }
    }
    var publisher: AnyPublisher<Int, Never> {
      Deferred { [self] in subject.prepend(stored) }.eraseToAnyPublisher()
    }
  }

  /// Replays the value it held when the publisher was made.
  @MainActor
  private final class EagerReplayBacked {
    let subject = PassthroughSubject<Int, Never>()
    private(set) var stored = 0
    var value: Int {
      get { stored }
      set {
        subject.send(newValue)
        stored = newValue
      }
    }
    var publisher: AnyPublisher<Int, Never> { subject.prepend(stored).eraseToAnyPublisher() }
  }

  /// Publishes in willSet without replaying the current value to a new subscriber.
  @MainActor
  private final class PassthroughBacked {
    let subject = PassthroughSubject<Int, Never>()
    var value = 0 { willSet { subject.send(newValue) } }
  }

  private final class Fired: @unchecked Sendable {
    private let lock = NSLock()
    private var checks: Set<ParityCheck> = []
    func insert(_ check: ParityCheck) { lock.withLock { _ = checks.insert(check) } }
    var all: Set<ParityCheck> { lock.withLock { checks } }
  }

  private func expectOnly(
    _ expected: Set<ParityCheck>, sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () async -> Void
  ) async {
    let fired = Fired()
    await withKnownIssue {
      await body()
    } matching: { issue in
      let text = issue.comments.map(\.rawValue).joined(separator: " ")
      guard let check = expected.first(where: { text.hasPrefix($0.rawValue) }) else {
        return false
      }
      fired.insert(check)
      return true
    }
    #expect(fired.all == expected, sourceLocation: sourceLocation)
  }

  @Test func publishedPasses() async {
    let object = Published1()
    await assertPublishedParity(
      object, \.value, { $0.$value.eraseToAnyPublisher() },
      change: { object.value = 1 },
      unchangedWrite: .before { object.value = object.value })
    assertSubscriberEdgeParity {
      let object = Published1()
      return EdgeSubject(
        publisher: object.$value.eraseToAnyPublisher(), value: { object.value },
        first: { object.value = 1 }, second: { object.value = 2 })
    }
  }

  /// The edge cases `@Published` handles that a `prepend` replay does not.
  @Test func prependReplayFailsWriteDuringReplayAndLimitedDemand() async {
    let object = PrependBacked()
    await assertPublishedParity(
      object, \.value, { $0.publisher },
      change: { object.value = 1 },
      unchangedWrite: .before { object.value = object.value })
    await expectOnly([.writeDuringReplay, .limitedDemand]) {
      assertSubscriberEdgeParity {
        let object = PrependBacked()
        return EdgeSubject(
          publisher: object.publisher, value: { object.value },
          first: { object.value = 1 }, second: { object.value = 2 })
      }
    }
  }

  @Test func eagerReplayFailsResubscription() async {
    let object = EagerReplayBacked()
    await expectOnly([.resubscribe]) {
      await assertPublishedParity(
        { object.publisher }, value: { object.value },
        change: { object.value = 1 },
        unchangedWrite: .before { object.value = object.value })
    }
  }

  @Test func subjectValueGetterFailsDeliveryOrderAndNestedReplay() async {
    let object = SubjectBacked()
    await expectOnly([.storedAfterDelivery, .nestedReplay, .nestedLater]) {
      await assertPublishedParity(
        object, \.value, { $0.subject.eraseToAnyPublisher() },
        change: { object.value = 1 },
        unchangedWrite: .before { object.value = object.value })
    }
  }

  /// Separate storage alone is not enough: a subscription made inside a sink replays the
  /// subject's value, which is already the one in flight.
  @Test func subjectReplayFailsNestedReplay() async {
    let object = SubjectReplayBacked()
    await expectOnly([.nestedReplay, .nestedLater]) {
      await assertPublishedParity(
        object, \.value, { $0.subject.eraseToAnyPublisher() },
        change: { object.value = 1 },
        unchangedWrite: .before { object.value = object.value })
    }
  }

  @Test func asynchronousDeliveryFailsReplayAndSynchrony() async {
    let object = Published1()
    await expectOnly([.replay, .synchronous, .lastIsStored, .resubscribe]) {
      await assertPublishedParity(
        object, \.value,
        { $0.$value.receive(on: DispatchQueue.main).eraseToAnyPublisher() },
        change: { object.value = 1 },
        unchangedWrite: .notDrivable("not under test"))
    }
  }

  @Test func missingReplayFailsReplay() async {
    let object = PassthroughBacked()
    await expectOnly([.replay, .resubscribe]) {
      await assertPublishedParity(
        object, \.value, { $0.subject.eraseToAnyPublisher() },
        change: { object.value = 1 },
        unchangedWrite: .notDrivable("not under test"))
    }
  }

  @Test func repeatFilterFailsWhereRepeatsMustEmit() async {
    let object = Published1()
    await expectOnly([.unchangedEmits]) {
      await assertPublishedParity(
        object, \.value, { $0.$value.removeDuplicates().eraseToAnyPublisher() },
        change: { object.value = 1 },
        unchangedWrite: .before { object.value = object.value })
    }
  }

  @Test func repeatDeliveryFailsWhereRepeatsMustDrop() async {
    let object = Published1()
    await expectOnly([.unchangedDropped]) {
      await assertPublishedParity(
        object, \.value, { $0.$value.eraseToAnyPublisher() },
        change: { object.value = 1 },
        unchangedWrite: .before { object.value = object.value },
        unchangedWriteDelivery: .isDropped)
    }
  }
}
