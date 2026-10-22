import SwiftUI

#if DEBUG
  /// Reads the actual button's enabled environment and records its rendered export options.
  struct ExportControlProbe: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.bodyInvalidationCounter) private var counter
    let key: String
    let help: String
    var includesOriginals: Bool?
    var toggleOriginals: (() -> Void)?

    var body: some View {
      var values = [String(isEnabled), help]
      if let includesOriginals { values.append(String(includesOriginals)) }
      counter?.recordText(values, for: key)
      if let toggleOriginals {
        counter?.recordAction("onboarding-toggle-originals", action: toggleOriginals)
      }
      return Color.clear.frame(width: 0, height: 0)
    }
  }
#endif
