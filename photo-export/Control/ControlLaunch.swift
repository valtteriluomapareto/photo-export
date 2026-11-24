#if DEBUG
  import CoreGraphics
  import Foundation

  enum ControlLaunch {
    struct Invalid: Error, CustomStringConvertible {
      let description: String
      init(_ description: String) { self.description = description }
    }

    enum Surface: String, CaseIterable {
      case library, favorites, autoExport, exportIssues, advanced

      var settingsTab: SettingsTab? { SettingsTab(rawValue: rawValue) }
    }

    struct Options: Equatable {
      var runDirectory: URL?
      var snapshot: String?
      var surface: Surface = .library
      var dark = false
      var size = CGSize(width: 1280, height: 800)
    }

    static func parse(_ arguments: [String]) throws -> Options? {
      var options = Options()
      var seen: Set<ControlLaunchFlag> = []
      var args = arguments.dropFirst()
      func value(for flag: String) throws -> String {
        guard let value = args.popFirst(), !value.isEmpty, !value.hasPrefix("-") else {
          throw Invalid("Missing value for \(flag).")
        }
        return value
      }
      while let flag = args.popFirst() {
        guard flag.hasPrefix("-PE") else { continue }
        guard let option = ControlLaunchFlag(rawValue: flag) else {
          throw Invalid("Unknown Photo Export control flag.")
        }
        guard seen.insert(option).inserted else { throw Invalid("Repeated flag \(flag).") }
        switch option {
        case .fixture:
          guard try value(for: flag) == "v1" else { throw Invalid("Unknown fixture.") }
        case .runDirectory:
          let path = try value(for: flag)
          guard path.hasPrefix("/") else { throw Invalid("Run directory must be absolute.") }
          options.runDirectory = URL(fileURLWithPath: path, isDirectory: true)
        case .snapshot:
          let name = try value(for: flag)
          guard name.hasSuffix(".png"), name.count > 4, name.utf8.count <= 128,
            !name.contains("/"), !name.contains("\0")
          else { throw Invalid("Use a PNG filename inside the run directory.") }
          options.snapshot = name
        case .surface:
          guard let surface = Surface(rawValue: try value(for: flag)) else {
            throw Invalid("Unknown surface.")
          }
          options.surface = surface
        case .dark:
          options.dark = true
        case .size:
          let dimensions = try value(for: flag).split(
            separator: "x", omittingEmptySubsequences: false)
          guard dimensions.count == 2,
            dimensions.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }),
            let width = Int(dimensions[0]), let height = Int(dimensions[1]),
            (1000...4096).contains(width), (700...4096).contains(height)
          else { throw Invalid("Size must be between 1000x700 and 4096x4096.") }
          options.size = CGSize(width: width, height: height)
        }
      }
      guard !seen.isEmpty else { return nil }
      guard seen.contains(.fixture) || options.snapshot != nil else {
        throw Invalid("Use -PEFixture v1 or -PESnapshot.")
      }
      guard options.surface.settingsTab == nil || options.snapshot != nil else {
        throw Invalid("Settings surfaces require -PESnapshot.")
      }
      guard !arguments.contains("--screenshot-mode"), !arguments.contains("--force-onboarding"),
        !arguments.contains(where: { $0.hasPrefix("--screenshot-") })
      else { throw Invalid("Control launches require their own fixture flags.") }
      return options
    }
  }
#endif
