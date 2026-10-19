import AppKit
import WebKit
import ImageIO
import UniformTypeIdentifiers

struct MediaAsset {
    let file: URL
    let name: String
    let mime: String
}

// Download through the existing official WebView: WebKit uses its own login
// session; no cookie is copied to the reader UI or a separate HTTP client.
final class MediaStore: NSObject, WKURLSchemeHandler {
    private let directory: URL
    private var jobs: [String: MediaDownload] = [:]
    private let previews = NSCache<NSString, NSData>()
    private var generation = 0
    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes:[.posixPermissions:0o700])
        super.init()
        previews.totalCostLimit = 64 * 1024 * 1024
        previews.countLimit = 256
    }
    func reset(completion: (() -> Void)? = nil) {
        generation += 1
        let active = Array(jobs.values); jobs.removeAll(); previews.removeAllObjects()
        let cancellation = DispatchGroup()
        active.forEach { job in
            cancellation.enter()
            job.cancel { cancellation.leave() }
        }
        if let completion { cancellation.notify(queue: .main, execute: completion) }
    }
    func fetch(accountId: String, attachment: [String: Any], using webView: WKWebView,
               completion: @escaping (Result<MediaAsset, Error>) -> Void) {
        do {
            let remote = try MediaPolicy.remoteURL(attachment["url"] as? String ?? "")
            let key = MediaPolicy.cacheKey(accountId: accountId, url: remote.absoluteString)
            let folder = directory.appendingPathComponent(key, isDirectory:true)
            let manifest = folder.appendingPathComponent("asset.json")
            if let data = try? Data(contentsOf: manifest), let info = try? JSONSerialization.jsonObject(with:data) as? [String:String],
               let name = info["name"], let mime = info["mime"],
               let file = try? MediaPolicy.payloadURL(in:folder,name:name),
               (try? MediaPolicy.validateCompletedFile(file)) != nil {
                completion(.success(MediaAsset(file:file,name:name,mime:mime))); return
            }
            if let job = jobs[key] { job.callbacks.append(completion); return }
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let expectedGeneration = generation
            let job = MediaDownload(folder:folder, preferredName:attachment["name"] as? String ?? "") { [weak self] _ in
                guard let self, expectedGeneration == self.generation else { return }
                self.jobs.removeValue(forKey:key)
            }
            job.callbacks.append(completion); jobs[key] = job
            var request = URLRequest(url:remote)
            request.setValue("https://api.weibo.com/", forHTTPHeaderField:"Referer")
            webView.startDownload(using:request) { [weak self, weak job] download in
                guard let self, let job, !job.ended, self.generation == expectedGeneration else { download.cancel { _ in }; return }
                job.download = download; download.delegate = job
            }
        } catch { completion(.failure(error)) }
    }
    func preview(_ asset: MediaAsset) throws -> String {
        guard let source = CGImageSourceCreateWithURL(asset.file as CFURL, [kCGImageSourceShouldCache:false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways:true,
                kCGImageSourceCreateThumbnailWithTransform:true,
                kCGImageSourceThumbnailMaxPixelSize:960,
                kCGImageSourceShouldCacheImmediately:true
              ] as CFDictionary) else {
            throw ReaderError.message("这个附件不是可显示的图片；可以点击打开或下载。")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ReaderError.message("图片预览暂时无法生成。")
        }
        CGImageDestinationAddImage(destination,image,nil)
        guard CGImageDestinationFinalize(destination) else { throw ReaderError.message("图片预览暂时无法生成。") }
        let token = UUID().uuidString; previews.setObject(data,forKey:token as NSString,cost:data.length)
        return "weiyue-media://asset/" + token
    }
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.host == "asset", let cached = previews.object(forKey:url.lastPathComponent as NSString) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let data = cached as Data
        urlSchemeTask.didReceive(URLResponse(url:url,mimeType:"image/png",expectedContentLength:data.count,textEncodingName:nil))
        urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

private final class MediaDownload: NSObject, WKDownloadDelegate {
    let folder: URL
    let preferredName: String
    let completion: (Result<MediaAsset,Error>) -> Void
    let callbacks = MediaCompletionGroup<MediaAsset>()
    var download: WKDownload?
    var destination: URL?
    var mime = "application/octet-stream"
    var ended = false
    init(folder:URL,preferredName:String,completion:@escaping(Result<MediaAsset,Error>)->Void) {
        self.folder=folder;self.preferredName=preferredName;self.completion=completion
    }
    func finish(_ result: Result<MediaAsset,Error>) { guard !ended else{return};ended=true;completion(result);callbacks.resolve(result) }
    func cancel(completion: @escaping () -> Void = {}) {
        // The caller may move cache folders only after WebKit has stopped writing.
        if let download { download.cancel { _ in completion() } }
        else { completion() }
        finish(.failure(URLError(.cancelled)))
    }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping(URL?)->Void) {
        guard !ended else {completionHandler(nil);return}
        if let http=response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            completionHandler(nil);finish(.failure(ReaderError.message("微博附件返回 \(http.statusCode)，请刷新登录或在官方聊天重试。")));return
        }
        guard response.expectedContentLength <= MediaPolicy.maximumDownloadBytes else { completionHandler(nil);finish(.failure(ReaderError.message("附件超过 200 MB，请使用官方聊天下载。")));return }
        mime=response.mimeType ?? mime
        guard mime != "text/html" && mime != "application/json" else { completionHandler(nil);finish(.failure(ReaderError.message("微博未返回附件内容，登录可能已过期，请在官方聊天重试。")));return }
        let name=MediaPolicy.filename(preferredName.isEmpty ? suggestedFilename : preferredName,mime:mime)
        do {
            let target=try MediaPolicy.payloadURL(in:folder,name:name)
            try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            if FileManager.default.fileExists(atPath:target.path) { try FileManager.default.removeItem(at:target) }
            destination=target;completionHandler(target)
        } catch {completionHandler(nil);finish(.failure(error))}
    }
    func download(_ download:WKDownload,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,decisionHandler:@escaping(WKDownload.RedirectPolicy)->Void) {
        decisionHandler(!ended && MediaPolicy.allowsRedirect(to:request.url) ? .allow : .cancel)
    }
    func downloadDidFinish(_ download:WKDownload) {
        guard !ended else {return}
        guard let file=destination else { finish(.failure(ReaderError.message("附件未能保存。")));return }
        do {
            do {try MediaPolicy.validateCompletedFile(file)} catch {
                try? FileManager.default.removeItem(at:file)
                throw error
            }
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
            let data=try JSONSerialization.data(withJSONObject:["name":file.lastPathComponent,"mime":mime])
            try data.write(to:folder.appendingPathComponent("asset.json"),options:.atomic)
            finish(.success(MediaAsset(file:file,name:file.lastPathComponent,mime:mime)))
        } catch { finish(.failure(error)) }
    }
    func download(_ download:WKDownload,didFailWithError error:Error,resumeData:Data?) { finish(.failure(ReaderError.message("附件加载失败，请重试或在官方聊天打开。"))) }
}
