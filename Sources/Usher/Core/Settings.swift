import Foundation

/// One directory the app watches. Downloads is seeded by default; Desktop and
/// anything else gets added from the settings window.
struct WatchFolder: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var path: String
    var enabled: Bool = true
    /// FSEvents reports the whole subtree; when false we ignore events deeper
    /// than the folder itself.
    var recursive: Bool = false
    /// What `{root}` means for files found here. Nil is the default root in
    /// settings (iCloud Drive). Set explicitly, destinations stay inside it.
    var destinationRoot: String?

    enum CodingKeys: String, CodingKey {
        case id, path, enabled, recursive, destinationRoot
    }

    var url: URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
    var displayName: String { url.lastPathComponent }

    var exists: Bool {
        var isDir: ObjCBool = false
        let ok = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return ok && isDir.boolValue
    }
}

struct AppSettings: Codable {
    var watchFolders: [WatchFolder]
    /// Classify and journal, but never touch the file. Stays on until you trust it.
    var dryRun: Bool
    /// Route probability at or above this moves the file without asking.
    var autoMoveThreshold: Double
    /// Below this the file stays put and the decision is only recorded.
    var askThreshold: Double
    var model: String
    /// Filename substrings and source hosts that must never reach the API.
    var sensitivePatterns: [String]
    var sensitiveHosts: [String]
    /// Vision labels that hold a file locally. Identifiers come from Vision's own
    /// 1303-entry taxonomy, so they must be spelled exactly as it spells them.
    var sensitiveImageLabels: [String] = ["passport", "credit_card"]
    var sensitiveLabelThreshold: Double = 0.30
    /// Formats that are secrets by definition: password-manager exports, private
    /// keys, certificates. Checked before anything else; the filename alone can
    /// name a site and an account.
    var sensitiveExtensions: [String] = AppSettings.defaultSensitiveExtensions
    /// Phrases checked against text extracted on-device (PDF text, OCR), before
    /// anything is sent. Deliberately a separate, stricter list: the filename
    /// words ("bank", "tax", "termin") would trip on every German exercise book,
    /// so only high-precision phrases belong here.
    var sensitiveContentPatterns: [String] = AppSettings.defaultSensitiveContentPatterns
    /// The user's own email addresses, phone numbers, IBANs, ID numbers. A page
    /// that mentions one is theirs. Empty in source by design — this list is
    /// personal data and lives only in the user's settings.json.
    var personalIdentifiers: [String] = []
    /// Where a duplicate is set aside. Empty means leave it where it is.
    var duplicatesFolder: String = "~/Downloads/Duplicates"
    /// Pull iCloud placeholders down so their contents can be read. Off means a
    /// placeholder is skipped rather than classified on its name alone.
    var downloadCloudFiles: Bool = true
    /// Never pull anything bigger than this just to classify it.
    var maxCloudDownloadMB: Int = 80
    /// Keep the panel open when you switch to another app. Off restores the
    /// standard menubar behaviour of closing as soon as focus is lost.
    var keepPanelOpen: Bool = true
    /// The watcher only sees files as they arrive. Catch-up goes back for
    /// everything already sitting in a live folder that has no decision yet —
    /// on launch, then on this interval.
    var autoSweep: Bool = true
    var autoSweepMinutes: Int = 30
    /// Where `{root}` in routes.json and rules.json points unless a watched
    /// folder says otherwise. iCloud Drive: what every destination was before.
    var defaultDestinationRoot: String = "~/Library/Mobile Documents/com~apple~CloudDocs"

    enum CodingKeys: String, CodingKey {
        case watchFolders, dryRun, autoMoveThreshold, askThreshold, model
        case sensitivePatterns, sensitiveHosts
        case sensitiveImageLabels, sensitiveLabelThreshold, sensitiveExtensions
        case sensitiveContentPatterns, personalIdentifiers
        case duplicatesFolder, downloadCloudFiles, maxCloudDownloadMB
        case keepPanelOpen, autoSweep, autoSweepMinutes, defaultDestinationRoot
    }

    static let defaultSensitiveExtensions: [String] = [
        // Password managers
        "rfp", "rfo", "kdbx", "kdb", "1pif", "1pux", "agilekeychain", "opvault",
        "psafe3", "bitwarden", "lpcsv",
        // Keys, certificates, keychains
        "pem", "key", "p12", "pfx", "keychain", "keychain-db", "gpg", "pgp", "asc",
        "ppk", "jks", "crt", "cer", "der",
        // Wallet and seed material. (`wallet.dat` is caught by name in
        // SecretFormats — `.dat` alone is far too generic to hold by extension.)
        "wallet"
    ]

