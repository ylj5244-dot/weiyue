import Foundation

func check(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
@main struct RetentionPolicyTests {
static func main() throws {
let now = ISO8601DateFormatter().date(from: "2026-10-21T12:00:00Z")!
func message(_ id: String, _ date: String = "2026-10-17T10:00:00Z", url: String? = nil) -> [String: Any] {
    var value: [String: Any] = ["accountId":"a", "id":id, "groupId":"g", "senderId":"u", "senderName":"合成成员", "sentAt":date, "text":"合成消息", "attachments": [[String:Any]]()]
    if let url { value["attachments"] = [["type":"image", "url":url, "name":"image.png"]] }
    return value
}
func fixture() -> [String: Any] {
    var value = StateStore.empty(accountId: "a")
    value["revision"] = 8
    value["settings"] = ["baseURL":"", "model":"", "autoCleanup":["enabled":true, "retentionDays":3]] as [String:Any]
    value["groups"] = [["accountId":"a", "id":"g", "name":"测试群", "selected":true]]
    return value
}
var state = fixture()
state["messages"] = [message("old", url:"https://wx1.sinaimg.cn/old.png"), message("boundary", "2026-10-18T12:00:00Z"), message("new", "2026-10-21T11:00:00Z"), message("future", "2026-10-23T12:00:00Z"), message("unknown", "bad")]
let plan = try RetentionPolicy.plan(state: state, now: now)
check(plan.removedCount == 1, "Only strictly older records should expire")
check(plan.refs.count == 1, "Expired cached image should be eligible")
check((plan.state["messages"] as! [[String:Any]]).count == 4, "Boundary, future and malformed time preserved")
check((state["messages"] as! [[String:Any]]).count == 5, "Original state unchanged")
check(plan.state["revision"] as? Int == 9, "Monotonic revision")
check((plan.state["cleanup"] as! [String:Any])["autoCutoffAt"] as? String == "2026-10-18T12:00:00.000Z", "Watermark prevents refill")

let shared = "https://wx1.sinaimg.cn/shared.png"
state = fixture()
state["messages"] = [message("book",url:shared),message("collection"),message("discussion"),message("anchor"),message("draft"),message("shared",url:shared),message("imported")]
var imported = message("imported");imported["localPath"] = "/not-a-cache/file.pdf"
var messages = state["messages"] as! [[String:Any]]; messages[messages.count-1] = imported;state["messages"] = messages
state["bookmarks"] = [["groupId":"g", "messageId":"book", "snapshot":message("book",url:shared), "deletedAt":"2026-10-20T10:00:00Z"]]
state["collections"] = [["messageIds":["g:collection"], "messages":[message("collection")]]]
state["discussions"] = [["contextSnapshots":[message("discussion")]]]
state["progress"] = ["g":["manual":["messageId":"anchor"]]]
let protected = try RetentionPolicy.plan(state:state, protectedMessages:[message("draft")], now:now)
check(protected.removedCount == 1, "All references, drafts and imported files protected")
check(protected.refs.isEmpty, "Shared file used by bookmark must survive")
check(protected.protectedCount == 5, "Five referenced records protected")

state = fixture(); state["messages"] = [message("old",url:shared), message("recent","2026-10-20T10:00:00Z",url:shared)]
check(try RetentionPolicy.plan(state:state,now:now).refs.isEmpty, "Recent message protects shared cache")
let cleanup:[String:Any] = ["autoPendingAssets":[["kind":"image","url":shared]],"autoCutoffAt":"2026-10-19T12:00:00Z"]
state["cleanup"] = cleanup
let retry = try RetentionPolicy.plan(state:state,now:now)
check(retry.refs.isEmpty,"New reference protects a pending delete")
check((retry.state["cleanup"] as! [String:Any])["autoCutoffAt"] as? String == "2026-10-19T12:00:00.000Z", "Watermark cannot go backward")
for days in [0,5,-1] {
    state=fixture(); state["settings"]=["autoCleanup":["enabled":true,"retentionDays":days]]
    do { _ = try RetentionPolicy.plan(state:state,now:now);fatalError("Invalid retention days") } catch { }
}
state=fixture();state["settings"]=["autoCleanup":["enabled":false,"retentionDays":3]]
do { _ = try RetentionPolicy.plan(state:state,now:now);fatalError("Disabled cleanup ran") } catch { }
state=fixture();state["messages"]=[message("edge","2026-10-18T12:00:00.400Z"),message("keep","2026-10-18T12:00:00.500Z")]
let subsecond=try RetentionPolicy.plan(state:state,now:now.addingTimeInterval(0.5009))
check(subsecond.removedCount==1,"Millisecond boundary preserves equality")
check((subsecond.state["cleanup"] as! [String:Any])["autoCutoffAt"] as? String == "2026-10-18T12:00:00.500Z","Serialized watermark matches deletion precision")
print("Retention policy tests passed")

}
}
