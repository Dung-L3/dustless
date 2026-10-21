import Foundation

public enum EngineContract {
    public static let currentSchemaVersion = 2
    public static let currentMajorVersion = currentSchemaVersion / 10

    public static func isSupported(_ version: Int) -> Bool {
        version / 10 == currentMajorVersion
    }
}
