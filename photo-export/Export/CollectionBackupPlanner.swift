import Foundation

/// A folder under the destination's `Collections/` tree found by
/// `BackupScanner.scanCollectionsFolder`. Raw: the planner decides what each folder is, so a
/// `videos/` folder can be an album's videos subfolder or a nested album called "videos".
struct ScannedCollectionDirectory: Equatable, Sendable {
  enum Root: String, CaseIterable, Sendable {
    case favorites = "Favorites"
    case albums = "Albums"
    case sharedAlbums = "Shared Albums"
  }

  let root: Root
  /// Folder names below the root folder, spelled as on disk. Empty for the root itself.
  let components: [String]
  /// Regular files directly inside this folder, sorted by filename. `subfolder` is `nil`.
  let files: [BackupScanner.ScannedFile]

  /// Destination-relative path, ending with `/`.
  var relativePath: String {
    "Collections/\(root.rawValue)/" + components.map { $0 + "/" }.joined()
  }
}

/// What `BackupScanner.scanCollectionsFolder` found under `Collections/`.
struct ScannedCollections: Sendable {
  var directories: [ScannedCollectionDirectory]
  /// The destination's volume tells folder names apart by case.
  var isCaseSensitiveVolume: Bool
}

/// Decides which album, shared album or Favorites folder in a backup belongs to which current
/// Photos collection. Pure: `BackupScanner.matchCollectionFolders` supplies the file matches.
///
/// Folder names come from `ExportPlacementResolver`, not from rules of their own. A current
/// album can only have been exported to its sanitized title under its sanitized parent folders,
/// or that title with the resolver's sibling-collision suffix (`_2`, `_3`, …). So:
/// - A saved placement for the album's current identity decides its folder.
/// - Otherwise the album's candidates are the folders on disk with its name or a suffixed form
///   of it, compared case-folded and NFC like the resolver's sibling keys. Albums whose names
///   collide therefore share candidates and are told apart by content, whatever order they were
///   exported in. A suffixed name that is another album's own title is not a candidate, and
///   folders saved placements own are not candidates for anyone else.
/// - Folders whose names differ only by case (possible on a case-sensitive volume) are not
///   candidates: which one an export wrote can't be told. On a case-sensitive volume a folder
///   spelled differently from the resolver's spelling is not a candidate either.
/// - A renamed or moved album's old folder is not a candidate: its name or parent path no
///   longer fits, so the next export uses a new folder and the old one is reported.
///
/// A folder is adopted on evidence: at least one matched file and no equal claim from another
/// album on the folder or from another folder on the album. When the folder is where the
/// resolver puts the album today and no other album or folder with matches competes for it
/// (the folder the next export writes to anyway), one match is enough. Otherwise at least
/// `precisionFloor` of the folder's files must match. Equal claims whose folders hold the same
/// files (same names and known sizes) are settled by the resolver's own order, since either
/// assignment exports nothing. The adopted placement has the id the resolver gives the album
/// and the resolver's spelling of the path, so the next export resolves to it.
enum CollectionBackupPlanner {
  /// Smallest share of a folder's files that must match an album when several albums or
  /// folders compete.
  static let precisionFloor = 0.5

  enum Target: Hashable, Sendable {
    case favorites
    case album(collectionId: String)
    case sharedAlbum(collectionId: String)

    var scope: PhotoFetchScope {
      switch self {
      case .favorites: .favorites
      case .album(let id): .album(collectionId: id)
      case .sharedAlbum(let id): .sharedAlbum(collectionId: id)
      }
    }

    fileprivate var sortKey: String {
      switch self {
      case .favorites: "0"
      case .album(let id): "1" + id
      case .sharedAlbum(let id): "2" + id
      }
    }
  }

  /// One folder an album could have been exported to, with the placement it would adopt.
  struct Candidate: Equatable {
    let target: Target
    /// The folder's on-disk relative path.
    let folderPath: String
    let placement: ExportPlacement
    /// The folder's files, then its `videos/` files with `subfolder == "videos"`.
    let files: [BackupScanner.ScannedFile]
    /// The placement is already in the history.
    let isSaved: Bool
    /// The folder is where the resolver puts the album today.
    let isResolverChoice: Bool
  }

