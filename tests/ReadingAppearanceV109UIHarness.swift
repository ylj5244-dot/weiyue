import AppKit
import WebKit

// Uses only temporary preferences, synthetic messages and installed font fixtures.
@main final class ReadingAppearanceV109UIHarness: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    var window: NSWindow!, web: WKWebView!, temp: URL!, output: URL!, source: URL!, appearances: ReadingAppearanceStore!
    var state: [String: Any] = [:], phase = 0
    var previousApp: NSRunningApplication?
    static func main() { let app = NSApplication.shared; let delegate = ReadingAppearanceV109UIHarness(); app.delegate = delegate; app.setActivationPolicy(.accessory); app.run() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            previousApp = NSWorkspace.shared.frontmostApplication
            source = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            output = source.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build")
            temp = FileManager.default.temporaryDirectory.appendingPathComponent("weiyue-v109-appearance-ui-" + UUID().uuidString)
            try FileManager.default.copyItem(at: source, to: temp)
            appearances = try ReadingAppearanceStore(directory: temp.appendingPathComponent("appearance-data"))
            // A genuine 1.0.8 preference file, without the new spacing key.
            try JSONSerialization.data(withJSONObject: ["density": 3, "skinId": "default", "fontChoice": "system"]).write(to: appearances.directory.appendingPathComponent("preferences.json"))
            state = fixture()
            let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent(); config.userContentController.add(self, name: "app")
            config.userContentController.addUserScript(WKUserScript(source: "window.__errors=[];window.__testReplies={};window.addEventListener('error',e=>__errors.push(e.message));window.addEventListener('unhandledrejection',e=>__errors.push(String(e.reason)));window.fetch=()=>Promise.reject(Error('External network disabled in fixture'));", injectionTime: .atDocumentStart, forMainFrameOnly: true))
            web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1488, height: 1000), configuration: config); web.navigationDelegate = self; web.autoresizingMask = [.width, .height]
            window = NSWindow(contentRect: web.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false); window.contentView = web; window.appearance = NSAppearance(named: .aqua); window.setFrameOrigin(NSPoint(x: -4000, y: -4000)); window.orderBack(nil)
            web.loadFileURL(temp.appendingPathComponent("index.html"), allowingReadAccessTo: temp)
            DispatchQueue.main.asyncAfter(deadline: .now() + 90) { self.finish(false, "v109 appearance UI timed out") }
        } catch { finish(false, error.localizedDescription) }
    }
    func fixture() -> [String: Any] {
        let account = "v109-appearance-synthetic", timestamp = "2026-10-19T08:00:00Z"
        let messages: [[String: Any]] = (0..<240).map { n in
            let text = "第 \(n) 条合成消息，用于验证连续记录之间的留白。\n第二行保留原有内容和阅读位置。" + (n < 6 && n % 2 == 0 ? " 筛选保留" : "")
            let senderID = n < 6 ? "u0" : "u\(n / 3)", name = n < 6 ? "林晓" : "成员\(n / 3)"
            return ["accountId": account, "groupId": "g", "id": String(n), "senderId": senderID, "senderName": name, "sentAt": timestamp, "text": text, "attachments": []]
        }
        return ["version": 1, "revision": 1, "accountId": account, "groups": [["accountId": account, "id": "g", "name": "阅读外观 · 合成验收", "selected": true]], "messages": messages, "bookmarks": [], "collections": [], "discussions": [], "progress": [:], "settings": ["baseURL": "https://synthetic.invalid/v1", "model": "synthetic", "activeGroupId": "g", "mode": "reader"]]
    }
    func json(_ value: Any) -> String { String(data: try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), encoding: .utf8)! }
    func reply(_ id: Any, _ result: Any = [:], error: String? = nil) {
        var payload: [String: Any] = ["id": id, "ok": error == nil, "result": result]; if let error { payload["error"] = error }
        let test = (id as? String)?.hasPrefix("test-") == true ? "window.__testReplies[\(json(id))]=\(json(payload));" : ""
        web.evaluateJavaScript(test + "window.nativeReceive(" + json(payload) + ")", completionHandler: nil)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let action = body["action"] as? String, let id = body["id"] else { return }
        let payload = body["payload"] as? [String: Any] ?? [:]
        do { switch action {
        case "ready":
            reply(id, ["state": state, "hasAPIKey": false, "accountName": "本地合成验收", "appearance": "light", "readingAppearance": appearances.snapshot()])
        case "save": state = payload["state"] as? [String: Any] ?? state; reply(id)
        case "aiCapabilities": reply(id, ["thinking": false, "canDisableThinking": false])
        case "storageLocations": reply(id, ["dataPath": temp.path, "attachmentsPath": temp.path])
        case "saveReadingAppearance": reply(id, try appearances.save(payload["preferences"] as! [String: Any]))
        case "importReadingSkin": reply(id, try appearances.importSkin(source.appendingPathComponent("skin-example.weiyue-skin.json")))
        case "importReadingFont": reply(id, try appearances.importFont(URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Arial.ttf")))
        case "testInspect": reply(id, appearances.snapshot())
        case "testFocus": NSApp.activate(ignoringOtherApps: true); window.makeKey(); window.makeFirstResponder(web); reply(id)
        case "testResize": window.setContentSize(NSSize(width: payload["width"] as? Double ?? 1488, height: payload["height"] as? Double ?? 1000)); reply(id)
        case "testSnapshot":
            let name = payload["name"] as? String ?? ""
            guard name.hasPrefix("v109-appearance-"), !name.contains("/") else { throw ReaderError.message("invalid snapshot name") }
            web.takeSnapshot(with: nil) { image, error in
                do { guard let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(using: .png, properties: [:]) else { throw ReaderError.message(error?.localizedDescription ?? "snapshot failed") }; try data.write(to: self.output.appendingPathComponent(name + ".png")); self.reply(id) } catch { self.reply(id, error: error.localizedDescription) }
            }
        case "ai", "aiDiscussionTitle", "webSearch", "openExternal", "loadRange": finish(false, "unexpected external operation: " + action)
        default: reply(id)
        } } catch { reply(id, error: error.localizedDescription) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) { decisionHandler(action.request.url?.isFileURL == true ? .allow : .cancel) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        NSApp.activate(ignoringOtherApps: true); window.makeKey(); window.makeFirstResponder(web)
        web.callAsyncJavaScript(Self.helpers + (phase == 0 ? Self.tests : Self.reloadTests), arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .success(let value):
                print("PASS phase \(self.phase): \(value)"); fflush(stdout)
                if self.phase == 0 { self.phase = 1; self.web.reload() } else { self.finish(true, "v109 appearance, spacing geometry, skin palettes, font preservation and reload") }
            case .failure(let error):
                self.web.evaluateJavaScript("JSON.stringify({errors:window.__errors,body:document.body.innerText.slice(-2500)})") { value, _ in self.finish(false, String(describing: (error as NSError).userInfo) + "\n" + String(describing: value)) }
            }
        }
    }
    func finish(_ success: Bool, _ result: String) { print((success ? "PASS: " : "FAIL: ") + result); fflush(stdout); previousApp?.activate(options: []); if let temp { try? FileManager.default.removeItem(at: temp) }; exit(success ? 0 : 1) }
    static let helpers = #"""
const $=id=>document.getElementById(id),sleep=ms=>new Promise(r=>setTimeout(r,ms)),assert=(v,l)=>{if(!v)throw Error(l);};
const wait=async(fn,label)=>{for(let n=0;n<240;n++){if(fn())return;await sleep(25);}throw Error('Timeout '+label);};
const request=async(action,payload={})=>{const id='test-'+Math.random();webkit.messageHandlers.app.postMessage({id,action,payload});await wait(()=>window.__testReplies[id],action);const reply=window.__testReplies[id];delete window.__testReplies[id];if(!reply.ok)throw Error(reply.error);return reply.result;};
const card=id=>document.querySelector('.message-card[data-message-id="'+id+'"]'),rect=el=>el.getBoundingClientRect(),style=el=>getComputedStyle(el),root=document.documentElement;
const inside=(a,b)=>{a=rect(a);b=rect(b);return a.left>=b.left-1&&a.right<=b.right+1&&a.top>=b.top-1&&a.bottom<=b.bottom+1;};
const openAppearance=async()=>{$('settings-button').click();await wait(()=>$('settings-dialog').open,'settings');$('open-reading-appearance').click();await wait(()=>$('reading-appearance-dialog').open,'reading appearance');};
const saved=()=>request('testInspect');
const click=async selector=>{document.querySelector(selector).click();await wait(()=>!$('reading-font').disabled,'appearance saved');await sleep(80);};
const select=async(id,value)=>{$(id).value=value;$(id).dispatchEvent(new Event('change',{bubbles:true}));await wait(()=>!$(id).disabled,'select saved');await sleep(80);};
const shot=async name=>{await wait(()=>$('toast').hidden,'toast settled');await request('testSnapshot',{name:'v109-appearance-'+name});};
const noOverflow=()=>{for(const el of [$('main'),$('inspector'),$('reader-scroll'),$('reading-appearance-dialog')].filter(el=>el.getClientRects().length))assert(el.scrollWidth<=el.clientWidth+1,'horizontal overflow '+el.id);};
const rgb=hex=>'rgb('+hex.slice(1).match(/../g).map(v=>parseInt(v,16)).join(', ')+')';
const luminance=color=>{const [r,g,b]=color.match(/[\d.]+/g).slice(0,3).map(v=>Number(v)/255).map(v=>v<=.04045?v/12.92:((v+.055)/1.055)**2.4);return r*.2126+g*.7152+b*.0722;};
const contrast=(a,b)=>{const levels=[luminance(a),luminance(b)].sort((a,b)=>a-b);return (levels[1]+.05)/(levels[0]+.05);};
await wait(()=>document.querySelector('.message-card')&&root.dataset.readingDensity,'ready');await sleep(120);
"""#
    static let tests = #"""
assert(root.dataset.readingDensity==='3'&&root.dataset.readingConsecutiveSpacing==='follow','legacy density migration');
const initialGap=rect(card('2').querySelector('.message-body')).top-rect(card('1').querySelector('.message-body')).bottom;
assert(Math.abs(initialGap-26)<1,'legacy standard text gap remains 26px: '+initialGap);
assert(new Set(['0','1','2'].map(id=>style(card(id)).backgroundColor)).size===1,'original skin retains same-member group background');
await openAppearance();assert(document.querySelector('[data-consecutive-spacing="follow"]').getAttribute('aria-pressed')==='true','follow visibly selected');
const initial=await saved();assert(initial.builtInSkins.length===3&&initial.skins.length===0,'built-ins need no imports');
assert([...$('reading-skin').options].map(o=>o.value).join(',')==='default,paper-green,claude-code','three built-in options visible');
const measures=[];
for(const level of [1,2,3,4,5]){
  await click('[data-consecutive-spacing="'+level+'"]');
  assert((await saved()).preferences.consecutiveSpacing===level,'spacing persisted');
  assert(document.querySelector('[data-consecutive-spacing="'+level+'"]').getAttribute('aria-pressed')==='true','independent selection visible');
  const c=card('2'),rail=c.querySelector('.message-actions'),body=c.querySelector('.message-body-row');
  measures.push(rect(c.querySelector('.message-body')).top-rect(card('1').querySelector('.message-body')).bottom);
  assert(inside(rail,c)&&rect(rail).bottom<=rect(body).top+1,'action lane does not obscure text');
}
assert(measures.every((gap,i)=>Math.abs(gap-[24,32,44,62,88][i])<1),'five actual text gaps '+measures);
await click('[data-reading-density="1"]');assert((await saved()).preferences.consecutiveSpacing===5&&style(card('2')).paddingBottom==='64px','density preserves independent spacing');
await click('[data-consecutive-spacing="follow"]');assert(style(card('2')).paddingBottom==='0px'&&$('reading-spacing-status').textContent.includes('紧凑'),'follow restored immediately');
await click('[data-reading-density="5"]');assert(style(card('2')).paddingBottom==='9px'&&$('reading-spacing-status').textContent.includes('宽松'),'follow responds to density');
await select('reading-font','family:Arial');
for(const skin of initial.builtInSkins.filter(s=>s.id!=='default')){
  await select('reading-skin',skin.id);
  for(const mode of ['light','dark']){
    ReaderAppearance.restore(mode);await sleep(100);
    assert(root.dataset.readingSkin===skin.id,'built-in skin applied');
    assert(style(root).getPropertyValue('--panel').trim()===skin[mode].panel,'panel palette '+skin.id+' '+mode);
    assert(style($('done-reading-appearance')).backgroundColor===rgb(skin[mode].accent),'button palette '+skin.id+' '+mode);
    assert((await saved()).preferences.fontChoice==='family:Arial','built-in does not reset font');
    const recordColors=['0','1','2'].map(id=>style(card(id)).backgroundColor);
    assert(new Set(recordColors).size===3,'each same-ID record has a distinct background '+skin.id+' '+mode+' '+recordColors);
    for(let index=0;index<3;index++){
      const item=card(String(index));assert(item.classList.contains('message-tone-'+index),'record tone marker '+index);
      assert(recordColors[index]===rgb(style(root).getPropertyValue('--reading-record-'+index).trim()),'record palette applied');
      assert(contrast(style(item.querySelector('.message-body')).color,recordColors[index])>=7,'readable body contrast '+skin.id+' '+mode);
      if(mode==='dark')assert(contrast(style(item.querySelector('.message-time')).color,recordColors[index])>=4.5,'readable dark metadata');
    }
    assert(card('0').classList.contains('speaker-start')&&card('1').classList.contains('continuation')&&style(card('1').querySelector('.message-heading')).height==='0px','same-ID group and single header retained');
    assert(style(document.querySelector('.app-icon')).backgroundColor===rgb(skin[mode].accent),'app icon follows skin accent');
    assert(style(document.querySelector('.ai-orb')).color===rgb(skin[mode].accent),'AI orb follows skin accent');
    const selected=card('1').cloneNode(true);selected.style.position='fixed';selected.style.left='-5000px';selected.classList.add('selected','reader-followed','target-message');document.body.append(selected);
    assert(style(selected).backgroundColor===recordColors[1],'selection preserves record tone');
    assert(style(selected).boxShadow.includes(rgb(skin[mode].accent))&&style(selected).boxShadow.includes(rgb(style(selected).getPropertyValue('--reading-mark-edge').trim())),'selection and navigation marker cues retained');
    assert(style(selected.querySelector('.message-name')).color===rgb(style(root).getPropertyValue('--reader-follow-text').trim()),'followed member name cue retained');selected.remove();
    const live=document.createElement('button');live.className='ai-option-toggle';live.setAttribute('aria-pressed','true');document.body.append(live);
    assert(style(live).color===rgb(skin[mode].accent),'selected control palette');live.remove();
    await shot(skin.id+'-'+mode);
    $('done-reading-appearance').click();await sleep(80);await shot(skin.id+'-'+mode+'-records');await openAppearance();
  }
}
// A retained middle record changes ordinal after filtering, even though its
// member and group position remain unchanged. This exercises the real cache key.
$('done-reading-appearance').click();$('message-search').value='筛选保留';$('message-search').dispatchEvent(new Event('input',{bubbles:true}));
await wait(()=>document.querySelectorAll('.message-card').length===3&&card('4'),'filtered three records');await sleep(80);
assert(['0','2','4'].every((id,index)=>card(id).classList.contains('message-tone-'+index)),'filtered record tones rebase before virtualization');
assert(style(card('2')).backgroundColor===rgb(style(root).getPropertyValue('--reading-record-1').trim()),'cached middle record recolors after filter');
$('clear-filters').click();await wait(()=>card('1')&&card('2'),'filter cleared');await sleep(80);assert(card('2').classList.contains('message-tone-2'),'clearing filter restores original ordinal');await openAppearance();
ReaderAppearance.restore('light');await click('#import-reading-font');const fontChoice=(await saved()).preferences.fontChoice;
assert(fontChoice.startsWith('import:')&&[...document.fonts].some(f=>f.status==='loaded'),'imported font loaded');
await click('#import-reading-skin');const imported=(await saved()).preferences.skinId;
assert(/^[a-f0-9]{64}$/.test(imported)&&$('reading-skin').value===imported,'imported green is selected by its own hash');
assert((await saved()).preferences.fontChoice===fontChoice,'import preserves imported font');
await select('reading-skin','paper-green');assert($('reading-skin').value==='paper-green','same named built-in remains distinct');
await select('reading-skin',imported);assert($('reading-skin').value===imported,'same named import remains distinct');
await select('reading-skin','default');assert(!root.classList.contains('custom-reading-skin')&&!root.style.getPropertyValue('--panel'),'original skin clears overrides');assert((await saved()).preferences.fontChoice===fontChoice,'original keeps font');assert(new Set(['0','1','2'].map(id=>style(card(id)).backgroundColor)).size===1,'returning to original restores group-based colors');
await select('reading-skin','claude-code');await click('[data-consecutive-spacing="5"]');$('done-reading-appearance').click();
await request('testResize',{width:1120,height:700});await sleep(120);await openAppearance();noOverflow();
const footer=$('done-reading-appearance'),fr=rect(footer);assert(inside(footer,$('reading-appearance-dialog'))&&footer.contains(document.elementFromPoint(fr.left+fr.width/2,fr.top+fr.height/2)),'footer reachable at minimum height');
await shot('minimum-settings');$('done-reading-appearance').click();
$('reader-scroll').scrollTop=0;await sleep(80);const c=card('2'),rail=c.querySelector('.message-actions');await request('testFocus');rail.firstElementChild.focus();await sleep(120);assert(inside(rail,c)&&rect(rail).bottom<=rect(c.querySelector('.message-body-row')).top+1,'narrow actions stay separate');await shot('narrow-reader');
window.dispatchEvent(new CustomEvent('weiyue:bookmark-jump',{detail:{groupId:'g',messageId:'150'}}));await wait(()=>card('150'),'deep target');await sleep(250);
assert(!card('0')&&[...document.querySelectorAll('.message-card')].every(item=>item.classList.contains('message-tone-'+(Number(item.dataset.messageId)%3))),'virtual window retains full-sequence record tones');
const readingAnchor=()=>{const top=rect($('reader-scroll')).top,c=[...document.querySelectorAll('.message-card')].find(c=>rect(c).bottom>top+1);return {id:c.dataset.messageId,offset:top-rect(c).top};};
const before=readingAnchor();await openAppearance();await click('[data-consecutive-spacing="1"]');await sleep(250);const after=readingAnchor();
assert(before.id===after.id&&Math.abs(before.offset-after.offset)<2,'spacing keeps deep reading anchor '+JSON.stringify({before,after}));
await click('[data-consecutive-spacing="4"]');await click('[data-reading-density="3"]');$('done-reading-appearance').click();
await window.flushBeforeQuit();assert(window.__errors.length===0,'no script errors '+JSON.stringify(window.__errors));
return JSON.stringify({legacyGap:initialGap,spacingGaps:measures,threeBuiltIns:true,fourPalettes:true,recordColorsAlternate:true,recordContrast:true,filteredAndVirtualTones:true,markerCuesPreserved:true,accentIcons:true,fontPreserved:true,importIDsDistinct:true,minimumHeight:true,deepAnchorPreserved:true});
"""#
    static let reloadTests = #"""
assert(root.dataset.readingDensity==='3'&&root.dataset.readingConsecutiveSpacing==='4'&&root.dataset.readingSkin==='claude-code','density, independent spacing and skin restored');
const current=await saved();assert(current.preferences.fontChoice.startsWith('import:')&&[...document.fonts].some(f=>f.status==='loaded'),'font restored with built-in skin');
await openAppearance();assert(document.querySelector('[data-consecutive-spacing="4"]').getAttribute('aria-pressed')==='true'&&$('reading-spacing-status').textContent.includes('独立'),'independent setting visible after reload');
await click('#reset-reading-appearance');const reset=await saved();assert(reset.preferences.consecutiveSpacing==='follow'&&reset.preferences.density===3&&reset.preferences.skinId==='default'&&reset.preferences.fontChoice==='system','reset restores every default');
assert(reset.skins.length===1&&reset.fonts.length===1&&reset.builtInSkins.length===3,'reset keeps imports and built-ins');
assert(!root.classList.contains('custom-reading-skin')&&!root.style.getPropertyValue('--reading-accent-ink'),'reset removes skin-specific values');noOverflow();assert(window.__errors.length===0,'no reload script errors');
return JSON.stringify({reload:true,reset:true,assetsRetained:true});
"""#
}
