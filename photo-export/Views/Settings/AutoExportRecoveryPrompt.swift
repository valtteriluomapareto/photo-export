import SwiftUI

/// Shows the pending destination prompt. Its buttons open recovery sheets that Settings
/// presents from its Form.
struct AutoExportRecoveryPrompt: View {
  let hasMigrationConflict: Bool
  let needsSafetyConfirmation: Bool
  let showMigrationRecovery: () -> Void
  let showSafetyConfirmation: () -> Void

  var body: some View {
    Group {
      if hasMigrationConflict {
        Section {
          MigrationConflictBanner(onTap: showMigrationRecovery)
            .accessibilityIdentifier("auto-export-destination-prompt")
            .listRowInsets(EdgeInsets())
        }
      } else if needsSafetyConfirmation {
        Section {
          SafetyConfirmationBanner(onTap: showSafetyConfirmation)
            .accessibilityIdentifier("auto-export-destination-prompt")
            .listRowInsets(EdgeInsets())
        }
      }

    }
  }
}

private struct MigrationConflictBanner: View {
  let onTap: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .font(.title3)
      VStack(alignment: .leading, spacing: 4) {
        Text("Destination Has Unresolved Issues")
          .font(.headline)
        Text(
          "This destination has both current and legacy record sets. Auto Export is blocked until you resolve which to use."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        HStack {
          Spacer()
          Button("Resolve\u{2026}") { onTap() }
            .controlSize(.regular)
            .accessibilityIdentifier("auto-export-resolve-destination")
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.orange.opacity(0.1))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color.orange.opacity(0.4), lineWidth: 1)
    )
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
  }
}

private struct SafetyConfirmationBanner: View {
  let onTap: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "exclamationmark.shield.fill")
        .foregroundStyle(.orange)
        .font(.title3)
      VStack(alignment: .leading, spacing: 4) {
        Text("Confirm This Destination")
          .font(.headline)
        Text(
          "The destination folder already contains files but has no export records. If you've exported here before, you can rebuild your progress; otherwise confirm it's your backup before Auto Export starts writing."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        HStack {
          Spacer()
          Button("Review\u{2026}") { onTap() }
            .controlSize(.regular)
            .accessibilityIdentifier("auto-export-review-destination")
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.orange.opacity(0.1))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color.orange.opacity(0.4), lineWidth: 1)
    )
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
  }
}
