#!/usr/bin/env node
// cdp.js — 通过 Chrome DevTools Protocol 操控内嵌 Chromium 的桌面 app
//
// 为什么存在：Windows SendInput 要求目标窗口在前台，多 agent 同时跑会互相抢焦点，
// 跨虚拟桌面还可能切走用户当前桌面。CDP 完全不碰焦点、不碰屏幕坐标，用 DOM 选择器定位，
// 窗口被遮住、在别的虚拟桌面、甚至最小化时通常仍能操作。
//
// 前提：目标 app 用 --remote-debugging-port=<port> 启动（CEF / Electron 都吃这个参数）。
//   powershell -File win.ps1 open "Xxx" --cdp 9333 [--relaunch]
//
// 用法：
//   node cdp.js <port> list [--json] [--summary]
//   node cdp.js <port> snapshot <target> [--all]        # 列出可交互元素并打 ref（默认只列视口内可见）
//   node cdp.js <port> find  <target> '<文本>' [--role button] [--all]   # 按文本/aria-label/placeholder 模糊找元素
//   node cdp.js <port> wait  <target> <条件> [超时秒=10]  # 条件: css选择器 | text:<文本> | gone:<选择器>
//   node cdp.js <port> inspect <target> '<选择器>' [--json] [--summary] # 脱敏读取控件角色、状态、字符数与占位符
//   node cdp.js <port> eval  <target> '<js表达式>'      # 只读求值；检测到可能副作用则拒绝（eval-read 同义）
//   node cdp.js <port> eval-unsafe <target> '<js表达式>' --allow-side-effects [--receipt <路径>]
//                                                        # 任意脚本写入；必须显式确认并留下回执
//   node cdp.js <port> click <target> '<选择器>' [--receipt <路径>]       # 真实 DOM click()
//   node cdp.js <port> text  <target> '<选择器>' '<文本>' [--receipt <路径>] # 给输入框写值并派发 input/change
//   node cdp.js <port> mouse <target> '<选择器>' [--receipt <路径>]       # 渲染器级真实鼠标点击，之后打印 DOM 差分
//   node cdp.js <port> insert <target> '<选择器或空>' '<文本>' [--receipt <路径>] # Input.insertText（输入法上屏）
//   node cdp.js <port> press <target> <Escape|Backspace|SelectAll|Slash|At> [选择器] [--receipt <路径>]
//                                                        # Enter 属最终动作会拒绝；SelectAll+Backspace 可撤回 insert
//   node cdp.js <port> shot  <target> <输出路径> [选择器]  # 整页或单元素截图
//   node cdp.js <port> html  <target> [选择器]           # 打印 outerHTML（默认 body，截断 20000 字）
//   node cdp.js <port> act   <target> <脚本文件|内联脚本|-> [--receipt <路径>] # 一次会话顺序执行多步（见下）
//
// <target> 可以是 target id，也可以是 title/url 的子串；子串匹配不唯一时拒绝。
// 特殊值 auto 会给非 background page 评分；授权集合含多个 page 时写操作禁止 auto。
//
// 选择器：所有接选择器的地方都接受 ref=eN 或 eN（snapshot/find 打出来的 ref），
// 内部转成 [data-hs-ref="eN"]。ref 是打在元素上的属性，页面刷新后失效，重新 snapshot 即可。
//
// wait 的退出码是三态：0 satisfied / 1 unsatisfied（条件本身无法评估，如选择器语法错）/ 2 unknown（超时）。
// 上层不能把 2 当成功。
//
// act 脚本：每行一步，# 开头是注释，参数含空格用双引号包住。
//   find "文本" [--role button]      # 结果第一条的 ref 记为 $last，后续步骤可用
//   mouse <ref或选择器>
//   insert <ref或选择器或-> "文本"    # - 表示不切焦点直接上屏
//   press <Escape|Backspace|SelectAll|Slash|At> [ref或选择器]  # Enter 拒绝
//   wait <条件> [秒]
//   shot <路径> [选择器]
//   eval-read <js>                    # 只允许能证明无副作用的表达式
//   sleep <秒>
//   snapshot [--all]
// 任一步 wait 返回 unknown、find 零命中、元素找不到，就停下并打印已完成到第几步，退出码 2。
// 脚本参数可以是文件路径、内联多行字符串，或 - 表示从 stdin 读。
// click/text/mouse/insert/press/eval-unsafe/act 都要求先由 win.ps1 open --cdp 签发 30 分钟会话，
// 每次写入前复核端口 owner 的 PID/路径/启动时间与 target id，并写 action-receipt-v1。
// 未指定 --receipt 时，动作回执写到系统临时目录。
// 收据不落输入正文或原始 CSS，只留长度、选择器类型/哈希、目标身份和动作前后语义摘要。
// HTTP/连接各限 5 秒，单次 CDP 请求限 6 秒；act 最多 200 步/120 秒。超时退出 2 并写 unknown 收据。

const [, , portArg, cmd, ...rest] = process.argv;
const PORT = portArg || '9333';
const BASE = `http://127.0.0.1:${PORT}`;
const fs = require('node:fs');
const pathUtil = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const childProcess = require('node:child_process');
const riskPolicyCore = require('./risk-policy.js');
const MUTATING_COMMANDS = new Set(['click', 'text', 'mouse', 'insert', 'press', 'act', 'eval-unsafe']);
const RISK_POLICY_SCHEMA = riskPolicyCore.RISK_POLICY_SCHEMA;
let riskPolicyCache = null;
const HTTP_TIMEOUT_MS = 5000;
const WS_CONNECT_TIMEOUT_MS = 5000;
const CDP_REQUEST_TIMEOUT_MS = 6000;
const AUTO_TARGET_TIMEOUT_MS = 1500;
const AUTO_TARGET_LIMIT = 12;
const ACT_DEADLINE_MS = 120000;
const ACT_STEP_LIMIT = 200;
// 常见 http_proxy 指向本地代理，127.0.0.1 不能走它
process.env.NO_PROXY = [process.env.NO_PROXY, '127.0.0.1', 'localhost'].filter(Boolean).join(',');

function usage() {
  const src = fs.readFileSync(__filename, 'utf8');
  const lines = src.split('\n').slice(1);
  const end = lines.findIndex(l => !l.startsWith('//'));
  console.log(lines.slice(0, end).map(l => l.replace(/^\/\/ ?/, '')).join('\n'));
}

async function listTargets() {
  try {
    const r = await fetch(`${BASE}/json/list`, { signal: AbortSignal.timeout(HTTP_TIMEOUT_MS) });
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    return r.json();
  } catch (e) {
    if (e.name === 'TimeoutError' || e.name === 'AbortError') {
      throw new CdpTimeoutError(`CDP /json/list 超过 ${HTTP_TIMEOUT_MS}ms`);
    }
    throw e;
  }
}

