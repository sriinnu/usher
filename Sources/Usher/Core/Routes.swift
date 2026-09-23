import Foundation

/// The destination tree. Each node's `description` becomes the criteria text Jev
/// reads, so write them the way you would explain the folder to a person.
///
/// A node is one of two kinds:
///   - **declared**: it has a `path`, and that exact folder is the destination.
///   - **scanning**: it has a `scan` root, and the real destinations are whatever
///     subfolders already exist in there. Nothing is invented; a folder that does
///     not exist yet is proposed and waits for you.
struct RouteNode: Codable {
    var label: String
    var description: String
    var path: String?
    /// Directory whose existing subfolders are the destinations.
    var scan: String?
    /// Whether the app may propose a new subfolder under `scan`. Proposing never
    /// creates anything — it only asks.
    var allowNew: Bool?
    var template: String?
    var children: [RouteNode]?

    var isScanning: Bool { scan != nil }
    var isLeaf: Bool { (children ?? []).isEmpty && !isScanning }
}

/// A flattened declared destination. `key` is what Jev picks.
struct RouteLeaf: Identifiable, Hashable {
    var key: String
    var description: String
    /// May start with `{root}`; resolved per file against its destination root.
    var path: String
    var template: String

    var id: String { key }

    func destination(root: URL) -> URL { DestinationRoot.resolve(path, root: root) }
}

/// A category whose destinations are read off the filesystem at classify time.
struct ScanNode: Identifiable, Hashable {
    var key: String
    var description: String
    /// May start with `{root}`; the directory whose subfolders are destinations.
    var scanPath: String
    var allowNew: Bool
    var template: String

    var id: String { key }

    func root(for base: URL) -> URL { DestinationRoot.resolve(scanPath, root: base) }

    /// Subfolders that already exist, each with a few of its filenames as context.
    /// This is what stops the app from inventing a folder when one already fits.
    func existingFolders(root base: URL, sampleLimit: Int = 4, folderLimit: Int = 80) -> [ExistingFolder] {
        let manager = FileManager.default
        let root = self.root(for: base)
        guard let entries = try? manager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries
            .filter { $0.hasDirectoryPath }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(folderLimit)
            .map { folder in
                let entries = (try? manager.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )) ?? []

                // Subfolder names first: a folder like "Ladder" holds only
                // directories, and "Mutual funds" is what says what it is.
                let subfolders = entries.filter(\.hasDirectoryPath)
                    .prefix(sampleLimit).map { $0.lastPathComponent + "/" }
                let files = entries.filter { !$0.hasDirectoryPath }
                    .prefix(max(0, sampleLimit - subfolders.count)).map(\.lastPathComponent)

                return ExistingFolder(name: folder.lastPathComponent,
                                      url: folder,
                                      samples: Array(subfolders) + Array(files))
            }
    }
}

struct ExistingFolder: Hashable {
    var name: String
    var url: URL
    var samples: [String]
}

struct RouteTable {
    var roots: [RouteNode]
    var leaves: [RouteLeaf]
    var scans: [ScanNode]
    /// Why the table is empty, when it is empty because the file is broken
    /// rather than because there are no routes.
    var loadError: String?

    /// Reserved key meaning "none of these fit". Code leaves the file alone.
    static let unsortedKey = "unsorted"
    /// Reserved key inside a scanning category meaning "no existing folder fits".
    /// Always ends in a request for approval, never in a silent mkdir.
    static let newFolderKey = "__new_folder__"

    /// Every destination the app can pick, for display purposes.
    func destinationCount(root: URL) -> Int {
        leaves.count + scans.reduce(0) { $0 + $1.existingFolders(root: root).count }
    }

    func leaf(for key: String) -> RouteLeaf? {
        leaves.first { $0.key == key }
    }

    func scan(for key: String) -> ScanNode? {
        scans.first { $0.key == key }
    }

    static func load() -> RouteTable {
        if !FileManager.default.fileExists(atPath: Paths.routes.path) {
            try? Data(defaultRoutesJSON.utf8).write(to: Paths.routes, options: .atomic)
        }
        guard let data = try? Data(contentsOf: Paths.routes) else {
            return RouteTable(roots: [], leaves: [], scans: [], loadError: "routes.json could not be read.")
        }
        let roots: [RouteNode]
        do { roots = try JSONDecoder().decode([RouteNode].self, from: data) }
        catch {
            return RouteTable(roots: [], leaves: [], scans: [],
                              loadError: "routes.json is not valid: \(Self.describe(error))")
        }
        var leaves: [RouteLeaf] = []
        var scans: [ScanNode] = []
        for root in roots {
            flatten(root, prefix: [], inheritedTemplate: nil, leaves: &leaves, scans: &scans)
        }
        return RouteTable(roots: roots, leaves: leaves, scans: scans)
    }

