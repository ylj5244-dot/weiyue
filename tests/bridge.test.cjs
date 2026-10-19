'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const bridgePath = path.join(__dirname, '../Resources/bridge/weibo.js');
const nodeFetchBeforeImport = globalThis.fetch;
const bridge = fs.existsSync(bridgePath) ? require(bridgePath) : {};
const origin = 'https://api.weibo.com';
const profileURL = origin + '/webim/query_primary_info.json';
const groupsURL = origin + '/webim/2/direct_messages/contacts.json?special_source=3';
const messageURL = origin + '/webim/groupchat/query_messages.json?id=9007199254740993123&count=20';
const rawMessage = '{"messages":[{"id":9007199254740993124,"from_uid":9007199254740993125,"time":1700000000,"content":"第一段\\n\\n  第二段","from_user":{"screen_name":"同名成员"},"pic_urls":[{"large":{"url":"https://example.org/a.png"}}]}]}';
const flush = async () => { for (let i = 0; i < 8; i++) await new Promise(setImmediate); };

test('exports normalizers without installing a browser observer in Node', () => {
  assert.equal(typeof bridge.normalizeResponse, 'function');
  assert.equal(typeof bridge.install, 'function');
  assert.equal(globalThis.fetch, nodeFetchBeforeImport);
  assert.equal(globalThis.__weiboReaderBridgeDiagnostics, undefined);
});

test('parses 64-bit identifiers before Number rounding without changing quoted content', () => {
  const parsed = bridge.parseJSON('{"id":9007199254740993123,"count":20,"text":"id:9007199254740993123; \\\"mid\\\": 123","nested":{"from_uid":9007199254740993124}}');
  assert.equal(parsed.id, '9007199254740993123');
  assert.equal(parsed.nested.from_uid, '9007199254740993124');
  assert.equal(parsed.count, 20);
  assert.equal(parsed.text, 'id:9007199254740993123; "mid": 123');
});

test('profile response identifies the account using a string ID', () => {
  assert.deepEqual(bridge.normalizeResponse(origin + '/webim/query_primary_info.json', '{"profile":{"id":9007199254740993123,"screen_name":"测试账号"}}'), {
    type: 'profile', accountId: '9007199254740993123', name: '测试账号'
  });
});

test('only explicit groups are emitted, retaining distinct IDs with the same name', () => {
  const event = bridge.normalizeResponse(origin + '/webim/2/direct_messages/contacts.json?special_source=3', {
    contacts: [
      {user: {id: '11', name: '同名群', type: 2}},
      {user: {id: '12', name: '同名群', type: 2}},
      {user: {id: '13', name: '私聊'}},
      {user: {id: '14', name: '虚拟收件箱', type: 3}},
      {user: {id: '11', name: '重复条目', type: 2}}
    ]
  });
  assert.deepEqual(event, {type: 'groups', groups: [
    {id: '11', name: '同名群', selected: false},
    {id: '12', name: '同名群', selected: false}
  ]});
});

test('normalizes complete message text, sender, time and safe attachments without guessing a deep link', () => {
  assert.deepEqual(bridge.normalizeResponse(messageURL, rawMessage), {
    type: 'messages', groupId: '9007199254740993123', messages: [{
      id: '9007199254740993124', groupId: '9007199254740993123',
      senderId: '9007199254740993125', senderName: '同名成员',
      text: '第一段\n\n  第二段', sentAt: '2023-11-14T22:13:20.000Z',
      attachments: [{type: 'image', url: 'https://example.org/a.png', name: ''}],
      sourceURL: 'https://api.weibo.com/chat'
    }]
  });
});

test('messages with absent or zero sender IDs do not reject the surrounding valid history batch', () => {
  const event = bridge.normalizeResponse(messageURL, {messages: [
    {id: '101', from_uid: '201', from_user: {screen_name: '成员'}, time: 1700000000, content: '普通消息'},
    {id: '102', from_uid: 0, time: 1700000001, content: '未提供发送者的通知'},
    {id: '103', time: 1700000002, content: '缺少发送者资料'},
    {id: '104', from_user: {idstr: '204', screen_name: '资料中有明确 ID'}, time: 1700000003, content: '已确认资料'}
  ]});
  assert.deepEqual(event.messages.map(message => [message.id, message.senderId, message.senderName]), [
    ['101', '201', '成员'],
    ['102', 'unknown:102', '发送者待确认'],
    ['103', 'unknown:103', '发送者待确认'],
    ['104', '204', '资料中有明确 ID']
  ]);
  assert.equal(event.messages.length, 4);
});

test('group screen_name is accepted when its explicit group record has no usable name', () => {
  assert.deepEqual(bridge.normalizeGroups({contacts: [
    {user: {id: '15', type: 2, screen_name: '仅昵称群'}},
    {user: {id: '16', type: 2, name: '  ', screen_name: '名称留空群'}}
  ]}), {type: 'groups', groups: [
    {id: '15', name: '仅昵称群', selected: false},
    {id: '16', name: '名称留空群', selected: false}
  ]});
});

test('unsafe parsed IDs, missing timestamps and conflicting group IDs cannot be silently imported', () => {
  assert.equal(typeof bridge.normalizeResponse, 'function');
  const common = {id: '22', from_uid: '23', time: 1700000000, content: 'fixture'};
  for (const message of [
    {...common, id: 9007199254740993124},
    {...common, from_uid: 9007199254740993124},
    {...common, time: undefined},
    {...common, gid: '999'}
  ]) assert.throws(() => bridge.normalizeResponse(messageURL, {messages: [message]}));
  assert.throws(() => bridge.normalizeResponse(messageURL, '{"messages":[{"id":9.007199254740993e18,"time":1700000000}]}'));
});

test('remote errors and malformed envelopes never become empty successful batches', () => {
  const event = bridge.normalizeResponse(messageURL, {error_code: 21301, error: 'private server detail'});
  assert.equal(event.type, 'status');
  assert.match(event.text, /21301/);
  assert.doesNotMatch(event.text, /private server detail/);
  assert.throws(() => bridge.normalizeResponse(messageURL, {unexpected: []}));
  assert.deepEqual(bridge.normalizeResponse(messageURL, {messages: []}), {
    type: 'messages', groupId: '9007199254740993123', messages: []
  });
});