// auto：不能取「第一个 page」——Electron/内嵌浏览器常带隐藏页（picker / launcher / background），
// 实测某 app 的第一个 page 是隐藏的技能选择页，snapshot 出来是空的。
// 改成对每个候选页打分：可见视口面积 + 可交互元素数，取最高，并回显选中了谁，方便下次直接指定。
async function pickTargetAuto(targets, summary = false) {
  const allCands = targets.filter(t => t.type === 'page' && !/background|devtools/i.test(t.url));
  const cands = allCands.slice(0, AUTO_TARGET_LIMIT);
  if (allCands.length > cands.length) console.error(`auto: target 候选 ${allCands.length} 个，只评分前 ${AUTO_TARGET_LIMIT} 个`);
  if (cands.length <= 1) return cands[0] || null;
  const scored = [];
  for (const t of cands) {
    let score = 0;
    try {
      const s = await connect(t.webSocketDebuggerUrl, AUTO_TARGET_TIMEOUT_MS);
      try {
        const r = await s.send('Runtime.evaluate', {
          expression: `(document.visibilityState==='visible' ? innerWidth*innerHeight : 0)
            + document.querySelectorAll('button,a[href],input,textarea,[contenteditable],[role=button]').length * 1000`,
          returnByValue: true, awaitPromise: true, userGesture: false,
        }, AUTO_TARGET_TIMEOUT_MS);
        score = r.result?.value || 0;
      } finally { s.close(); }
    } catch { score = 0; }
    scored.push({ target: t, score });
  }
  scored.sort((a, b) => b.score - a.score);
  const best = scored[0]?.target;
  if (!best) return null;
  if (scored.length > 1 && scored[0].score === scored[1].score) {
    throw new CdpRefusalError(`refused: auto target 最高分并列（score=${scored[0].score}），请运行 list 后使用明确 target id`);
  }
  console.error(summary
    ? 'auto → 已选择一个 target；--summary 已省略 title/url，请用 list --json --summary 核对计数'
    : `auto → ${(best.title || '').slice(0, 30)} (${best.url.slice(0, 60)})  # 下次可直接指定这个 title/url 子串`);
  return best;
}
function pickTarget(targets, sel, summary = false) {
  const exact = targets.filter(t => t.id === sel);
  if (exact.length === 1) return exact[0];
  const pageMatches = targets.filter(t => t.type === 'page' && (t.title.includes(sel) || t.url.includes(sel)));
  const matches = pageMatches.length ? pageMatches : targets.filter(t => t.title.includes(sel) || t.url.includes(sel));
  if (matches.length > 1) {
    if (summary) throw new CdpRefusalError(`refused: target 选择器匹配 ${matches.length} 项；--summary 已省略选择器与候选详情，请使用明确 target id`);
    const candidates = matches.slice(0, 8).map(t => `${t.type} id=${t.id} title=${JSON.stringify(String(t.title || '').slice(0, 60))}`).join('\n  ');
    throw new CdpRefusalError(`refused: target 选择器匹配 ${matches.length} 项，不会自动选择\n  ${candidates}\n请使用明确 target id`);
  }
  return matches[0];
}

class CdpTimeoutError extends Error {
  constructor(message) { super(message); this.name = 'CdpTimeoutError'; this.code = 'CDP_TIMEOUT'; }
}

class CdpRefusalError extends Error {
  constructor(message) { super(message); this.name = 'CdpRefusalError'; this.code = 'CDP_REFUSED'; }
}

function getRiskPolicy() {
  if (riskPolicyCache) return riskPolicyCache;
  const policyPath = pathUtil.join(__dirname, '..', 'config', 'risk-actions.json');
  try { riskPolicyCache = riskPolicyCore.loadRiskPolicy(policyPath); }
  catch (e) { throw new CdpRefusalError('refused: 高风险动作规则不可用或无效'); }
  return riskPolicyCache;
}

function riskRefusal(ruleId, message) {
  const error = new CdpRefusalError(`refused: ${message}；没有执行。规则=${ruleId}`);
  error.riskGuard = { schema: RISK_POLICY_SCHEMA, decision: 'refused', ruleId };
  throw error;
}

function cdpSessionPath(port) {
  if (process.env.WIN_USE_MASTER_CDP_SESSION) return pathUtil.resolve(process.env.WIN_USE_MASTER_CDP_SESSION);
  const local = process.env.LOCALAPPDATA || pathUtil.join(os.homedir(), 'AppData', 'Local');
  return pathUtil.join(local, 'win-use-master', 'sessions', `cdp-${port}.json`);
}

function queryCdpPortOwners(port) {
  const numericPort = Number(port);
  if (!Number.isInteger(numericPort) || numericPort < 1 || numericPort > 65535) {
    throw new CdpRefusalError(`refused: 无效 CDP 端口 ${port}`);
  }
  const script = [
    "$ErrorActionPreference='Stop'",
    `$rows=@(Get-NetTCPConnection -State Listen -LocalPort ${numericPort} -ErrorAction Stop | Select-Object -ExpandProperty OwningProcess -Unique | ForEach-Object {`,
    '  $p=Get-Process -Id $_ -ErrorAction Stop',
    "  [pscustomobject]@{pid=[int]$p.Id;executablePath=[IO.Path]::GetFullPath($p.Path);startTimeUtc=$p.StartTime.ToUniversalTime().ToString('o')}",
    '})',
    'ConvertTo-Json -InputObject $rows -Compress',
  ].join(';');
  try {
    const shell = process.env.WIN_USE_MASTER_PWSH || 'pwsh';
    const raw = childProcess.execFileSync(shell, ['-NoProfile', '-NonInteractive', '-Command', script], {
      encoding: 'utf8', timeout: 6000, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'],
    }).trim();
    const rows = raw ? JSON.parse(raw) : [];
    return Array.isArray(rows) ? rows : [rows];
  } catch (e) {
    const detail = String(e.stderr || e.message || e).trim().slice(0, 300);
    throw new CdpRefusalError(`refused: 无法独立读取 CDP 端口 owner 身份：${detail}`);
  }
}

function validateCdpSession(port, expectedSessionId = null) {
  const path = cdpSessionPath(port);
  let session;
  try { session = JSON.parse(fs.readFileSync(path, 'utf8')); }
  catch (e) {
    throw new CdpRefusalError(`refused: CDP 写操作需要有效授权会话。先运行 win.ps1 open <app> --cdp ${port}；session=${path}`);
  }
  if (session.schema !== 'win-use-master/cdp-session-v1' || Number(session.port) !== Number(port) || !session.sessionId) {
    throw new CdpRefusalError('refused: CDP 授权会话 schema、端口或 sessionId 不匹配；请重新运行 open --cdp');
  }
  if (expectedSessionId && session.sessionId !== expectedSessionId) {
    throw new CdpRefusalError('refused: CDP 授权会话在目标选择期间被替换；请重新读取 target 后再执行');
  }
  const expires = Date.parse(session.expiresAt);
  if (!Number.isFinite(expires) || expires <= Date.now()) {
    throw new CdpRefusalError('refused: CDP 写授权已过期；请重新运行 open --cdp');
  }
  const expectedOwners = Array.isArray(session.owners) ? session.owners : [];
  const currentOwners = queryCdpPortOwners(port);
  if (!expectedOwners.length || currentOwners.length !== expectedOwners.length) {
    throw new CdpRefusalError('refused: CDP 监听进程集合与授权会话不一致；端口可能已被复用');
  }
  const currentByPid = new Map(currentOwners.map(owner => [Number(owner.pid), owner]));
  for (const expected of expectedOwners) {
    const current = currentByPid.get(Number(expected.pid));
    const samePath = current && String(current.executablePath || '').toLowerCase() === String(expected.executablePath || '').toLowerCase();
    const sameStart = current && String(current.startTimeUtc || '') === String(expected.startTimeUtc || '');
    if (!current || !samePath || !sameStart) {
      throw new CdpRefusalError(`refused: CDP owner pid=${expected.pid} 的路径或启动时间已变化；不会信任复用的 PID/端口`);
    }
  }
  if (!Array.isArray(session.targetIds) || !session.targetIds.length) {
    throw new CdpRefusalError('refused: CDP 授权会话没有可写 target 集合');
  }
  return { ...session, manifestPath: path };
}

function assertAuthorizedTarget(session, target) {
  if (!target || !session.targetIds.includes(target.id)) {
    throw new CdpRefusalError(`refused: target id=${target?.id || 'none'} 不在本次 CDP 写授权中；请重新运行 open --cdp`);
  }
}

