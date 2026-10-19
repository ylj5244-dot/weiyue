/* Original official-page observer and explicitly configured, read-only group synchronizer. */
(function () {
  'use strict';

  const ORIGIN = 'https://api.weibo.com';
  const PATHS = Object.freeze({
    '/webim/query_primary_info.json': 'profile',
    '/webim/2/direct_messages/contacts.json': 'groups',
    '/webim/groupchat/query_messages.json': 'messages'
  });
  const DIAGNOSTICS = '__weiboReaderBridgeDiagnostics';
  const MAX_BODY_LENGTH = 8 * 1024 * 1024;

  // Walk JSON tokens, never text inside a quoted string. Large integer literals
  // become strings before JSON.parse can round them. Decimal/exponent tokens
  // stay lexical strings too, so a fractional ID cannot round into an integer.
  // Already-parsed XHR JSON bodies also pass identifier()'s safety check.
  function parseJSON(source) {
    if (typeof source !== 'string' || source.length > MAX_BODY_LENGTH) {
      throw new Error('Unsupported JSON body');
    }
    let cursor = 0;
    let protectedJSON = '';
    while (cursor < source.length) {
      const start = cursor;
      const character = source[cursor];
      if (character === '"') {
        cursor++;
        while (cursor < source.length) {
          const next = source[cursor++];
          if (next === '\\') cursor++;
          else if (next === '"') break;
        }
        protectedJSON += source.slice(start, cursor);
      } else if (character === '-' || /[0-9]/.test(character)) {
        const token = source.slice(cursor).match(/^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/);
        if (!token) throw new Error('Invalid JSON number');
        const literal = token[0];
        const digits = literal[0] === '-' ? literal.slice(1) : literal;
        const largeInteger = /^[0-9]+$/.test(digits) &&
          (digits.length > 16 || (digits.length === 16 && digits > '9007199254740991'));
        protectedJSON += largeInteger || /[.eE]/.test(literal) ? '"' + literal + '"' : literal;
        cursor += literal.length;
      } else {
        protectedJSON += character;
        cursor++;
      }
    }
    return JSON.parse(protectedJSON);
  }

  function identifier(value) {
    if (typeof value === 'number' && !Number.isSafeInteger(value)) {
      throw new Error('Identifier precision unavailable');
    }
    if (typeof value !== 'string' && typeof value !== 'number') throw new Error('Invalid identifier');
    const result = String(value);
    if (!/^[1-9][0-9]*$/.test(result)) throw new Error('Invalid identifier');
    return result;
  }

  function endpoint(value) {
    try {
      const url = new URL(value, ORIGIN + '/chat');
      if (url.origin !== ORIGIN || !Object.prototype.hasOwnProperty.call(PATHS, url.pathname)) return null;
      return {url, kind: PATHS[url.pathname]};
    } catch (_) { return null; }
  }

  function normalizeProfile(data) {
    if (!data.profile || typeof data.profile !== 'object') throw new Error('Missing account profile');
    return {type: 'profile', accountId: identifier(data.profile.id),
      name: typeof data.profile.screen_name === 'string' ? data.profile.screen_name : ''};
  }

  function normalizeGroups(data) {
    if (!Array.isArray(data.contacts)) throw new Error('Missing contact list');
    const groups = [];
    const seen = new Set();
    for (const contact of data.contacts) {
      const user = contact && contact.user;
      if (!user || user.type !== 2) continue;
      const id = identifier(user.id);
      const name = typeof user.name === 'string' && user.name.trim() ? user.name : user.screen_name;
      if (typeof name !== 'string' || !name.trim()) throw new Error('Missing group name');
      if (!seen.has(id)) {
        seen.add(id);
        const group = {id, name, selected: false};
        if (Number.isSafeInteger(contact.unread_count) && contact.unread_count >= 0) group.unreadCount = contact.unread_count;
        groups.push(group);
      }
    }
    return {type: 'groups', groups};
  }

  function mediaURL(value) {
    if (typeof value !== 'string' || !value) return null;
    try {
      const url = new URL(value.startsWith('//') ? 'https:' + value : value);
      return (url.protocol === 'https:' || url.protocol === 'http:') && !url.username && !url.password
        ? url.href : null;
    } catch (_) { return null; }
  }

  function attachmentsFor(message) {
    const attachments = [];
    const seen = new Set();
    function add(type, candidate, name, metadata) {
      const url = mediaURL(candidate);
      if (!url || seen.has(url)) return;
      seen.add(url);
      const attachment = {type, url, name: typeof name === 'string' ? name : ''};
      if (metadata) {
        const thumbnail = mediaURL(metadata.thumbnailURL);
        if (thumbnail) attachment.thumbnailURL = thumbnail;
        if (Number.isSafeInteger(metadata.size) && metadata.size >= 0) attachment.size = metadata.size;
        if (typeof metadata.mimeType === 'string' && /^[a-z0-9.+-]+\/[a-z0-9.+-]+$/i.test(metadata.mimeType)) attachment.mimeType = metadata.mimeType;
      }
      attachments.push(attachment);
    }
    if (Array.isArray(message.pic_urls)) {
      for (const picture of message.pic_urls) {
        if (typeof picture === 'string') add('image', picture);
        else if (picture && typeof picture === 'object') {
          add('image', picture.url || picture.pic || (picture.large && picture.large.url));
        }
      }
    }
    if (Array.isArray(message.pic_infos)) {
      for (const picture of message.pic_infos) {
        if (!picture || typeof picture !== 'object') continue;
        add('image',picture.original_pic,picture.filename,{thumbnailURL:picture.thumbnail_pic});
      }
    }
    // Official frontend uses att_ids/fids and this MSS download endpoint. Keep
    // IDs lexical; unsafe Numbers cannot be recovered and must not form URLs.
    const rawFids = message.att_ids !== undefined ? message.att_ids : message.fids;
    const fids = Array.isArray(rawFids) ? rawFids : typeof rawFids === 'string' ? rawFids.split(',') : [rawFids];
    const type = Number(message.media_type) === 1 ? 'image' : Number(message.media_type) === 10 ? 'video' : 'document';
    if (!(type === 'image' && attachments.some(item=>item.type==='image'))) {
      for (const value of fids) {
        if (typeof value === 'number' && !Number.isSafeInteger(value)) continue;
        if (typeof value !== 'string' && typeof value !== 'number') continue;
        const fid = String(value).trim();
        if (!fid || fid.length>512 || /[\x00-\x20]/.test(fid)) continue;
        const url = new URL('https://upload.api.weibo.com/2/mss/msget');
        url.searchParams.set('source','209678993'); url.searchParams.set('fid',fid);
        if(type==='image')url.searchParams.set('imageType','origin');
        add(type,url.href,message.filename,{size:message.filesize,mimeType:message.mime_type});
      }
    }
    add('image', message.pic);
    add('link', message.url);
    add('link', message.short_url);
    if (Array.isArray(message.url_objects)) {
      for (const object of message.url_objects) {
        if (!object || typeof object !== 'object') continue;
        const info = object.info || {};
        add('video', info.video_url, info.title);
        add('link', object.url_ori || info.url_long || info.url_short, info.title);
      }
    }
    return attachments;
  }

  function messageTime(message) {
    let milliseconds;
    if (message.time !== undefined && message.time !== null) {
      const seconds = typeof message.time === 'number' ? message.time :
        typeof message.time === 'string' && /^[0-9]+(?:\.[0-9]+)?$/.test(message.time) ? Number(message.time) : NaN;
      milliseconds = seconds * 1000;
    } else if (typeof message.created_at === 'string') {
      milliseconds = Date.parse(message.created_at);
    }
    if (!Number.isFinite(milliseconds) || Math.abs(milliseconds) > 8640000000000000) {
      throw new Error('Missing or invalid message time');
    }
    return new Date(milliseconds).toISOString();
  }

  function normalizeMessages(data, groupId) {
    groupId = identifier(groupId);
    if (!Array.isArray(data.messages)) throw new Error('Missing message list');
    const messages = data.messages.map(function (message) {
      if (!message || typeof message !== 'object') throw new Error('Invalid message');
      if (message.gid !== undefined && identifier(message.gid) !== groupId) throw new Error('Group mismatch');
      const sender = message.from_user || {};
      const text = message.content !== undefined ? message.content : message.text;
      if (text !== undefined && typeof text !== 'string') throw new Error('Invalid message text');
      const id = identifier(message.id !== undefined ? message.id : message.mid !== undefined ? message.mid : message.message_id);
      const senderValue = message.from_uid !== undefined && message.from_uid !== null ? message.from_uid :
        sender.idstr !== undefined ? sender.idstr : sender.id;
      const unknownSender = senderValue === undefined || senderValue === null || senderValue === '' || senderValue === 0 || senderValue === '0';
      const senderName = typeof sender.screen_name === 'string' && sender.screen_name.trim() ? sender.screen_name : sender.name;
      return {
        id,
        groupId,
        senderId: unknownSender ? 'unknown:' + id : identifier(senderValue),
        senderName: typeof senderName === 'string' && senderName.trim() ? senderName : '发送者待确认',
        text: text === undefined ? '' : text,
        sentAt: messageTime(message),
        attachments: attachmentsFor(message),
        sourceURL: ORIGIN + '/chat'
      };
    });
    return {type: 'messages', groupId, messages};
  }

  function normalizeResponse(url, body) {
    const target = endpoint(url);
    if (!target) return null;
    const data = typeof body === 'string' ? parseJSON(body) : body;
    if (!data || typeof data !== 'object' || Array.isArray(data)) throw new Error('Invalid response envelope');
    if ((data.error_code !== undefined && String(data.error_code) !== '0') || data.error) {
      const code = /^[0-9]{1,12}$/.test(String(data.error_code)) ? String(data.error_code) : '未知';
      return {type: 'status', text: '微博接口返回错误（' + code + '），此响应未归档。'};
    }
    if (target.kind === 'profile') return normalizeProfile(data);
    if (target.kind === 'groups') return normalizeGroups(data);
    return normalizeMessages(data, target.url.searchParams.get('id'));
  }

  // Transport is injected so the same cursor/identity logic is exercised in tests.
  // Only configure() authorizes requests; installation alone remains passive.
  function createSynchronizer(options) {
    const schedule = options.setTimeout;
    const unschedule = options.clearTimeout;
    const now = options.now || Date.now;
    const groups = new Map();
    const controllers = new Map();
    const sleepers = new Set();
    const rangeJobs = new Map();
    let configuredAccount = '', generation = 0, paused = true, timer = null;
    let interval = 4000, requestTail = Promise.resolve(), nextRequestAt = 0, blockedUntil = 0, backoff = 0;
    const compare = (a, b) => BigInt(a) < BigInt(b) ? -1 : BigInt(a) > BigInt(b) ? 1 : 0;
    const previous = id => String(BigInt(id) - 1n);
    function identity() {return options.getIdentity() || {};}
    function token(group) {return {generation, accountId: configuredAccount, epoch: identity().epoch, group, requestStartedAt:new Date(now()).toISOString()};}
    function valid(t) {
      const current = identity();
      return !paused && t.generation === generation && t.accountId === configuredAccount &&
        current.accountId === t.accountId && current.epoch === t.epoch && groups.get(t.group.id) === t.group;
    }
    function cancelled() {const error = new Error('同步已暂停或账号已切换。'); error.cancelled = true; return error;}
    function check(t) {
      if (t.rangeJob && t.rangeJob.error) throw t.rangeJob.error;
      if (!valid(t)) throw cancelled();
    }
    function emit(event) {try {options.emit(event);} catch (_) {}}
    function status(group, state, phase, text, force) {
      if (phase === 'history') group.historyState = state;
      const event = {type:'sync', accountId:configuredAccount, groupId:group.id, state, phase,
        loadedCount:group.loadedCount, oldestId:group.oldestId || '', newestId:group.newestId || '',
        hasMore:group.hasMore, anchorReached:group.anchorReached, text:text || ''};
      if (group.unreadCount !== undefined) event.unreadCount = group.unreadCount;
      const signature = JSON.stringify(event);
      if (force || group.lastStatus !== signature) {group.lastStatus = signature; emit(event);}
    }
    function sleep(ms, t) {
      check(t);
      if (ms <= 0) return Promise.resolve();
      return new Promise((resolve, reject) => {
        const item = {id:null, reject, token:t};
        item.id = schedule(() => {sleepers.delete(item); valid(t) ? resolve() : reject(cancelled());}, ms);
        sleepers.add(item);
      });
    }
    function stop(clear) {
      paused = true; generation++;
      for (const job of rangeJobs.values()) job.stop(cancelled());
      if (timer !== null) unschedule(timer);
      timer = null;
      controllers.forEach((group, controller) => controller.abort()); controllers.clear();
      sleepers.forEach(item => {unschedule(item.id); item.reject(cancelled());}); sleepers.clear();
      for (const group of groups.values()) {group.historyJob = null; group.liveJob = null; group.refreshJob = null;}
      // Old transports may ignore abort; their result remains guarded by token.
      requestTail = Promise.resolve(); nextRequestAt = 0;
      if (clear) {groups.clear(); configuredAccount = ''; blockedUntil = 0; backoff = 0;}
    }
    async function page(group, cursor, t, phase, metadata) {
      const execute = async () => {
        while (true) {
          check(t);
          await sleep(Math.max(nextRequestAt, blockedUntil) - now(), t);
          check(t);
          const url = new URL('/webim/groupchat/query_messages.json', ORIGIN);
          url.searchParams.set('convert_emoji','1'); url.searchParams.set('query_sender','1');
          url.searchParams.set('source','209678993'); url.searchParams.set('count','20'); url.searchParams.set('id',group.id);
          if (cursor !== null) url.searchParams.set('max_mid',cursor);
          const controller = new options.AbortController(); controllers.set(controller,group);
          if (t.rangeJob) t.rangeJob.controller = controller;
          let response, timeout;
          const deadline = new Promise((resolve,reject)=>{timeout=schedule(()=>{
            reject(new Error('微博读取超时，请稍后重试；已取得的消息已保留。')); controller.abort();
          },20000);});
          try {
            nextRequestAt = now() + 250;
            response = await Promise.race([options.fetch(url.href, {method:'GET', credentials:'same-origin', redirect:'error', cache:'no-store', signal:controller.signal}),deadline]);
            check(t);
            if (response.url && !endpoint(response.url)) throw new Error('微博同步地址发生变化，已停止读取。');
            if (response.status === 429) {
              const header = response.headers && response.headers.get('Retry-After');
              const seconds = header && /^\d+(?:\.\d+)?$/.test(header) ? Number(header) * 1000 : header ? Date.parse(header) - now() : 0;
              backoff = Math.min(300000, backoff ? backoff * 2 : 5000);
              blockedUntil = now() + Math.max(backoff, Number.isFinite(seconds) ? Math.min(3600000, seconds) : 0);
              if (t.rangeJob) t.rangeJob.progress('backoff','微博暂时限流，正在等待后继续；已取得的消息已保留。');
              else status(group,'backoff',phase,'微博暂时限流，稍后自动继续；已取得的消息已保留。');
              continue;
            }
            if (response.status === 401 || response.status === 403) {
              if (options.onAuthenticationFailure) options.onAuthenticationFailure();
              stop(true); throw cancelled();
            }
            if (response.status < 200 || response.status >= 300) throw new Error('微博同步暂未完成（HTTP ' + response.status + '）。');
            const raw = await Promise.race([response.text(),deadline]); check(t);
            let data;
            try {data = parseJSON(raw);} catch (_) {throw new Error('微博消息响应格式无法确认，本批未归档。');}
            if (!data || typeof data !== 'object' || Array.isArray(data)) throw new Error('微博消息响应格式无法确认，本批未归档。');
            if (String(data.error_code) === '21301') {
              if (options.onAuthenticationFailure) options.onAuthenticationFailure();
              stop(true); throw cancelled();
            }
            const normalized = normalizeResponse(url.href, data);
            if (normalized.type !== 'messages') throw new Error(normalized.text || '微博消息响应暂时无法读取。');
            const unique = new Map();
            for (const message of normalized.messages) {
              if (cursor !== null && compare(message.id,cursor)>0) throw new Error('微博分页游标未生效，已停止，避免重复读取。');
              unique.set(message.id,message);
            }
            backoff = 0; blockedUntil = 0;
            const messages = [...unique.values()].sort((a,b)=>compare(a.id,b.id));
            if (!metadata) return messages;
            const flag = data.has_more !== undefined ? data.has_more : data.hasMore;
            const hasMore = flag === true || flag === 1 || flag === '1' ? true : flag === false || flag === 0 || flag === '0' ? false : null;
            return {messages,hasMore};
          } finally {
            unschedule(timeout); controllers.delete(controller);
            if (t.rangeJob && t.rangeJob.controller === controller) t.rangeJob.controller = null;
          }
        }
      };
      const queued = requestTail.catch(()=>{}).then(execute);
      requestTail = queued.catch(()=>{});
      return t.rangeJob ? Promise.race([queued,t.rangeJob.interrupted]) : queued;
    }
    function accept(group, messages, t, preserveBounds, messageSource, requestStartedAt) {
      check(t);
      const fresh = [];
      for (const message of messages) {
        if (group.resumeMessageId === message.id) group.anchorReached = true;
        if (!preserveBounds && (!group.oldestId || compare(message.id,group.oldestId)<0)) group.oldestId = message.id;
        const fingerprint=JSON.stringify(message);
        if (group.seen.get(message.id)===fingerprint) continue;
        const seenBefore=group.seen.has(message.id);
        group.seen.set(message.id,fingerprint); fresh.push(message);
        const alreadyLocal=group.localOldest && group.localNewest && compare(message.id,group.localOldest)>=0 && compare(message.id,group.localNewest)<=0;
        if(!seenBefore && !alreadyLocal)group.loadedCount++;
      }
      if (fresh.length) emit({type:'messages', accountId:t.accountId, groupId:group.id, messages:fresh,
        messageSource, requestStartedAt:requestStartedAt || t.requestStartedAt});
      return fresh.length;
    }
    function result(group, loadedCount, wasCancelled) {
      return {groupId:group.id, loadedCount, oldestId:group.oldestId || '', newestId:group.newestId || '',
        hasMore:group.hasMore, anchorReached:group.anchorReached, cancelled:!!wasCancelled};
    }
    function selected(id) {
      const group = groups.get(identifier(id));
      if (!group) throw new Error('此群未启用同步。');
      if (paused || identity().accountId !== configuredAccount) throw new Error('同步已暂停或账号尚未确认。');
      return group;
    }
    // A range is verified against a fresh contiguous traversal, never against
    // cached bounds. It is a separate read-only job: no ordinary message event,
    // history cursor, seen map, reading anchor, or cleanup exclusion is changed.
    async function loadRange(request) {
      if (!request || request.accountId !== configuredAccount || identity().accountId !== request.accountId) throw new Error('账号已切换，请重新选择时间段。');
      const group = selected(request.groupId);
      const requestId = request.requestId;
      if (typeof requestId !== 'string' || !requestId || requestId.length > 160 || /[\x00-\x1f]/.test(requestId)) throw new Error('时间段读取请求无效。');
      const parseBound = value => {
        if (typeof value !== 'string') return NaN;
        const match = value.match(/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,3})?(?:Z|([+-])(\d{2}):(\d{2}))$/);
        if (!match) return NaN;
        const numbers = match.slice(1,7).map(Number), [year,month,day,hour,minute,second] = numbers;
        if (month<1 || month>12 || day<1 || day>new Date(Date.UTC(year,month,0)).getUTCDate() || hour>23 || minute>59 || second>59 || Number(match[8]||0)>23 || Number(match[9]||0)>59) return NaN;
        return Date.parse(value);
      };
      const from = parseBound(request.from), to = parseBound(request.to);
      if (!Number.isFinite(from) || !Number.isFinite(to) || from > to) throw new Error('请选择有效的起止日期和时间，开始时间不能晚于结束时间。');
      if (to > now()) throw new Error('结束时间不能晚于当前时间，请重新选择。');
      if (rangeJobs.has(requestId)) throw new Error('该时间段正在读取，请等待当前操作完成。');
      if (rangeJobs.size >= 1) throw new Error('已有时间段正在读取，请先完成或取消。');
      const t = token(group), found = new Map();
      let pages = 0, scannedCount = 0, cursor = null, newerOldest = Infinity, deadline;
      let complete = false, reason = '', terminal = 'partial';
      const bounds = {from:new Date(from).toISOString(),to:new Date(to).toISOString()};
      const job = {group,error:null,controller:null,interrupted:null,reject:null,progress:null,stop:null};
      job.interrupted = new Promise((resolve,reject)=>{job.reject=reject;});
      job.interrupted.catch(()=>{});
      job.progress = (status,text) => {
        // Never forward a prior account's progress after identity invalidation.
        if (identity().accountId !== t.accountId || identity().epoch !== t.epoch) return;
        emit(Object.assign({type:'rangeProgress',accountId:t.accountId,groupId:group.id,requestId,
          loadedCount:found.size,scannedCount,pages,status,text},bounds));
      };
      job.stop = error => {
        if (job.error) return;
        job.error = error;
        if (job.controller) job.controller.abort();
        for (const item of [...sleepers]) if (item.token.rangeJob === job) {
          unschedule(item.id); sleepers.delete(item); item.reject(error);
        }
        job.reject(error);
      };
      t.rangeJob = job;
      rangeJobs.set(requestId,job);
      deadline = schedule(()=>job.stop(new Error('读取已达到 10 分钟上限，仅保留已取得的消息；请缩小时间段后重试。')),600000);
      job.progress('loading','正在从最新消息开始核实所选时间段。');
      try {
        for (let index=0; index<200; index++) {
          const response = await page(group,cursor,t,'range',true); check(t);
          pages++;
          const messages = response.messages;
          scannedCount += messages.length;
          for (const message of messages) {
            const time = Date.parse(message.sentAt);
            if (time >= from && time <= to) found.set(message.id,message);
          }
          job.progress('loading','已读取 '+pages+' 页，所选时间段内已有 '+found.size+' 条消息。');
          if (!messages.length) {
            if (response.hasMore === true) throw new Error('微博仍提示存在更早消息，但没有返回下一页，尚不能确认加载完整。');
            complete = true; reason = '已逐页读取到微博接口可提供的历史起点，所选时段内可取得的消息已加载完整。'; break;
          }
          // IDs are the pagination key. Timestamp inversions make a time cutoff
          // unsafe, so preserve the fetched messages and report partial coverage.
          const times = messages.map(message=>Date.parse(message.sentAt));
          if (times.some((time,i)=>!Number.isFinite(time) || (i && time < times[i-1])) || times[times.length-1] > newerOldest) {
            throw new Error('微博消息时间顺序异常，已保留取得的消息，尚不能确认加载完整。');
          }
          newerOldest = times[0];
          if (times[0] < from) {
            complete = true; reason = '已连续读取至开始时间之前，所选时段内当前微博可读取的消息已加载完整。'; break;
          }
          if (response.hasMore === false) {
            complete = true; reason = '微博接口已明确返回历史结束，所选时段内可取得的消息已加载完整。'; break;
          }
          const next = previous(messages[0].id);
          if (cursor !== null && compare(next,cursor)>=0) throw new Error('微博分页没有继续向前，已停止重复读取，尚不能确认加载完整。');
          if (next === '0') { complete = true; reason = '已读取到最早消息，所选时段内可取得的消息已加载完整。'; break; }
          cursor = next;
        }
        if (!complete) reason = '已达到本次 200 页读取上限，仅保留已取得的消息；请缩小时间段后重试。';
      } catch (error) {
        const stopped = job.error || error;
        reason = stopped.message || '时间段读取未完成，已取得的消息已保留。';
        if (stopped.cancelled || !valid(t)) terminal = 'cancelled';
      } finally {
        unschedule(deadline);
        if (rangeJobs.get(requestId) === job) rangeJobs.delete(requestId);
      }
      const messages = [...found.values()].sort((a,b)=>Date.parse(a.sentAt)-Date.parse(b.sentAt) || compare(a.id,b.id)).map(message=>Object.assign({accountId:t.accountId},message));
      const coverage = Object.assign({complete,reason,checkedAt:new Date(now()).toISOString(),loadedCount:messages.length,pages},bounds);
      job.progress(complete?'complete':terminal,reason);
      return {messages,coverage};
    }
    function cancelRange(request) {
      if (!request || request.accountId !== configuredAccount || identity().accountId !== request.accountId) throw new Error('账号已切换，本次取消未操作其他账号。');
      if (typeof request.requestId !== 'string' || !request.requestId || request.requestId.length > 160) throw new Error('时间段读取请求无效。');
      const job = rangeJobs.get(request.requestId);
      if (job) { const error = new Error('已取消时间段读取；已取得的消息已保留，尚未加载完整。'); error.cancelled = true; job.stop(error); }
      return {ok:true,cancelled:!!job};
    }
    async function loadHistory(id, targetCount) {
      const group = selected(id);
      if (group.historyJob) return group.historyJob;
      const count = targetCount === undefined ? 500 : Number(targetCount);
      if (!Number.isSafeInteger(count) || count < 1 || count > 5000) throw new Error('每次加载数量需为 1 至 5000 条。');
      const t = token(group);
      let loaded = 0;
      const work = (async () => {
        status(group,'loading','history','正在读取更早的群消息。');
        try {
          while (loaded < count && group.hasMore) {
            const cursor = group.oldestId ? previous(group.oldestId) : null;
            if (cursor === '0') {group.hasMore = false; break;}
            const messages = await page(group,cursor,t,'history'); check(t);
            if (!messages.length) {group.hasMore = false; break;}
            if (!group.newestId) group.newestId = messages[messages.length-1].id;
            const oldOldest = group.oldestId;
            loaded += accept(group,messages,t,false,'history');
            if (oldOldest && (!group.oldestId || compare(group.oldestId,oldOldest)>=0)) throw new Error('历史游标未前进，请稍后重试。');
            if (messages.length < 20) group.hasMore = false;
            status(group,'loading','history','已继续读取 ' + loaded + ' 条较早消息。');
          }
          status(group,'idle','history',group.hasMore ? '历史已加载，可继续读取更早消息。' : '已到达当前可取得的历史起点。');
          return result(group,loaded,false);
        } catch (error) {
          if (!valid(t) || error.cancelled) return result(group,loaded,true);
          status(group,'error','history',error.message); throw error;
        }
      })();
      group.historyJob = work;
      try {return await work;} finally {if (group.historyJob===work) group.historyJob=null;}
    }
    // Explicit upgrade/migration pass. Its private cursor must never acknowledge
    // a live gap or change where the independent older-history job resumes.
    async function replayRecent(id, targetCount) {
      const group = selected(id);
      const count = targetCount === undefined ? Math.min(group.loadedCount || 500,500) : Number(targetCount);
      if (!Number.isSafeInteger(count) || count < 1 || count > 500) throw new Error('每次补全数量需为 1 至 500 条。');
      if (group.refreshJob) return group.refreshJob;
      const t=token(group);
      let scanned=0, refreshed=0, cursor=null;
      const completion=wasCancelled=>Object.assign(result(group,refreshed,wasCancelled),{scannedCount:scanned,refreshedCount:refreshed});
      const work=(async()=>{
        status(group,'loading','refresh','正在补全已有消息的图片和文件资料。');
        try {
          while(scanned<count) {
            const messages=await page(group,cursor,t,'refresh');check(t);
            if(!messages.length)break;
            const batch=messages.slice(-Math.min(messages.length,count-scanned));
            scanned+=batch.length;
            refreshed+=accept(group,batch,t,true,'refresh');
            status(group,'loading','refresh','已检查 '+scanned+' 条已有消息的附件。');
            if(messages.length<20 || messages[0].id==='1')break;
            cursor=previous(messages[0].id);
          }
          status(group,'idle','refresh','已有消息的附件资料已补全，本次检查 '+scanned+' 条。');
          return completion(false);
        } catch(error) {
          if(!valid(t)||error.cancelled)return completion(true);
          status(group,'error','refresh',error.message);throw error;
        }
      })();
      group.refreshJob=work;
      try{return await work;}finally{if(group.refreshJob===work)group.refreshJob=null;}
    }
    async function live(group) {
      if (group.liveJob) return group.liveJob;
      if (group.historyJob && !group.newestId) return result(group,0,false);
      const t = token(group);
      let loaded = 0;
      const work = (async () => {
        // Retain a gap cursor until it reaches the prior newest ID, including
        // through transport errors and pause/resume. Never move the watermark early.
        const pending = group.pendingLive || {cursor:null, baseline:group.newestId, head:null, requestStartedAt:t.requestStartedAt};
        group.pendingLive = pending;
        try {
          for (let pages=0; pages<250; pages++) {
            const messages = await page(group,pending.cursor,t,'live'); check(t);
            if (!messages.length) {
              if (pending.head) group.newestId = pending.head;
              group.pendingLive = null; break;
            }
            if (!pending.head) pending.head = messages[messages.length-1].id;
            // Refresh the overlap page once each session as well: an older local
            // record may predate attachment support or have edited metadata.
            loaded += accept(group,messages,t,false,'live',pending.requestStartedAt);
            const reached = pending.baseline && compare(messages[0].id,pending.baseline)<=0;
            if (reached || messages.length<20 || !pending.baseline) {
              group.newestId = pending.head;
              group.pendingLive = null; break;
            }
            pending.cursor = previous(messages[0].id);
            status(group,'loading','live','新消息超过一页，正在补齐期间的消息。');
          }
          if (loaded || group.pendingLive) status(group,group.pendingLive?'loading':'idle','live',group.pendingLive?'正在继续补齐新消息。':'新消息已同步。');
          return result(group,loaded,false);
        } catch (error) {
          if (!valid(t) || error.cancelled) return result(group,loaded,true);
          status(group,'error','live',error.message); throw error;
        }
      })();
      group.liveJob = work;
      try {return await work;} finally {if (group.liveJob===work) group.liveJob=null;}
    }
    function arm() {
      if (paused || timer !== null || !groups.size) return;
      timer = schedule(() => {
        timer = null;
        if (!paused) {for (const group of groups.values()) live(group).catch(()=>{}); arm();}
      }, interval);
    }
    function configure(config) {
      const nextAccount = identifier(config && config.accountId);
      if (identity().accountId !== nextAccount) throw new Error('微博账号尚未确认，未启动同步。');
      if (!Array.isArray(config.groups)) throw new Error('请选择需要同步的群。');
      const entries = config.groups.map(item => ({id:identifier(item.id), oldestId:item.oldestId?identifier(item.oldestId):null,
        newestId:item.newestId?identifier(item.newestId):null, resumeMessageId:item.resumeMessageId?identifier(item.resumeMessageId):null,
        unreadCount:Number.isSafeInteger(item.unreadCount)&&item.unreadCount>=0?item.unreadCount:undefined,
        loadedCount:Number.isSafeInteger(item.loadedCount)&&item.loadedCount>=0?item.loadedCount:0}));
      const initial = config.initialHistoryCount === undefined ? 500 : Number(config.initialHistoryCount);
      if (!Number.isSafeInteger(initial) || initial<0 || initial>5000) throw new Error('初次历史数量需为 0 至 5000 条。');
      if (configuredAccount && configuredAccount!==nextAccount) stop(true);
      configuredAccount = nextAccount;
      const nextIds = new Set(entries.map(item=>item.id));
      for (const [id] of groups) if (!nextIds.has(id)) {
        const removed = groups.get(id); groups.delete(id);
        for (const job of rangeJobs.values()) if (job.group === removed) job.stop(cancelled());
        controllers.forEach((group,controller)=>{if(group===removed)controller.abort();});
      }
      const added=[];
      for (const item of entries) {
        if (groups.has(item.id)) {
          const group=groups.get(item.id);
          group.unreadCount=item.unreadCount; group.resumeMessageId=item.resumeMessageId;
          group.loadedCount=Math.max(group.loadedCount,item.loadedCount);
          continue;
        }
        const group=Object.assign({},item,{hasMore:true,seen:new Map(),localOldest:item.oldestId,localNewest:item.newestId,anchorReached:false,historyJob:null,liveJob:null,refreshJob:null,pendingLive:null});
        groups.set(item.id,group); added.push(group);
      }
      interval=Math.max(3000,Math.min(5000,Number(config.pollIntervalMs)||4000));
      paused=false; arm();
      for (const group of added) {
        const deficit=Math.max(0,Math.min(5000,Math.max(initial,group.unreadCount||0))-group.loadedCount);
        if (initial && deficit) loadHistory(group.id,deficit).catch(()=>{});
      }
      return {ok:true,paused,groups:groups.size};
    }
    function pause() {stop(false); for(const group of groups.values())status(group,'paused','live','后台同步已暂停。'); return {ok:true,paused:true};}
    function resume() {
      if (!configuredAccount || identity().accountId!==configuredAccount) throw new Error('请先确认当前账号并重新配置同步。');
      paused=false; arm(); return {ok:true,paused:false};
    }
    async function syncNow(id) {
      async function requested(group) {
        const t = token(group), completed = await live(group);
        if (completed.cancelled || !valid(t)) return completed;
        // Automatic polls stay quiet when nothing changes. An explicit request
        // must complete the frontend's loading state on every click, including
        // repeated identical empty results, without hiding other active work.
        if (group.pendingLive) status(group,'loading','live','正在继续补齐新消息。',true);
        else if (group.historyJob && ['loading','backoff'].includes(group.historyState)) {
          status(group,'loading','history','历史消息仍在读取，已取得的消息会继续显示。',true);
        } else status(group,'idle','live',completed.loadedCount ? '新消息已同步。' : '已检查，暂无新消息。',true);
        return completed;
      }
      if (id !== undefined && id !== null && id !== '') return requested(selected(id));
      if (paused) throw new Error('同步已暂停。');
      return Promise.all([...groups.values()].map(requested));
    }
    function observe(event) {
      if (event.type!=='messages') return;
      const group=groups.get(event.groupId);
      if (!group || event.accountId!==configuredAccount) return;
      for(const message of event.messages) {
        group.seen.set(message.id,JSON.stringify(message));
        if(group.resumeMessageId===message.id)group.anchorReached=true;
      }
    }
    return Object.freeze({configure,loadHistory,loadRange,cancelRange,replayRecent,pause,resume,syncNow,reset:()=>stop(true),observe});
  }

  function install(win) {
    if (!win || !win.location || win.location.origin !== ORIGIN || win[DIAGNOSTICS]) return false;
    const counts = {version: 3, responses: 0, profiles: 0, groups: 0, messages: 0, errors: 0,
      epoch: 0, buffered: 0, dropped: 0};
    let epoch = 0;
    let accountId = '';
    let waiting = [];
    let loginRoute = false;
    let overflowReported = false;
    let synchronizer = null;
    Object.defineProperty(win, DIAGNOSTICS, {get: function () {return Object.freeze(Object.assign({}, counts));}});

    function post(event) {
      try {
        const handler = win.webkit && win.webkit.messageHandlers && win.webkit.messageHandlers.weibo;
        if (handler && typeof handler.postMessage === 'function') handler.postMessage(event);
      } catch (_) { /* A missing native bridge must never affect the official page. */ }
    }
    function invalidateIdentity() {
      if (synchronizer) synchronizer.reset();
      accountId = '';
      counts.dropped += waiting.length;
      waiting = [];
      counts.buffered = 0;
      counts.epoch = ++epoch;
      overflowReported = false;
    }
    function observeRoute() {
      let hash = '';
      try {hash = typeof win.location.hash === 'string' ? win.location.hash : new URL(win.location.href).hash;} catch (_) {}
      const next = /^#\/login(?:[/?]|$)/i.test(hash);
      if (next && !loginRoute) invalidateIdentity();
      loginRoute = next;
    }
    function current(ticket) {
      observeRoute();
      return ticket && ticket.epoch === epoch && !loginRoute;
    }
    function beginRequest(url, method) {
      observeRoute();
      const target = endpoint(url);
      if (String(method).toUpperCase() !== 'GET' || !target) return null;
      if (target.kind === 'profile') invalidateIdentity();
      return {epoch, kind: target.kind, requestStartedAt:new Date().toISOString()};
    }
    function failed(ticket, identityFailure) {
      if (!current(ticket)) {if (ticket) counts.dropped++; return;}
      if (ticket.kind === 'profile' || identityFailure) invalidateIdentity();
      counts.errors++;
      post({type: 'status', text: '微博响应暂未归档：数据格式或标识精度无法确认。'});
    }
    function sendData(event, ticket) {
      if (!current(ticket)) {counts.dropped++; return;}
      if (!accountId) {
        if (waiting.length < 30) {
          waiting.push(event);
          counts.buffered = waiting.length;
        } else {
          counts.dropped++;
          if (!overflowReported) {
            overflowReported = true;
            post({type: 'status', text: '等待确认微博账号，部分响应未暂存；请确认账号后重新加载需要的历史。'});
          }
        }
        return;
      }
      if (event.type === 'groups') counts.groups += event.groups.length;
      else counts.messages += event.messages.length;
      const tagged = Object.assign({}, event, {accountId});
      if (synchronizer) synchronizer.observe(tagged);
      post(tagged);
    }
    function receive(ticket, url, body, status) {
      if (!current(ticket)) {if (ticket) counts.dropped++; return;}
      try {
        const target = endpoint(url);
        if (!target || target.kind !== ticket.kind) {
          if (ticket.kind === 'profile') failed(ticket);
          return;
        }
        counts.responses++;
        if (status && (status < 200 || status >= 300)) {failed(ticket, status === 401 || status === 403); return;}
        const data = typeof body === 'string' ? parseJSON(body) : body;
        const event = normalizeResponse(url, data);
        if (!event) return;
        if (event.type === 'messages') {
          event.messageSource = target.url.searchParams.has('max_mid') || target.url.searchParams.has('max_id') ? 'history' : 'passive';
          event.requestStartedAt = ticket.requestStartedAt;
        }
        if (event.type === 'profile') {
          accountId = event.accountId;
          counts.profiles++;
          post(event);
          const buffered = waiting;
          waiting = [];
          counts.buffered = 0;
          for (const pending of buffered) sendData(pending, ticket);
        } else if (event.type === 'status') {
          if (ticket.kind === 'profile' || String(data.error_code) === '21301') invalidateIdentity();
          counts.errors++;
          post(event);
        } else sendData(event, ticket);
      } catch (_) {failed(ticket);}
    }

    // A full navigation creates a fresh observer. Hash navigation needs an
    // explicit reset. An invisible Cookie change without navigation, a login
    // route, an auth error, or a profile request cannot be proven from these
    // three passive endpoints; the native app must reset on new navigation.
    observeRoute();
    if (typeof win.addEventListener === 'function') {
      win.addEventListener('hashchange', observeRoute);
      win.addEventListener('popstate', observeRoute);
    }

    if (typeof win.fetch === 'function') {
      const pageFetch = win.fetch;
      synchronizer = createSynchronizer({
        fetch: function (url, init) {return Reflect.apply(pageFetch,win,[url,init]);},
        getIdentity: function () {observeRoute(); return {accountId,epoch};},
        emit: function (event) {
          if(event.type==='messages')counts.messages+=event.messages.length;
          post(event);
        },
        onAuthenticationFailure: function () {
          invalidateIdentity();
          post({type:'status',text:'微博登录状态已失效，后台同步已暂停。请重新确认登录。'});
        },
        setTimeout: function (fn,ms) {return win.setTimeout(fn,ms);},
        clearTimeout: function (id) {win.clearTimeout(id);},
        AbortController: win.AbortController || (typeof AbortController==='function'?AbortController:null)
      });
      Object.defineProperty(win,'__weiboReaderSync',{value:Object.freeze({
        configure:synchronizer.configure, loadHistory:synchronizer.loadHistory, loadRange:synchronizer.loadRange, cancelRange:synchronizer.cancelRange, replayRecent:synchronizer.replayRecent,
        pause:synchronizer.pause, resume:synchronizer.resume, syncNow:synchronizer.syncNow
      })});
      win.fetch = function () {
        const args = arguments;
        let requestedURL, ticket;
        try {
          const input = args[0];
          requestedURL = typeof input === 'string' ? input : input instanceof URL ? input.href : input && input.url;
          const method = (args[1] && args[1].method) || (input && input.method) || 'GET';
          ticket = beginRequest(requestedURL, method);
        } catch (_) {}
        let returned;
        try {returned = Reflect.apply(pageFetch, this, args);} catch (error) {
          if (ticket && ticket.kind === 'profile') failed(ticket);
          throw error;
        }
        try {
          if (!ticket) return returned;
          returned.then(function (response) {
            if (!current(ticket)) {counts.dropped++; return;}
            try {
              const url = response.url || requestedURL;
              const target = endpoint(url);
              if (!target || target.kind !== ticket.kind) {
                if (ticket.kind === 'profile') failed(ticket);
                return;
              }
              response.clone().text().then(function (text) {receive(ticket, url, text, response.status);}, function () {failed(ticket);});
            } catch (_) {failed(ticket);}
          }, function () {if (ticket.kind === 'profile') failed(ticket);});
        } catch (_) { /* Observation is optional; fetch's return and errors are not. */ }
        return returned;
      };
    }

    const prototype = win.XMLHttpRequest && win.XMLHttpRequest.prototype;
    if (prototype && typeof prototype.open === 'function' && typeof prototype.send === 'function') {
      const pageOpen = prototype.open;
      const pageSend = prototype.send;
      const requests = new WeakMap();
      const listening = new WeakSet();
      prototype.open = function () {
        const returned = Reflect.apply(pageOpen, this, arguments);
        try {requests.set(this, {method: String(arguments[0]).toUpperCase(), url: arguments[1]});} catch (_) {}
        return returned;
      };
      prototype.send = function () {
        let ticket;
        try {
          const request = requests.get(this);
          if (request) request.ticket = ticket = beginRequest(request.url, request.method);
          if (!listening.has(this)) {
            const xhr = this;
            xhr.addEventListener('load', function () {
              try {
                const request = requests.get(xhr);
                if (!request || !request.ticket) return;
                const url = xhr.responseURL || request.url;
                if (xhr.responseType === '' || xhr.responseType === 'text') receive(request.ticket, url, xhr.responseText, xhr.status);
                else if (xhr.responseType === 'json') receive(request.ticket, url, xhr.response, xhr.status);
                else if (request.ticket.kind === 'profile') failed(request.ticket);
              } catch (_) {const request = requests.get(xhr); failed(request && request.ticket);}
            });
            for (const name of ['error', 'abort', 'timeout']) {
              xhr.addEventListener(name, function () {
                const request = requests.get(xhr);
                if (request && request.ticket && request.ticket.kind === 'profile') failed(request.ticket);
              });
            }
            listening.add(this);
          }
        } catch (_) { /* Keep send usable even if listeners cannot be installed. */ }
        try {return Reflect.apply(pageSend, this, arguments);} catch (error) {
          if (ticket && ticket.kind === 'profile') failed(ticket);
          throw error;
        }
      };
    }
    return true;
  }

  const api = Object.freeze({parseJSON, normalizeProfile, normalizeGroups, normalizeMessages, normalizeResponse, createSynchronizer, install});
  if (typeof module === 'object' && module.exports) module.exports = api;
  else if (typeof window === 'object') {
    try {install(window);} catch (_) { /* The official page must remain usable. */ }
  }
}());
