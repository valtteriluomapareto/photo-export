import Foundation

/// The question asked when the app can't compare a newly picked folder with the previous
/// destination (its bookmark won't resolve, or the old drive or share is unreachable). Kept as a
/// value so the wording and the button-to-decision mapping are testable without `NSAlert`.
///
/// "Same Folder" is first and the default: keeping the history is the choice that can't create
/// duplicate re-exports (#127), and the import that follows it checks the history against the
/// folder.
struct AmbiguousFolderPrompt: Equatable {
  let folderName: String

  var title: String { "Is this your previous backup folder?" }

  var message: String {
    "Photo Export can't reach the folder you used before, so it can't tell whether "
      + "\u{201C}\(folderName)\u{201D} is the same one. This happens when a drive is "
      + "disconnected or a network share reconnects under a new name.\n\n"
      + "Same Folder keeps your export history and checks it against this folder, so "
      + "nothing is exported twice.\n"
      + "New Folder starts an empty history and exports everything to this folder."
  }

  var buttons: [String] { ["Same Folder", "New Folder"] }

  func decision(forButtonAt index: Int) -> ExportDestinationManager.FolderSelectionDecision {
    index == 0 ? .sameDestination : .newDestination
  }
}