function connect(wsUrl, connectTimeoutMs = WS_CONNECT_TIMEOUT_MS) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(wsUrl);
    let id = 0;
    let opened = false;
    const pending = new Map();
    const connectTimer = setTimeout(() => {
      try { ws.close(); } catch {}
      reject(new CdpTimeoutError(`CDP WebSocket 连接超过 ${connectTimeoutMs}ms`));
    }, connectTimeoutMs);
    const rejectPending = error => {
      for (const item of pending.values()) { clearTimeout(item.timer); item.reject(error); }
      pending.clear();
    };
    ws.addEventListener('message', ev => {
      const msg = JSON.parse(ev.data);
      if (msg.id && pending.has(msg.id)) {
        const { resolve: res, reject: rej, timer } = pending.get(msg.id);
        pending.delete(msg.id);
        clearTimeout(timer);
        msg.error ? rej(new Error(JSON.stringify(msg.error))) : res(msg.result);
      }
    });
    ws.addEventListener('error', e => {
      const error = new Error('WebSocket 连接失败: ' + (e.message || e.type));
      if (!opened) { clearTimeout(connectTimer); reject(error); }
      rejectPending(error);
    });
    ws.addEventListener('close', () => {
      clearTimeout(connectTimer);
      rejectPending(new Error('CDP WebSocket 已关闭'));
    });
    ws.addEventListener('open', () => {
      opened = true;
      clearTimeout(connectTimer);
      resolve({
        send(method, params = {}, timeoutMs = CDP_REQUEST_TIMEOUT_MS) {
          return new Promise((res, rej) => {
            if (ws.readyState !== 1) { rej(new Error('CDP WebSocket 未打开')); return; }
            const mid = ++id;
            const timer = setTimeout(() => {
              pending.delete(mid);
              rej(new CdpTimeoutError(`CDP ${method} 超过 ${timeoutMs}ms`));
              try { ws.close(); } catch {}
            }, timeoutMs);
            pending.set(mid, { resolve: res, reject: rej, timer });
            try { ws.send(JSON.stringify({ id: mid, method, params })); }
            catch (e) { clearTimeout(timer); pending.delete(mid); rej(e); }
          });
        },
        close: () => ws.close(),
      });
    });
  });
}

async function evaluate(sess, expr, options = {}) {
  const r = await sess.send('Runtime.evaluate', {
    expression: expr,
    returnByValue: true,
    awaitPromise: true,
    userGesture: !!options.userGesture,
  });
  if (r.exceptionDetails) throw new Error('JS 异常: ' + JSON.stringify(r.exceptionDetails.exception?.description || r.exceptionDetails));
  return r.result?.value;
}

async function evaluateReadOnly(sess, expr) {
  const r = await sess.send('Runtime.evaluate', {
    expression: expr,
    returnByValue: true,
    awaitPromise: true,
    userGesture: false,
    throwOnSideEffect: true,
  });
  if (r.exceptionDetails) {
    const detail = JSON.stringify(r.exceptionDetails.exception?.description || r.exceptionDetails.text || r.exceptionDetails);
    throw new CdpRefusalError('refused: eval 只允许浏览器能证明无副作用的表达式；需要写入时改用 eval-unsafe --allow-side-effects。详情: ' + detail);
  }
  return r.result?.value;
}

const jsStr = s => JSON.stringify(String(s));
const sleep = ms => new Promise(r => setTimeout(r, ms));

// ref=e3 / e3 → [data-hs-ref="e3"]；其它原样当 CSS 选择器
function resolveSel(s) {
  const m = /^(?:ref=)?(e\d+)$/.exec(String(s || '').trim());
  return m ? `[data-hs-ref="${m[1]}"]` : s;
}

// ---------- 可交互元素采集（在页面里执行） ----------
// 返回 [{ref, kind, text, match, x, y, w, h, disabled, visible}]
// ref 打在 data-hs-ref 属性上，已有的不改，保证同一元素多次采集 ref 稳定。
const COLLECT_JS = `(function(opts){
  const SEL = 'button,a[href],input,textarea,select,[contenteditable="true"],[contenteditable=""],[contenteditable="plaintext-only"],'
    + '[role="button"],[role="menuitem"],[role="tab"],[role="option"],[role="checkbox"],[role="switch"],[role="link"],[onclick]';
  const norm = s => (s == null ? '' : String(s)).replace(/\\s+/g, ' ').trim();
  const vw = window.innerWidth, vh = window.innerHeight;
  let counter = window.__hsRefCounter || 0;
  const out = [];
  for (const el of document.querySelectorAll(SEL)) {
    if (el.type === 'hidden') continue;
    const r = el.getBoundingClientRect();
    const cs = getComputedStyle(el);
    const visible = r.width > 0 && r.height > 0 && cs.visibility !== 'hidden' && cs.display !== 'none'
      && r.bottom > 0 && r.right > 0 && r.top < vh && r.left < vw && !el.closest('[aria-hidden="true"]');
    if (!visible && !opts.all) continue;
    let ref = el.getAttribute('data-hs-ref');
    if (!ref) { ref = 'e' + (++counter); el.setAttribute('data-hs-ref', ref); }
    const tag = el.tagName.toLowerCase();
    const role = el.getAttribute('role');
    let kind = tag;
    if (role) kind = tag + '/' + role;
    else if (el.isContentEditable) kind = tag + '/editable';
    else if (tag === 'input' && el.type && el.type !== 'text') kind = 'input/' + el.type;
    // 文本回退链：可见文本 > aria-label > placeholder（含 tiptap 类编辑器子节点的 data-placeholder）> title > value
    //   > 图片 alt > svg title > 测试 id（图标按钮往往只有这个，显示成 #xxx）
    const ownId = el.id && !/^radix-/.test(el.id) ? el.id : '';
    const testId = el.getAttribute('data-testid') || el.getAttribute('data-test-id') || el.getAttribute('name') || ownId;
    const parts = [norm(el.innerText), norm(el.getAttribute('aria-label')),
      norm(el.getAttribute('placeholder') || el.getAttribute('data-placeholder') || el.querySelector('[data-placeholder]')?.getAttribute('data-placeholder')),
      norm(el.getAttribute('title')), (tag === 'input' || tag === 'textarea') ? norm(el.value) : '',
      norm(el.querySelector('img[alt]')?.alt), norm(el.querySelector('svg title')?.textContent),
      testId ? '#' + norm(testId) : ''];
    const text = parts.find(Boolean) || '';
    const disabled = !!(el.disabled || el.getAttribute('aria-disabled') === 'true');
    // Anything that holds user-typed text. Slate/ProseMirror editors carry
    // role=textbox, which makes kind "div/textbox" rather than "div/editable",
    // so the flag must not be derived from kind alone.
    const editable = !!(el.isContentEditable || tag === 'input' || tag === 'textarea' || role === 'textbox' || role === 'searchbox');
    out.push({ ref, kind, text: text.slice(0, 40), match: parts.join(' ').toLowerCase().replace(/\\s+/g, '').slice(0, 300),
      x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height), disabled, visible, editable });
  }
  window.__hsRefCounter = counter;
  return out;
})`;

async function collect(sess, opts = {}) {
  return (await evaluate(sess, `(${COLLECT_JS})(${JSON.stringify(opts)})`)) || [];
}

const fmtEl = e =>
  `ref=${e.ref} ${e.kind} "${e.text}" [${e.x},${e.y} ${e.w}×${e.h}]` + (e.disabled ? ' [disabled]' : '') + (e.visible ? '' : ' [hidden]');

const hasSensitiveValue = e => !!e.editable || /^(?:input|textarea)(?:\/|$)|\/editable$/.test(e.kind);
const fmtDiffEl = e => hasSensitiveValue(e)
  ? `ref=${e.ref} ${e.kind} "<${String(e.text || '').length} chars>" [${e.x},${e.y} ${e.w}×${e.h}]` + (e.disabled ? ' [disabled]' : '') + (e.visible ? '' : ' [hidden]')
  : fmtEl(e);