test('fractional ID tokens cannot round into apparently safe integer identifiers', () => {
  for (const token of ['9007199254740991.1', '1.00000000000000001', '1.00000000000000001e1']) {
    assert.throws(() => bridge.normalizeResponse(messageURL,
      '{"messages":[{"id":' + token + ',"time":1700000000}]}'));
  }
});

test('only the three exact HTTPS official paths are accepted', () => {
  for (const url of [
    'https://evil.example/webim/query_primary_info.json',
    'http://api.weibo.com/webim/query_primary_info.json',
    origin + '/webim/query_primary_info.json/extra',
    origin + '/webim/2/direct_messages/conversation.json',
    origin + '/webim/groupchat/clear_unread.json'
  ]) assert.equal(bridge.normalizeResponse(url, '{}'), null);
});

function fakeWindow(fetchImpl, hostOrigin = origin) {
  const events = [];
  const target = new EventTarget();
  return {events, location: {origin: hostOrigin, href: hostOrigin + '/chat'}, fetch: fetchImpl,
    addEventListener: target.addEventListener.bind(target), dispatchEvent: target.dispatchEvent.bind(target),
    webkit: {messageHandlers: {weibo: {postMessage(event) {events.push(event);}}}}};
}

function deferredPage() {
  const requests = [];
  const win = fakeWindow(url => {
    let resolve, reject;
    const promise = new Promise((yes, no) => {resolve = yes; reject = no;});
    requests.push({url, promise, resolve(body, status = 200) {resolve(new Response(typeof body === 'string' ? body : JSON.stringify(body), {status}));}, reject});
    return promise;
  });
  bridge.install(win);
  return {win, requests, start(url) {win.fetch(url).catch(() => {}); return requests.at(-1);}};
}

test('unknown identity buffers only current-epoch responses, then emits profile before account-tagged data', async () => {
  const page = deferredPage();
  const beforeIdentity = page.start(messageURL);
  const profile = page.start(profileURL);
  const messages = page.start(messageURL);
  const groups = page.start(groupsURL);
  beforeIdentity.resolve(rawMessage);
  messages.resolve(rawMessage);
  groups.resolve({contacts: [{user: {id: '11', name: '测试群', type: 2}}]});
  await flush();
  assert.deepEqual(page.win.events, []);
  profile.resolve({profile: {id: '1001', screen_name: '账号 A'}});
  await flush();
  assert.deepEqual(page.win.events.map(event => [event.type, event.accountId]), [
    ['profile', '1001'], ['messages', '1001'], ['groups', '1001']
  ]);
  assert.equal(page.win.events[1].messages[0].id, '9007199254740993124');
});

test('starting another profile request invalidates A immediately and drops late A messages and profiles', async () => {
  const page = deferredPage();
  const firstProfile = page.start(profileURL);
  firstProfile.resolve({profile: {id: '1001', screen_name: '账号 A'}});
  await flush();
  page.win.events.length = 0;
  const oldMessages = page.start(messageURL);
  const oldProfile = page.start(profileURL);
  const newProfile = page.start(profileURL);
  const newMessages = page.start(messageURL);
  newMessages.resolve(rawMessage);
  oldMessages.resolve(rawMessage);
  oldProfile.resolve({profile: {id: '1001', screen_name: '账号 A'}});
  await flush();
  assert.deepEqual(page.win.events, []);
  newProfile.resolve({profile: {id: '2002', screen_name: '账号 B'}});
  await flush();
  const subsequent = page.start(groupsURL);
  subsequent.resolve({contacts: []});
  await flush();
  assert.deepEqual(page.win.events.map(event => [event.type, event.accountId]), [
    ['profile', '2002'], ['messages', '2002'], ['groups', '2002']
  ]);
});

test('failed profile and authentication errors discard buffered and in-flight data until a new identity succeeds', async () => {
  for (const failure of ['network', 'invalid-json', 'api']) {
    const page = deferredPage();
    const profile = page.start(profileURL);
    const pending = page.start(messageURL);
    pending.resolve(rawMessage);
    await flush();
    if (failure === 'network') profile.reject(new Error('network'));
    else if (failure === 'invalid-json') profile.resolve('{broken');
    else profile.resolve({error_code: 21301});
    await flush();
    assert.equal(page.win.events.some(event => ['messages', 'groups', 'profile'].includes(event.type)), false);
    const later = page.start(messageURL);
    later.resolve(rawMessage);
    await flush();
    assert.equal(page.win.events.some(event => event.type === 'messages'), false);
  }
  const page = deferredPage();
  page.start(profileURL).resolve({profile: {id: '1001', screen_name: '账号 A'}});
  await flush();
  page.win.events.length = 0;
  const stale = page.start(messageURL);
  page.start(groupsURL).resolve({error_code: 21301});
  await flush();
  stale.resolve(rawMessage);
  page.start(messageURL).resolve(rawMessage);
  await flush();
  assert.equal(page.win.events.some(event => event.type === 'messages'), false);
});

test('identity wait buffer is bounded to thirty response events', async () => {
  const page = deferredPage();
  const profile = page.start(profileURL);
  for (let i = 0; i < 33; i++) page.start(messageURL).resolve(rawMessage);
  await flush();
  assert.equal(page.win.events.some(event => event.type === 'messages'), false);
  assert.equal(page.win.__weiboReaderBridgeDiagnostics.buffered, 30);
  profile.resolve({profile: {id: '1001', screen_name: '账号 A'}});
  await flush();
  const data = page.win.events.filter(event => event.type === 'messages');
  assert.equal(data.length, 30);
  assert.equal(data.every(event => event.accountId === '1001'), true);
  assert.equal(page.win.__weiboReaderBridgeDiagnostics.buffered, 0);
});