    private static func flatten(_ node: RouteNode,
                                prefix: [String],
                                inheritedTemplate: String?,
                                leaves: inout [RouteLeaf],
                                scans: inout [ScanNode]) {
        let keyPath = prefix + [node.label]
        let key = keyPath.joined(separator: ".")
        let template = node.template ?? inheritedTemplate ?? "{name}.{ext}"

        if let scanPath = node.scan {
            scans.append(ScanNode(key: key, description: node.description,
                                  scanPath: scanPath, allowNew: node.allowNew ?? true, template: template))
            return
        }

        if node.isLeaf {
            guard let path = node.path else { return }
            leaves.append(RouteLeaf(key: key, description: node.description, path: path, template: template))
            return
        }

        for child in node.children ?? [] {
            flatten(child, prefix: keyPath, inheritedTemplate: template,
                    leaves: &leaves, scans: &scans)
        }
    }
}

extension RouteTable {
    static func describe(_ error: Error) -> String {
        if let d = error as? DecodingError {
            switch d {
            case .dataCorrupted(let c): return c.debugDescription
            case .keyNotFound(let k, _): return "missing key \"\(k.stringValue)\""
            case .typeMismatch(_, let c), .valueNotFound(_, let c): return c.debugDescription
            @unknown default: break
            }
        }
        return error.localizedDescription
    }
}

/// Seeded on first run. Edit `~/Library/Application Support/Usher/routes.json`
/// — the descriptions are the prompt, so they matter more than the folder names.
///
/// Note the `scan` nodes: those route into folders you already keep, rather than
/// declaring new ones.
let defaultRoutesJSON = """
[
  {
    "label": "german",
    "description": "German language learning material: textbooks, workbooks, grammar sheets, exam practice, vocabulary lists, audio scripts.",
    "children": [
      {
        "label": "a1",
        "description": "Absolute beginner German. Greetings, the alphabet, numbers, present tense of regular verbs, basic articles, simple self-introduction. Marked A1, Start Deutsch 1, or 'Anfänger'.",
        "path": "{root}/Documents/German/A1"
      },
      {
        "label": "a2",
        "description": "Elementary German. Past tense (Perfekt), separable verbs, dative case, everyday topics like shopping, health, travel. Marked A2 or Start Deutsch 2.",
        "path": "{root}/Documents/German/A2"
      },
      {
        "label": "b1",
        "description": "Intermediate German. Subjunctive, passive voice, connected opinions and arguments, longer reading texts. Marked B1 or Zertifikat Deutsch.",
        "path": "{root}/Documents/German/B1"
      },
      {
        "label": "b2",
        "description": "Upper intermediate German. Abstract topics, newspaper-level texts, complex subordinate clauses, formal register. Marked B2.",
        "path": "{root}/Documents/German/B2"
      },
      {
        "label": "c1",
        "description": "Advanced German. Academic or literary text, idiomatic and nuanced register, full command of style. Marked C1 or higher.",
        "path": "{root}/Documents/German/C1"
      }
    ]
  },
  {
    "label": "people",
    "description": "A photo or image of one specific, identifiable person — an actor, musician, public figure, friend, or family member. Choose this when the image is primarily of a person and there is a name available in the filename, the surrounding text, or the page it came from.",
    "scan": "{root}/Pictures/People",
    "allowNew": true,
    "template": "{name}.{ext}"
  },
  {
    "label": "books",
    "description": "Books and long-form reading that is not German language study.",
    "children": [
      {
        "label": "technical",
        "description": "Programming, mathematics, machine learning, systems, engineering textbooks and manuals.",
        "path": "{root}/Documents/Books/Technical"
      },
      {
        "label": "general",
        "description": "Fiction, philosophy, history, biography, and any other non-technical book.",
        "path": "{root}/Documents/Books/General"
      }
    ]
  },
  {
    "label": "software",
    "description": "Installable software and code archives.",
    "children": [
      {
        "label": "installers",
        "description": "macOS application installers: .dmg, .pkg, or a zip whose contents are a single .app bundle.",
        "path": "{root}/Downloads/Software/Installers"
      },
      {
        "label": "source",
        "description": "Source code archives: a zip or tarball containing source files, a repository export, package manifests like package.json, Cargo.toml, pyproject.toml.",
        "path": "{root}/Downloads/Software/Source"
      },
      {
        "label": "datasets",
        "description": "Data archives: CSV, JSON, JSONL, parquet, or a zip of data files intended for analysis or model training.",
        "path": "{root}/Downloads/Software/Datasets"
      }
    ]
  },
  {
    "label": "images",
    "description": "Images that are not primarily a photo of one identifiable person.",
    "template": "{yyyy}-{mm}-{name}.{ext}",
    "children": [
      {
        "label": "screenshots",
        "description": "Screen captures: UI, terminal output, chat windows, web pages, error dialogs.",
        "path": "{root}/Pictures/Screenshots"
      },
      {
        "label": "diagrams",
        "description": "Charts, architecture diagrams, figures from papers, whiteboard photos, and other explanatory graphics.",
        "path": "{root}/Pictures/Diagrams"
      },
      {
        "label": "photos",
        "description": "Photographs of places, objects, food, animals, or groups with no single identifiable subject. Not screenshots and not diagrams.",
        "path": "{root}/Pictures/Inbox"
      }
    ]
  },
  {
    "label": "papers",
    "description": "Academic papers and preprints: arXiv PDFs, conference or journal papers with an abstract and references section.",
    "path": "{root}/Documents/Papers",
    "template": "{name}.{ext}"
  }
]
"""
