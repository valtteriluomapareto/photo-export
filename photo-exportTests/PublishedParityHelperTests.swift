import Combine
import Foundation
import Testing

/// Shows that `assertPublishedParity` accepts `@Published` and rejects the storage shapes a
/// migration could slip into: a getter that reads the subject's value, an asynchronous hop and a
/// repeat filter.
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

  @Test func publishedPasses() async {
    let object = Published1()
    await assertPublishedParity(
      object, \.value, { $0.$value.eraseToAnyPublisher() },
      change: { object.value = 1 },
      unchangedWrite: .before { object.value = object.value })
  }

  @Test func subjectValueGetterFails() async {
    let object = SubjectBacked()
    await withKnownIssue("a sink reading the property sees the new value") {
      await assertPublishedParity(
        object, \.value, { $0.subject.eraseToAnyPublisher() },
        change: { object.value = 1 },
        unchangedWrite: .before { object.value = object.value })
    }
  }

  @Test func asynchronousDeliveryFails() async {
    let object = Published1()
    await withKnownIssue("the value arrives after the setter returns") {
      await assertPublishedParity(
        object, \.value,
        { $0.$value.receive(on: DispatchQueue.main).eraseToAnyPublisher() },
        change: { object.value = 1 },
        unchangedWrite: .notDrivable("not under test"))
    }
  }

  @Test func repeatFilterFailsWhereRepeatsMustEmit() async {
    let object = Published1()
    await withKnownIssue("an unchanged write is dropped") {
      await assertPublishedParity(
        object, \.value, { $0.$value.removeDuplicates().eraseToAnyPublisher() },
        change: { object.value = 1 },
        unchangedWrite: .before { object.value = object.value })
    }
  }
}