test('entering the login hash route clears identity and ignores prior requests before reauthentication', async () => {
  const page = deferredPage();
  page.start(profileURL).resolve({profile: {id: '1001', screen_name: '账号 A'}});
  await flush();
  page.win.events.length = 0;
  const stale = page.start(messageURL);
  page.win.location.href = origin + '/chat#/login';
  page.win.dispatchEvent(new Event('hashchange'));
  stale.resolve(rawMessage);
  page.start(messageURL).resolve(rawMessage);
  await flush();
  assert.equal(page.win.events.some(event => event.type === 'messages'), false);
  page.win.location.href = origin + '/chat#/chat';
  page.win.dispatchEvent(new Event('hashchange'));
  const newProfile = page.start(profileURL);
  page.start(messageURL).resolve(rawMessage);
  await flush();
  newProfile.resolve({profile: {id: '2002', screen_name: '账号 B'}});
  await flush();
  assert.deepEqual(page.win.events.filter(event => event.type !== 'status').map(event => [event.type, event.accountId]), [
    ['profile', '2002'], ['messages', '2002']
  ]);
});

test('a profile requested using a URL object also invalidates the previous account immediately', async () => {
  const page = deferredPage();
  page.start(profileURL).resolve({profile: {id: '1001', screen_name: '账号 A'}});
  await flush();
  page.win.events.length = 0;
  const next = page.start(new URL(profileURL));
  page.start(messageURL).resolve(rawMessage);
  await flush();
  assert.deepEqual(page.win.events, []);
  next.resolve({profile: {id: '2002', screen_name: '账号 B'}});
  await flush();
  assert.deepEqual(page.win.events.map(event => [event.type, event.accountId]), [
    ['profile', '2002'], ['messages', '2002']
  ]);
});

test('a response whose cloned body finishes after an identity change is discarded', async () => {
  let finishBody;
  const body = new Promise(resolve => {finishBody = resolve;});
  const delayed = {status: 200, url: messageURL, clone() {return {text() {return body;}};}};
  let account = '1001';
  const win = fakeWindow(url => Promise.resolve(url === profileURL
    ? new Response(JSON.stringify({profile: {id: account, screen_name: '合成账号'}})) : delayed));
  bridge.install(win);
  await win.fetch(profileURL);
  await flush();
  await win.fetch(messageURL);
  await flush();
  win.events.length = 0;
  account = '2002';
  await win.fetch(profileURL);
  await flush();
  finishBody(rawMessage);
  await flush();
  assert.deepEqual(win.events.map(event => [event.type, event.accountId]), [['profile', '2002']]);
});

test('concurrent XHR history is buffered under the new profile epoch and old-account responses are discarded', () => {
  class DelayedXHR extends EventTarget {
    constructor() {super(); this.responseType = ''; this.responseURL = ''; this.status = 200;}
    open() {}
    send() {}
    finish(body) {this.responseText = typeof body === 'string' ? body : JSON.stringify(body); this.dispatchEvent(new Event('load'));}
  }
  const win = fakeWindow(undefined);
  win.XMLHttpRequest = DelayedXHR;
  bridge.install(win);
  const start = url => {const xhr = new DelayedXHR(); xhr.open('GET', url); xhr.send(); return xhr;};
  start(profileURL).finish({profile: {id: '1001', screen_name: '账号 A'}});
  win.events.length = 0;
  const old = start(messageURL);
  const profile = start(profileURL);
  const fresh = start(messageURL);
  fresh.finish(rawMessage);
  old.finish(rawMessage);
  assert.deepEqual(win.events, []);
  profile.finish({profile: {id: '2002', screen_name: '账号 B'}});
  assert.deepEqual(win.events.map(event => [event.type, event.accountId]), [
    ['profile', '2002'], ['messages', '2002']
  ]);
  win.events.length = 0;
  const failedProfile = start(profileURL);
  start(messageURL).finish(rawMessage);
  failedProfile.dispatchEvent(new Event('error'));
  start(messageURL).finish(rawMessage);
  assert.equal(win.events.some(event => event.type === 'messages'), false);
});

test('fetch observer preserves exact promise, response, this and arguments without consuming the body', async () => {
  const response = new Response(rawMessage);
  const promise = Promise.resolve(response);
  let originalCall;
  const win = fakeWindow(function (...args) {
    if (args[0] === profileURL) return Promise.resolve(new Response('{"profile":{"id":"1001","screen_name":"账号 A"}}'));
    originalCall = {receiver: this, args}; return promise;
  });
  const receiver = {};
  const options = {credentials: 'include'};
  assert.equal(bridge.install(win), true);
  assert.equal(bridge.install(win), false);
  await win.fetch(profileURL);
  await flush();
  win.events.length = 0;
  const returned = win.fetch.call(receiver, messageURL, options);
  assert.equal(returned, promise);
  assert.equal(await returned, response);
  await flush();
  assert.equal(originalCall.receiver, receiver);
  assert.deepEqual(originalCall.args, [messageURL, options]);
  assert.equal(response.bodyUsed, false);
  assert.equal(await response.text(), rawMessage);
  assert.equal(win.events.length, 1);
  assert.equal(win.events[0].messages[0].id, '9007199254740993124');
  assert.equal(win.__weiboReaderBridgeDiagnostics.messages, 1);
});

test('fetch failures and unrelated or redirected responses keep original behavior and stay uncaptured', async () => {
  const failure = new Error('original network error');
  const rejected = Promise.reject(failure);
  rejected.catch(() => {});
  const win = fakeWindow(() => rejected);
  bridge.install(win);
  assert.equal(win.fetch(messageURL), rejected);
  await assert.rejects(rejected, error => error === failure);
  await flush();
  assert.deepEqual(win.events, []);
  const sync = fakeWindow(() => {throw failure;});
  bridge.install(sync);
  assert.throws(() => sync.fetch(messageURL), error => error === failure);
  const redirected = new Response(rawMessage);
  Object.defineProperty(redirected, 'url', {value: 'https://evil.example/message'});
  const other = fakeWindow(() => Promise.resolve(redirected));
  bridge.install(other);
  await other.fetch(messageURL);
  await other.fetch(origin + '/webim/2/direct_messages/conversation.json');
  await flush();
  assert.deepEqual(other.events, []);
});