  /// A candidate's matching evidence.
  struct Score {
    let candidate: Candidate
    let matched: [BackupScanner.MatchedExportFile]
  }

  struct Adoption {
    let placement: ExportPlacement
    let folderPath: String
    let matched: [BackupScanner.MatchedExportFile]

    /// The records to import: each matched file as a completed variant at its folder. A
    /// second file for the same asset and variant (an earlier duplicate) is left out.
    func importBatch(exportedAt: Date) -> CollectionExportRecordStore.ImportBatch {
      var records: [String: [ExportVariant: ExportVariantRecord]] = [:]
      for match in matched where records[match.asset.id]?[match.variant] == nil {
        records[match.asset.id, default: [:]][match.variant] = ExportVariantRecord(
          filename: match.file.filename, status: .done, exportDate: exportedAt, lastError: nil,
          subfolder: match.file.subfolder)
      }
      return CollectionExportRecordStore.ImportBatch(placement: placement, records: records)
    }
  }

  struct Plan {
    var adoptions: [Adoption] = []
    /// Folders with files that no current collection was adopted into and no saved placement
    /// owns, sorted: usually albums renamed, moved or deleted in Photos, or an album recreated
    /// under the same title without the photos. A `videos/` folder is reported as its parent.
    var unrecognizedFolders: [String] = []
  }

  // MARK: - Candidates

  static func candidates(
    directories: [ScannedCollectionDirectory],
    collections: [PhotoCollectionDescriptor],
    existingPlacements: [ExportPlacement],
    caseSensitiveVolume: Bool = false,
    resolver: ExportPlacementResolver = ExportPlacementResolver()
  ) -> [Candidate] {
    let index = FolderIndex(directories: directories, resolver: resolver)
    let owned = Set(existingPlacements.compactMap { index.key(forRelativePath: $0.relativePath) })
    var result: [Candidate] = []
    // On a case-sensitive volume a folder spelled differently from the placement is not the
    // folder exports use; a case-insensitive volume treats both spellings as one folder.
    func spelledAsExportsUse(_ directory: ScannedCollectionDirectory, _ path: String) -> Bool {
      !caseSensitiveVolume
        || directory.relativePath.precomposedStringWithCanonicalMapping
          == path.precomposedStringWithCanonicalMapping
    }

    func savedCandidate(_ target: Target, _ saved: ExportPlacement) {
      guard let key = index.key(forRelativePath: saved.relativePath),
        let directory = index.directory(forKey: key),
        spelledAsExportsUse(directory, saved.relativePath),
        let files = index.files(in: directory)
      else { return }
      result.append(
        Candidate(
          target: target, folderPath: directory.relativePath, placement: saved, files: files,
          isSaved: true, isResolverChoice: true))
    }

    // Favorites has one fixed folder.
    if let saved = resolver.existingCollectionPlacement(
      for: .favorites, collections: collections, existingPlacements: existingPlacements)
    {
      savedCandidate(.favorites, saved)
    } else if let directory = index.directory(forKey: index.key(.favorites, [])),
      let files = index.files(in: directory)
    {
      result.append(
        Candidate(
          target: .favorites, folderPath: directory.relativePath, placement: .favorites(),
          files: files, isSaved: false, isResolverChoice: true))
    }

    // Shared albums never nest; like the resolver, only top-level ones are their siblings.
    let albums = resolver.albumsInTree(collections)
    let sharedAlbums = collections.filter { $0.kind == .sharedAlbum }
    let entries:
      [(PhotoCollectionDescriptor, ScannedCollectionDirectory.Root, [PhotoCollectionDescriptor])] =
        albums.map { ($0, .albums, albums) }
        + sharedAlbums.map { ($0, .sharedAlbums, sharedAlbums) }
    for (descriptor, root, siblings) in entries {
      guard let id = descriptor.localIdentifier, !id.isEmpty else { continue }
      let target: Target =
        root == .albums ? .album(collectionId: id) : .sharedAlbum(collectionId: id)
      let selection: LibrarySelection =
        root == .albums ? .album(collectionId: id) : .sharedAlbum(collectionId: id)
      if let saved = resolver.existingCollectionPlacement(
        for: selection, collections: collections, existingPlacements: existingPlacements)
      {
        savedCandidate(target, saved)
        continue
      }
      let resolved = try? resolver.placement(
        for: selection, collections: collections, existingPlacements: existingPlacements)

      let parent = resolver.sanitizedFolderPath(descriptor.pathComponents)
      let leaf = ExportPathPolicy.sanitizeComponent(descriptor.title)
      let leafKey = resolver.siblingLeafKey(leaf)
      // The resolver never gives a suffixed name that is a sibling's own title.
      let reserved = Set(
        siblings
          .filter {
            $0.localIdentifier != id && resolver.sanitizedFolderPath($0.pathComponents) == parent
          }
          .map { resolver.siblingLeafKey(ExportPathPolicy.sanitizeComponent($0.title)) })
      let parentKey = index.key(
        root, descriptor.pathComponents.map(ExportPathPolicy.sanitizeComponent))

      for directory in index.children(ofKey: parentKey) {
        guard let name = directory.components.last else { continue }
        let folderLeaf: String
        switch FolderName(resolver.siblingLeafKey(name), base: leafKey) {
        case .other: continue
        case .bare: folderLeaf = leaf
        case .suffixed(let number):
          folderLeaf = "\(leaf)_\(number)"
          if reserved.contains(resolver.siblingLeafKey(folderLeaf)) { continue }
        }
        guard let key = index.key(forRelativePath: directory.relativePath), !owned.contains(key),
          let files = index.files(in: directory),
          let placement = resolver.adoptedPlacement(for: descriptor, leaf: folderLeaf),
          spelledAsExportsUse(directory, placement.relativePath)
        else { continue }
        result.append(
          Candidate(
            target: target, folderPath: directory.relativePath, placement: placement,
            files: files, isSaved: false,
            isResolverChoice: resolved?.relativePath == placement.relativePath))
      }
    }
    return result
  }

