//
//  ContentView.swift
//  photo-export
//
//  Created by Valtteri Luoma on 22.4.2025.
//

import AppKit
import Foundation
import Photos
import SwiftUI

/// Top-level router for the app's three states: pre-onboarding, onboarding, and the
/// authorized library view. `LibraryRootView` owns the authorized split-view layout
/// so this view can keep routing separate from library presentation.
struct ContentView: View {
  #if DEBUG
    @Environment(\.bodyInvalidationCounter) private var bodyCounter
  #endif
  @EnvironmentObject private var photoLibraryManager: PhotoLibraryManager
  @Environment(\.screenshotSurfaceKey) private var screenshotSurfaceKey
  /// Read only by the onboarding auto-skip in `onAppear`. Plain references rather than
  /// environment objects, so destination and record publications don't re-run the root body.
  let destinationManager: ExportDestinationManager
  let recordStore: ExportRecordStore

  // Onboarding — default to false for new users; existing users are auto-detected in .onAppear
  @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false

  // Debug-only: launch with `--force-onboarding` to route straight to `OnboardingView`,
  // regardless of Photos authorization or saved onboarding state. Lets you preview and
  // iterate on the first-run screens without disturbing real app state — handy because a
  // Debug build is rarely Photos-authorized, so the router would otherwise land on
  // `AuthorizationView`. Always false in release builds.
  private static let forceOnboarding: Bool = {
    #if DEBUG
      return CommandLine.arguments.contains("--force-onboarding")
    #else
      return false
    #endif
  }()

  var body: some View {
    #if DEBUG
      // swiftlint:disable:next redundant_discardable_let
      let _ = bodyCounter?.record("content-root")
    #endif
    Group {
      if Self.forceOnboarding || (photoLibraryManager.isAuthorized && !hasCompletedOnboarding) {
        OnboardingView {
          hasCompletedOnboarding = true
        }
      } else if photoLibraryManager.isAuthorized {
        LibraryRootView(screenshotSurfaceKey: screenshotSurfaceKey)
      } else {
        AuthorizationView(photoLibraryManager: photoLibraryManager)
      }
    }
    .onAppear {
      // Auto-skip onboarding for existing users who already have an export destination
      // or records.
      if !hasCompletedOnboarding {
        let hasDestination = destinationManager.selectedFolderURL != nil
        let hasRecords = !recordStore.recordsById.isEmpty
        if hasDestination || hasRecords {
          hasCompletedOnboarding = true
        }
      }
      #if DEBUG
        bodyCounter?.record("onboarding-auto-skip-checked")
      #endif
    }
  }
}

extension ContentView: Equatable {
  /// Compares the injected references by identity, for `.equatable()` at the call site.
  /// The `@AppStorage` property otherwise makes SwiftUI re-run this body every time
  /// `App.body` rebuilds the view. The view's own `@AppStorage` and `@EnvironmentObject`
  /// changes still re-run it.
  static func == (lhs: ContentView, rhs: ContentView) -> Bool {
    lhs.destinationManager === rhs.destinationManager && lhs.recordStore === rhs.recordStore
  }
}

struct AuthorizationView: View {
  @Environment(\.openURL) private var openURL
  #if DEBUG
    @Environment(\.bodyInvalidationCounter) private var bodyCounter
  #endif
  @ObservedObject var photoLibraryManager: PhotoLibraryManager

  var body: some View {
    #if DEBUG
      // swiftlint:disable:next redundant_discardable_let
      let _ = bodyCounter?.record(
        "authorization-pane:\(photoLibraryManager.authorizationStatus.rawValue)")
    #endif
    VStack(spacing: 20) {
      Image(systemName: "photo.on.rectangle.angled")
        .resizable()
        .scaledToFit()
        .frame(width: 100, height: 100)
        .foregroundColor(.blue)

      Text("Photo Library Access Required")
        .font(.title)
        .bold()

      Text(
        "This app needs access to your Photos library to back up photos and videos to external storage."
      )
      .multilineTextAlignment(.center)
      .padding(.horizontal)

      if photoLibraryManager.authorizationStatus == .denied
        || photoLibraryManager.authorizationStatus == .restricted
      {
        let message = PhotosAccessGuidance.message
        #if DEBUG
          // swiftlint:disable:next redundant_discardable_let
          let _ = bodyCounter?.recordText([message], for: "photos-access-guidance")
        #endif
        Text(message)
          .foregroundColor(.secondary)
          .padding()

        #if DEBUG
          // swiftlint:disable:next redundant_discardable_let
          let _ = bodyCounter?.recordAction(
            "authorization-open-settings", action: openSystemSettings)
        #endif
        Button("Open System Settings", action: openSystemSettings)
          .padding()
      } else {
        ProgressView()
          .padding()
        Text("Waiting for Photos access…")
          .foregroundColor(.secondary)
      }
    }
    .padding()
    .firstRunWindowMinSize()
    // `PhotoLibraryManager.observeAppActivation` refreshes access on every activation.
    .task {
      photoLibraryManager.refreshAuthorizationStatus()
      if photoLibraryManager.authorizationStatus == .notDetermined {
        _ = await photoLibraryManager.requestAuthorization()
      }
      #if DEBUG
        bodyCounter?.record("authorization-initial-check-complete")
      #endif
    }
  }