test('observer failures cannot reject the page fetch or leak response bodies into status', async () => {
  const response = new Response('{bad private message');
  const win = fakeWindow(() => Promise.resolve(response));
  bridge.install(win);
  assert.equal(await win.fetch(messageURL), response);
  await flush();
  assert.equal(win.events[0].type, 'status');
  assert.doesNotMatch(win.events[0].text, /private message/);
  win.webkit.messageHandlers.weibo.postMessage = () => {throw new Error('bridge unavailable');};
  assert.equal(await win.fetch(messageURL), response);
});

test('installation is restricted to the official frame origin and never initiates a request', () => {
  let requests = 0;
  const fetch = () => {requests++;};
  const evil = fakeWindow(fetch, 'https://evil.example');
  assert.equal(bridge.install(evil), false);
  assert.equal(evil.fetch, fetch);
  const official = fakeWindow(fetch);
  bridge.install(official);
  assert.equal(requests, 0);
});

test('classic browser script auto-installs once and leaves official POST calls untouched', async () => {
  let requests = 0;
  const response = new Response(rawMessage);
  const win = fakeWindow(() => {requests++; return Promise.resolve(response);});
  const context = vm.createContext({window: win, URL, console});
  const source = fs.readFileSync(bridgePath, 'utf8');
  vm.runInContext(source, context);
  const observedFetch = win.fetch;
  vm.runInContext(source, context);
  assert.equal(win.fetch, observedFetch);
  assert.equal(requests, 0);
  assert.equal(await win.fetch(messageURL, {method: 'POST', body: 'official action'}), response);
  await flush();
  assert.equal(requests, 1);
  assert.deepEqual(win.events, []);
});

test('attachments keep safe official links and never forward executable schemes', () => {
  const event = bridge.normalizeResponse(messageURL, {messages: [{
    id: '10', time: 1700000000, content: '',
    pic: 'javascript:alert(1)', url: 'file:///Users/example/private',
    pic_urls: ['https://example.org/photo.png', 'https://example.org/photo.png'],
    url_objects: [{url_ori: 'https://example.org/article', info: {title: '资料', video_url: 'https://example.org/movie.mp4'}}]
  }]});
  assert.deepEqual(event.messages[0].attachments, [
    {type: 'image', url: 'https://example.org/photo.png', name: ''},
    {type: 'video', url: 'https://example.org/movie.mp4', name: '资料'},
    {type: 'link', url: 'https://example.org/article', name: '资料'}
  ]);
});

test('XHR observation preserves sync return values and page listeners across reuse', () => {
  class TestXHR extends EventTarget {
    constructor() {super(); this.responseType = ''; this.responseText = rawMessage; this.responseURL = ''; this.status = 200;}
    open(...args) {this.openArgs = args; return 'opened';}
    send(...args) {this.sendArgs = args; this.dispatchEvent(new Event('load')); return 'sent';}
  }
  const win = fakeWindow(undefined);
  win.XMLHttpRequest = TestXHR;
  bridge.install(win);
  const login = new TestXHR();
  login.responseText = '{"profile":{"id":"1001","screen_name":"账号 A"}}';
  login.open('GET', profileURL, false);
  login.send();
  win.events.length = 0;
  const xhr = new TestXHR();
  let pageLoads = 0;
  xhr.addEventListener('load', () => {pageLoads++;});
  assert.equal(xhr.open('GET', messageURL, false), 'opened');
  assert.equal(xhr.send(null), 'sent');
  assert.equal(win.events.length, 1);
  assert.equal(xhr.responseText, rawMessage);
  assert.deepEqual(xhr.openArgs, ['GET', messageURL, false]);
  assert.deepEqual(xhr.sendArgs, [null]);
  xhr.open('GET', origin + '/other', true);
  xhr.send();
  assert.equal(pageLoads, 2);
  assert.equal(win.events.length, 1);
  xhr.open('GET', messageURL, true);
  xhr.responseType = 'json';
  xhr.response = {messages: [{id: 9007199254740993124, time: 1700000000}]};
  xhr.send();
  assert.equal(win.events.at(-1).type, 'status');
});


function syncFixture(messages = []) {
  let time = 0, timerId = 0;
  const timers = new Map(), events = [], requests = [];
  let identity = {accountId: '1001', epoch: 1};
  let data = messages, responder = null;
  const options = {
    getIdentity: () => identity, emit: event => events.push(event), now: () => time,
    setTimeout(fn, ms) {const id = ++timerId; timers.set(id, {fn, at: time + ms}); return id;},
    clearTimeout(id) {timers.delete(id);}, AbortController,
    async fetch(url, init) {
      requests.push({url, init, at: time});
      if (responder) return responder(url, init);
      const target = new URL(url), cursor = target.searchParams.get('max_mid');
      const selected = data.filter(m => !cursor || BigInt(m.id) <= BigInt(cursor)).slice(-20);
      return new Response(JSON.stringify({messages: selected}), {status: 200});
    }
  };
  assert.equal(typeof bridge.createSynchronizer, 'function', 'a testable read-only synchronizer is exported');
  const sync = bridge.createSynchronizer(options);
  return {sync, events, requests, timers,
    setData(next) {data = next;}, setResponder(next) {responder = next;},
    setIdentity(next) {identity = next; sync.reset();},
    async advance(ms) {
      const end = time + ms;
      await flush();
      for (let guard = 0; guard < 10000; guard++) {
        const due = [...timers.entries()].filter(([, t]) => t.at <= end).sort((a,b) => a[1].at-b[1].at)[0];
        if (!due) break;
        time = due[1].at; timers.delete(due[0]); due[1].fn(); await flush();
      }
      time = end; await flush();
    }
  };
}
function fixtureMessages(count, start = 9007199254740993000n) {
  return Array.from({length: count}, (_, i) => ({id: String(start + BigInt(i)), from_uid: '22', from_user: {screen_name:'合成成员'}, time: 1700000000 + i, content: '合成 ' + i}));
}
function dataEvents(fixture) {return fixture.events.filter(e => e.type === 'messages');}

