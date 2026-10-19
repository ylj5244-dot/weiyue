import Foundation
@main struct MediaTests {
 static func main() throws {
  let official = try MediaPolicy.remoteURL("https://upload.api.weibo.com/2/mss/msget?fid=123"); precondition(official.host == "upload.api.weibo.com")
  let upgraded = try MediaPolicy.remoteURL("http://wx1.sinaimg.cn/large/a.jpg"); precondition(upgraded.scheme == "https")
  for value in ["file:///etc/passwd","javascript:alert(1)","https://localhost/a","http://127.0.0.1/a","https://weibo.com.evil.com/a","https://user:pass@weibo.com/a"] {
   do {_ = try MediaPolicy.remoteURL(value); fatalError("unsafe URL accepted") } catch {}
  }
  precondition(MediaPolicy.cacheKey(accountId:"a",url:"https://weibo.com/a") != MediaPolicy.cacheKey(accountId:"b",url:"https://weibo.com/a"))
  precondition(!MediaPolicy.filename("../../secret.pdf",mime:"application/pdf").contains("/"))
  precondition(MediaPolicy.filename("download",mime:"application/pdf").hasSuffix(".pdf"))
  precondition(MediaPolicy.filename("malware.app",mime:"application/octet-stream").hasSuffix(".download"))
  precondition(MediaPolicy.allowsRedirect(to:URL(string:"https://wx1.sinaimg.cn/a.jpg")))
  precondition(!MediaPolicy.allowsRedirect(to:URL(string:"http://wx1.sinaimg.cn/a.jpg")))
  precondition(!MediaPolicy.allowsRedirect(to:URL(string:"https://weibo.com.evil.com/a.jpg")))
  precondition(!MediaPolicy.allowsRedirect(to:nil))

  let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
  defer {try? FileManager.default.removeItem(at:folder)}
  let payload=try MediaPolicy.payloadURL(in:folder,name:"asset.json")
  precondition(payload.path == folder.appendingPathComponent("payload/asset.json").path)
  try FileManager.default.createDirectory(at:payload.deletingLastPathComponent(),withIntermediateDirectories:true)
  let original=Data("original attachment".utf8)
  try original.write(to:payload)
  try Data("manifest".utf8).write(to:folder.appendingPathComponent("asset.json"))
  let retained=try Data(contentsOf:payload);precondition(retained == original)
  try MediaPolicy.validateCompletedFile(payload)
  for name in ["../asset.json",".","..","", "a/b"] {
   do {_=try MediaPolicy.payloadURL(in:folder,name:name);fatalError("unsafe payload name accepted")} catch {}
  }
  // Sparse files exercise the final size limit without allocating 200 MB of memory.
  let handle=try FileHandle(forWritingTo:payload)
  try handle.truncate(atOffset:UInt64(MediaPolicy.maximumDownloadBytes + 1));try handle.close()
  do {try MediaPolicy.validateCompletedFile(payload);fatalError("oversized download accepted")} catch {}

  var jobs:[String:MediaCompletionGroup<Int>]=[:]
  let group=MediaCompletionGroup<Int>();jobs["asset"]=group
  var cancelled=0
  for _ in 0..<2 {group.append {result in if case .failure = result {cancelled += 1} else {fatalError("cancelled callback received success")}}}
  let active=Array(jobs.values);jobs.removeAll()
  active.forEach {$0.resolve(.failure(URLError(.cancelled)))}
  group.resolve(.success(1)) // A late download completion must not call anyone twice.
  precondition(cancelled == 2)
  group.append {result in if case .failure = result {cancelled += 1}}
  precondition(cancelled == 3)
  print("PASS: media origins, HTTPS redirects, payload/manifest isolation, final size limit and cancellation callbacks")
 }
}