  /// How a folder name relates to an album's sanitized title (both as sibling keys).
  private enum FolderName {
    case bare
    /// The resolver's sibling-collision suffix: `_N`, `N ≥ 2`, no leading zero.
    case suffixed(Int)
    case other

    init(_ name: String, base: String) {
      if name == base {
        self = .bare
        return
      }
      let digits = name.dropFirst(base.count + 1)
      guard name.hasPrefix(base + "_"), let first = digits.first, first != "0",
        digits.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(digits), number >= 2
      else {
        self = .other
        return
      }
      self = .suffixed(number)
    }
  }

  /// Files an album could own in a candidate folder: every file in the folder, and the video
  /// files in its `videos/` subfolder (an export puts nothing else there).
  static func ownableFileCount(_ files: [BackupScanner.ScannedFile]) -> Int {
    files.filter {
      $0.subfolder == nil || BackupScanner.mediaType(for: $0.fileExtension) == .video
    }.count
  }

  // MARK: - Assignment

  private struct Claim {
    let score: Score
    let matched: Int
    let considered: Int
    var target: Target { score.candidate.target }
    var folder: String { score.candidate.folderPath }

    func ranksEqual(_ other: Claim) -> Bool {
      matched == other.matched && matched * other.considered == other.matched * considered
    }
    func ranksAbove(_ other: Claim) -> Bool {
      if matched != other.matched { return matched > other.matched }
      return matched * other.considered > other.matched * considered
    }
    /// What the folder holds for the album: equal evidence means equal files to export. `nil`
    /// when a matched file's size is unknown, since then the files can't be shown equal.
    var evidence: Set<String>? {
      var result = Set<String>()
      for match in score.matched {
        guard let size = match.file.fileSize else { return nil }
        result.insert(
          [
            match.asset.id, match.variant.rawValue, match.file.filename,
            match.file.subfolder ?? "", String(size),
          ].joined(separator: "\u{0}"))
      }
      return result
    }
  }