    /// Things that appear on a personal document and almost nowhere else.
    static let defaultSensitiveContentPatterns: [String] = [
        // Identity
        "passport no", "passport number", "reisepass", "aufenthaltstitel", "residence permit",
        "date of birth", "geburtsdatum", "nationality", "staatsangehörigkeit",
        "aadhaar", "pan card", "sozialversicherungsnummer", "steuernummer", "steuer-id",
        "national insurance", "ssn", "social security number",
        // Money
        // Austrian/German insurer vocabulary: 22 insurer health-claim letters in
        // one sweep said "Polizze Nummer" and "Leistungsnummer", never "policy".
        "polizze", "polizzennummer", "polizzen-nr", "leistungsnummer", "versicherungsnummer",
        "versicherungsnehmer", "vertragsnummer", "krankenversicherung", "schadensnummer",
        "republic of india", "beglaubigte fotokopie", "beglaubigte kopie",
        "tax invoice", "registered mobile", "completed date", "top-up by",
        "transaction history", "statement of account",
        "iban", "bic", "kontoauszug", "account statement", "balance certificate",
        "kontonummer", "account number", "policy number", "policy no", "customer number",
        "kundennummer", "amount due", "total due", "rechnungsnummer", "invoice number",
        "proof of payment", "payment confirmation", "zahlungsbestätigung", "lastschrift",
        // Residence and identity documents as they are actually titled
        "rot-weiß-rot", "rot-weiss-rot", "rwr-karte", "rwr plus", "aadhar", "aadhaar number",
        "impfpass", "impfung", "vaccination", "covid-19 registration", "covid registrierung",
        "mri", "referral", "überweisung", "überweisungsschein",
        // Employment, health, official
        "gehaltsabrechnung", "payslip", "arbeitsvertrag", "employment contract",
        "kündigung", "kuendigung", "krankmeldung", "arbeitsunfähig", "diagnose", "befund",
        "verordnung", "bescheid", "aktenzeichen", "case number", "reference number"
    ]

    static let `default` = AppSettings(
        watchFolders: [
            WatchFolder(path: "~/Downloads", enabled: true, recursive: false)
        ],
        dryRun: true,
        autoMoveThreshold: 0.80,
        askThreshold: 0.45,
        model: "jev-latest",
        sensitivePatterns: [
            // Banking and payroll
            "bank", "kontoauszug", "statement", "payslip", "gehaltsabrechnung",
            "salary", "1099", "w2", "iban", "hdfc", "icici", "sbi", "axis",
            // Tax and identity
            "tax", "steuer", "passport", "reisepass", "aadhaar", "pan card",
            "pancard", "ckyc", "kyc", "visa", "anmeldung", "meldebescheinigung",
            // Insurance, loans, investments
            "insurance", "versicherung", "lic ", "licindia", "policy", "premium",
            "loan", "darlehen", "emi", "chit", "chits", "mutual fund", "demat",
            // Health
            "medical", "arztbrief", "befund", "prescription", "diagnos",
            // Legal and billing
            "invoice", "rechnung", "contract", "vertrag", "electricity"
        ],
        sensitiveHosts: [
            "bank", "sparkasse", "dkb", "n26", "paypal", "elster", "sozialversicherung",
            "irs.gov", "incometax", "aadhaar", "uidai"
        ],
        sensitiveImageLabels: ["passport", "credit_card"],
        sensitiveLabelThreshold: 0.30,
        sensitiveExtensions: AppSettings.defaultSensitiveExtensions,
        sensitiveContentPatterns: AppSettings.defaultSensitiveContentPatterns,
        personalIdentifiers: [],
        duplicatesFolder: "~/Downloads/Duplicates",
        downloadCloudFiles: true,
        maxCloudDownloadMB: 80,
        keepPanelOpen: true,
        autoSweep: true,
        autoSweepMinutes: 30,
        defaultDestinationRoot: "~/Library/Mobile Documents/com~apple~CloudDocs"
    )
}

/// Swift's synthesized `Codable` ignores a property's default value and throws
/// `keyNotFound` when a key is absent. That makes every new setting a breaking
/// change for anyone with an existing settings.json: decoding fails, the app falls
/// back to defaults, and the saved file gets overwritten with them — quietly
/// destroying watch folders and tuned privacy patterns. Decoding each key
/// independently, with the default as the fallback, is what makes the file
/// forward- and backward-compatible.
///
/// Both types below live in extensions so the memberwise initializer survives.
extension AppSettings {

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AppSettings.default

