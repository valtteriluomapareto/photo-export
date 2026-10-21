import Foundation
import Testing

@testable import Photo_Export

/// Cases from `docs/project/archive/collections-export-plan.md` §"Path Policy → Test cases".
/// Cases 9–11 exercise the resolver's sibling-collision disambiguation and live with the
/// resolver tests in Phase 2; this file covers the per-component sanitizer rules only.
struct CollectionPathComponentPolicyTests {

  @Test func asciiPassthrough() {
    #expect(
      CollectionPathComponentPolicy.sanitizeComponent("Family Trip 2024") == "Family Trip 2024")
    #expect(CollectionPathComponentPolicy.sanitizeComponent("simple") == "simple")
  }

  @Test func forwardSlashIsReplaced() {
    #expect(CollectionPathComponentPolicy.sanitizeComponent("a/b") == "a_b")
    #expect(CollectionPathComponentPolicy.sanitizeComponent("/leading") == "_leading")
    #expect(CollectionPathComponentPolicy.sanitizeComponent("trailing/") == "trailing_")
  }

  @Test func backslashIsReplaced() {
    #expect(CollectionPathComponentPolicy.sanitizeComponent(#"a\b"#) == "a_b")
  }

  @Test func windowsBannedCharactersReplaced() {
    // Plan §"Per-component rules" point 1: <, >, :, ", |, ?, * also replaced.
    #expect(CollectionPathComponentPolicy.sanitizeComponent("a:b") == "a_b")
    #expect(CollectionPathComponentPolicy.sanitizeComponent("a*b") == "a_b")
    #expect(CollectionPathComponentPolicy.sanitizeComponent("a?b") == "a_b")
    #expect(CollectionPathComponentPolicy.sanitizeComponent("a|b") == "a_b")
    #expect(CollectionPathComponentPolicy.sanitizeComponent("a<b>c") == "a_b_c")
    #expect(CollectionPathComponentPolicy.sanitizeComponent(#"a"b"#) == "a_b")
  }

  @Test func controlCharactersReplaced() {
    #expect(CollectionPathComponentPolicy.sanitizeComponent("a\u{0000}b") == "a_b")
    #expect(CollectionPathComponentPolicy.sanitizeComponent("a\u{001F}b") == "a_b")
    #expect(CollectionPathComponentPolicy.sanitizeComponent("a\u{007F}b") == "a_b")
    // Tab and newline are whitespace and are control chars; both rules collapse them to `_`,
    // then trimming removes leading/trailing whitespace. Embedded tabs/newlines stay as `_`.
    #expect(CollectionPathComponentPolicy.sanitizeComponent("a\tb") == "a_b")
    #expect(CollectionPathComponentPolicy.sanitizeComponent("a\nb") == "a_b")
  }

  @Test func trailingDotStripped() {
    #expect(CollectionPathComponentPolicy.sanitizeComponent("Family.") == "Family")
    #expect(CollectionPathComponentPolicy.sanitizeComponent("Family...") == "Family")
    // Internal dots stay.
    #expect(CollectionPathComponentPolicy.sanitizeComponent("a.b.c") == "a.b.c")
  }

  @Test func whitespaceTrimmed() {
    #expect(CollectionPathComponentPolicy.sanitizeComponent("  Family Trip  ") == "Family Trip")
    #expect(CollectionPathComponentPolicy.sanitizeComponent("\t\n  Family\n") == "Family")
  }

  @Test func emptyInputReturnsUnderscore() {
    #expect(CollectionPathComponentPolicy.sanitizeComponent("") == "_")
    #expect(CollectionPathComponentPolicy.sanitizeComponent("   ") == "_")
    #expect(CollectionPathComponentPolicy.sanitizeComponent("...") == "_")
    #expect(CollectionPathComponentPolicy.sanitizeComponent("\n\t") == "_")
  }

  @Test func dotComponentsReplaced() {
    #expect(CollectionPathComponentPolicy.sanitizeComponent(".") == "_")
    #expect(CollectionPathComponentPolicy.sanitizeComponent("..") == "_")
    // ".." surrounded by other content is preserved (the trailing-dot strip handles that
    // case; we only catch the bare ".."/".").
    #expect(CollectionPathComponentPolicy.sanitizeComponent("..something") == "..something")
  }

  @Test func nfcNormalizationApplied() {
    // NFD: e + combining acute accent (U+0065 + U+0301)
    let nfd = "Cafe\u{0301}"
    // NFC: precomposed é (U+00E9)
    let nfc = "Caf\u{00E9}"
    let result = CollectionPathComponentPolicy.sanitizeComponent(nfd)
    #expect(result == nfc)
  }
}
