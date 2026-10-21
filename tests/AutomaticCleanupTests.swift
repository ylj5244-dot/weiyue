import Foundation
@main struct AutomaticCleanupTests {
 static func main() throws {
  let fm=FileManager.default,root=fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("retention-transaction-"+UUID().uuidString)
  defer {try? fm.removeItem(at:root)}
  let media=root.appendingPathComponent("附件"),recovery=root.appendingPathComponent("清理记录")
  try fm.createDirectory(at:media,withIntermediateDirectories:true)
  let store=try StateStore(directory:root),cleaner=CacheCleaner(directory:media,recoveryDirectory:recovery)
  let account="fixture",remote="https://wx1.sinaimg.cn/expired.png",folder=media.appendingPathComponent(MediaPolicy.cacheKey(accountId:account,url:remote))
  try fm.createDirectory(at:folder,withIntermediateDirectories:true)
  let file=try MediaPolicy.payloadURL(in:folder,name:"expired.png")
  try fm.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
  try Data(repeating:65,count:4096).write(to:file)
  try JSONSerialization.data(withJSONObject:["name":"expired.png","mime":"image/png"]).write(to:folder.appendingPathComponent("asset.json"))
  var state=StateStore.empty(accountId:account)
  state["revision"]=1
  state["settings"]=["baseURL":"","model":"","autoCleanup":["enabled":true,"retentionDays":2]]
  state["messages"]=[["accountId":account,"groupId":"g","id":"old","sentAt":"2026-10-01T00:00:00Z","senderId":"u","senderName":"Test","text":"old","attachments":[["type":"image","url":remote,"name":"expired.png"]]]]
  state["groups"]=[["accountId":account,"id":"g","name":"Group","selected":true]]
  try store.save(state:state,accountId:account)
  let now=ISO8601DateFormatter().date(from:"2026-10-21T12:00:00Z")!
  let result=try AutomaticCleanup.run(store:store,cleaner:cleaner,accountId:account,revision:1,protectedMessages:[],now:now)
  let saved=result["state"] as! [String:Any]
  precondition((saved["messages"] as! [[String:Any]]).isEmpty)
  precondition(!fm.fileExists(atPath:folder.path))
  precondition(!fm.fileExists(atPath:recovery.path),"Automatic cleanup must not create growing undo snapshots")
  let auto=(saved["settings"] as! [String:Any])["autoCleanup"] as! [String:Any]
  precondition(auto["lastFreedBytes"] as! Int64 > 0)
  precondition(((saved["cleanup"] as! [String:Any])["autoPendingAssets"] as! [[String:Any]]).isEmpty)
  let reloaded=try StateStore(directory:root).load(accountId:account).state
  precondition(reloaded["revision"] as! Int == saved["revision"] as! Int)
  do {_ = try AutomaticCleanup.run(store:store,cleaner:cleaner,accountId:account,revision:1,protectedMessages:[],now:now);fatalError("stale accepted")}catch{}
  // Interrupted downloads with no manifest still consume bytes and must not
  // lose their last retry reference without removing the account-bound folder.
  try fm.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
  try Data(repeating:66,count:8192).write(to:file)
  let orphan=cleaner.removeExpiredRemote(accountId:account,refs:[["kind":"image","url":remote]])
  precondition(orphan.pending.isEmpty && orphan.bytes>0 && !fm.fileExists(atPath:folder.path))
  let external=root.appendingPathComponent("external");try Data("preserve".utf8).write(to:external)
  try fm.createDirectory(at:folder,withIntermediateDirectories:true)
  try fm.createSymbolicLink(at:folder.appendingPathComponent("escape"),withDestinationURL:external)
  let blocked=cleaner.removeExpiredRemote(accountId:account,refs:[["kind":"image","url":remote]])
  precondition(blocked.pending.count==1 && !blocked.warnings.isEmpty && fm.fileExists(atPath:external.path))
  print("PASS: automatic cleanup commits before file removal, compacts backup, releases bytes and rejects stale revisions")
 }
}
