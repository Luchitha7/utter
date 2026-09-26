import Foundation

/// Installed applications, resolved from spoken names like "chrome" or "the VS Code app".
struct AppCatalog {
    static let defaultDirectories = ["/Applications", "/Applications/Utilities", "/System/Applications",
                                     "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"].map { URL(fileURLWithPath: $0) }
    static let defaultExtras = [URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")]
    static let aliases = [
        "chrome": "google chrome", "vs code": "visual studio code", "vscode": "visual studio code",
        "code": "visual studio code", "settings": "system settings", "system preferences": "system settings",
        "preferences": "system settings", "zoom": "zoom.us", "word": "microsoft word", "outlook": "microsoft outlook",
        "itunes": "music", "apple music": "music",
    ]

    private(set) var apps: [String: URL] = [:]

    init(directories: [URL] = defaultDirectories, extras: [URL] = defaultExtras) {
        let fileManager = FileManager.default
        for directory in directories {
            let entries = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for app in entries.filter({ $0.pathExtension == "app" }).sorted(by: { $0.path < $1.path }) where Self.infoPlist(app) != nil {
                let name = Self.normalize(app.deletingPathExtension().lastPathComponent)
                if apps[name] == nil { apps[name] = app }
            }
        }
        for app in extras where Self.infoPlist(app) != nil {
            let name = Self.normalize(app.deletingPathExtension().lastPathComponent)
            if apps[name] == nil { apps[name] = app }
        }
    }

    func resolve(_ spoken: String) -> URL? {
        var wanted = Self.normalize(spoken)
        wanted = Self.aliases[wanted] ?? wanted
        guard !wanted.isEmpty else { return nil }
        if let exact = apps[wanted] { return exact }
        let shortest = { (names: [String]) in names.min { ($0.count, $0) < ($1.count, $1) }.flatMap { apps[$0] } }
        if let prefixed = shortest(apps.keys.filter { $0.hasPrefix(wanted) }) { return prefixed }
        let word = Pattern(#"\b"# + NSRegularExpression.escapedPattern(for: wanted) + #"\b"#)
        return shortest(apps.keys.filter { word.contains($0) })
    }

    static func bundleID(_ app: URL) -> String {
        guard let plist = infoPlist(app), let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String else { return app.path }
        return identifier
    }

    /// A real app has an Info.plist; iPhone/iPad apps keep theirs inside WrappedBundle. Empty leftovers have none.
    static func infoPlist(_ app: URL) -> URL? {
        for plist in [app.appendingPathComponent("Contents/Info.plist"), app.appendingPathComponent("WrappedBundle/Info.plist")]
        where FileManager.default.fileExists(atPath: plist.path) {
            return plist
        }
        return nil
    }

    static func normalize(_ name: String) -> String {
        var name = name.lowercased().replacingOccurrences(of: ".app", with: "")
        name = name.replacingOccurrences(of: "[^a-z0-9. ]+", with: " ", options: .regularExpression)
        name = name.replacingOccurrences(of: #"\b(?:the|app|application)\b"#, with: " ", options: .regularExpression)
        return name.split(separator: " ").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}