        func value<T: Decodable>(_ key: CodingKeys, _ backup: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) .flatMap { $0 } ?? backup
        }

        watchFolders = value(.watchFolders, fallback.watchFolders)
        dryRun = value(.dryRun, fallback.dryRun)
        // Clamped on the way in. A hand-edited 0.04 auto-move threshold is a
        // sane thing to type and used to trap the UI that displays it.
        autoMoveThreshold = min(max(value(.autoMoveThreshold, fallback.autoMoveThreshold), 0.05), 0.99)
        askThreshold = min(max(value(.askThreshold, fallback.askThreshold), 0.02), autoMoveThreshold - 0.03)
        model = value(.model, fallback.model)
        sensitivePatterns = value(.sensitivePatterns, fallback.sensitivePatterns)
        sensitiveHosts = value(.sensitiveHosts, fallback.sensitiveHosts)
        sensitiveImageLabels = value(.sensitiveImageLabels, fallback.sensitiveImageLabels)
        sensitiveLabelThreshold = value(.sensitiveLabelThreshold, fallback.sensitiveLabelThreshold)
        sensitiveExtensions = value(.sensitiveExtensions, fallback.sensitiveExtensions)
        sensitiveContentPatterns = value(.sensitiveContentPatterns, fallback.sensitiveContentPatterns)
        personalIdentifiers = value(.personalIdentifiers, fallback.personalIdentifiers)
        duplicatesFolder = value(.duplicatesFolder, fallback.duplicatesFolder)
        downloadCloudFiles = value(.downloadCloudFiles, fallback.downloadCloudFiles)
        maxCloudDownloadMB = value(.maxCloudDownloadMB, fallback.maxCloudDownloadMB)
        keepPanelOpen = value(.keepPanelOpen, fallback.keepPanelOpen)
        autoSweep = value(.autoSweep, fallback.autoSweep)
        autoSweepMinutes = value(.autoSweepMinutes, fallback.autoSweepMinutes)
        defaultDestinationRoot = value(.defaultDestinationRoot, fallback.defaultDestinationRoot)
    }
}

extension WatchFolder {

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A folder with no path is the only genuinely unusable case.
        path = try container.decode(String.self, forKey: .path)
        id = (try? container.decodeIfPresent(UUID.self, forKey: .id)).flatMap { $0 } ?? UUID()
        enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)).flatMap { $0 } ?? true
        recursive = (try? container.decodeIfPresent(Bool.self, forKey: .recursive)).flatMap { $0 } ?? false
        destinationRoot = (try? container.decodeIfPresent(String.self, forKey: .destinationRoot)).flatMap { $0 }
    }
}

/// Everything lives under Application Support so the bundle stays disposable.
enum Paths {
    static let support: URL = {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let base = root.appendingPathComponent("Usher", isDirectory: true)

        // The app was called DwnClassifier before. Carry the old configuration and
        // journal across rather than silently starting from defaults — losing the
        // journal would also lose the accumulated calibration data.
        let legacy = root.appendingPathComponent("DwnClassifier", isDirectory: true)
        if !FileManager.default.fileExists(atPath: base.path),
           FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.moveItem(at: legacy, to: base)
        }

        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static var settings: URL { support.appendingPathComponent("settings.json") }
    static var routes: URL { support.appendingPathComponent("routes.json") }
    static var rules: URL { support.appendingPathComponent("rules.json") }
    static var journal: URL { support.appendingPathComponent("journal.ndjson") }
    static var renames: URL { support.appendingPathComponent("renames.ndjson") }
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published var settings: AppSettings {
        didSet { save() }
    }

    /// Bumped whenever the watch list changes so the pipeline can restart streams.
    @Published private(set) var watchGeneration: Int = 0

    init() {
        guard let data = try? Data(contentsOf: Paths.settings) else {
            settings = .default
            save()
            return
        }

        do {
            settings = try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            // Something is in there that we could not read. Keep a copy before
            // writing defaults over it, so a bad parse never costs a real config.
            let backup = Paths.support.appendingPathComponent(
                "settings.broken-\(Int(Date().timeIntervalSince1970)).json")
            // Owner-only: it holds the same personal identifiers settings do.
            FileManager.default.createFile(atPath: backup.path, contents: data,
                                           attributes: [.posixPermissions: 0o600])
            settings = .default
            save()
        }
    }

    func addFolder(_ url: URL) {
        let path = url.path
        guard !settings.watchFolders.contains(where: { $0.url.path == path }) else { return }
        settings.watchFolders.append(WatchFolder(path: path))
        watchGeneration += 1
    }

    func removeFolder(_ folder: WatchFolder) {
        settings.watchFolders.removeAll { $0.id == folder.id }
        watchGeneration += 1
    }

    func toggleEnabled(_ folder: WatchFolder) {
        guard let i = settings.watchFolders.firstIndex(where: { $0.id == folder.id }) else { return }
        settings.watchFolders[i].enabled.toggle()
        watchGeneration += 1
    }

    /// nil = the default root; a path = file only inside that root.
    func setDestinationRoot(_ folder: WatchFolder, _ root: String?) {
        guard let i = settings.watchFolders.firstIndex(where: { $0.id == folder.id }) else { return }
        settings.watchFolders[i].destinationRoot = root
    }

    func toggleRecursive(_ folder: WatchFolder) {
        guard let i = settings.watchFolders.firstIndex(where: { $0.id == folder.id }) else { return }
        settings.watchFolders[i].recursive.toggle()
        watchGeneration += 1
    }

    private func save() {
        ConfigFingerprint.invalidate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(settings).write(to: Paths.settings, options: .atomic)
    }
}