function diffSnap(before, after) {
  const b = new Map(before.map(e => [e.ref, e]));
  const a = new Map(after.map(e => [e.ref, e]));
  const add = [], rem = [], chg = [];
  for (const [ref, e] of a) if (!b.has(ref)) add.push('+ ' + fmtDiffEl(e));
  for (const [ref, e] of b) if (!a.has(ref)) rem.push('- ' + fmtDiffEl(e));
  for (const [ref, e] of a) {
    const o = b.get(ref);
    if (!o) continue;
    const bits = [];
    if (o.disabled !== e.disabled) bits.push(`disabled ${o.disabled}→${e.disabled}`);
    if (o.text !== e.text) bits.push(hasSensitiveValue(e) || hasSensitiveValue(o)
      ? `text <${String(o.text || '').length} chars>→<${String(e.text || '').length} chars>`
      : `text "${o.text}"→"${e.text}"`);
    if (bits.length) chg.push(`~ ref=${ref} ${e.kind} ${bits.join(', ')}`);
  }
  const lines = [];
  for (const arr of [add, rem, chg]) {
    lines.push(...arr.slice(0, 8));
    if (arr.length > 8) lines.push(`  (${arr[0][0]} 还有 ${arr.length - 8} 条)`);
  }
  return {
    lines: lines.length ? lines : ['suspected_noop: 动作前后可交互元素无变化'],
    counts: { added: add.length, removed: rem.length, changed: chg.length },
  };
}

function semanticDigest(elements) {
  if (!elements) return null;
  const stable = elements.map(e => ({
    ref: e.ref, kind: e.kind, text: e.text, x: e.x, y: e.y, w: e.w, h: e.h,
    disabled: !!e.disabled, visible: !!e.visible,
  }));
  return {
    sha256: crypto.createHash('sha256').update(JSON.stringify(stable)).digest('hex'),
    elementCount: stable.length,
  };
}

function makeTrace(before, after) {
  const diff = before && after ? diffSnap(before, after) : null;
  const changed = !!diff && Object.values(diff.counts).some(n => n > 0);
  return {
    before: semanticDigest(before), after: semanticDigest(after),
    diff: diff?.counts || null,
    effect: diff ? (changed ? 'partial' : 'suspected_noop') : 'unknown',
  };
}

// 动作前后各采一次可见交互元素，打印差分。settle 给 UI 一点反应时间。
async function withDiff(sess, action, settleMs = 300) {
  const before = await collect(sess);
  try {
    // 仅供本地回归确定性模拟“修改请求已发出但 provider 永不回应”。
    if (process.env.HUASHU_CDP_TEST_HANG === 'action') {
      await sess.send('Runtime.evaluate', { expression: 'new Promise(() => {})', awaitPromise: true });
    }
    await action();
  } catch (e) {
    e.actionTrace = makeTrace(before, null);
    throw e;
  }
  await sleep(settleMs);
  const after = await collect(sess);
  const diff = diffSnap(before, after);
  for (const l of diff.lines) console.log(l);
  return makeTrace(before, after);
}

// ---------- 各命令 ----------
async function doEvalReadOnly(sess, expr) {
  const out = await evaluateReadOnly(sess, expr);
  console.log(typeof out === 'string' ? out : JSON.stringify(out, null, 2));
}

async function doEvalUnsafe(sess, expr) {
  const observed = await withDiff(sess, async () => {
    const out = await evaluate(sess, expr, { userGesture: true });
    console.log(typeof out === 'string' ? out : JSON.stringify(out, null, 2));
  });
  // Arbitrary JavaScript can change network/server/storage state without any
  // visible DOM difference. Preserve the observed DOM digest, but never claim
  // that it proves the total side effect.
  return { ...observed, observedDomEffect: observed.effect, effect: 'unknown' };
}

async function doInspect(sess, sel, emit = true, summary = false) {
  if (!sel) throw new Error('inspect 需要选择器');
  let out;
  try {
    out = await evaluate(
      sess,
      `(() => { const el=document.querySelector(${jsStr(resolveSel(sel))}); if(!el) return null;
        const r=el.getBoundingClientRect(); const cs=getComputedStyle(el);
        const tag=el.tagName.toLowerCase(); const role=el.getAttribute('role') || '';
        let value;
        if(tag==='input'||tag==='textarea') value=el.value;
        else { const copy=el.cloneNode(true); copy.querySelectorAll('[data-slate-placeholder]').forEach(x=>x.remove()); value=copy.textContent; }
        return { found:true, tag, role, editable:!!(el.isContentEditable||tag==='input'||tag==='textarea'||role==='textbox'||role==='searchbox'),
          disabled:!!(el.disabled||el.getAttribute('aria-disabled')==='true'),
          visible:r.width>0&&r.height>0&&cs.visibility!=='hidden'&&cs.display!=='none',
          textLength:String(value||'').length,
          placeholderVisible:!!el.querySelector('[data-slate-placeholder]'),
          placeholderPresent:!!(el.getAttribute('placeholder')||el.getAttribute('data-placeholder')) }; })()`
    );
  } catch (e) {
    if (summary && !(e instanceof CdpTimeoutError)) throw new Error('inspect 无法评估选择器；--summary 已省略选择器与页面异常详情');
    throw e;
  }
  if (!out) throw new Error(summary ? '元素未找到；--summary 已省略选择器' : '元素未找到: ' + sel);
  if (emit) console.log(JSON.stringify(out));
  return out;
}

async function inspectActionSemantic(sess, sel) {
  if (!sel) throw new Error('动作需要选择器');
  return evaluate(
    sess,
    `(() => { const el=document.querySelector(${jsStr(resolveSel(sel))}); if(!el) return null;
      const tag=el.tagName.toLowerCase(); const type=String(el.getAttribute('type')||'').toLowerCase();
      const role=String(el.getAttribute('role')||'').toLowerCase();
      const norm=s=>(s==null?'':String(s)).normalize('NFKC').replace(/([a-z0-9])([A-Z])/g,'$1 $2').replace(/[_-]+/g,' ').replace(/\\s+/g,' ').trim();
      const value=(tag==='input'&&['button','submit','reset','image'].includes(type))?norm(el.value):'';
      const parts=[norm(el.innerText),norm(el.textContent),norm(el.getAttribute('aria-label')),
        norm(el.getAttribute('title')),value,norm(el.getAttribute('alt')),
        norm(el.getAttribute('data-testid')),norm(el.getAttribute('data-test-id')),
        norm(el.getAttribute('name')),norm(el.id)];
      const semanticText=parts.filter(Boolean).join(' ').slice(0,1200);
      const formSubmit=(tag==='input'&&(type==='submit'||type==='image'))||
        (tag==='button'&&!!el.form&&(type===''||type==='submit'));
      const actionLike=tag==='button'||tag==='a'||!!el.getAttribute('onclick')||
        ['button','submit','reset','image','checkbox','radio'].includes(type)||
        ['button','link','menuitem','checkbox','radio','switch'].includes(role);
      return {semanticText,unlabeled:parts.slice(0,6).every(x=>!x),formSubmit,actionLike}; })()`
  );
}

async function assertSafeActionTarget(sess, sel) {
  const policy = getRiskPolicy();
  const semantic = await inspectActionSemantic(sess, sel);
  if (!semantic) throw new Error('元素未找到: ' + sel);
  if (semantic.actionLike) {
    const blockedRule = riskPolicyCore.findBlockedTextRule(policy, semantic.semanticText);
    if (blockedRule) riskRefusal(blockedRule, 'CDP 目标语义命中高风险最终动作');
  }
  if (semantic.formSubmit && policy.blockedDomSemantics?.includes('form-submit')) {
    riskRefusal('form-submit', 'CDP 目标具有表单提交语义');
  }
  if (semantic.actionLike && semantic.unlabeled) riskRefusal('unlabeled-action', 'CDP 动作目标没有可核对标签');
  return { schema: policy.schema, decision: 'passed' };
}

