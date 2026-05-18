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
/// authorized library view. The Phase 4 refactor moved the bulk of the authorized
/// layout into `LibraryRootView`; this file is now responsible for routing only.
struct ContentView: View {
  @EnvironmentObject private var photoLibraryManager: PhotoLibraryManager
  @EnvironmentObject private var exportDestinationManager: ExportDestinationManager
  @EnvironmentObject private var exportRecordStore: ExportRecordStore

  // Onboarding — default to false for new users; existing users are auto-detected in .onAppear
  @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false

  var body: some View {
    Group {
      if photoLibraryManager.isAuthorized && !hasCompletedOnboarding {
        OnboardingView {
          hasCompletedOnboarding = true
        }
      } else if photoLibraryManager.isAuthorized {
        LibraryRootView()
      } else {
        AuthorizationView(photoLibraryManager: photoLibraryManager)
      }
    }
    .onAppear {
      // Auto-skip onboarding for existing users who already have an export destination
      // or records.
      if !hasCompletedOnboarding {
        let hasDestination = exportDestinationManager.selectedFolderURL != nil
        let hasRecords = !exportRecordStore.recordsById.isEmpty
        if hasDestination || hasRecords {
          hasCompletedOnboarding = true
        }
      }
    }
  }
}

struct AuthorizationView: View {
  @ObservedObject var photoLibraryManager: PhotoLibraryManager

  var body: some View {
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
        Text("Please enable Photos access in System Settings to use this app.")
          .foregroundColor(.red)
          .padding()

        Button("Open System Settings") {
          NSWorkspace.shared.open(
            URL(
              string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos"
            )!)
        }
        .padding()
      } else {
        ProgressView()
          .padding()
        Text("Waiting for Photos access…")
          .foregroundColor(.secondary)
      }
    }
    .padding()
    .task {
      if photoLibraryManager.authorizationStatus == .notDetermined {
        _ = await photoLibraryManager.requestAuthorization()
      }
    }
  }
}

struct YearRow: View {
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
      adjustedCountsByMonth: adjustedCountsByMonth, selection: selection)
    let total = yearTotal()
    return HStack(spacing: 8) {
      Text(verbatim: String(year))
      Spacer()
      if let total, total > 0 && exported > 0 {
        if exported >= total {
          Image(systemName: "checkmark.circle.fill")
            .foregroundColor(.green)
            .font(.caption)
        } else {
          let pct = Int(Double(exported) / Double(total) * 100)
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
  @EnvironmentObject private var exportManager: ExportManager
  @EnvironmentObject private var exportRecordStore: ExportRecordStore

  let year: Int
  let month: Int
  let total: Int
  let adjusted: Int?

  var body: some View {
    let selection = exportManager.versionSelection
    let summary = exportRecordStore.sidebarSummary(
      year: year, month: month, totalCount: total, adjustedCount: adjusted,
      selection: selection)
    let queued = exportManager.queuedCount(year: year, month: month)
    // Only the row owning the currently-in-flight job spins. Other rows with queued work
    // show just the "N left" text — a spinner on every queued row of a Year export reads
    // as visual clutter (macOS Finder / Mail sidebars use a single global indicator plus
    // quiet per-item status), and the global progress bar already advertises that work
    // is happening.
    let isActive =
      exportManager.currentJobPlacement?.timelineYearMonth.map { $0 == (year, month) }
      ?? false
    return HStack(spacing: 8) {
      Text(MonthFormatting.name(for: month))
      Spacer()
      if queued > 0 {
        if isActive {
          ProgressView()
            .scaleEffect(0.5)
            .frame(width: 16, height: 16)
        }
        Text("\(queued) left")
          .font(.caption2)
          .foregroundColor(.orange)
      } else if total > 0, let summary {
        switch summary.status {
        case .complete:
          Image(systemName: "checkmark.circle.fill")
            .foregroundColor(.green)
            .font(.caption)
        case .partial:
          Text("\(summary.exportedCount)/\(summary.totalCount)")
            .foregroundColor(.orange)
            .font(.caption)
        case .notExported:
          Text("\(summary.totalCount)")
            .foregroundColor(.secondary)
            .font(.caption)
        }
      } else if total > 0 {
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

#Preview {
  ContentView()
}
