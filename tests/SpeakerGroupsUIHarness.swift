import AppKit
import WebKit

@main final class SpeakerGroupsUIHarness: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    var window: NSWindow!, web: WKWebView!, temp: URL!, output: URL!
    var state: [String: Any] = [:]
    var previousApp: NSRunningApplication?
    var mouseEventNumber = 0
    static func main() { let app = NSApplication.shared; let delegate = SpeakerGroupsUIHarness(); app.delegate = delegate; app.setActivationPolicy(.accessory); app.run() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            previousApp = NSWorkspace.shared.frontmostApplication
            let source = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            // Keep diagnostics in this checkout when comparing another UI bundle.
            output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true).appendingPathComponent("build")
            temp = FileManager.default.temporaryDirectory.appendingPathComponent("weiyue-speakers-" + UUID().uuidString)
            try FileManager.default.copyItem(at: source, to: temp)
            state = fixture()
            let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent(); configuration.userContentController.add(self, name: "app")
            configuration.userContentController.addUserScript(WKUserScript(source: "window.__speakerNativeEvents=[];for(const type of ['mousedown','mousemove','mouseup'])window.addEventListener(type,event=>{__speakerNativeEvents.push({type,x:event.clientX,y:event.clientY,trusted:event.isTrusted,target:event.target.className});if(__speakerNativeEvents.length>24)__speakerNativeEvents.shift();},true);", injectionTime: .atDocumentStart, forMainFrameOnly: true))
            web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1488, height: 1000), configuration: configuration); web.navigationDelegate = self
            window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false); window.contentView = web; window.appearance = NSAppearance(named: .aqua); window.setFrameOrigin(NSPoint(x: -4000, y: -4000)); window.ignoresMouseEvents = true; window.acceptsMouseMovedEvents = true; window.orderBack(nil); window.makeKey(); window.makeFirstResponder(web); NSApplication.shared.activate(ignoringOtherApps: true)
            web.loadFileURL(temp.appendingPathComponent("index.html"), allowingReadAccessTo: temp)
            DispatchQueue.main.asyncAfter(deadline: .now() + 90) { self.finish(false, "speaker UI timeout") }
        } catch { finish(false, error.localizedDescription) }
    }
    func message(_ index: Int) -> [String: Any] {
        let authors = ["u1", "u1", "u1", "u2", "u3", "u3", "u1", "u2", "u3", "u3", "u3", "u4"]
        let names = ["u1": "沈远", "u2": "林初", "u3": "周宁", "u4": "陈墨"]
        let texts = ["今天这段讨论的核心，是把已经确认的事实和自己的判断分开。", "同一个观点可以分成几条来说，阅读时应当仍然是连贯的一段。间隔十分钟，也不必重新打断。", "重要的是保留不同人的声音，同时让阅读的节奏轻一点。", "我比较关心的是：哪些结论已经有依据，哪些还只是等待验证的推测？", "可以先整理共识，再把分歧和待办分别列出来。", "每一条原始消息仍然能够单独选择、添加标记和回到出处。", "重新发言时，颜色跟随这一段出现的位置。", "三个颜色应按发言块轮转。", "这一段继续使用第三种颜色。", "同一人的连续消息不会换色。", "刚同步的消息会接进同一个发言框。", "新成员发言重新从第一种颜色开始。"]
        let formatter = ISO8601DateFormatter()
        return ["accountId": "synthetic-speaker", "groupId": "g", "id": String(index), "senderId": authors[index], "senderName": names[authors[index]]!, "sentAt": formatter.string(from: Date(timeIntervalSince1970: 1_792_281_600 + Double(index * 600))), "text": texts[index], "attachments": []]
    }
    func fixture() -> [String: Any] {
        ["version": 1, "revision": 1, "accountId": "synthetic-speaker", "groups": [["accountId": "synthetic-speaker", "id": "g", "name": "阅读讨论 · 合成验收", "selected": true]], "messages": (0..<10).map(message), "bookmarks": [], "collections": [], "discussions": [], "progress": [:], "settings": ["baseURL": "", "model": "", "activeGroupId": "g", "mode": "reader"]]
    }
    func json(_ value: Any) -> String { String(data: try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), encoding: .utf8)! }
    func reply(_ id: Any, _ value: Any = [:]) { web.evaluateJavaScript("window.nativeReceive(" + json(["id": id, "ok": true, "result": value]) + ")", completionHandler: nil) }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let action = body["action"] as? String, let id = body["id"] else { return }
        let payload = body["payload"] as? [String: Any] ?? [:]
        switch action {
        case "ready": reply(id, ["state": state, "hasAPIKey": false, "accountName": "合成验收", "appearance": "light"])
        case "save": state = payload["state"] as? [String: Any] ?? state; reply(id)
        case "storageLocations": reply(id, ["dataPath": temp.path, "attachmentsPath": temp.path])
        case "speakerAppend":
            web.evaluateJavaScript("window.onNativeEvent(" + json(["type": "messages", "accountId": "synthetic-speaker", "groupId": "g", "messages": [self.message(payload["index"] as? Int ?? 10)]]) + ")", completionHandler: nil); reply(id)
        case "speakerFocus":
            NSApplication.shared.activate(ignoringOtherApps: true); window.makeKey(); window.makeFirstResponder(web)
            print("Speaker focus visible=\(window.isVisible), occlusion=\(window.occlusionState.rawValue), canKey=\(window.canBecomeKey), screen=\(String(describing: NSScreen.main?.visibleFrame)), frame=\(window.frame), policy=\(NSApplication.shared.activationPolicy().rawValue)"); fflush(stdout)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.reply(id) }
        case "speakerPointer":
            let x = payload["x"] as? Double ?? 1, y = payload["y"] as? Double ?? 1
            let point = NSPoint(x: x, y: web.isFlipped ? y : web.bounds.height - y), location = web.convert(point, to: nil)
            let target = web.hitTest(point)
            print("Speaker pointer x=\(x), y=\(y), flipped=\(web.isFlipped), target=\(String(describing: target)), key=\(window.isKeyWindow), active=\(NSApplication.shared.isActive)"); fflush(stdout)
            for (index, type) in [NSEvent.EventType.leftMouseDown, .leftMouseDragged, .leftMouseUp].enumerated() {
                mouseEventNumber += 1
                let at = NSPoint(x: location.x + (index == 0 ? 0 : 1), y: location.y)
                if let event = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + Double(index) * 0.001, windowNumber: window.windowNumber, context: nil, eventNumber: mouseEventNumber, clickCount: 1, pressure: index == 2 ? 0 : 1) {
                    if index == 0 { target?.mouseDown(with: event) } else if index == 1 { target?.mouseDragged(with: event) } else { target?.mouseUp(with: event) }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { self.reply(id) }
        case "speakerSnapshot":
            let name = payload["name"] as? String ?? "speaker"
            guard ["v101-speakers-day", "v101-speakers-night", "v107-speakers-short", "v107-speakers-long", "v107-speakers-actions"].contains(name) else { finish(false, "invalid screenshot name"); return }
            web.takeSnapshot(with: nil) { image, error in
                guard let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(using: .png, properties: [:]) else { self.finish(false, error?.localizedDescription ?? "snapshot failed"); return }
                do { try data.write(to: self.output.appendingPathComponent(name + ".png")); self.web.evaluateJavaScript("window.__speakerShot=" + self.json(name), completionHandler: nil); self.reply(id) } catch { self.finish(false, error.localizedDescription) }
            }
        case "ai": finish(false, "speaker test must not send AI requests")
        default: reply(id)
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        web.callAsyncJavaScript(Self.tests, arguments: [:], in: nil, in: .page) { result in
            switch result { case .success(let value): self.finish(true, String(describing: value)); case .failure(let error): self.web.evaluateJavaScript("JSON.stringify({geometry:window.__speakerGeometry?.map(({width,size,kind,gaps,bodies,lines})=>({width,size,kind,gaps,bodyWidths:bodies.map(r=>r.width),bodyHeights:bodies.map(r=>r.height),firstLines:lines.map(r=>r[0]?.width)})),interaction:window.__speakerInteraction,visibility:document.visibilityState,focus:document.hasFocus(),nativeEvents:window.__speakerNativeEvents})") { value, _ in self.finish(false, error.localizedDescription + " " + String(describing: (error as NSError).userInfo) + "\n" + String(describing: value)) } }
        }
    }
    func finish(_ success: Bool, _ result: String) { print((success ? "PASS: " : "FAIL: ") + result); previousApp?.activate(options: []); if let temp { try? FileManager.default.removeItem(at: temp) }; exit(success ? 0 : 1) }
    static let tests = #"""
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms)),assert=(value,label)=>{if(!value)throw new Error(label);};
const wait=async(fn,label)=>{for(let n=0;n<100;n++){if(fn())return;await sleep(30);}throw new Error('Timeout '+label);};
const card=id=>document.querySelector('.message-card[data-message-id="'+id+'"]'),style=id=>getComputedStyle(card(id));
await wait(()=>card('9'),'ten original messages');await sleep(150);
assert(card('0').classList.contains('speaker-start')&&card('1').classList.contains('speaker-middle')&&card('2').classList.contains('speaker-end'),'three same-member messages form start/middle/end');
assert(card('3').classList.contains('speaker-single'),'different member starts separate frame');
for(const pair of [['0','1'],['1','2']])assert(Math.abs(card(pair[0]).getBoundingClientRect().bottom-card(pair[1]).getBoundingClientRect().top)<0.6,'joined messages have zero gap');
assert(Math.abs(card('3').getBoundingClientRect().top-card('2').getBoundingClientRect().bottom-6)<0.6,'different speaker gets a compact six-pixel gap');
assert(style('0').borderBottomWidth==='0px'&&style('1').borderTopWidth==='0px'&&style('1').borderBottomWidth==='0px'&&style('2').borderBottomWidth==='1px','only exterior frame has horizontal borders');
assert(style('0').borderTopLeftRadius==='10px'&&style('1').borderTopLeftRadius==='0px'&&style('2').borderBottomLeftRadius==='10px','frame corners only at beginning/end');
const tone=id=>[...card(id).classList].find(c=>/^speaker-tone-/.test(c));
const starts=['0','3','4','6','7','8'];assert(starts.map(tone).join(',')==='speaker-tone-0,speaker-tone-1,speaker-tone-2,speaker-tone-0,speaker-tone-1,speaker-tone-2','six consecutive blocks cycle through exactly three colours');
assert(new Set(starts.map(id=>style(id).backgroundColor)).size===3,'three visually distinct block colours');
assert(style('0').backgroundColor===style('1').backgroundColor&&style('0').backgroundColor===style('6').backgroundColor,'joined rows and repeated sequence colour stay consistent');
assert(!document.querySelector('#messages .message-avatar'),'focus reading creates no sender avatars');
const nameStyle=getComputedStyle(card('0').querySelector('.message-name')),bodyStyle=getComputedStyle(card('0').querySelector('.message-body'));assert(parseInt(nameStyle.fontWeight,10)>=600&&parseFloat(nameStyle.fontSize)>=parseFloat(bodyStyle.fontSize),'author name remains prominent without an avatar');
assert(getComputedStyle(card('1').querySelector('.message-heading')).height==='0px','continuation heading is hidden');
const initialHeight=card('1').getBoundingClientRect().height,checkbox=card('1').querySelector('.message-select');checkbox.focus();await sleep(40);assert(card('1').getBoundingClientRect().height===initialHeight,'focus does not reflow continuation');
checkbox.click();assert(card('1').classList.contains('selected')&&!card('0').classList.contains('selected'),'messages remain individually selectable');assert(style('1').backgroundColor!==style('0').backgroundColor,'selection remains clearly visible');checkbox.click();checkbox.blur();
assert(card('1').title.includes('沈远')&&card('1').getAttribute('aria-label').includes('沈远'),'continuation retains author/time metadata');
assert(card('1').querySelectorAll('.message-actions button').length>=3,'per-message bookmark and source actions retained');
const originalTones=starts.map(tone),previousLast=card('9');assert(previousLast.classList.contains('speaker-end'),'original last message is end');
window.webkit.messageHandlers.app.postMessage({id:'speaker-append',action:'speakerAppend',payload:{index:10}});await wait(()=>card('10'),'same-member live append');
assert(card('9')!==previousLast&&card('9').classList.contains('speaker-middle')&&card('10').classList.contains('speaker-end'),'live append refreshes prior last-frame cache');
assert(Math.abs(card('9').getBoundingClientRect().bottom-card('10').getBoundingClientRect().top)<0.6,'appended message joins without gap');
assert(tone('10')==='speaker-tone-2'&&JSON.stringify(starts.map(tone))===JSON.stringify(originalTones),'same-member append preserves colour sequence');
window.webkit.messageHandlers.app.postMessage({id:'speaker-next',action:'speakerAppend',payload:{index:11}});await wait(()=>card('11'),'new-member live append');
assert(tone('11')==='speaker-tone-0'&&card('11').classList.contains('speaker-single'),'new-member append wraps to first colour');assert(JSON.stringify(starts.map(tone))===JSON.stringify(originalTones),'new-member append does not recolour earlier blocks');
const snapshot=async name=>{window.__speakerShot='';window.webkit.messageHandlers.app.postMessage({id:name,action:'speakerSnapshot',payload:{name}});await wait(()=>window.__speakerShot===name,'screenshot '+name);};
ReaderAppearance.restore('light');await sleep(80);const day=style('0').backgroundColor;await snapshot('v101-speakers-day');
// Clone production-rendered cards into an isolated, visible measurement lane. The
// classes, structure, typography and action controls are the actual reader UI.
let qaSequence=0;const qaRequests=new Map(),nativeReceive=window.nativeReceive;window.nativeReceive=response=>{const resolve=qaRequests.get(response.id);if(resolve){qaRequests.delete(response.id);resolve(response.result);}else nativeReceive(response);};
const qa=(action,payload={})=>new Promise(resolve=>{const id='speaker-qa-'+(++qaSequence);qaRequests.set(id,resolve);webkit.messageHandlers.app.postMessage({id,action,payload});});
const rect=element=>{const r=element.getBoundingClientRect();return {left:r.left,right:r.right,top:r.top,bottom:r.bottom,width:r.width,height:r.height};};
const overlap=(a,b)=>Math.min(a.right,b.right)-Math.max(a.left,b.left)>0.6&&Math.min(a.bottom,b.bottom)-Math.max(a.top,b.top)>0.6;
const lineRects=body=>{const range=document.createRange();range.selectNodeContents(body);return [...range.getClientRects()].filter(r=>r.width>0.1).map(r=>({left:r.left,right:r.right,top:r.top,bottom:r.bottom,width:r.width,height:r.height}));};
const probe=document.createElement('section');probe.className='messages';probe.style.cssText='position:fixed;left:24px;top:68px;max-width:none;padding:10px;z-index:1000;background:var(--panel);container-type:inline-size;';document.body.append(probe);
const probeCards=Array.from({length:4},(_,index)=>{const c=card(index===0?'0':'1').cloneNode(true);c.className='message-card speaker-group speaker-tone-0 '+(index===0?'speaker-start':index===3?'continuation speaker-end':'continuation speaker-middle');c.dataset.messageId='geometry-'+index;c.querySelector('.message-name').textContent='这是用于验证姓名与按钮不重叠的很长成员名称';const extra=c.querySelector('.message-actions button').cloneNode(true);extra.className='message-translate-action';extra.textContent='翻译成中文';c.querySelector('.message-actions').append(extra);probe.append(c);return c;});
const body=c=>c.querySelector('.message-body'),actions=c=>c.querySelector('.message-actions');
const observations=[];window.__speakerGeometry=observations;
for(const width of [560,820])for(const size of [12,14,16,18])for(const kind of ['long','short','newlines']){
  probe.style.width=width+'px';probe.style.setProperty('--reader-size',size+'px');
  const text=kind==='short'?'同一个人的连续短消息。':kind==='long'?'这一段用来验证每条完整消息都应当使用全部可用宽度自然换行，不会因为隐藏的操作按钮把正文挤到左侧。'.repeat(3):'原文第一行。\n\n原文第三行保留空行。\n最后一行。';
  for(const c of probeCards)body(c).textContent=text;
  await sleep(30);
  const sample={width,size,kind,bodies:probeCards.map(c=>rect(body(c))),lines:probeCards.map(c=>lineRects(body(c))),cards:probeCards.map(rect),actions:probeCards.map(c=>rect(actions(c)))};sample.gaps=sample.bodies.slice(1).map((r,index)=>r.top-sample.bodies[index].bottom);observations.push(sample);
  assert(Math.max(...sample.gaps)-Math.min(...sample.gaps)<0.6,'identical body-to-body gaps, including first-to-second: '+JSON.stringify({width,size,kind,gaps:sample.gaps}));
  assert(sample.gaps.every(g=>g>=0&&g<=28),'action rail stays compact: '+sample.gaps);
  const first=sample.bodies[0],firstLines=sample.lines[0];
  for(let i=1;i<4;i++){
    assert(Math.abs(sample.bodies[i].width-first.width)<0.6&&Math.abs(sample.bodies[i].height-first.height)<0.6,'same text uses identical full width and wrapping in first and continuation '+i);
    assert(sample.lines[i].length===firstLines.length&&sample.lines[i].every((r,n)=>Math.abs(r.width-firstLines[n].width)<0.6),'every text line wraps identically in continuation '+i);
    assert(getComputedStyle(body(probeCards[i])).fontSize===getComputedStyle(body(probeCards[0])).fontSize&&getComputedStyle(body(probeCards[i])).lineHeight===getComputedStyle(body(probeCards[0])).lineHeight,'all message typography matches');
  }
  for(let i=0;i<4;i++){
    const c=probeCards[i],content=rect(c.querySelector('.message-content'));assert(Math.abs(rect(body(c)).right-content.right)<0.6,'body reaches the full content edge');
    assert(!overlap(rect(actions(c)),rect(body(c))),'actions never obscure body');
    if(i===0)for(const selector of ['.message-name','.message-time'])assert(!overlap(rect(actions(c)),rect(c.querySelector(selector))),'actions never obscure '+selector);
  }
  if(kind==='newlines')assert(firstLines.length===3&&body(probeCards[0]).textContent===text,'source newlines and blank paragraph are preserved');
  if(width===820&&size===16&&kind==='short')await snapshot('v107-speakers-short');
  if(width===820&&size===16&&kind==='long')await snapshot('v107-speakers-long');
}
probe.style.width='820px';probe.style.setProperty('--reader-size','16px');for(const c of probeCards)body(c).textContent='悬停和键盘聚焦时，正文位置与消息高度保持不变。';
await qa('speakerFocus');await qa('speakerPointer',{x:3,y:3});document.activeElement?.blur();await sleep(140);
for(const c of [probeCards[0],probeCards[1]]){
  const before={card:rect(c),body:rect(body(c))},r=rect(c);for(let attempt=0;attempt<3;attempt++){await qa('speakerFocus');await qa('speakerPointer',{x:r.right-5,y:r.top+3});await sleep(140);if(c.matches(':hover')&&Number(getComputedStyle(actions(c)).opacity)>.99)break;await qa('speakerPointer',{x:3,y:3});}
  window.__speakerInteraction={hover:c.matches(':hover'),opacity:getComputedStyle(actions(c)).opacity,card:rect(c),body:rect(body(c)),actions:rect(actions(c))};assert(c.matches(':hover')&&Number(getComputedStyle(actions(c)).opacity)>.99,'native hover reveals actions');
  assert(Math.abs(rect(c).height-before.card.height)<0.6&&Math.abs(rect(body(c)).top-before.body.top)<0.6,'hover preserves message height and body position');
  for(const button of actions(c).querySelectorAll('button')){const b=rect(button),hit=document.elementFromPoint((b.left+b.right)/2,(b.top+b.bottom)/2);assert(hit&&button.contains(hit),'every hover action is clickable');}
  await qa('speakerPointer',{x:3,y:3});const firstButton=actions(c).querySelector('button');for(let attempt=0;attempt<3;attempt++){await qa('speakerFocus');firstButton.focus({preventScroll:true});await sleep(180);if(firstButton.matches(':focus')&&Number(getComputedStyle(actions(c)).opacity)>.99)break;}window.__speakerInteraction.focus={active:document.activeElement?.outerHTML,focus:firstButton.matches(':focus'),within:c.matches(':focus-within'),opacity:getComputedStyle(actions(c)).opacity};
  assert(firstButton.matches(':focus')&&Number(getComputedStyle(actions(c)).opacity)>.99,'keyboard focus reveals actions');assert(Math.abs(rect(c).height-before.card.height)<0.6&&Math.abs(rect(body(c)).top-before.body.top)<0.6,'focus preserves geometry');firstButton.blur();
}
actions(probeCards[1]).querySelector('button').focus({preventScroll:true});await sleep(150);await snapshot('v107-speakers-actions');probe.remove();

ReaderAppearance.restore('dark');await sleep(80);const night=style('0').backgroundColor;assert(day!==night,'night palette adapts');assert(style('0').backgroundColor===style('1').backgroundColor,'night group remains continuous');assert(new Set(starts.map(id=>style(id).backgroundColor)).size===3,'night palette retains exactly three distinct colours');await snapshot('v101-speakers-night');
return JSON.stringify({geometry:observations.map(({width,size,kind,gaps,bodies,lines})=>({width,size,kind,gaps,bodyWidth:bodies[0].width,bodyHeight:bodies[0].height,lineWidths:lines[0].map(r=>r.width)})),messages:12,threeColourCycle:true,noAvatars:true,prominentNames:true,continuousThreeMessageFrame:true,zeroInnerGap:true,outerCornersOnly:true,individualSelection:true,actionsPreserved:true,noFocusReflow:true,liveAppendFrameUpdated:true,day,night,screenshots:['v101-speakers-day.png','v101-speakers-night.png']});
"""#
}
