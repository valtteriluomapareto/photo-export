import SwiftUI

/// Owns the actual recovery controls and their sheet composition, independently of Form layout.
struct AutoExportRecoveryPrompt: View {
  @EnvironmentObject private var lifecycleCoordinator: AppLifecycleCoordinator
  @EnvironmentObject private var safetyMonitor: DestinationSafetyMonitor
  @EnvironmentObject private var exportDestinationManager: ExportDestinationManager
  @Environment(ExportManager.self) private var exportManagerFromEnvironment
  @State private var isShowingMigrationRecoverySheet = false
  @State private var isShowingSafetyConfirm = false

  var body: some View {
    Group {
      if lifecycleCoordinator.migrationConflict != nil {
        let showRecovery = { isShowingMigrationRecoverySheet = true }
        Section {
          MigrationConflictBanner(onTap: showRecovery)
            .accessibilityIdentifier("auto-export-destination-prompt")
            .listRowInsets(EdgeInsets())
        }
      } else if safetyMonitor.needsSafetyConfirmation {
        let showConfirmation = { isShowingSafetyConfirm = true }
        Section {
          SafetyConfirmationBanner(onTap: showConfirmation)
            .accessibilityIdentifier("auto-export-destination-prompt")
            .listRowInsets(EdgeInsets())
        }
      }

    }
    .sheet(isPresented: $isShowingMigrationRecoverySheet) {
      DestinationRecordRecoveryView(
        mode: .migrationConflict,
        onRebuildComplete: { lifecycleCoordinator.clearMigrationConflictAfterReconcile() },
        onUseAsIs: nil
      )
      .environmentObject(lifecycleCoordinator)
      .environment(exportManagerFromEnvironment)
      .environmentObject(exportDestinationManager)
    }
    .sheet(isPresented: $isShowingSafetyConfirm) {
      // The destination has files but no records. Offer to rebuild
      // progress from the drive (so re-exports skip the existing files instead
      // of creating ` (1)` duplicates) as well as the plain "these are my
      // pre-existing files" confirm. Both resolve the safety prompt by
      // confirming the destination; the rebuild path additionally restores the
      // record store from the drive's contents first.
      DestinationRecordRecoveryView(
        mode: .orphanedProgress,
        onRebuildComplete: { safetyMonitor.confirmCurrentDestination() },
        onUseAsIs: { safetyMonitor.confirmCurrentDestination() }
      )
      .environmentObject(lifecycleCoordinator)
      .environment(exportManagerFromEnvironment)
      .environmentObject(exportDestinationManager)
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