  private func openSystemSettings() {
    openURL(
      URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!)
  }
}

struct YearRow: View {
  #if DEBUG
    @Environment(\.bodyInvalidationCounter) private var bodyCounter
  #endif
  @EnvironmentObject private var exportManager: ExportManager
  @EnvironmentObject private var exportRecordStore: ExportRecordStore

  let year: Int
  let totalAssets: Int
  let totalCountsByMonth: [Int: Int]
  let adjustedCountsByMonth: [Int: Int?]

  var body: some View {
    let selection = exportManager.versionSelection
    let exported = exportRecordStore.sidebarYearExportedCount(
      year: year, totalCountsByMonth: totalCountsByMonth,
      adjustedCountsByMonth: adjustedCountsByMonth, selection: selection,
      livePhotosPaired: exportManager.livePhotosPairedExport)
    let total = yearTotal()
    #if DEBUG
      // swiftlint:disable:next redundant_discardable_let
      let _ = bodyCounter?.recordText([], for: "timeline-year:\(year)")
    #endif
    return HStack(spacing: 8) {
      Text(verbatim: String(year))
      Spacer()
      if let total, total > 0 && exported > 0 {
        if exported >= total {
          #if DEBUG
            // swiftlint:disable:next redundant_discardable_let
            let _ = bodyCounter?.recordText(["complete"], for: "timeline-year:\(year)")
          #endif
          Image(systemName: "checkmark.circle.fill")
            .foregroundColor(.green)
            .font(.caption)
            .accessibilityLabel(yearTooltip(selection: selection, exported: exported, total: total))
        } else {
          let pct = Int(Double(exported) / Double(total) * 100)
          #if DEBUG
            // swiftlint:disable:next redundant_discardable_let
            let _ = bodyCounter?.recordText(["\(pct)%"], for: "timeline-year:\(year)")
          #endif
          Text("\(pct)%")
            .foregroundColor(.orange)
            .font(.caption)
        }
      }
    }
    .help(yearTooltip(selection: selection, exported: exported, total: total))
  }

  /// Returns nil until every month with assets has reported its adjusted count, so the
  /// badge can't briefly flash 100% while counts are still loading. Both modes need the
  /// adjusted count for the records-only sidebar formula's cap.
  private func yearTotal() -> Int? {
    for month in 1...12 {
      let monthTotal = totalCountsByMonth[month] ?? 0
      if monthTotal == 0 { continue }
      if (adjustedCountsByMonth[month] ?? nil) == nil { return nil }
    }
    return totalAssets
  }

  private func yearTooltip(
    selection: ExportVersionSelection, exported: Int, total: Int?
  ) -> String {
    guard let total else { return "Counting photos in \(year)…" }
    switch selection {
    case .edited:
      return "\(exported) of \(total) photos exported in \(year)."
    case .editedWithOriginals:
      return
        "\(exported) of \(total) photos fully exported in \(year) "
        + "(including original copies for edited photos)."
    }
  }
}

struct MonthRow: View {
  #if DEBUG
    @Environment(\.bodyInvalidationCounter) private var bodyCounter
  #endif
  @EnvironmentObject private var exportManager: ExportManager
  @EnvironmentObject private var exportRecordStore: ExportRecordStore
  /// Reads `currentJobPlacement` from the live-progress observable rather than the
  /// manager, so the per-job placement mutations don't ripple through every view
  /// holding `ExportManager` as `@EnvironmentObject`. `MonthRow` still observes
  /// `ExportManager` for `versionSelection`, `livePhotosPairedExport` and the queue badge.
  @EnvironmentObject private var progressState: ExportProgressState