function assertSafeCdpKey(key) {
  const policy = getRiskPolicy();
  if (policy.blockedKeyChords?.includes(String(key))) {
    riskRefusal(`key:${key}`, `CDP 按键 ${key} 可能直接提交、保存或关闭`);
  }
  return { schema: policy.schema, decision: 'passed' };
}

async function doClick(sess, sel) {
  const riskGuard = await assertSafeActionTarget(sess, sel);
  const trace = await withDiff(sess, async () => {
    const out = await evaluate(
      sess,
      `(() => { const el = document.querySelector(${jsStr(resolveSel(sel))});
        if (!el) return 'NOT_FOUND';
        el.scrollIntoView({block:'center'});
        el.click();
        return 'clicked: ' + (el.innerText||el.getAttribute('aria-label')||el.tagName).slice(0,60); })()`,
      { userGesture: true }
    );
    console.log(out);
    if (out === 'NOT_FOUND') throw new Error('元素未找到: ' + sel);
  });
  return { ...trace, riskGuard };
}

async function doText(sess, sel, value) {
  return withDiff(sess, async () => {
    const out = await evaluate(
      sess,
      `(() => { const el = document.querySelector(${jsStr(resolveSel(sel))});
        if (!el) return 'NOT_FOUND';
        el.focus();
        const v = ${jsStr(value)};
        if (el.isContentEditable) { el.textContent = v; }
        else {
          const setter = Object.getOwnPropertyDescriptor(el.constructor.prototype,'value')?.set;
          setter ? setter.call(el, v) : (el.value = v);
        }
        el.dispatchEvent(new InputEvent('input',{bubbles:true,data:v,inputType:'insertText'}));
        el.dispatchEvent(new Event('change',{bubbles:true}));
        return 'typed into ' + el.tagName + ' len=' + v.length; })()`,
      { userGesture: true }
    );
    console.log(out);
    if (out === 'NOT_FOUND') throw new Error('元素未找到: ' + sel);
  });
}

async function doMouse(sess, sel) {
  // Input.dispatchMouseEvent：渲染器层面的真实鼠标事件，坐标是页面内 CSS 像素。
  // 比 el.click() 强一层——很多组件库（mantine/radix/tiptap 菜单）只认真实指针事件。
  // 仍然不需要 OS 焦点，不受窗口遮挡与 Windows 虚拟桌面影响。
  const riskGuard = await assertSafeActionTarget(sess, sel);
  const trace = await withDiff(sess, async () => {
    const box = await evaluate(
      sess,
      `(() => { const el=document.querySelector(${jsStr(resolveSel(sel))}); if(!el) return null;
        el.scrollIntoView({block:'center'});
        const r=el.getBoundingClientRect();
        return {x:r.x+r.width/2, y:r.y+r.height/2, label:(el.innerText||el.getAttribute('aria-label')||el.tagName).slice(0,40)}; })()`
    );
    if (!box) throw new Error('元素未找到: ' + sel);
    for (const type of ['mouseMoved', 'mousePressed', 'mouseReleased']) {
      await sess.send('Input.dispatchMouseEvent', {
        type, x: box.x, y: box.y, button: 'left', clickCount: type === 'mouseMoved' ? 0 : 1,
      });
    }
    console.log(`mouse click @(${box.x.toFixed(0)},${box.y.toFixed(0)}) → ${box.label}`);
  });
  return { ...trace, riskGuard };
}

async function doInsert(sess, sel, text) {
  // 走 Input.insertText：等价于输入法上屏，React/Slate/Vue 的 state 会更新。
  // 比 DOM 的 el.value= 可靠得多——后者常见「字画进 UI 但发送键仍是灰的」。
  return withDiff(sess, async () => {
    if (sel && sel !== '-') {
      const r = await evaluate(sess, `(() => { const el=document.querySelector(${jsStr(resolveSel(sel))}); if(!el) return 'NOT_FOUND'; el.focus(); return 'focused'; })()`, { userGesture: true });
      if (r === 'NOT_FOUND') throw new Error('焦点元素未找到: ' + sel);
    }
    await sess.send('Input.insertText', { text: String(text ?? '') });
    console.log(`insertText: ${String(text ?? '').length} 字`);
  });
}

async function doPress(sess, key, sel) {
  // 真实键盘事件，用于快捷键与「/ 唤起菜单」这类只认 keydown 的交互
  const map = {
    Enter: { windowsVirtualKeyCode: 13, key: 'Enter', code: 'Enter', text: '\r' },
    Escape: { windowsVirtualKeyCode: 27, key: 'Escape', code: 'Escape' },
    Backspace: { windowsVirtualKeyCode: 8, key: 'Backspace', code: 'Backspace' },
    Slash: { windowsVirtualKeyCode: 191, key: '/', code: 'Slash', text: '/' },
    At: { windowsVirtualKeyCode: 50, key: '@', code: 'Digit2', text: '@', modifiers: 8 },
    // Ctrl+A inside a focused editing host selects only that editor's content;
    // followed by Backspace it is the honest way to revert an insert through the
    // same editing pipeline (Slate/ProseMirror state stays consistent).
    SelectAll: { windowsVirtualKeyCode: 65, key: 'a', code: 'KeyA', modifiers: 2 },
  };
  const k = map[key];
  if (!k) throw new Error('未知按键: ' + key + '（可用: ' + Object.keys(map).join('/') + '）');
  const riskGuard = assertSafeCdpKey(key);
  const trace = await withDiff(sess, async () => {
    if (sel) {
      const r = await evaluate(sess, `(() => { const el=document.querySelector(${jsStr(resolveSel(sel))}); if(!el) return 'NOT_FOUND'; el.focus(); return 'focused'; })()`, { userGesture: true });
      if (r === 'NOT_FOUND') throw new Error('焦点元素未找到: ' + sel);
    }
    await sess.send('Input.dispatchKeyEvent', { type: 'keyDown', ...k });
    if (k.text) await sess.send('Input.dispatchKeyEvent', { type: 'char', ...k });
    await sess.send('Input.dispatchKeyEvent', { type: 'keyUp', ...k });
    console.log(`press: ${key}`);
  });
  return { ...trace, riskGuard };
}

async function doHtml(sess, sel) {
  const out = await evaluate(
    sess,
    `(document.querySelector(${jsStr(resolveSel(sel || 'body'))})?.outerHTML || 'NOT_FOUND').slice(0,20000)`
  );
  console.log(out);
}

async function doShot(sess, path, sel, target) {
  if (!path) throw new Error('shot 需要输出路径');
  let clip;
  if (sel) {
    clip = await evaluate(
      sess,
      `(() => { const el = document.querySelector(${jsStr(resolveSel(sel))}); if (!el) return null;
        el.scrollIntoView({block:'center'});
        const r = el.getBoundingClientRect();
        return {x:r.x, y:r.y, width:r.width, height:r.height, scale:1}; })()`
    );
    if (!clip) throw new Error('元素未找到: ' + sel);
  }
  const r = await sess.send('Page.captureScreenshot', {
    format: 'png',
    captureBeyondViewport: !!clip,
    ...(clip ? { clip } : {}),
  });
  const out = pathUtil.resolve(path);
  fs.mkdirSync(pathUtil.dirname(out), { recursive: true });
  const bytes = Buffer.from(r.data, 'base64');
  fs.writeFileSync(out, bytes);
  // 与 win.ps1 shot 一样，原图旁边写机器可读收据。URL 去掉 query/hash，
  // 避免把临时 token 一起落盘。
  let safeUrl = target?.url || '';
  try { const u = new URL(safeUrl); u.search = ''; u.hash = ''; safeUrl = u.toString(); } catch {}
  const receipt = {
    schema: 'win-use-master/receipt-v1', capturedAt: new Date().toISOString(),
    method: 'Chrome DevTools Protocol Page.captureScreenshot', image: out,
    sha256: crypto.createHash('sha256').update(bytes).digest('hex'),
    target: target ? { id: target.id, type: target.type, title: target.title || '', url: safeUrl } : undefined,
    selector: sel || null, cdpPort: Number(PORT),
  };
  fs.writeFileSync(out + '.receipt.json', JSON.stringify(receipt, null, 2) + '\n');
  console.log(`截图: ${out} (${(bytes.length / 1024).toFixed(0)}KB) — 未借焦点，窗口可被遮挡；receipt=${out}.receipt.json`);
}