test('automatic four-second polling refreshes every selected group without a foreground-group filter', async () => {
  const f = syncFixture();
  const messages = fixtureMessages(21);
  f.setResponder(url => {
    const groupId = new URL(url).searchParams.get('id');
    assert.ok(['11','12'].includes(groupId));
    return new Response(JSON.stringify({messages: messages.slice(-2)}), {status:200});
  });
  f.sync.configure({accountId:'1001',groups:['11','12'].map(id=>({id,oldestId:messages[0].id,newestId:messages[19].id,loadedCount:20})),initialHistoryCount:0,pollIntervalMs:4000});
  await f.advance(3999); assert.equal(f.requests.length,0);
  await f.advance(501);
  assert.deepEqual([...new Set(f.requests.map(request=>new URL(request.url).searchParams.get('id')))].sort(),['11','12']);
  assert.deepEqual(dataEvents(f).map(event=>event.groupId).sort(),['11','12']);
  assert.ok(dataEvents(f).every(event=>event.messageSource==='live'&&event.requestStartedAt==='1970-01-01T00:00:04.000Z'));
  f.events.length=0;
  await f.advance(4000); assert.equal(dataEvents(f).length,0,'unchanged background pages are silent');
});

test('history and refresh events carry non-live provenance; passive requests retain their own start time', async () => {
  const f=syncFixture(fixtureMessages(25));
  f.sync.configure({accountId:'1001',groups:[{id:'11'}],initialHistoryCount:0});
  const history=f.sync.loadHistory('11',20);await f.advance(1000);await history;
  assert.ok(dataEvents(f).every(event=>event.messageSource==='history'));
  f.setData(fixtureMessages(27));f.events.length=0;
  const refresh=f.sync.replayRecent('11',20);await f.advance(1000);await refresh;
  assert.ok(dataEvents(f).length>0&&dataEvents(f).every(event=>event.messageSource==='refresh'));
  const page=deferredPage();page.start(profileURL).resolve({profile:{id:'1001',screen_name:'Synthetic'}});await flush();
  const old=page.start(messageURL+'&max_mid=9007199254740993124');old.resolve(rawMessage);await flush();
  const historyEvent=page.win.events.find(event=>event.type==='messages');
  assert.equal(historyEvent.messageSource,'history');assert.ok(Number.isFinite(Date.parse(historyEvent.requestStartedAt)));
  page.win.events.length=0;page.start(messageURL).resolve(rawMessage);await flush();
  assert.equal(page.win.events.find(event=>event.type==='messages').messageSource,'passive');
});

test('sync is opt-in, checks the confirmed account and only requests selected groups with GET', async () => {
  const f = syncFixture(fixtureMessages(30));
  await f.advance(10000);
  assert.equal(f.requests.length, 0);
  assert.throws(() => f.sync.configure({accountId:'2002', groups:[{id:'11'}]}), /账号/);
  assert.equal(f.sync.configure({accountId:'1001', groups:[{id:'11'}], initialHistoryCount:0}).ok, true);
  await assert.rejects(f.sync.loadHistory('12',20), /群/);
  const job = f.sync.loadHistory('11',20);
  await f.advance(1000); await job;
  assert.equal(f.requests.length, 1);
  const {url,init} = f.requests[0];
  assert.equal(new URL(url).pathname, '/webim/groupchat/query_messages.json');
  assert.equal(new URL(url).searchParams.get('id'), '11');
  assert.equal(init.method, 'GET'); assert.equal(init.credentials, 'same-origin');
  assert.equal(init.body, undefined); assert.equal(init.headers, undefined);
  assert.equal(init.redirect, 'error');
  f.sync.pause();
});

test('sync imports 500 history records without ID rounding and continues older pages on demand', async () => {
  const f = syncFixture(fixtureMessages(650));
  f.sync.configure({accountId:'1001', groups:[{id:'11'}], initialHistoryCount:0});
  const first = f.sync.loadHistory('11',500); await f.advance(12000);
  const result = await first;
  assert.equal(result.loadedCount, 500); assert.equal(result.hasMore, true);
  const ids = dataEvents(f).flatMap(e => e.messages.map(m => m.id));
  assert.equal(new Set(ids).size,500); assert.equal(ids.length,500);
  const historyRequests = f.requests.filter(r=>new URL(r.url).searchParams.has('max_mid'));
  assert.equal(new URL(historyRequests[0].url).searchParams.get('max_mid'),'9007199254740993629');
  const second = f.sync.loadHistory('11',500); await f.advance(12000);
  const next = await second;
  assert.equal(next.loadedCount,150); assert.equal(next.hasMore,false);
  assert.equal(new Set(dataEvents(f).flatMap(e=>e.messages.map(m=>m.id))).size,650);
  assert.ok(dataEvents(f).every(e=>e.accountId==='1001'));
  f.sync.pause();
});

test('live polling fills more than one page back to the known newest and is silent with no new IDs', async () => {
  const all = fixtureMessages(110);
  const f = syncFixture(all.slice(0,40));
  f.sync.configure({accountId:'1001',groups:[{id:'11',oldestId:all[0].id,newestId:all[39].id}],initialHistoryCount:0});
  await f.advance(4100);
  assert.equal(dataEvents(f).flatMap(e=>e.messages).length,20); // First session pass refreshes old attachments.
  f.events.length=0;
  f.setData(all);
  await f.advance(7000);
  const ids = dataEvents(f).flatMap(e=>e.messages.map(m=>m.id));
  assert.equal(ids.length,70); assert.equal(new Set(ids).size,70);
  assert.equal(ids.includes(all[39].id),false);
  const count = dataEvents(f).length;
  await f.advance(10000);
  assert.equal(dataEvents(f).length,count);
  f.sync.pause();
});

