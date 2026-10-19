import Foundation
import CoreFoundation

enum WorkspacePolicy {
    static let defaultsKey = "workspaceLayoutV1"
    static let appearanceDefaultsKey = "workspaceAppearanceV1"
    static func appearance(_ raw: Any?) throws -> String {
        guard let value = raw as? String, ["system", "light", "dark"].contains(value) else {
            throw ReaderError.message("请选择跟随系统、日间或夜间外观。")
        }
        return value
    }
    static func savedAppearance(_ defaults: UserDefaults = .standard) -> String {
        (try? appearance(defaults.string(forKey: appearanceDefaultsKey))) ?? "system"
    }
    static func layout(_ raw: [String: Any]) throws -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, bounds) in [("sidebarWidth", 188.0...380.0), ("inspectorWidth", 280.0...620.0)] {
            guard let value = raw[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else {
                throw ReaderError.message("区域宽度无效，请重新调整。")
            }
            result[key] = min(bounds.upperBound, max(bounds.lowerBound, value.doubleValue))
        }
        for key in ["sidebarCollapsed", "inspectorCollapsed"] {
            guard let value = raw[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
                throw ReaderError.message("区域显示设置无效。")
            }
            result[key] = value.boolValue
        }
        return result
    }
    static func importDirectory(base: URL, accountId: String) throws -> URL {
        guard !accountId.isEmpty else { throw ReaderError.message("请先登录微博，再添加本地资料。") }
        return base.appendingPathComponent("本地资料", isDirectory: true)
            .appendingPathComponent(MediaPolicy.cacheKey(accountId: accountId, url: "local-imports"), isDirectory: true)
    }
    static func importedFile(path: String, base: URL, accountId: String) throws -> URL {
        let folder = try importDirectory(base: base, accountId: accountId).resolvingSymlinksInPath().standardizedFileURL
        let file = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(folder.path + "/") else { throw ReaderError.message("这份资料不在当前账号的本地附件文件夹中。") }
        try MediaPolicy.validateCompletedFile(file)
        return file
    }
}
