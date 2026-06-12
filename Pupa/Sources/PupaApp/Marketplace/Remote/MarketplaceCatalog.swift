import Foundation

/// The remote `index.json` — a flat list of installable apps. Its own
/// `formatVersion` is gated independently of the bundle format (hard-reject a
/// newer catalog, same rule as `MyAppBundle`). Carries integrity + display
/// metadata per entry; the actual bundle is fetched on demand.
public struct MarketplaceCatalog: Codable, Hashable, Sendable {
    public let formatVersion: Int
    public let entries: [Entry]

    public static let currentFormatVersion = 1

    public init(formatVersion: Int = currentFormatVersion, entries: [Entry]) {
        self.formatVersion = formatVersion
        self.entries = entries
    }

    public struct Entry: Codable, Identifiable, Hashable, Sendable {
        /// Stable catalog id (independent of the bundle's reassigned app id).
        public let id: String
        public let name: String
        public let author: String?
        public let summary: String?
        public let icon: String?
        public let tags: [String]?
        /// `MyAppBundle.formatVersion` the bundle was exported with — lets the
        /// browser grey out apps this build can't import, before download.
        public let appFormatVersion: Int
        /// Catalog-relative path to the `.pupaapp` bundle.
        public let path: String
        /// Expected byte size — checked before download as a DoS pre-filter.
        public let sizeBytes: Int
        /// Expected SHA-256 (hex) of the bundle bytes — verified post-download.
        public let sha256: String

        public init(
            id: String, name: String, author: String? = nil, summary: String? = nil,
            icon: String? = nil, tags: [String]? = nil, appFormatVersion: Int,
            path: String, sizeBytes: Int, sha256: String
        ) {
            self.id = id; self.name = name; self.author = author; self.summary = summary
            self.icon = icon; self.tags = tags; self.appFormatVersion = appFormatVersion
            self.path = path; self.sizeBytes = sizeBytes; self.sha256 = sha256
        }

        /// This build can import the bundle's format.
        public var isCompatible: Bool { appFormatVersion <= MyAppBundle.currentFormatVersion }

        /// SF Symbol for the row, mapped from the component-kind hint. Falls
        /// back to a generic box for unknown/missing icons.
        public var displaySymbol: String {
            switch icon {
            case "tracker": return "list.bullet.rectangle"
            case "calendar": return "calendar"
            case "checklist": return "checklist"
            case "slack": return "bubble.left.and.bubble.right"
            case "calculator": return "function"
            case "chart": return "chart.bar"
            default: return "shippingbox"
            }
        }
    }

    public static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