async function doSnapshot(sess, all) {
  const els = await collect(sess, { all });
  if (!els.length) { console.log(all ? '无可交互元素' : '视口内无可见交互元素（试试 --all）'); return; }
  for (const e of els.slice(0, 200)) console.log(fmtEl(e));
  if (els.length > 200) console.log(`... 共 ${els.length} 个，只列前 200；用 find "<文本>" 定位目标`);
}

const normQ = s => String(s || '').toLowerCase().replace(/\s+/g, '');

// 返回命中数组；零命中时打印候选。
async function doFind(sess, query, role, all) {
  if (!query) throw new Error('find 需要文本');
  const q = normQ(query);
  const els = await collect(sess, { all });
  const pool = role ? els.filter(e => e.kind === role || e.kind.endsWith('/' + role)) : els;
  const hits = pool.filter(e => e.match.includes(q));
  if (hits.length) {
    for (const e of hits.slice(0, 10)) console.log(fmtEl(e));
    if (hits.length > 10) console.log(`... 共 ${hits.length} 条命中，只列前 10`);
    return hits;
  }
  console.log(`not_found: "${query}"` + (role ? ` (role=${role})` : '') + (all ? '' : '（默认只搜视口内可见元素，可加 --all）'));
  const qset = new Set(q);
  const scored = pool.filter(e => e.match)
    .map(e => ({ e, score: [...new Set(e.match)].filter(c => qset.has(c)).length }))
    .filter(s => s.score > 0)
    .sort((x, y) => y.score - x.score || x.e.match.length - y.e.match.length)
    .slice(0, 5);
  if (scored.length) { console.log('最相近的候选:'); for (const s of scored) console.log('  ' + fmtEl(s.e)); }
  process.exitCode = 1;
  return [];
}

// 三态：返回 'satisfied' | 'unsatisfied' | 'unknown'
async function doWait(sess, cond, secs) {
  if (!cond) throw new Error('wait 需要条件');
  const timeout = (Number(secs) > 0 ? Number(secs) : 10) * 1000;
  let expr;
  if (cond.startsWith('text:')) expr = `(document.body?.innerText || '').includes(${jsStr(cond.slice(5))})`;
  else if (cond.startsWith('gone:')) expr = `!document.querySelector(${jsStr(resolveSel(cond.slice(5)))})`;
  else expr = `!!document.querySelector(${jsStr(resolveSel(cond))})`;
  const t0 = Date.now();
  while (Date.now() - t0 < timeout) {
    let ok;
    try { ok = await evaluate(sess, expr); }
    catch (e) {
      if (e instanceof CdpTimeoutError) throw e;
      // 选择器语法错是确定的否定；页面导航中 evaluate 临时失败则继续轮询
      if (/SyntaxError|not a valid selector/.test(e.message)) { console.log(`unsatisfied: 条件无法评估 ${e.message.slice(0, 120)}`); return 'unsatisfied'; }
      await sleep(200); continue;
    }
    if (ok) { console.log(`satisfied (${((Date.now() - t0) / 1000).toFixed(1)}s)`); return 'satisfied'; }
    await sleep(200);
  }
  console.log(`unknown: timeout ${timeout / 1000}s`);
  return 'unknown';
}

// ---------- act：多步脚本 ----------
function tokenize(line) {
  const toks = [];
  const re = /"((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)'|(\S+)/g;
  const unesc = s => s.replace(/\\(.)/g, (_, c) => (c === 'n' ? '\n' : c === 't' ? '\t' : c));
  let m;
  while ((m = re.exec(line))) toks.push(m[1] !== undefined ? unesc(m[1]) : m[2] !== undefined ? unesc(m[2]) : m[3]);
  return toks;
}

async function readScript(arg) {
  const fs = require('node:fs');
  if (!arg) throw new Error('act 需要脚本文件、内联脚本或 -');
  if (arg === '-') return fs.readFileSync(0, 'utf8');
  try { if (fs.statSync(arg).isFile()) return fs.readFileSync(arg, 'utf8'); } catch {}
  return arg;
}

class StopAct extends Error {}

function selectorReceipt(sel) {
  const value = String(sel ?? '');
  if (!value || value === '-') return { kind: 'current_focus' };
  const ref = /^(?:ref=)?(e\d+)$/.exec(value.trim());
  if (ref) return { kind: 'ref', ref: ref[1] };
  return {
    kind: 'css',
    sha256: crypto.createHash('sha256').update(value).digest('hex'),
    length: value.length,
  };
}

function directActionReceipt(kind, args) {
  if (kind === 'click' || kind === 'mouse') return { kind, selector: selectorReceipt(args[1]), riskPolicy: RISK_POLICY_SCHEMA };
  if (kind === 'text' || kind === 'insert') {
    return { kind, selector: selectorReceipt(args[1]), textLength: String(args[2] ?? '').length };
  }
  if (kind === 'press') return { kind, key: String(args[1] || ''), selector: args[2] ? selectorReceipt(args[2]) : { kind: 'current_focus' }, riskPolicy: RISK_POLICY_SCHEMA };
  if (kind === 'act') {
    const source = args[1] === '-' ? 'stdin' : (() => {
      try { return fs.statSync(args[1]).isFile() ? 'file' : 'inline'; } catch { return 'inline'; }
    })();
    return { kind, scriptSource: source, riskPolicy: RISK_POLICY_SCHEMA };
  }
  if (kind === 'eval-unsafe') {
    const expression = String(args[1] ?? '');
    return {
      kind,
      expression: {
        sha256: crypto.createHash('sha256').update(expression).digest('hex'),
        length: expression.length,
      },
      explicitSideEffects: true,
    };
  }
  return { kind };
}

function safeTarget(target, summary = false) {
  let url = target?.url || '';
  try { const u = new URL(url); u.search = ''; u.hash = ''; url = u.toString(); } catch {}
  return target ? {
    id: target.id, type: target.type,
    title: summary ? null : String(target.title || '').slice(0, 120),
    url: summary ? null : url,
  } : null;
}

function parseOutputFlags(argv, command) {
  const args = [...argv];
  const jsonCount = args.filter(x => x === '--json').length;
  const summaryCount = args.filter(x => x === '--summary').length;
  const requested = jsonCount > 0 || summaryCount > 0;
  if (jsonCount > 1 || summaryCount > 1) {
    throw new CdpRefusalError('refused: --json/--summary 每项最多出现一次');
  }
  if (requested && !['list', 'inspect'].includes(command)) {
    throw new CdpRefusalError('refused: 当前只有 CDP list/inspect 支持 --json/--summary');
  }
  return {
    args: args.filter(x => x !== '--json' && x !== '--summary'),
    json: jsonCount === 1,
    summary: summaryCount === 1,
  };
}

function typeCounts(items) {
  const counts = new Map();
  for (const item of items) counts.set(String(item.type || 'unknown'), (counts.get(String(item.type || 'unknown')) || 0) + 1);
  return [...counts.entries()].sort((a, b) => a[0].localeCompare(b[0])).map(([type, count]) => ({ type, count }));
}