test('sync pause and account reset cancel late requests; resuming cannot archive a previous account', async () => {
  const f = syncFixture(); let resolve;
  f.setResponder(() => new Promise(yes=>{resolve=yes;}));
  f.sync.configure({accountId:'1001',groups:[{id:'11'}],initialHistoryCount:0});
  const first = f.sync.loadHistory('11',20); await flush();
  f.sync.pause(); assert.equal(f.requests[0].init.signal.aborted,true);
  resolve(new Response(JSON.stringify({messages:fixtureMessages(20)}))); await flush();
  assert.equal((await first).cancelled,true); assert.equal(dataEvents(f).length,0);
  f.sync.resume();
  const second = f.sync.loadHistory('11',20); await f.advance(500);
  f.setIdentity({accountId:'2002',epoch:2});
  resolve(new Response(JSON.stringify({messages:fixtureMessages(20)}))); await flush();
  assert.equal((await second).cancelled,true); assert.equal(dataEvents(f).length,0);
  assert.throws(()=>f.sync.resume(), /账号/);
});

test('HTTP 429 honours Retry-After globally and retries the same history cursor', async () => {
  const f = syncFixture(fixtureMessages(25)); let attempts=0;
  f.setResponder(url=>{
    if (++attempts===1) return new Response('{}',{status:429,headers:{'Retry-After':'10'}});
    return new Response(JSON.stringify({messages:fixtureMessages(20)}));
  });
  f.sync.configure({accountId:'1001',groups:[{id:'11'}],initialHistoryCount:0});
  const work=f.sync.loadHistory('11',20);
  await f.advance(9000); assert.equal(f.requests.length,1);
  assert.ok(f.events.some(e=>e.type==='sync'&&e.state==='backoff'));
  await f.advance(1500); assert.ok(f.requests.length>=2); assert.equal(f.requests[1].at>=10000,true);
  assert.equal((await work).loadedCount,20);
  f.sync.pause();
});

test('group unread counts retain official values without inventing absent counters', () => {
  const groups=bridge.normalizeGroups({contacts:[{user:{id:'1',type:2,name:'群'},unread_count:358},{user:{id:'2',type:2,name:'另一个'}}]}).groups;
  assert.equal(groups[0].unreadCount,358); assert.equal('unreadCount' in groups[1],false);
});

test('installed sync uses the original transport once and resets when another profile request starts', async () => {
  let finish;
  const calls=[];
  const win=fakeWindow((url,init)=>{
    calls.push({url,init});
    if(url===profileURL)return Promise.resolve(new Response('{"profile":{"id":"1001"}}'));
    return new Promise(resolve=>{finish=resolve;});
  });
  win.setTimeout=setTimeout; win.clearTimeout=clearTimeout; win.AbortController=AbortController;
  bridge.install(win);
  assert.equal(typeof win.__weiboReaderSync,'object');
  assert.throws(()=>win.__weiboReaderSync.configure({accountId:'1001',groups:[{id:'11'}]}),/账号/);
  await win.fetch(profileURL); await flush();
  win.__weiboReaderSync.configure({accountId:'1001',groups:[{id:'11'}],initialHistoryCount:0});
  const job=win.__weiboReaderSync.loadHistory('11',20); await flush();
  assert.equal(calls.length,2);
  await win.fetch(profileURL); await flush();
  assert.equal(calls[1].init.signal.aborted,true);
  finish(new Response(JSON.stringify({messages:fixtureMessages(20)}))); await flush();
  assert.equal((await job).cancelled,true);
  assert.equal(win.events.some(e=>e.type==='messages'),false);
  win.__weiboReaderSync.pause();
});

test('live gap survives a failed middle page without advancing its completed newest watermark', async () => {
  const all=fixtureMessages(110),f=syncFixture(all);let calls=0;
  f.setResponder(url=>{
    if(++calls===2)return new Response('{}',{status:503});
    const cursor=new URL(url).searchParams.get('max_mid');
    return new Response(JSON.stringify({messages:all.filter(m=>!cursor||BigInt(m.id)<=BigInt(cursor)).slice(-20)}));
  });
  f.sync.configure({accountId:'1001',groups:[{id:'11',oldestId:all[0].id,newestId:all[39].id}],initialHistoryCount:0});
  const first=f.sync.syncNow('11'); first.catch(()=>{});await f.advance(1000);
  await assert.rejects(first,/503/);
  const second=f.sync.syncNow('11');await f.advance(3000);await second;
  const ids=dataEvents(f).flatMap(e=>e.messages.map(m=>m.id));
  assert.equal(ids.filter(id=>BigInt(id)>BigInt(all[39].id)).length,70);assert.equal(new Set(ids).size,ids.length);
  f.sync.pause();
});

test('history advances past passively observed duplicate pages and finds the exact resume message', async () => {
  const all=fixtureMessages(40),f=syncFixture(all);
  f.sync.configure({accountId:'1001',groups:[{id:'11',resumeMessageId:all[5].id}],initialHistoryCount:0});
  f.sync.observe({type:'messages',accountId:'1001',groupId:'11',messages:bridge.normalizeMessages({messages:all.slice(-20)},'11').messages});
  const job=f.sync.loadHistory('11',20);await f.advance(1000);
  assert.equal(f.requests.length,2);
  const result=await job;
  assert.equal(result.loadedCount,20);assert.equal(result.anchorReached,true);
  assert.equal(f.requests.length,2);f.sync.pause();
});

test('normalizes official picture metadata and MSS file IDs using safe string URLs', () => {
  const messages=bridge.normalizeMessages({messages:[
    {id:'1',time:1700000000,media_type:1,pic_infos:[{original_pic:'https://example.org/original.gif',thumbnail_pic:'https://example.org/thumb.gif'}]},
    {id:'2',time:1700000000,media_type:5,fids:['9007199254740993123'],filename:'研究.pdf',filesize:1024},
    {id:'3',time:1700000000,media_type:1,fids:'abc:123,abc:456'},
    {id:'4',time:1700000000,media_type:5,fids:[9007199254740993123]},
    {id:'5',time:1700000000,media_type:1,pic_infos:[{original_pic:'javascript:bad',thumbnail_pic:'file:///bad'}]}
  ]},'11').messages;
  assert.deepEqual(messages[0].attachments,[{type:'image',url:'https://example.org/original.gif',name:'',thumbnailURL:'https://example.org/thumb.gif'}]);
  assert.deepEqual(messages[1].attachments,[{type:'document',url:'https://upload.api.weibo.com/2/mss/msget?source=209678993&fid=9007199254740993123',name:'研究.pdf',size:1024}]);
  assert.equal(messages[2].attachments.length,2);assert.equal(new URL(messages[2].attachments[0].url).searchParams.get('fid'),'abc:123');
  assert.equal(messages[3].attachments.length,0);assert.equal(messages[4].attachments.length,0);
});

