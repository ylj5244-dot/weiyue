import Foundation

func check(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
@main struct StorageUsageTests {
static func main() throws {
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("weiyue-usage-" + UUID().uuidString)
try fm.createDirectory(at: root.appendingPathComponent("附件/cache"), withIntermediateDirectories: true)
try fm.createDirectory(at: root.appendingPathComponent("清理记录/receipt"), withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
for (path, count) in [("account-demo.json", 200), ("account-demo.json.backup", 100), ("附件/cache/image.png", 400), ("清理记录/receipt/before.json", 300), ("other.txt", 50)] {
    try Data(repeating: 65, count: count).write(to: root.appendingPathComponent(path))
}
try fm.createSymbolicLink(at: root.appendingPathComponent("outside"), withDestinationURL: fm.temporaryDirectory)
let usage = try StorageUsage.scan(directory: root)
check(usage["logicalBytes"] as? Int64 == 1050, "Logical file size should count every real file once")
check(usage["fileCount"] as? Int == 5, "Symlinks must not be traversed")
check(usage["skippedSymlinks"] as? Int == 1, "Skipped link must be reported")
let categories = usage["categories"] as! [[String: Any]]
check(categories.first { $0["id"] as? String == "attachments" }?["logicalBytes"] as? Int64 == 400, "Attachment accounting")
check(categories.first { $0["id"] as? String == "recovery" }?["logicalBytes"] as? Int64 == 400, "Backups and cleanup recovery accounting")
check(categories.reduce(Int64(0)) { $0 + ($1["bytes"] as! Int64) } == usage["totalBytes"] as? Int64, "Category sum")
do { _ = try StorageUsage.scan(directory: root.appendingPathComponent("outside")); fatalError("Root link must reject") } catch { }
print("Storage usage tests passed")

}
}
