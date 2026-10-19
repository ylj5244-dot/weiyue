import Foundation
import AppKit

@main struct ReadingAppearanceTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("weiyue-appearance-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ReadingAppearanceStore(directory: root.appendingPathComponent("settings"), systemFonts: ["PingFang SC", "Arial"])
        func prefs(_ result: [String: Any]) -> [String: Any] { result["preferences"] as! [String: Any] }
        func rejects(_ run: () throws -> Void) { do { try run(); fatalError("invalid input accepted") } catch {} }
        precondition(prefs(store.snapshot())["density"] as? Int == 3)
        precondition(prefs(store.snapshot())["consecutiveSpacing"] as? String == "follow", "old settings must default to follow density")
        let builtIns = store.snapshot()["builtInSkins"] as! [[String: Any]]
        precondition(builtIns.compactMap { $0["id"] as? String } == ["default", "paper-green", "claude-code"])
        precondition(store.skins().isEmpty, "built-ins must not consume imported skin slots")
        let legacy: [String: Any] = ["density": 4, "skinId": "default", "fontChoice": "family:Arial"]
        try JSONSerialization.data(withJSONObject: legacy).write(to: store.directory.appendingPathComponent("preferences.json"))
        let migrated = prefs(store.snapshot())
        precondition(migrated["density"] as? Int == 4 && migrated["fontChoice"] as? String == "family:Arial")
        precondition(migrated["consecutiveSpacing"] as? String == "follow")
        for level in 1...5 {
            let saved = try store.save(["density": 3, "consecutiveSpacing": level, "skinId": "default", "fontChoice": "family:Arial"])
            precondition(prefs(saved)["consecutiveSpacing"] as? Int == level)
        }
        for invalid: Any in [0, 6, 2.5, true, "3", "automatic", NSNull()] { rejects { _ = try store.save(["density": 3, "consecutiveSpacing": invalid, "skinId": "default", "fontChoice": "system"]) } }
        for id in ["default", "paper-green", "claude-code"] {
            let saved = try store.save(["density": 3, "consecutiveSpacing": 4, "skinId": id, "fontChoice": "family:Arial"])
            precondition(prefs(saved)["skinId"] as? String == id && prefs(saved)["fontChoice"] as? String == "family:Arial")
        }
        for level in 1...5 { _ = try store.save(["density": level, "skinId": "default", "fontChoice": "system"]) }
        for invalid: Any in [0, 6, 2.5, true, "3"] { rejects { _ = try store.save(["density": invalid, "skinId": "default", "fontChoice": "system"]) } }
        rejects { _ = try store.save(["density": 3, "skinId": "../other", "fontChoice": "system"]) }
        rejects { _ = try store.save(["density": 3, "skinId": "default", "fontChoice": "family:unknown"]) }
        let sample = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/ui/skin-example.weiyue-skin.json")
        let sampleSkin = try JSONSerialization.jsonObject(with: Data(contentsOf: sample)) as! [String: Any]
        let green = builtIns.first { $0["id"] as? String == "paper-green" }!
        for mode in ["light", "dark"] {
            precondition(NSDictionary(dictionary: green[mode] as! [String: String]).isEqual(to: sampleSkin[mode] as! [String: String]), "green skin must retain the exact previous palette")
            for skin in builtIns.dropFirst() { precondition(Set((skin[mode] as! [String: String]).keys) == ReadingAppearanceStore.colorKeys) }
        }
        _ = try store.save(["density": 5, "consecutiveSpacing": 5, "skinId": "claude-code", "fontChoice": "family:Arial"])
        let skinResult = try store.importSkin(sample), skinID = prefs(skinResult)["skinId"] as! String
        precondition(skinID.count == 64 && prefs(skinResult)["fontChoice"] as? String == "family:Arial", "skin import preserves the selected font")
        precondition(prefs(skinResult)["consecutiveSpacing"] as? Int == 5)
        _ = try store.importSkin(sample); precondition(store.skins().count == 1)
        let before = try Data(contentsOf: root.appendingPathComponent("settings/preferences.json"))
        let bad = root.appendingPathComponent("bad.json")
        for content in ["not json", "{\"format\":\"weiyue-skin\",\"version\":1,\"name\":\"bad\",\"light\":{\"panel\":\"url(https://bad.invalid)\"},\"dark\":{}}", "{\"format\":\"weiyue-skin\",\"version\":true,\"name\":\"bad\",\"light\":{},\"dark\":{}}"] {
            try Data(content.utf8).write(to: bad); rejects { _ = try store.importSkin(bad) }
            let unchanged = try Data(contentsOf: root.appendingPathComponent("settings/preferences.json")); precondition(unchanged == before)
        }
        try Data(repeating: 32, count: 65537).write(to: bad); rejects { _ = try store.importSkin(bad) }
        let fake = root.appendingPathComponent("fake.ttf"); try Data("not a font".utf8).write(to: fake); rejects { _ = try store.importFont(fake) }
        let source = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Arial.ttf")
        precondition(FileManager.default.fileExists(atPath: source.path), "local font fixture unavailable")
        let result = try store.importFont(source), choice = prefs(result)["fontChoice"] as! String
        precondition(choice.hasPrefix("import:")); precondition((result["fontData"] as? [String: String])?["base64"]?.isEmpty == false)
        _ = try store.importFont(source); precondition(store.fonts().count == 1)
        let reopened = try ReadingAppearanceStore(directory: store.directory, systemFonts: ["PingFang SC", "Arial"])
        precondition(prefs(reopened.snapshot())["fontChoice"] as? String == choice)
        precondition(prefs(reopened.snapshot())["density"] as? Int == 5)
        precondition(prefs(reopened.snapshot())["consecutiveSpacing"] as? Int == 5)
        precondition(prefs(reopened.snapshot())["skinId"] as? String == skinID)
        let afterImportedFontSkin = try reopened.importSkin(sample)
        precondition(prefs(afterImportedFontSkin)["fontChoice"] as? String == choice, "skin import must preserve an imported font")
        _ = try reopened.save(["density": 5, "consecutiveSpacing": 5, "skinId": "claude-code", "fontChoice": choice])
        precondition(prefs(reopened.snapshot())["skinId"] as? String == "claude-code")
        let imported = root.appendingPathComponent("settings/fonts/" + String(choice.dropFirst(7)) + ".ttf")
        try Data("damaged".utf8).write(to: imported)
        precondition(prefs(reopened.snapshot())["fontChoice"] as? String == "system")
        precondition(!(reopened.snapshot()["warning"] as! String).isEmpty)
        let reset = try reopened.save(ReadingAppearanceStore.defaultPreferences); precondition(prefs(reset)["skinId"] as? String == "default")
        precondition(prefs(reset)["consecutiveSpacing"] as? String == "follow")
        precondition(reopened.skins().count == 1, "reset must keep imported assets")
        let otf = try reopened.importFont(URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/STIXGeneralBol.otf"))
        precondition((otf["fonts"] as! [[String: Any]]).contains { $0["extension"] as? String == "otf" })
        precondition((otf["fontData"] as? [String: String])?["base64"]?.isEmpty == false)
        print("PASS: five density and independent spacing levels, legacy migration, three built-in skins, exact green palette, font preservation, skin/TTF/OTF imports, duplicate reuse, relaunch persistence, invalid/oversized inputs, tamper detection and reset")
    }
}