test('removing a selected group aborts its request and never emits a late archive batch', async () => {
  const f=syncFixture();let finish;
  f.setResponder(()=>new Promise(resolve=>{finish=resolve;}));
  f.sync.configure({accountId:'1001',groups:[{id:'11'}],initialHistoryCount:0});
  const job=f.sync.loadHistory('11',20);await flush();
  f.sync.configure({accountId:'1001',groups:[],initialHistoryCount:0});
  assert.equal(f.requests[0].init.signal.aborted,true);
  finish(new Response(JSON.stringify({messages:fixtureMessages(20)})));await flush();
  assert.equal((await job).cancelled,true);assert.equal(dataEvents(f).length,0);f.sync.pause();
});

test('active authentication errors stop all selected groups until profile is confirmed again', async () => {
  const f=syncFixture();f.setResponder(()=>new Response('{"error_code":21301,"error":"private detail"}'));
  f.sync.configure({accountId:'1001',groups:[{id:'11'}],initialHistoryCount:0});
  const job=f.sync.loadHistory('11',20);await flush();
  assert.equal((await job).cancelled,true);
  const count=f.requests.length;await f.advance(20000);
  assert.equal(f.requests.length,count);assert.equal(dataEvents(f).length,0);
  assert.throws(()=>f.sync.resume(),/账号/);
});

test('malformed active responses never include private response text in errors or status', async () => {
  const f=syncFixture();f.setResponder(()=>new Response('secret_private_text_not_json'));
  f.sync.configure({accountId:'1001',groups:[{id:'11'}],initialHistoryCount:0});
  await assert.rejects(f.sync.loadHistory('11',20),error=>!String(error.message).includes('secret'));
  assert.equal(JSON.stringify(f.events).includes('secret'),false);f.sync.pause();
});

test('a stalled history response times out and releases the loading state', async () => {
  const f=syncFixture();f.setResponder(()=>new Promise(()=>{}));
  f.sync.configure({accountId:'1001',groups:[{id:'11'}],initialHistoryCount:0});
  let failure=null;
  const job=f.sync.loadHistory('11',20).catch(error=>{failure=error;});
  await f.advance(21000);
  assert.ok(failure && /超时/.test(failure.message));
  assert.ok(f.events.some(e=>e.type==='sync'&&e.state==='error'));
  assert.equal(f.requests[0].init.signal.aborted,true);
  f.sync.pause();await job;
});


test('initial history fills only the deficit from the local loaded count on every new page session', async () => {
  const all=fixtureMessages(650),f=syncFixture(all);
  f.sync.configure({accountId:'1001',groups:[{id:'11',oldestId:all[392].id,newestId:all[649].id,loadedCount:258}],initialHistoryCount:500});
  await f.advance(12000);
  const imported=dataEvents(f).flatMap(e=>e.messages).filter(m=>BigInt(m.id)<BigInt(all[392].id));
  assert.equal(imported.length,260); // 242 requested, rounded up to full 20-item pages.
  assert.equal(imported.some(m=>m.id===all[0].id),false);
  f.sync.pause();
  const settled=syncFixture(all);
  settled.sync.configure({accountId:'1001',groups:[{id:'11',oldestId:all[150].id,newestId:all[649].id,loadedCount:500}],initialHistoryCount:500});
  await settled.advance(1000);assert.equal(settled.requests.length,0);
  settled.sync.pause();
});

test('first overlap page refreshes existing messages, while later identical content is not re-emitted', async () => {
  const all=fixtureMessages(30),f=syncFixture(all);
  f.sync.configure({accountId:'1001',groups:[{id:'11',oldestId:all[0].id,newestId:all[29].id,loadedCount:30}],initialHistoryCount:0});
  const first=f.sync.syncNow('11');await f.advance(500);await first;
  assert.equal(dataEvents(f).flatMap(e=>e.messages).length,20);
  const count=dataEvents(f).length;
  const second=f.sync.syncNow('11');await f.advance(500);await second;
  assert.equal(dataEvents(f).length,count);
  all[29]={...all[29],media_type:1,fids:['9007199254740993999']};f.setData(all);
  const third=f.sync.syncNow('11');await f.advance(500);await third;
  assert.equal(dataEvents(f).length,count+1);
  assert.equal(dataEvents(f).at(-1).messages.length,1);
  assert.equal(dataEvents(f).at(-1).messages[0].attachments[0].type,'image');
  f.sync.pause();
});

test('manual sync with zero messages always emits completion, including repeated identical checks', async () => {
  const f=syncFixture([]);
  f.sync.configure({accountId:'1001',groups:[{id:'11'}],initialHistoryCount:0});
  for(let attempt=0;attempt<2;attempt++) {
    f.events.length=0;
    const job=f.sync.syncNow('11');await f.advance(500);
    assert.equal((await job).loadedCount,0);
    const complete=f.events.filter(event=>event.type==='sync'&&event.groupId==='11').at(-1);
    assert.ok(complete,'each manual request must finish the frontend loading state');
    assert.equal(complete.state,'idle');assert.equal(complete.phase,'live');assert.match(complete.text,/暂无新消息/);
  }
  f.events.length=0;await f.advance(5000);
  assert.equal(f.events.filter(event=>event.type==='sync').length,0,'unchanged automatic polling remains quiet');
  f.sync.pause();
});

