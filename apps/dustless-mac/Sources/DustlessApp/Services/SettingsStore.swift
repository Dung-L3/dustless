import Foundation

final class SettingsStore {
    private let file: URL?
    private var values: [String: Any] = [:]

    init() {
        #if DUSTLESS_UI_TESTING
        guard let path = ProcessInfo.processInfo.environment["DUSTLESS_PREFS_FILE"], !path.isEmpty else {
            fatalError("DUSTLESS_PREFS_FILE is required in the UI-test app")
        }
        file = URL(fileURLWithPath: path)
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           let dictionary = plist as? [String: Any] {
            values = dictionary
        }
        #else
        file = nil
        #endif
    }

    func string(_ key: String) -> String? {
        if file != nil { return values[key] as? String }
        return UserDefaults.standard.string(forKey: key)
    }

    func object(_ key: String) -> Any? {
        if file != nil { return values[key] }
        return UserDefaults.standard.object(forKey: key)
    }

    func set(_ value: Any?, forKey key: String) {
        if let file {
            if let value {
                values[key] = value
            } else {
                values.removeValue(forKey: key)
            }
            persist(file)
        } else {
            UserDefaults.standard.set(value, forKey: key)
        }
    }

    private func persist(_ file: URL) {
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: values,
            format: .xml,
            options: 0
        ) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