function cdpTargetsReport(targets, summary) {
  return {
    schema: 'win-use-master/cdp-targets-result-v1',
    observedAt: new Date().toISOString(),
    status: 'ok',
    privacy: {
      mode: summary ? 'summary' : 'full',
      collection: 'unchanged',
      redactedFields: summary ? ['targets'] : ['targets[].url.query', 'targets[].url.fragment', 'targets[].webSocketDebuggerUrl'],
    },
    cdpPort: Number(PORT),
    counts: { total: targets.length, pages: targets.filter(t => t.type === 'page').length },
    typeCounts: typeCounts(targets),
    targets: summary ? [] : targets.map(t => safeTarget(t, false)),
  };
}

function cdpInspectReport(target, result, summary) {
  return {
    schema: 'win-use-master/cdp-inspect-result-v1',
    observedAt: new Date().toISOString(),
    status: result?.found ? 'found' : 'not-found',
    privacy: {
      mode: summary ? 'summary' : 'full',
      collection: 'safe-metadata-only',
      targetSelectorIncluded: false,
      elementSelectorIncluded: false,
      redactedFields: summary
        ? ['target.title', 'target.url']
        : ['target.url.query', 'target.url.fragment', 'target.webSocketDebuggerUrl'],
    },
    cdpPort: Number(PORT),
    target: safeTarget(target, summary),
    element: result,
  };
}

function formatTargetsSummary(report) {
  const types = report.typeCounts.map(item => `${item.type}:${item.count}`).join(',') || 'none';
  return `cdp list summary: status=${report.status} total=${report.counts.total} pages=${report.counts.pages} types=${types}; title/url=<redacted>`;
}

function formatInspectSummary(report) {
  const e = report.element;
  return `cdp inspect summary: status=${report.status} target=${report.target?.id || 'unknown'} tag=${e?.tag || 'unknown'} role=${e?.role || 'unknown'} editable=${!!e?.editable} disabled=${!!e?.disabled} visible=${!!e?.visible} textLength=${e?.textLength ?? 'unknown'}; selectors/title/url=<redacted>`;
}

function parseReceiptFlag(argv) {
  const args = [...argv];
  const indices = args.map((x, i) => x === '--receipt' ? i : -1).filter(i => i >= 0);
  if (!indices.length) return { args, requested: null };
  if (indices.length !== 1 || indices[0] !== args.length - 2 || !args[indices[0] + 1]) {
    throw new Error('--receipt 必须且只能在命令末尾出现一次，后接输出路径');
  }
  const i = indices[0];
  const requested = args[i + 1];
  args.splice(i, 2);
  return { args, requested };
}

function combineActTrace(events, stopped) {
  const traces = events.map(e => e.trace).filter(Boolean);
  const effect = stopped || traces.some(t => t.effect === 'unknown') ? 'unknown'
    : traces.some(t => t.effect === 'partial') ? 'partial'
      : 'suspected_noop';
  const counts = { added: 0, removed: 0, changed: 0 };
  for (const t of traces) for (const k of Object.keys(counts)) counts[k] += Number(t.diff?.[k] || 0);
  return {
    before: traces[0]?.before || null,
    after: traces[traces.length - 1]?.after || null,
    diff: traces.length ? counts : null,
    effect,
    events: events.map(e => ({ step: e.step, action: e.action, effect: e.trace?.effect || 'unknown' })),
  };
}

function writeActionReceipt(requestedPath, target, action, trace, startedAt, outcome, error, session) {
  const out = requestedPath
    ? pathUtil.resolve(requestedPath)
    : pathUtil.join(os.tmpdir(), `win-use-master-cdp-action-${crypto.randomUUID()}.receipt.json`);
  fs.mkdirSync(pathUtil.dirname(out), { recursive: true });
  const completedAt = new Date();
  const receipt = {
    schema: 'win-use-master/action-receipt-v1',
    startedAt: startedAt.toISOString(), completedAt: completedAt.toISOString(),
    durationMs: completedAt.getTime() - startedAt.getTime(),
    method: 'Chrome DevTools Protocol', cdpPort: Number(PORT),
    target: safeTarget(target), action,
    authorization: session ? {
      schema: session.schema,
      sessionId: session.sessionId,
      expiresAt: session.expiresAt,
      ownerPids: session.owners.map(owner => Number(owner.pid)),
      targetBound: session.targetIds.includes(target?.id),
    } : null,
    focus: { borrowed: false, seconds: 0 },
    verification: {
      effect: trace?.effect || 'unknown',
      before: trace?.before || null, after: trace?.after || null, diff: trace?.diff || null,
      basis: 'visible interactive DOM semantic digest',
    },
    result: {
      status: outcome,
      ...(error ? { errorType: error.name || 'Error', timedOut: error instanceof CdpTimeoutError } : {}),
    },
    riskGuard: error?.riskGuard || trace?.riskGuard || null,
  };
  if (trace?.events) receipt.events = trace.events;
  fs.writeFileSync(out, JSON.stringify(receipt, null, 2) + '\n', 'utf8');
  console.log(`action-receipt: ${out}`);
  return out;
}

async function doAct(sess, scriptArg, target) {
  const lines = (await readScript(scriptArg)).split('\n');
  const deadline = Date.now() + ACT_DEADLINE_MS;
  let last = null;
  let step = 0;
  const events = [];
  const sub = s => (s === '$last' ? (last || (() => { throw new StopAct('$last 为空：前面没有成功的 find'); })()) : s);
  for (const raw of lines) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    step++;
    if (step > ACT_STEP_LIMIT || Date.now() >= deadline) {
      const e = new CdpTimeoutError(step > ACT_STEP_LIMIT
        ? `act 超过 ${ACT_STEP_LIMIT} 步上限`
        : `act 超过 ${ACT_DEADLINE_MS / 1000}s 总截止时间`);
      e.actionTrace = { ...combineActTrace(events, true), stepsAttempted: step, stepsCompleted: step - 1, stopped: true };
      throw e;
    }
    const [op, ...args] = tokenize(line);
    const safeLog = (op === 'insert' || op === 'text')
      ? `${op} ${args[0] || ''} <${String(args[1] ?? '').length} chars>` : line;
    console.log(`[${step}] ${safeLog}`);
    try {
      if (op === 'find') {
        const ri = args.indexOf('--role');
        const role = ri >= 0 ? args[ri + 1] : undefined;
        const all = args.includes('--all');
        const hits = await doFind(sess, args[0], role, all);
        if (!hits.length) throw new StopAct('find 零命中');
        last = 'ref=' + hits[0].ref;
      } else if (op === 'mouse') {
        const sel = sub(args[0]); const trace = await doMouse(sess, sel);
        events.push({ step, action: { kind: op, selector: selectorReceipt(sel) }, trace });
      } else if (op === 'insert') {
        const sel = sub(args[0]); const trace = await doInsert(sess, sel, args[1]);
        events.push({ step, action: { kind: op, selector: selectorReceipt(sel), textLength: String(args[1] ?? '').length }, trace });
      } else if (op === 'click') {
        const sel = sub(args[0]); const trace = await doClick(sess, sel);
        events.push({ step, action: { kind: op, selector: selectorReceipt(sel) }, trace });
      } else if (op === 'text') {
        const sel = sub(args[0]); const trace = await doText(sess, sel, args[1]);
        events.push({ step, action: { kind: op, selector: selectorReceipt(sel), textLength: String(args[1] ?? '').length }, trace });
      } else if (op === 'press') {
        const sel = args[1] && sub(args[1]); const trace = await doPress(sess, args[0], sel);
        events.push({ step, action: { kind: op, key: args[0], selector: sel ? selectorReceipt(sel) : { kind: 'current_focus' } }, trace });
      } else if (op === 'wait') {
        const requestedSeconds = Number(args[1]) > 0 ? Number(args[1]) : 10;
        const remainingSeconds = Math.max(0.001, (deadline - Date.now()) / 1000);
        const r = await doWait(sess, sub(args[0]), Math.min(requestedSeconds, remainingSeconds));
        if (r !== 'satisfied') throw new StopAct('wait ' + r);
      } else if (op === 'shot') await doShot(sess, args[0], args[1] && sub(args[1]), target);
      else if (op === 'eval-read') await doEvalReadOnly(sess, line.replace(/^eval-read\s+/, ''));
      else if (op === 'eval' || op === 'eval-unsafe') {
        throw new StopAct('act 不允许任意脚本写入；请使用受限 eval-read，或在 act 外单独运行 eval-unsafe 并审查其回执');
      }
      else if (op === 'sleep') {
        const sleepMs = (Number(args[0]) || 1) * 1000;
        if (sleepMs < 0 || Date.now() + sleepMs > deadline) {
          throw new CdpTimeoutError(`sleep 会超过 act 的 ${ACT_DEADLINE_MS / 1000}s 总截止时间`);
        }
        await sleep(sleepMs);
      }
      else if (op === 'snapshot') await doSnapshot(sess, args.includes('--all'));
      else throw new StopAct('未知步骤: ' + op);
    } catch (e) {
      if (e.actionTrace) events.push({ step, action: { kind: op }, trace: e.actionTrace });
      if (e instanceof StopAct || /未找到|NOT_FOUND/.test(e.message)) {
        console.log(`stopped: 完成 ${step - 1} 步，第 ${step} 步失败 — ${e.message}`);
        process.exitCode = 2;
        return { ...combineActTrace(events, true), stepsAttempted: step, stepsCompleted: step - 1, stopped: true };
      }
      e.actionTrace = { ...combineActTrace(events, true), stepsAttempted: step, stepsCompleted: step - 1, stopped: true };
      throw e;
    }
  }
  console.log(`done: ${step} 步全部完成`);
  return { ...combineActTrace(events, false), stepsAttempted: step, stepsCompleted: step, stopped: false };
}