  static func assign(
    _ scores: [Score], directories: [ScannedCollectionDirectory],
    existingPlacements: [ExportPlacement],
    resolver: ExportPlacementResolver = ExportPlacementResolver()
  ) -> Plan {
    // Only folders with matches compete: a leftover folder that matches nothing doesn't make
    // the album's own folder contested.
    var candidatesPerTarget: [Target: Int] = [:]
    var candidatesPerFolder: [String: Int] = [:]
    for score in scores where !score.matched.isEmpty {
      candidatesPerTarget[score.candidate.target, default: 0] += 1
      candidatesPerFolder[score.candidate.folderPath, default: 0] += 1
    }
    func isUncontested(_ candidate: Candidate) -> Bool {
      candidate.isSaved
        || (candidate.isResolverChoice && candidatesPerTarget[candidate.target] == 1
          && candidatesPerFolder[candidate.folderPath] == 1)
    }

    var claims: [Claim] = scores.compactMap { score in
      let matched = Set(score.matched.map(\.file.url)).count
      let considered = max(ownableFileCount(score.candidate.files), matched)
      guard matched > 0 else { return nil }
      if !isUncontested(score.candidate),
        Double(matched) < precisionFloor * Double(considered)
      {
        return nil
      }
      return Claim(score: score, matched: matched, considered: considered)
    }
    claims.sort {
      if !$0.ranksEqual($1) { return $0.ranksAbove($1) }
      if $0.folder != $1.folder { return $0.folder < $1.folder }
      return $0.target.sortKey < $1.target.sortKey
    }

    var plan = Plan()
    var settledTargets = Set<Target>()
    var settledFolders = Set<String>()
    while let top = claims.first {
      let rivals = tiedGroup(of: top, in: claims)
      for claim in rivals {
        settledTargets.insert(claim.target)
        settledFolders.insert(claim.folder)
      }
      for claim in rivals.count == 1 ? rivals : resolverOrder(rivals) {
        plan.adoptions.append(
          Adoption(
            placement: claim.score.candidate.placement, folderPath: claim.folder,
            matched: claim.score.matched))
      }
      claims.removeAll { settledTargets.contains($0.target) || settledFolders.contains($0.folder) }
    }

    plan.unrecognizedFolders = unrecognizedFolders(
      directories: directories, adopted: Set(plan.adoptions.map(\.folderPath)),
      existingPlacements: existingPlacements, resolver: resolver)
    return plan
  }

  /// The claims ranked equal to `top` and linked to it through a shared album or folder.
  private static func tiedGroup(of top: Claim, in claims: [Claim]) -> [Claim] {
    var group = [top]
    var targets: Set<Target> = [top.target]
    var folders: Set<String> = [top.folder]
    var grew = true
    while grew {
      grew = false
      for claim in claims
      where claim.ranksEqual(top)
        && !group.contains(where: { $0.score.candidate == claim.score.candidate })
      {
        if targets.contains(claim.target) || folders.contains(claim.folder) {
          group.append(claim)
          targets.insert(claim.target)
          folders.insert(claim.folder)
          grew = true
        }
      }
    }
    return group
  }

  /// Each album's claim on the folder the resolver gives it, when every tied claim holds the
  /// same files and those folders cover every album once; otherwise none (all abstain).
  private static func resolverOrder(_ tied: [Claim]) -> [Claim] {
    guard let evidence = tied.first?.evidence, tied.allSatisfy({ $0.evidence == evidence })
    else { return [] }
    let chosen = tied.filter(\.score.candidate.isResolverChoice)
    let targets = Set(tied.map(\.target))
    guard Set(chosen.map(\.target)) == targets, chosen.count == targets.count,
      Set(chosen.map(\.folder)).count == chosen.count
    else { return [] }
    return chosen
  }