test('manual sync of already-seen overlap ends idle without inventing new messages', async () => {
  const all=fixtureMessages(20),f=syncFixture(all);
  f.sync.configure({accountId:'1001',groups:[{id:'11',oldestId:all[0].id,newestId:all[19].id,loadedCount:20}],initialHistoryCount:0});
  const first=f.sync.syncNow('11');await f.advance(500);await first;f.events.length=0;
  const second=f.sync.syncNow('11');await f.advance(500);
  assert.equal((await second).loadedCount,0);assert.equal(dataEvents(f).length,0);
  const complete=f.events.filter(event=>event.type==='sync').at(-1);
  assert.equal(complete.state,'idle');assert.match(complete.text,/暂无新消息/);f.sync.pause();
});

test('manual sync does not claim idle while initial history is still reading or after cancellation', async () => {
  const f=syncFixture();let resolve;
  f.setResponder(()=>new Promise(yes=>{resolve=yes;}));
  f.sync.configure({accountId:'1001',groups:[{id:'11'}],initialHistoryCount:0});
  const history=f.sync.loadHistory('11',20);await flush();f.events.length=0;
  const waiting=await f.sync.syncNow('11');assert.equal(waiting.loadedCount,0);
  const status=f.events.filter(event=>event.type==='sync').at(-1);
  assert.equal(status.state,'loading');assert.equal(status.phase,'history');
  f.sync.pause();resolve(new Response(JSON.stringify({messages:[]})));await history;

  f.sync.resume();const live=f.sync.syncNow('11');await f.advance(500);
  f.sync.pause();const pauseIndex=f.events.length;
  resolve(new Response(JSON.stringify({messages:[]})));await flush();
  assert.equal((await live).cancelled,true);
  assert.equal(f.events.slice(pauseIndex).some(event=>event.type==='sync'&&event.state==='idle'),false);
});

test('manual sync retains loading when a live gap exceeds the current page budget', async () => {
  const all=fixtureMessages(6001),f=syncFixture(all);
  f.sync.configure({accountId:'1001',groups:[{id:'11',oldestId:all[0].id,newestId:all[0].id,loadedCount:1}],initialHistoryCount:0});
  const job=f.sync.syncNow('11');await f.advance(63000);
  const result=await job, status=f.events.filter(event=>event.type==='sync').at(-1);
  assert.equal(result.loadedCount,5000);assert.equal(result.newestId,all[0].id);
  assert.equal(status.state,'loading');assert.equal(status.phase,'live');assert.match(status.text,/继续补齐/);f.sync.pause();
});

test('new messages continue polling while a long older-history backfill is running', async () => {
  const all=fixtureMessages(1225),f=syncFixture(all.slice(0,1200));
  f.sync.configure({accountId:'1001',groups:[{id:'11',oldestId:all[1000].id,newestId:all[1199].id,loadedCount:200}],initialHistoryCount:0});
  const job=f.sync.loadHistory('11',1000);
  await f.advance(3000);f.setData(all);
  await f.advance(2500);
  assert.ok(dataEvents(f).some(e=>e.messages.some(m=>m.id===all[1224].id)));
  await f.advance(15000);await job;f.sync.pause();
});

test('one-time recent replay refreshes middle attachments without moving history or live watermarks', async () => {
  const all=fixtureMessages(300),f=syncFixture(all);
  all[100]={...all[100],media_type:1,fids:['9007199254740993999']};
  f.sync.configure({accountId:'1001',groups:[{id:'11',oldestId:all[42].id,newestId:all[299].id,loadedCount:258}],initialHistoryCount:0});
  assert.equal(typeof f.sync.replayRecent,'function');
  const job=f.sync.replayRecent('11',258);await f.advance(3500);
  const result=await job;
  assert.equal(result.scannedCount,258);assert.equal(result.refreshedCount,258);
  assert.equal(result.oldestId,all[42].id);assert.equal(result.newestId,all[299].id);
  const records=dataEvents(f).flatMap(e=>e.messages);
  assert.equal(records.length,258);assert.equal(records.find(m=>m.id===all[100].id).attachments[0].type,'image');
  assert.equal(records.some(m=>BigInt(m.id)<BigInt(all[42].id)),false);
  assert.ok(f.events.some(e=>e.type==='sync'&&e.phase==='refresh'&&e.state==='idle'));
  const count=dataEvents(f).length;
  const second=f.sync.replayRecent('11',258);await f.advance(4000);await second;
  assert.equal(dataEvents(f).length,count);f.sync.pause();
});

test('replay never acknowledges new-message gaps and normal polling still fills them', async () => {
  const all=fixtureMessages(100),f=syncFixture(all);
  f.sync.configure({accountId:'1001',groups:[{id:'11',oldestId:all[0].id,newestId:all[19].id,loadedCount:20}],initialHistoryCount:0});
  assert.equal(typeof f.sync.replayRecent,'function');
  const replay=f.sync.replayRecent('11',20);await f.advance(500);
  const replayResult=await replay;
  assert.equal(replayResult.newestId,all[19].id);
  const live=f.sync.syncNow('11');await f.advance(2000);await live;
  const records=dataEvents(f).flatMap(e=>e.messages);
  assert.equal(new Set(records.filter(m=>BigInt(m.id)>BigInt(all[19].id)).map(m=>m.id)).size,80);
  f.sync.pause();
});

test('replay is restricted to selected groups and cancelled batches cannot cross an account reset', async () => {
  const f=syncFixture();let finish;
  f.setResponder(()=>new Promise(resolve=>{finish=resolve;}));
  f.sync.configure({accountId:'1001',groups:[{id:'11'}],initialHistoryCount:0});
  assert.equal(typeof f.sync.replayRecent,'function');
  await assert.rejects(f.sync.replayRecent('12',20),/群/);
  await assert.rejects(f.sync.replayRecent('11',501),/500/);
  const job=f.sync.replayRecent('11',20);await flush();
  f.setIdentity({accountId:'2002',epoch:2});
  finish(new Response(JSON.stringify({messages:fixtureMessages(20)})));await flush();
  assert.equal((await job).cancelled,true);assert.equal(dataEvents(f).length,0);
});