// ---------- 入口 ----------
async function main() {
  if (!portArg) { usage(); return; }
  const parsed = parseReceiptFlag(rest);
  const output = parseOutputFlags(parsed.args, cmd);
  let args = output.args;
  if ((cmd === 'list' || !cmd) && args.length !== 0) {
    throw new CdpRefusalError('refused: list 只支持 --json/--summary；未知或多余参数已拒绝');
  }
  if (cmd === 'inspect' && args.length !== 2) {
    throw new CdpRefusalError('refused: inspect 需要且只接受 <target> <selector> [--json] [--summary]；未知或多余参数已拒绝');
  }
  if (cmd === 'eval-unsafe') {
    const confirmations = args.filter(x => x === '--allow-side-effects').length;
    if (confirmations !== 1) {
      throw new CdpRefusalError('refused: eval-unsafe 必须且只能提供一次 --allow-side-effects；表达式可能产生任意页面或网络副作用');
    }
    args = args.filter(x => x !== '--allow-side-effects');
  } else if (args.includes('--allow-side-effects')) {
    throw new CdpRefusalError('refused: --allow-side-effects 只用于 eval-unsafe');
  }
  const mutating = MUTATING_COMMANDS.has(cmd);
  let cdpSession = mutating ? validateCdpSession(PORT) : null;
  const targets = await listTargets();

  if (cmd === 'list' || !cmd) {
    if (output.json) console.log(JSON.stringify(cdpTargetsReport(targets, output.summary), null, 2));
    else if (output.summary) console.log(formatTargetsSummary(cdpTargetsReport(targets, true)));
    else for (const t of targets) console.log(`${t.type}\t${t.id}\t${(t.title || '').slice(0, 40)}\t${t.url.slice(0, 80)}`);
    return;
  }

  const automaticTarget = !args[0] || args[0] === 'auto';
  if (mutating && automaticTarget && cdpSession.targetIds.length !== 1) {
    throw new CdpRefusalError(`refused: 本次授权包含 ${cdpSession.targetIds.length} 个 page target，写操作不能使用 auto；请运行 list 并指定准确 target id`);
  }
  const selectableTargets = mutating
    ? targets.filter(target => cdpSession.targetIds.includes(target.id))
    : targets;
  const t = automaticTarget ? await pickTargetAuto(selectableTargets, output.summary) : pickTarget(targets, args[0], output.summary);
  if (!t) {
    if (output.summary) throw new Error('找不到 target；--summary 已省略选择器与候选详情');
    throw new Error(`找不到 target: ${args[0]}\n可用的:\n` + targets.map(x => `  ${x.type} ${x.title} ${x.url}`).join('\n'));
  }
  if (mutating) {
    assertAuthorizedTarget(cdpSession, t);
    cdpSession = validateCdpSession(PORT, cdpSession.sessionId);
    assertAuthorizedTarget(cdpSession, t);
  }
  const sess = await connect(t.webSocketDebuggerUrl);
  const startedAt = new Date();
  let trace = null;
  let actionError = null;

  try {
    if (cmd === 'eval' || cmd === 'eval-read') await doEvalReadOnly(sess, args[1]);
    else if (cmd === 'eval-unsafe') trace = await doEvalUnsafe(sess, args[1]);
    else if (cmd === 'inspect') {
      const inspected = await doInspect(sess, args[1], !output.json && !output.summary, output.summary);
      if (output.json) console.log(JSON.stringify(cdpInspectReport(t, inspected, output.summary), null, 2));
      else if (output.summary) console.log(formatInspectSummary(cdpInspectReport(t, inspected, true)));
    }
    else if (cmd === 'click') trace = await doClick(sess, args[1]);
    else if (cmd === 'text') trace = await doText(sess, args[1], args[2]);
    else if (cmd === 'mouse') trace = await doMouse(sess, args[1]);
    else if (cmd === 'insert') trace = await doInsert(sess, args[1], args[2]);
    else if (cmd === 'press') trace = await doPress(sess, args[1], args[2]);
    else if (cmd === 'html') await doHtml(sess, args[1]);
    else if (cmd === 'shot') await doShot(sess, args[1], args[2], t);
    else if (cmd === 'snapshot') await doSnapshot(sess, args.includes('--all'));
    else if (cmd === 'find') {
      const ri = args.indexOf('--role');
      await doFind(sess, args[1], ri >= 0 ? args[ri + 1] : undefined, args.includes('--all'));
    } else if (cmd === 'wait') {
      const r = await doWait(sess, args[1], args[2]);
      process.exitCode = r === 'satisfied' ? 0 : r === 'unsatisfied' ? 1 : 2;
    } else if (cmd === 'act') trace = await doAct(sess, args[1], t);
    else throw new Error('未知命令: ' + cmd);
  } catch (e) {
    actionError = e;
    trace = e.actionTrace || trace;
    throw e;
  } finally {
    try {
      if (mutating) {
        const action = directActionReceipt(cmd, args);
        if (cmd === 'act' && trace) {
          action.stepsAttempted = trace.stepsAttempted;
          action.stepsCompleted = trace.stepsCompleted;
        }
        writeActionReceipt(parsed.requested, t, action, trace, startedAt,
          actionError instanceof CdpRefusalError ? 'refused' : actionError ? 'error' : trace?.stopped ? 'stopped' : 'completed', actionError, cdpSession);
      }
    } finally { sess.close(); }
  }
}

main().catch(e => {
  console.error('错误: ' + e.message);
  // 不在 WebSocket close 尚未排空时强制 process.exit；Windows 上 Node/libuv
  // 可能因此触发 UV_HANDLE_CLOSING 断言并把确定失败变成异常 NTSTATUS。
  process.exitCode = e instanceof CdpTimeoutError || e instanceof CdpRefusalError ? 2 : 1;
});
