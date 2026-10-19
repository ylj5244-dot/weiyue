import Foundation

private final class SearchStubProtocol: URLProtocol {
    struct Reply { var status=200; var headers:[String:String]=["Content-Type":"application/json"]; var chunks:[Data]; var interval=0.001; var error:Error?=nil; var responseURL:URL?=nil }
    static var reply:(URLRequest)throws->Reply = {_ in throw URLError(.badServerResponse)}
    private let lock=NSLock(); private var stopped=false
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading(){
        do {let response=try Self.reply(request);client?.urlProtocol(self,didReceive:HTTPURLResponse(url:response.responseURL ?? request.url!,statusCode:response.status,httpVersion:"HTTP/1.1",headerFields:response.headers)!,cacheStoragePolicy:.notAllowed);deliver(response,0)}
        catch {client?.urlProtocol(self,didFailWithError:error)}
    }
    private func deliver(_ response:Reply,_ index:Int){DispatchQueue.global().asyncAfter(deadline:.now()+response.interval){[weak self] in
        guard let self else{return};self.lock.lock();let stopped=self.stopped;self.lock.unlock();guard !stopped else{return}
        if index<response.chunks.count {self.client?.urlProtocol(self,didLoad:response.chunks[index]);self.deliver(response,index+1)}
        else if let error=response.error{self.client?.urlProtocol(self,didFailWithError:error)}else{self.client?.urlProtocolDidFinishLoading(self)}
    }}
    override func stopLoading(){lock.lock();stopped=true;lock.unlock()}
}

