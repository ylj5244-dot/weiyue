import Foundation
import AppKit
import CoreText
import CryptoKit

// Workspace appearance is separate from account archives and OS font installation.
final class ReadingAppearanceStore {
    static let defaultPreferences: [String: Any] = ["density": 3, "consecutiveSpacing": "follow", "skinId": "default", "fontChoice": "system"]
    static let colorKeys: Set<String> = ["background", "panel", "sidebar", "text", "secondary", "accent", "line", "soft"]
    // The original skin continues to use the application's CSS. Other built-ins
    // share the imported skin schema, but never occupy imported-file slots.
    static let builtInSkins: [[String: Any]] = [
        ["id": "default", "name": "微阅原生"],
        ["id": "paper-green", "format": "weiyue-skin", "version": 1, "name": "纸页 · 青绿",
         "light": ["background": "#edece4", "panel": "#fffdf6", "sidebar": "#e8ece4", "text": "#263a32", "secondary": "#66766b", "accent": "#277860", "line": "#d4ded3", "soft": "#f1f4e9"],
         "dark": ["background": "#19251f", "panel": "#222f28", "sidebar": "#1d2a23", "text": "#e0e9dd", "secondary": "#a7b8a9", "accent": "#79c9a3", "line": "#405648", "soft": "#2a3b30"]],
        ["id": "claude-code", "format": "weiyue-skin", "version": 1, "name": "Claude Code 风格",
         "light": ["background": "#f7f4ee", "panel": "#fffcf7", "sidebar": "#eee8df", "text": "#302b27", "secondary": "#766b60", "accent": "#b55335", "line": "#ddd4c8", "soft": "#f1e9dd"],
         "dark": ["background": "#191816", "panel": "#24211e", "sidebar": "#201d1a", "text": "#eee6db", "secondary": "#b4a99d", "accent": "#d98b69", "line": "#494038", "soft": "#302a24"]]
    ]
    let directory: URL
    let systemFonts: [String]
    private let fm = FileManager.default
    init(directory: URL, systemFonts: [String]? = nil) throws {
        self.directory = directory
        self.systemFonts = (systemFonts ?? NSFontManager.shared.availableFontFamilies).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in ["skins", "fonts"] { try fm.createDirectory(at: directory.appendingPathComponent(name), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
    }
    static func fontName(_ raw: Any?) throws -> String {
        guard let value = raw as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.count <= 120,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || "\"'\\;{}<>():,".unicodeScalars.contains($0) }) else { throw ReaderError.message("字体名称无效。") }
        return value
    }
    static func skin(_ raw: Any) throws -> [String: Any] {
        guard let value = raw as? [String: Any], Set(value.keys).isSubset(of: ["format", "version", "name", "fontFamily", "light", "dark"]),
              value["format"] as? String == "weiyue-skin", let version = value["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1,
              let name = value["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80,
              value["light"] != nil, value["dark"] != nil else { throw ReaderError.message("不是有效的微阅皮肤文件，请使用版本 1 的 JSON 样例。") }
        var result: [String: Any] = ["format": "weiyue-skin", "version": 1, "name": name]
        for mode in ["light", "dark"] {
            guard let colors = value[mode] as? [String: Any], Set(colors.keys).isSubset(of: colorKeys) else { throw ReaderError.message("皮肤配色字段不受支持。") }
            var checked: [String: String] = [:]
            for (key, rawColor) in colors {
                guard let color = rawColor as? String, color.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil else { throw ReaderError.message("皮肤颜色必须是 #RRGGBB 格式。") }
                checked[key] = color
            }
            result[mode] = checked
        }
        if let family = value["fontFamily"] { result["fontFamily"] = try fontName(family) }
        return result
    }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func validID(_ id: String) -> Bool { id.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }
    private func read(_ file: URL, maximum: Int) throws -> Data {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size > 0, size <= maximum else { throw ReaderError.message("文件类型或大小不符合要求。皮肤限 64 KB，字体限 32 MB。") }
        let data = try Data(contentsOf: file)
        guard data.count <= maximum else { throw ReaderError.message("文件超过大小限制。") }
        return data
    }
    private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]) }
    private func files(_ folder: String) -> [URL] { ((try? fm.contentsOfDirectory(at: directory.appendingPathComponent(folder), includingPropertiesForKeys: nil)) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent } }
    func skins() -> [[String: Any]] {
        files("skins").filter { $0.pathExtension == "json" }.prefix(64).compactMap { file in
            let id = file.deletingPathExtension().lastPathComponent
            guard validID(id), let data = try? read(file, maximum: 65536), let object = try? JSONSerialization.jsonObject(with: data), var skin = try? Self.skin(object) else { return nil }
            skin["id"] = id; return skin
        }
    }
    func fonts() -> [[String: Any]] {
        files("fonts").filter { $0.pathExtension == "json" }.prefix(32).compactMap { file in
            let id = file.deletingPathExtension().lastPathComponent
            guard validID(id), let data = try? read(file, maximum: 4096), let item = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  item["id"] as? String == id, let name = item["name"] as? String, name.count <= 250,
                  let family = try? Self.fontName(item["family"]), let ext = item["extension"] as? String, ["ttf", "otf"].contains(ext),
                  fm.fileExists(atPath: directory.appendingPathComponent("fonts/\(id).\(ext)").path) else { return nil }
            return ["id": id, "name": name, "family": family, "extension": ext]
        }
    }
    func validatePreferences(_ raw: [String: Any]) throws -> [String: Any] {
        guard let density = raw["density"] as? NSNumber, CFGetTypeID(density) != CFBooleanGetTypeID(), density.doubleValue.rounded() == density.doubleValue, (1...5).contains(density.intValue),
              let skinID = raw["skinId"] as? String, Self.builtInSkins.contains(where: { $0["id"] as? String == skinID }) || skins().contains(where: { $0["id"] as? String == skinID }),
              let choice = raw["fontChoice"] as? String else { throw ReaderError.message("阅读设置无效，请重新选择密度、皮肤和字体。") }
        let spacing: Any
        if raw["consecutiveSpacing"] == nil || raw["consecutiveSpacing"] as? String == "follow" {
            spacing = "follow"
        } else if let level = raw["consecutiveSpacing"] as? NSNumber, CFGetTypeID(level) != CFBooleanGetTypeID(), level.doubleValue.rounded() == level.doubleValue, (1...5).contains(level.intValue) {
            spacing = level.intValue
        } else { throw ReaderError.message("连续消息间距无效，请选择跟随阅读密度或五档间距。") }
        let validFont = choice == "system" || choice.hasPrefix("family:") && systemFonts.contains(String(choice.dropFirst(7))) || choice.hasPrefix("import:") && fonts().contains { $0["id"] as? String == String(choice.dropFirst(7)) }
        guard validFont else { throw ReaderError.message("所选字体不可用，请重新选择或导入字体文件。") }
        return ["density": density.intValue, "consecutiveSpacing": spacing, "skinId": skinID, "fontChoice": choice]
    }
    private func readPreferences() throws -> [String: Any] {
        let file = directory.appendingPathComponent("preferences.json")
        if !fm.fileExists(atPath: file.path) { return Self.defaultPreferences }
        guard let raw = try JSONSerialization.jsonObject(with: read(file, maximum: 8192)) as? [String: Any] else { throw ReaderError.message("阅读设置格式无效。") }
        return try validatePreferences(raw)
    }
    func snapshot() -> [String: Any] {
        var warning = "", preferences = Self.defaultPreferences
        do { preferences = try readPreferences() } catch { warning = "阅读外观设置未能载入，暂用默认外观：" + error.localizedDescription }
        var result: [String: Any] = ["preferences": preferences, "builtInSkins": Self.builtInSkins, "skins": skins(), "fonts": fonts(), "systemFonts": systemFonts]
        if let choice = preferences["fontChoice"] as? String, choice.hasPrefix("import:") {
            let id = String(choice.dropFirst(7))
            do {
                guard let font = fonts().first(where: { $0["id"] as? String == id }), let ext = font["extension"] as? String else { throw ReaderError.message("字体文件不存在。") }
                let data = try read(directory.appendingPathComponent("fonts/\(id).\(ext)"), maximum: 32 * 1024 * 1024)
                guard hash(data) == id else { throw ReaderError.message("字体文件校验失败，请重新导入。") }
                result["fontData"] = ["id": id, "base64": data.base64EncodedString()]
            } catch { preferences["fontChoice"] = "system"; result["preferences"] = preferences; warning = error.localizedDescription }
        }
        result["warning"] = warning; return result
    }
    @discardableResult func save(_ preferences: [String: Any]) throws -> [String: Any] {
        let value = try validatePreferences(preferences)
        try json(value).write(to: directory.appendingPathComponent("preferences.json"), options: .atomic)
        return snapshot()
    }
    func importSkin(_ file: URL) throws -> [String: Any] {
        guard file.pathExtension.lowercased() == "json" else { throw ReaderError.message("请选择微阅皮肤 JSON 文件。") }
        let skin = try Self.skin(JSONSerialization.jsonObject(with: read(file, maximum: 65536)))
        let data = try json(skin), id = hash(data), target = directory.appendingPathComponent("skins/\(id).json")
        guard fm.fileExists(atPath: target.path) || skins().count < 64 else { throw ReaderError.message("最多可导入 64 个皮肤。") }
        try data.write(to: target, options: .atomic)
        var preferences = (snapshot()["preferences"] as? [String: Any]) ?? Self.defaultPreferences
        preferences["skinId"] = id
        return try save(preferences)
    }
    func importFont(_ file: URL) throws -> [String: Any] {
        let ext = file.pathExtension.lowercased()
        guard ["ttf", "otf"].contains(ext) else { throw ReaderError.message("请选择 TTF 或 OTF 字体文件。") }
        let data = try read(file, maximum: 32 * 1024 * 1024), signature = Array(data.prefix(4))
        guard [[0,1,0,0], Array("OTTO".utf8), Array("true".utf8)].contains(signature),
              let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor], let descriptor = descriptors.first,
              let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String else { throw ReaderError.message("未识别到有效的 TTF／OTF 字体，原设置已保留。") }
        _ = try Self.fontName(family)
        let id = hash(data), target = directory.appendingPathComponent("fonts/\(id).\(ext)")
        guard fm.fileExists(atPath: target.path) || fonts().count < 32 else { throw ReaderError.message("最多可导入 32 个字体文件。") }
        try data.write(to: target, options: .atomic)
        try json(["id": id, "name": String(file.lastPathComponent.prefix(250)), "family": family, "extension": ext]).write(to: directory.appendingPathComponent("fonts/\(id).json"), options: .atomic)
        var preferences = (snapshot()["preferences"] as? [String: Any]) ?? Self.defaultPreferences
        preferences["fontChoice"] = "import:" + id
        return try save(preferences)
    }
}