  let year: Int
  let month: Int
  let total: Int
  let adjusted: Int?

  var body: some View {
    let selection = exportManager.versionSelection
    let summary = exportRecordStore.sidebarSummary(
      year: year, month: month, totalCount: total, adjustedCount: adjusted,
      selection: selection,
      livePhotosPaired: exportManager.livePhotosPairedExport)
    // `queuedCount(year:month:)` reads the queue coordinator's unpublished per-month counts.
    // The "N left" badge relies on the manager publishing `queueCount` (and, for a job
    // starting, `progressState` publishing `currentJobPlacement`) in the same turn.
    let queued = exportManager.queuedCount(year: year, month: month)
    // Only the row owning the currently-in-flight job spins. Other rows with queued work
    // show just the "N left" text — a spinner on every queued row of a Year export reads
    // as visual clutter (macOS Finder / Mail sidebars use a single global indicator plus
    // quiet per-item status), and the global progress bar already advertises that work
    // is happening.
    let inFlight = progressState.currentJobPlacement?.timelineYearMonth
    let isActive = inFlight?.year == year && inFlight?.month == month
    #if DEBUG
      // swiftlint:disable:next redundant_discardable_let
      let _ = bodyCounter?.recordText([], for: "timeline-month:\(year)-\(month)")
    #endif
    return HStack(spacing: 8) {
      Text(MonthFormatting.name(for: month))
      Spacer()
      if queued > 0 {
        #if DEBUG
          // swiftlint:disable:next redundant_discardable_let
          let _ = bodyCounter?.recordText(
            ["\(queued) left"], for: "timeline-month:\(year)-\(month)")
        #endif
        if isActive {
          // `.controlSize(.mini)` renders the spinner at the right pixel size as a
          // vector; the previous `scaleEffect(0.5).frame(width:16, height:16)`
          // pattern scaled the rasterised default and produced a fuzzy indicator.
          ProgressView()
            .controlSize(.mini)
            .accessibilityLabel("Exporting \(MonthFormatting.name(for: month)) \(year)")
        }
        Text("\(queued) left")
          .font(.caption2)
          .foregroundColor(.orange)
      } else if total > 0, let summary {
        switch summary.status {
        case .complete:
          #if DEBUG
            // swiftlint:disable:next redundant_discardable_let
            let _ = bodyCounter?.recordText(["complete"], for: "timeline-month:\(year)-\(month)")
          #endif
          Image(systemName: "checkmark.circle.fill")
            .foregroundColor(.green)
            .font(.caption)
            .accessibilityLabel(monthTooltip(selection: selection, summary: summary))
        case .partial:
          #if DEBUG
            // swiftlint:disable:next redundant_discardable_let
            let _ = bodyCounter?.recordText(
              ["\(summary.exportedCount)/\(summary.totalCount)"],
              for: "timeline-month:\(year)-\(month)")
          #endif
          Text("\(summary.exportedCount)/\(summary.totalCount)")
            .foregroundColor(.orange)
            .font(.caption)
        case .notExported:
          #if DEBUG
            // swiftlint:disable:next redundant_discardable_let
            let _ = bodyCounter?.recordText(
              ["\(summary.totalCount)"], for: "timeline-month:\(year)-\(month)")
          #endif
          Text("\(summary.totalCount)")
            .foregroundColor(.secondary)
            .font(.caption)
        }
      } else if total > 0 {
        #if DEBUG
          // swiftlint:disable:next redundant_discardable_let
          let _ = bodyCounter?.recordText(["…"], for: "timeline-month:\(year)-\(month)")
        #endif
        // Adjusted count is still loading; show a neutral dash so the row doesn't flicker
        // between 0/0 and the real value.
        Text("…").foregroundColor(.secondary).font(.caption)
      }
    }
    .contentShape(Rectangle())
    .help(monthTooltip(selection: selection, summary: summary))
  }

  private func monthTooltip(
    selection: ExportVersionSelection, summary: MonthStatusSummary?
  ) -> String {
    let monthName = MonthFormatting.name(for: month)
    guard let summary else { return "Counting photos in \(monthName) \(year)…" }
    switch selection {
    case .edited:
      return
        "\(monthName) \(year): \(summary.exportedCount) of \(summary.totalCount) photos exported."
    case .editedWithOriginals:
      return
        "\(monthName) \(year): \(summary.exportedCount) of \(summary.totalCount) "
        + "photos fully exported (including original copies for edited photos)."
    }
  }
}