  private static func unrecognizedFolders(
    directories: [ScannedCollectionDirectory], adopted: Set<String>,
    existingPlacements: [ExportPlacement], resolver: ExportPlacementResolver
  ) -> [String] {
    let index = FolderIndex(directories: directories, resolver: resolver)
    let ownedKeys = Set(
      existingPlacements.compactMap { index.key(forRelativePath: $0.relativePath) })
    let accounted = adopted
    var result = Set<String>()
    for directory in directories where !directory.files.isEmpty {
      let isRoot = directory.root != .favorites && directory.components.isEmpty
      if isRoot { continue }
      let parentComponents = Array(directory.components.dropLast())
      let parentPath =
        "Collections/\(directory.root.rawValue)/" + parentComponents.map { $0 + "/" }.joined()
      let isNamedVideos =
        directory.components.last.map { resolver.siblingLeafKey($0) == "videos" } ?? false
      let isVideosFolder =
        isNamedVideos && (directory.root == .favorites || !parentComponents.isEmpty)
      let key = index.key(directory.root, directory.components)
      if accounted.contains(directory.relativePath) || ownedKeys.contains(key) { continue }
      if isVideosFolder {
        let parentKey = index.key(directory.root, parentComponents)
        if accounted.contains(parentPath) || ownedKeys.contains(parentKey) { continue }
        result.insert(parentPath)
      } else {
        result.insert(directory.relativePath)
      }
    }
    return result.sorted()
  }
}

/// Scanned folders keyed by the resolver's case-folded, NFC sibling keys. Folders that share a
/// key with another folder (or sit under one that does) are ambiguous and never returned.
private struct FolderIndex {
  let resolver: ExportPlacementResolver
  private var directories: [String: ScannedCollectionDirectory] = [:]
  private var ambiguousKeys = Set<String>()
  private var childrenByParent: [String: [ScannedCollectionDirectory]] = [:]

  init(directories scanned: [ScannedCollectionDirectory], resolver: ExportPlacementResolver) {
    self.resolver = resolver
    for directory in scanned {
      let key = key(directory.root, directory.components)
      if directories.updateValue(directory, forKey: key) != nil { ambiguousKeys.insert(key) }
      if !directory.components.isEmpty {
        childrenByParent[
          self.key(directory.root, Array(directory.components.dropLast())), default: []
        ].append(directory)
      }
    }
    for (parent, children) in childrenByParent {
      childrenByParent[parent] = children.sorted { $0.relativePath < $1.relativePath }
    }
  }

  func key(_ root: ScannedCollectionDirectory.Root, _ components: [String]) -> String {
    ([root.rawValue] + components.map(resolver.siblingLeafKey)).joined(separator: "/")
  }

  /// The key of a placement's folder, or `nil` for a path outside the collection roots.
  func key(forRelativePath path: String) -> String? {
    for root in ScannedCollectionDirectory.Root.allCases {
      let prefix = "Collections/\(root.rawValue)/"
      guard path.hasPrefix(prefix) else { continue }
      let components = path.dropFirst(prefix.count).split(separator: "/").map(String.init)
      return key(root, components)
    }
    return nil
  }

  private func isAmbiguous(_ root: ScannedCollectionDirectory.Root, _ components: [String])
    -> Bool
  {
    (0...components.count).contains {
      ambiguousKeys.contains(key(root, Array(components.prefix($0))))
    }
  }

  func directory(forKey key: String) -> ScannedCollectionDirectory? {
    guard let directory = directories[key],
      !isAmbiguous(directory.root, directory.components)
    else { return nil }
    return directory
  }

  func children(ofKey key: String) -> [ScannedCollectionDirectory] {
    (childrenByParent[key] ?? []).filter { !isAmbiguous($0.root, $0.components) }
  }

  /// A folder's files, then its `videos/` subfolder's files tagged with that subfolder; `nil`
  /// when the `videos/` folder is ambiguous.
  func files(in directory: ScannedCollectionDirectory) -> [BackupScanner.ScannedFile]? {
    var files = directory.files
    let videosComponents = directory.components + ["videos"]
    if isAmbiguous(directory.root, videosComponents) { return nil }
    let videos = directories[key(directory.root, videosComponents)]
    for file in videos?.files ?? [] {
      files.append(
        BackupScanner.ScannedFile(
          url: file.url, year: file.year, month: file.month, filename: file.filename,
          baseFilename: file.baseFilename, hasCollisionSuffix: file.hasCollisionSuffix,
          fileExtension: file.fileExtension, modificationDate: file.modificationDate,
          fileSize: file.fileSize, subfolder: "videos"))
    }
    return files
  }
}
