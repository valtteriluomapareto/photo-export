#if DEBUG
  import Foundation

  enum ControlAction: Equatable {
    case export(LibrarySelection, confirm: Bool)
    case pause, resume, cancel, startImport, cancelImport
    case setAutoSync(Bool)
    case advanceClock(Int)
  }

  enum ControlRefusal: String, Error {
    case invalidRequest, staleRun, unavailable, unknownSelection, needsConfirmation
  }

  enum ControlOutcome: Equatable {
    case accepted, noop, refused(ControlRefusal)

    func response(run: String, sequence: Int) -> [String: Any] {
      var fields: [String: Any] = ["version": 1, "run": run, "seq": sequence]
      switch self {
      case .accepted: fields["status"] = "accepted"
      case .noop: fields["status"] = "noop"
      case .refused(let reason):
        fields["status"] = "refused"
        fields["reason"] = reason.rawValue
      }
      return fields
    }
  }

  enum ControlRequest {
    static let maxBytes = 16_384

    private enum Field: Decodable {
      case text(String), integer(Int), boolean(Bool)

      init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let text = try? value.decode(String.self) {
          self = .text(text)
        } else if let boolean = try? value.decode(Bool.self) {
          self = .boolean(boolean)
        } else if let integer = try? value.decode(Int.self) {
          self = .integer(integer)
        } else {
          throw ControlRefusal.invalidRequest
        }
      }
    }

    static func decode(_ data: Data, run: String, sequence: Int) throws -> ControlAction {
      guard data.count <= maxBytes, String(data: data, encoding: .utf8) != nil,
        var fields = try? JSONDecoder().decode([String: Field].self, from: data),
        (try? uniqueKeys(in: data)) == true,
        case .integer(1) = fields.removeValue(forKey: "version"),
        case .integer(sequence) = fields.removeValue(forKey: "seq"),
        case .text(let requestRun) = fields.removeValue(forKey: "run"),
        case .text(let action) = fields.removeValue(forKey: "action")
      else { throw ControlRefusal.invalidRequest }
      guard requestRun == run else { throw ControlRefusal.staleRun }
      let result: ControlAction
      switch action {
      case "export.month", "export.year", "export.album", "export.favorites":
        result = try export(action, fields: &fields)
      case "export.pause": result = .pause
      case "export.resume": result = .resume
      case "export.cancel": result = .cancel
      case "import.start": result = .startImport
      case "import.cancel": result = .cancelImport
      case "autoSync.setEnabled":
        guard case .boolean(let enabled) = fields.removeValue(forKey: "enabled") else {
          throw ControlRefusal.invalidRequest
        }
        result = .setAutoSync(enabled)
      case "clock.advance":
        guard case .integer(let seconds) = fields.removeValue(forKey: "seconds"),
          (0...86_400).contains(seconds)
        else { throw ControlRefusal.invalidRequest }
        result = .advanceClock(seconds)
      default: throw ControlRefusal.invalidRequest
      }
      guard fields.isEmpty else { throw ControlRefusal.invalidRequest }
      return result
    }

    private static func export(_ action: String, fields: inout [String: Field]) throws
      -> ControlAction
    {
      var confirm = false
      if let flag = fields.removeValue(forKey: "confirm") {
        guard case .boolean(let value) = flag else { throw ControlRefusal.invalidRequest }
        confirm = value
      }
      let selection: LibrarySelection
      switch action {
      case "export.album":
        guard case .text(let id) = fields.removeValue(forKey: "id"), !id.isEmpty,
          id.utf8.count <= 512
        else { throw ControlRefusal.invalidRequest }
        selection = .album(collectionId: id)
      case "export.favorites":
        selection = .favorites
      default:
        guard case .integer(let year) = fields.removeValue(forKey: "year"),
          (1...9999).contains(year)
        else { throw ControlRefusal.invalidRequest }
        if action == "export.month" {
          guard case .integer(let month) = fields.removeValue(forKey: "month"),
            (1...12).contains(month)
          else { throw ControlRefusal.invalidRequest }
          selection = .timelineMonth(year: year, month: month)
        } else {
          selection = .timelineYear(year: year)
        }
      }
      return .export(selection, confirm: confirm)
    }

    /// A valid flat object already decoded. Decode each member spelling so escaped aliases count.
    private static func uniqueKeys(in data: Data) throws -> Bool {
      var keys: Set<String> = []
      var opening: Data.Index?
      var escaped = false
      for (index, byte) in zip(data.indices, data) {
        if let start = opening {
          if escaped {
            escaped = false
            continue
          }
          if byte == 0x5C {
            escaped = true
            continue
          }
          guard byte == 0x22 else { continue }
          opening = nil
          let next = data.suffix(from: data.index(after: index)).first {
            ![0x20, 0x09, 0x0A, 0x0D].contains($0)
          }
          if next == 0x3A {
            let key = try JSONDecoder().decode(String.self, from: data[start...index])
            if !keys.insert(key).inserted { return false }
          }
        } else if byte == 0x22 {
          opening = index
        }
      }
      return true
    }
  }
#endif