@main struct WebSearchTests {
    static var assertions=0
    static func check(_ value:Bool,_ message:String){assertions+=1;precondition(value,message)}
    static func wait<T>(_ start:(@escaping(Result<T,Error>)->Void)throws->Void)throws->Result<T,Error>{
        var result:Result<T,Error>?;try start{check(Thread.isMainThread,"Completion returns on main");result=$0}
        let deadline=Date().addingTimeInterval(7);while result == nil && Date()<deadline{RunLoop.current.run(until:Date().addingTimeInterval(0.002))}
        guard let result else{throw ReaderError.message("Synthetic web search timed out")};return result
    }
    static func json(_ value:Any)->Data {try! JSONSerialization.data(withJSONObject:value)}
    static func source(_ i:Int=1)->[String:Any]{["title":"标题 \(i)","url":"https://example.org/news/\(i)","snippet":"短摘要 \(i)","summary":"较长摘要 \(i)","content":"网页正文 \(i)","site_name":"Example","site_icon":NSNull(),"date":"2026-10-18T03:00:00Z","rerank_score":2,"authority":3]}
    static func requestBody(_ request:URLRequest)->[String:Any]{
        var data=request.httpBody ?? Data()
        if data.isEmpty,let stream=request.httpBodyStream{stream.open();defer{stream.close()};var bytes=[UInt8](repeating:0,count:4096);while stream.hasBytesAvailable{let count=stream.read(&bytes,maxLength:bytes.count);if count<=0{break};data.append(bytes,count:count)}}
        return try! JSONSerialization.jsonObject(with:data) as! [String:Any]
    }
    static func main()throws{
        for base in ["https://api.deepseek.com","https://api.deepseek.com/v1/","https://api.deepseek.com:443/v1/chat/completions","https://API.DEEPSEEK.COM/chat/completions"]{check(try WebSearchPolicy.endpoint(baseURL:base)==WebSearchPolicy.fixedEndpoint,"Supported base uses fixed official search endpoint")}
        for base in ["http://api.deepseek.com","https://api.deepseek.com.evil.example/v1","https://api.deepseek.com:8443","https://user@api.deepseek.com","https://api.deepseek.com/?key=secret","https://api.deepseek.com/tenant/v1","https://api.deepseek.com./v1"]{do{_=try WebSearchPolicy.endpoint(baseURL:base);fatalError("Unsafe search endpoint accepted")}catch{assertions+=1}}
        check(try WebSearchPolicy.enabled(nil)==false && WebSearchPolicy.enabled(true)==true && WebSearchPolicy.enabled(false)==false,"Only explicit boolean enables web search")
        for invalid in [1,0,"true",NSNull()] as [Any] { do { _=try WebSearchPolicy.enabled(invalid);fatalError("Nonboolean switch accepted") } catch {assertions+=1} }
        let safeURLs=["https://example.org/page#part","http://www.example.org:8080/path?a=b","https://8.8.8.8/dns","https://例子.中国/新闻"]
        for value in safeURLs{check(WebSearchPolicy.publicURL(value) != nil,"Public URL retained")}
        for value in ["file:///tmp/a","javascript:alert(1)","https://user:pass@example.org","https://@example.org","https://localhost","https://x.local","https://x.internal","https://x.lan","https://x.home","https://intranet","https://127.0.0.1","https://127.1","https://2130706433","https://0x7f000001","https://0177.0.0.1","https://10.1.2.3","https://192.168.1.1","https://192.0.2.5","https://169.254.169.254","https://172.31.0.1","https://100.64.0.1","https://198.19.0.1","https://198.51.100.1","https://203.0.113.1","https://224.1.2.3","https://[::1]","https://[2001:4860:4860::8888]","https://example.org/a b","https://example.org:70000/a","https://example.org/\\evil"]{check(WebSearchPolicy.publicURL(value)==nil,"Private, ambiguous or nonweb URL rejected: \(value)")}
        check(try WebSearchPolicy.query(String(repeating:"🌙",count:100),messages:[]).utf16.count==128,"Query truncates without splitting Unicode scalar")
        check(try WebSearchPolicy.query(nil,messages:[["role":"user","content":" Earlier "],["role":"assistant","content":"Reply"],["role":"user","content":" Current question "]])=="Current question","Query fallback only uses latest user question")
        do{_=try WebSearchPolicy.query(" \n",messages:[]);fatalError("Blank query accepted")}catch{assertions+=1}
        var first=source();first["title"]=String(repeating:"🌙",count:400);first["snippet"]=String(repeating:"长",count:1500);first["content"]=String(repeating:"字",count:7000)
        let parsed=try WebSearchPolicy.decode(json(["results":[first]+(2...7).map(source)]),query:"test",at:Date(timeIntervalSince1970:1700000000))
        let sources=parsed.metadata["sources"] as! [[String:Any]]
        check(parsed.status=="success" && sources.count==5 && parsed.evidence.count==5,"Exactly five normalized public sources")
        check(sources.enumerated().allSatisfy{($0.element["id"] as? String)=="网页\($0.offset+1)"},"Stable sequential reference IDs")
        check((sources[0]["title"] as! String).utf16.count==500 && (sources[0]["excerpt"] as! String).utf16.count==1200,"Metadata clipped to validated bounds")
        check((parsed.evidence[0]["content"] as! String).utf16.count==5000 && parsed.evidence[0]["contentTruncated"] as? Bool==true,"Model text bounded with truthful truncation marker")
        check(sources[0]["content"]==nil && sources[0]["contentTruncated"]==nil,"Large fetched body excluded from UI metadata")
        var badPort=source(9);badPort["url"]="https://example.org:65536/news"
        var boundaryZero=source(1);boundaryZero["url"]="https://example.org:0/news"
        var boundaryMax=source(2);boundaryMax["url"]="https://example.org:65535/news"
        let mixed=try WebSearchPolicy.decode(json(["results":[badPort,boundaryZero,boundaryMax]+(3...7).map(source)]),query:"port bounds")
        let mixedSources=mixed.metadata["sources"] as! [[String:Any]]
        check(mixed.status=="success" && mixedSources.count==5 && mixedSources.allSatisfy{!($0["url"] as! String).contains(":65536")},"Invalid-port hit is filtered while five valid sources survive")
        check((mixedSources[0]["url"] as! String).contains(":0/") && (mixedSources[1]["url"] as! String).contains(":65535/"),"Port boundary values mirror JavaScript URL acceptance")
        let temporary=FileManager.default.temporaryDirectory.appendingPathComponent("weiyue-web-port-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:temporary)}
        let store=try StateStore(directory:temporary)
        var saved=StateStore.empty(accountId:"A");saved["revision"]=1
        saved["discussions"]=[["id":"web-port-test","accountId":"A","createdAt":"2026-10-18T03:00:00Z","contextSnapshots":[],"messages":[["role":"assistant","content":"Synthetic web answer","webSearch":mixed.metadata]]]]
        try store.save(state:saved,accountId:"A")
        check((try store.load(accountId:"A").state["discussions"] as? [Any])?.count==1,"Normalized mixed-port metadata is accepted by native Store")
        let validate=Process(),input=Pipe();validate.executableURL=URL(fileURLWithPath:"/usr/bin/env")
        validate.arguments=["node","-e","const fs=require('node:fs'), W=require('./Resources/ui/web-search.js'); if(!W.normalize(JSON.parse(fs.readFileSync(0,'utf8')))) process.exit(1);"]
        validate.standardInput=input;try validate.run();input.fileHandleForWriting.write(json(mixed.metadata));try input.fileHandleForWriting.close();validate.waitUntilExit()
        check(validate.terminationStatus==0,"The same native metadata is accepted by JS normalization")
        var undated=source();undated["date"]="not a date";undated["content"]="";undated["summary"]="Fallback summary"
        let fallback=try WebSearchPolicy.decode(json(["results":[undated]]),query:"q")
        check((fallback.metadata["sources"] as! [[String:Any]])[0]["publishedAt"] is NSNull,"Missing publication date remains unknown")
        check(fallback.evidence[0]["content"] as? String=="Fallback summary","Missing page body uses actual summary only")
        var echoed=source();echoed["title"]="synthetic-secret";echoed["site_name"]="synthetic-secret";echoed["snippet"]="synthetic-secret";echoed["content"]="synthetic-secret"
        let redacted=try WebSearchPolicy.decode(json(["results":[echoed]]),query:"q",secret:"synthetic-secret")
        check(!String(data:json(["metadata":redacted.metadata,"evidence":redacted.evidence]),encoding:.utf8)!.contains("synthetic-secret"),"Even a response echo cannot expose the credential in metadata or evidence")
        let empty=try WebSearchPolicy.decode(json(["results":[]]),query:"q");check(empty.status=="empty" && empty.warning != nil,"No search hits is explicit and not verified")
        for data in [Data("bad json".utf8),json(["results":"wrong"]),json(["error":["message":"failed"]]),json(["results":[["url":"http://127.0.0.1","content":"unsafe"]]]),Data(repeating:65,count:WebSearchPolicy.maxResponseBytes+1)]{do{_=try WebSearchPolicy.decode(data,query:"q");fatalError("Malformed or unsafe search evidence accepted")}catch{assertions+=1}}
        let original:[[String:Any]]=[["role":"system","content":"个人偏好：使用完整段落。临时要求：简短。"],["role":"user","content":"Earlier question"],["role":"assistant","content":"Earlier answer"],["role":"user","content":"Latest explicit format"]]
        let injected=try WebSearchPolicy.messages(original,result:parsed)
        check(injected.last?["content"] as? String=="Latest explicit format" && injected[1]["content"] as? String=="Earlier question" && injected[2]["content"] as? String=="Earlier answer","Evidence preserves history and latest user request order")
        let system=injected[0]["content"] as! String
        check(system.hasPrefix(original[0]["content"] as! String) && system.contains("不可信资料") && system.contains("最新用户要求 > 当前讨论临时要求 > 长期偏好") && system.contains("不能编造") && system.contains("历史网页轮次-序号") && system.contains("本轮 [网页N] 只对应本次搜索结果"),"Trusted preferences retained, history source numbers isolated, and web prompt injection blocked")
        check((injected[injected.count-2]["content"] as! String).contains("网页1"),"Actual source records supplied before user question")
        let many=Array(repeating:["role":"user","content":"q"],count:199)
        check(try WebSearchPolicy.messages(Array(many.dropLast()),result:parsed).count==200,"Adding system and evidence preserves 200 message ceiling")
        for over in [many,Array(repeating:["role":"system","content":"s"],count:199)+[["role":"user","content":"q"]]] {do{_=try WebSearchPolicy.messages(over,result:parsed);fatalError("Too many messages accepted")}catch{assertions+=1}}
        let failed=WebSearchPolicy.failed(query:"q",error:ReaderError.message("secret-key Bearer other-secret\n"+String(repeating:"x",count:800)),secret:"secret-key")
        let failureText=failed.metadata["error"] as! String
        check(failed.status=="failed" && failureText.utf16.count<=500 && !failureText.contains("secret-key") && !failureText.contains("other-secret"),"Error diagnostics are bounded and redacted")
        for result in [empty,failed]{let sent=try WebSearchPolicy.messages(original,result:result);check((sent[0]["content"] as! String).contains("未完成联网核实") && (sent[sent.count-2]["content"] as! String).contains(result.status),"Failed/empty searches cannot be silently represented as verified")}

        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[SearchStubProtocol.self]
        var keyReads=0,dispatches=0
        let client=WebSearchClient(configuration:config,keyReader:{account,base in
            check(!Thread.isMainThread,"Key lookup is background with no system prompt")
            check(account=="A" && base=="https://api.deepseek.com/v1","Search reuses exact existing credential scope")
            keyReads+=1;return "synthetic-search-key"
        })
        SearchStubProtocol.reply={request in
            dispatches+=1
            check(request.url==WebSearchPolicy.fixedEndpoint && request.httpMethod=="POST","Credentials only sent to fixed HTTPS official endpoint")
            check(request.value(forHTTPHeaderField:"Authorization")=="Bearer synthetic-search-key","Native credential is attached only to request")
            let body=requestBody(request)
            check(body["query"] as? String=="最新公开信息" && body["count"] as? Int==5 && body["need_content"] as? Bool==true && body.count==3,"Search request contains bounded query and documented fields only")
            return .init(chunks:[json(["results":[source()]])])
        }
        func search(_ query:String="最新公开信息")throws->WebSearchResult{try wait{done in try client.search(accountId:"A",baseURL:"https://api.deepseek.com/v1",query:query,completion:done)}.get()}
        let network=try search();check(network.status=="success" && keyReads==1 && dispatches==1,"Synthetic transport succeeds without remote network")
        check(!String(data:json(network.metadata),encoding:.utf8)!.contains("synthetic-search-key"),"Credential never appears in UI metadata")
        for reply in [
            SearchStubProtocol.Reply(chunks:[json(["results":[]])]),
            .init(chunks:[Data("{bad".utf8)]),
            .init(status:401,chunks:[json(["error":["message":"rejected synthetic-search-key"]])]),
            .init(status:429,chunks:[json(["error":["message":"rate limit"]])]),
            .init(status:503,chunks:[json(["error":["message":"unavailable"]])]),
            .init(status:302,headers:["Location":"https://evil.example/receive"],chunks:[Data()]),
            .init(chunks:[Data(repeating:65,count:WebSearchPolicy.maxResponseBytes),Data([66])]),
            .init(headers:["Content-Length":"3000000"],chunks:[]),
            .init(chunks:[json(["results":[source()]])],responseURL:URL(string:"https://evil.example/response"))
        ]{
            SearchStubProtocol.reply={_ in reply};let value=try search()
            check(["empty","failed"].contains(value.status) && value.warning != nil,"Empty/malformed/status/redirect/size failure explicitly disclosed")
            check(!String(data:json(value.metadata),encoding:.utf8)!.contains("synthetic-search-key"),"Failure metadata never leaks credential")
        }
        var delayed:Result<WebSearchResult,Error>?,replacement:Result<WebSearchResult,Error>?,sentCount=0,lateSuccesses=0
        SearchStubProtocol.reply={_ in sentCount+=1;return .init(chunks:[json(["results":[source()]])],interval:0.15)}
        try client.search(accountId:"A",baseURL:"https://api.deepseek.com/v1",query:"old"){result in delayed=result;if case .success=result{lateSuccesses+=1}}
        let until=Date().addingTimeInterval(0.04);while Date()<until{RunLoop.current.run(until:Date().addingTimeInterval(0.002))}
        client.cancel();SearchStubProtocol.reply={_ in sentCount+=1;return .init(chunks:[json(["results":[]])])}
        try client.search(accountId:"A",baseURL:"https://api.deepseek.com/v1",query:"new"){replacement=$0}
        let deadline=Date().addingTimeInterval(3);while (delayed == nil || replacement == nil) && Date()<deadline{RunLoop.current.run(until:Date().addingTimeInterval(0.005))}
        guard case .failure(let cancelled)=delayed else{fatalError("Cancelled search returned usable evidence")}
        check((cancelled as? URLError)?.code == .cancelled && lateSuccesses==0,"Cancelled search cannot continue to chat with late evidence")
        check(try replacement?.get().status=="empty" && sentCount==2,"Replacement search works independently")
        var earlyDispatch=0;SearchStubProtocol.reply={_ in earlyDispatch+=1;return .init(chunks:[json(["results":[]])])}
        let early=try wait{done in try client.search(accountId:"A",baseURL:"https://api.deepseek.com/v1",query:"early",completion:done);client.cancel()}
        guard case .failure=early else{fatalError("Cancelled preparation dispatched")};check(earlyDispatch==0,"Cancel during background credential preparation prevents POST")
        print("PASS: \(assertions) web search endpoint/security/bounds/evidence/prompt/cancellation assertions (synthetic URLProtocol only)")
    }
}
