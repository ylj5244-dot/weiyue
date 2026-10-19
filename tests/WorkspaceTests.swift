import Foundation

@main struct WorkspaceTests {
    static func main() throws {
        let valid: [String: Any] = ["sidebarWidth": 240, "inspectorWidth": 370, "sidebarCollapsed": false, "inspectorCollapsed": true]
        let layout = try WorkspacePolicy.layout(valid)
        precondition(layout["sidebarWidth"] as? Double == 240 && layout["inspectorCollapsed"] as? Bool == true)
        var bounded = valid; bounded["sidebarWidth"] = -40; bounded["inspectorWidth"] = 3000
        let clamped = try WorkspacePolicy.layout(bounded)
        precondition(clamped["sidebarWidth"] as? Double == 188 && clamped["inspectorWidth"] as? Double == 620)
        for bad: Any in [Double.nan, Double.infinity, true, "250"] {
            var value = valid; value["sidebarWidth"] = bad
            do { _ = try WorkspacePolicy.layout(value); fatalError("invalid layout accepted") } catch {}
        }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = try WorkspacePolicy.importDirectory(base: base, accountId: "a")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("sample.txt")
        try Data("fixture".utf8).write(to: file)
        let found = try WorkspacePolicy.importedFile(path: file.path, base: base, accountId: "a")
        precondition(found == file.resolvingSymlinksInPath())
        do { _ = try WorkspacePolicy.importedFile(path: file.path, base: base, accountId: "b"); fatalError("other account accepted") } catch {}
        let outside = base.appendingPathComponent("outside.txt"); try Data("private".utf8).write(to: outside)
        let link = folder.appendingPathComponent("link.txt"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        for path in [outside.path, link.path, folder.path + "/../../outside.txt"] {
            do { _ = try WorkspacePolicy.importedFile(path: path, base: base, accountId: "a"); fatalError("escaped import accepted") } catch {}
        }
        let suite = UserDefaults(suiteName: "weiyue-test-" + UUID().uuidString)!
        suite.set(layout, forKey: WorkspacePolicy.defaultsKey)
        let restored = try WorkspacePolicy.layout(suite.dictionary(forKey: WorkspacePolicy.defaultsKey)!)
        precondition(restored["sidebarWidth"] as? Double == 240)
        precondition(WorkspacePolicy.savedAppearance(suite) == "system")
        for appearance in ["system", "light", "dark"] {
            let validated = try WorkspacePolicy.appearance(appearance)
            precondition(validated == appearance)
            suite.set(validated, forKey: WorkspacePolicy.appearanceDefaultsKey)
            precondition(WorkspacePolicy.savedAppearance(suite) == appearance)
            precondition(suite.dictionary(forKey: WorkspacePolicy.defaultsKey)?["sidebarWidth"] as? Double == 240)
        }
        for invalid: Any in ["", "LIGHT", "night", 1, true] {
            do { _ = try WorkspacePolicy.appearance(invalid); fatalError("invalid appearance accepted") } catch {}
        }
        suite.set("invalid", forKey: WorkspacePolicy.appearanceDefaultsKey)
        precondition(WorkspacePolicy.savedAppearance(suite) == "system")
        suite.removeObject(forKey: WorkspacePolicy.appearanceDefaultsKey)
        suite.removeObject(forKey: WorkspacePolicy.defaultsKey)
        print("PASS: layout and appearance validation/persistence, scoped local imports and symlink isolation")
    }
}
