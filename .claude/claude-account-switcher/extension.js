const vscode = require('vscode');
const fs = require('fs');
const os = require('os');
const path = require('path');
const https = require('https');

const HOME = os.homedir();
const CREDS = path.join(HOME, '.claude', '.credentials.json');
const GLOBAL_CFG = path.join(HOME, '.claude.json');
const STORE = path.join(HOME, '.claude-profiles');
const AUTO_REFRESH_MS = 60_000;

let statusItem;
let panel; // PanelProvider

const profileDir = (name) => path.join(STORE, name);
const readJson = (p) => JSON.parse(fs.readFileSync(p, 'utf8'));
const writeJson = (p, o) => fs.writeFileSync(p, JSON.stringify(o, null, 2), 'utf8');

// ---------- profile storage ----------

function listProfiles() {
  if (!fs.existsSync(STORE)) return [];
  return fs.readdirSync(STORE, { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => d.name);
}

function currentAccount() {
  try {
    const a = readJson(GLOBAL_CFG).oauthAccount;
    return a?.accountUuid && fs.existsSync(CREDS) ? { uuid: a.accountUuid, email: a.emailAddress, name: a.displayName } : null;
  } catch { return null; }
}

function loadProfile(name) {
  const dir = profileDir(name);
  const acc = readJson(path.join(dir, 'account.json'));
  let oauth = {};
  try { oauth = readJson(path.join(dir, 'credentials.json')).claudeAiOauth ?? {}; } catch { /* ignore */ }
  return {
    name,
    uuid: acc.oauthAccount?.accountUuid,
    email: acc.oauthAccount?.emailAddress,
    org: acc.oauthAccount?.organizationName,
    plan: oauth.subscriptionType,
    tier: oauth.rateLimitTier,
    expiresAt: oauth.expiresAt,
    accessToken: oauth.accessToken,
    usage: acc.usage ?? null,
  };
}

// Copy the live login into a profile folder (keeps previously stored usage).
function snapshotTo(name) {
  if (!fs.existsSync(CREDS)) throw new Error('No Claude login found. Sign in to Claude Code first.');
  const dir = profileDir(name);
  fs.mkdirSync(dir, { recursive: true });
  fs.copyFileSync(CREDS, path.join(dir, 'credentials.json'));
  let usage = null;
  try { usage = readJson(path.join(dir, 'account.json')).usage ?? null; } catch { /* new profile */ }
  writeJson(path.join(dir, 'account.json'), { oauthAccount: readJson(GLOBAL_CFG).oauthAccount ?? null, usage });
}

function storeUsage(name, usage) {
  const f = path.join(profileDir(name), 'account.json');
  const acc = readJson(f);
  acc.usage = usage;
  writeJson(f, acc);
}

// Write a profile's login over the live one (only touches oauthAccount in ~/.claude.json).
function applyFrom(name) {
  const dir = profileDir(name);
  fs.copyFileSync(path.join(dir, 'credentials.json'), CREDS);
  const { oauthAccount } = readJson(path.join(dir, 'account.json'));
  const cfg = readJson(GLOBAL_CFG);
  if (oauthAccount) cfg.oauthAccount = oauthAccount; else delete cfg.oauthAccount;
  writeJson(GLOBAL_CFG, cfg);
}

function activeProfileName() {
  const cur = currentAccount();
  if (!cur) return undefined;
  return listProfiles().find((n) => {
    try { return readJson(path.join(profileDir(n), 'account.json')).oauthAccount?.accountUuid === cur.uuid; } catch { return false; }
  });
}

// Tokens refresh while you work, so persist them back to the active profile before leaving it.
function saveBackActive() {
  const active = activeProfileName();
  if (active) { try { snapshotTo(active); } catch { /* ignore */ } }
}

// ---------- usage ----------

function normalizeUsage(u) {
  if (!u) return null;
  const pick = (w) => (w && typeof w.utilization === 'number' ? { pct: w.utilization, resetsAt: w.resets_at ?? null } : null);
  const fiveHour = pick(u.five_hour);
  const sevenDay = pick(u.seven_day);
  if (!fiveHour && !sevenDay) return null;
  return { fiveHour, sevenDay, fetchedAt: Date.now() };
}

function fetchUsage(token) {
  return new Promise((resolve) => {
    const req = https.request({
      hostname: 'api.anthropic.com',
      path: '/api/oauth/usage',
      method: 'GET',
      headers: {
        Authorization: `Bearer ${token}`,
        'anthropic-beta': 'oauth-2025-04-20',
        'User-Agent': 'claude-code/2.0',
        Accept: 'application/json',
      },
      timeout: 8000,
    }, (res) => {
      let body = '';
      res.on('data', (d) => { body += d; });
      res.on('end', () => {
        if (res.statusCode !== 200) return resolve(null);
        try { resolve(JSON.parse(body)); } catch { resolve(null); }
      });
    });
    req.on('error', () => resolve(null));
    req.on('timeout', () => { req.destroy(); resolve(null); });
    req.end();
  });
}

// Usage Claude Code itself cached for the logged-in account.
function cachedLiveUsage(uuid) {
  try {
    const c = readJson(GLOBAL_CFG).cachedUsageUtilization;
    if (c?.accountUuid !== uuid) return null;
    const n = normalizeUsage(c.utilization);
    if (n) n.fetchedAt = c.fetchedAtMs ?? n.fetchedAt;
    return n;
  } catch { return null; }
}

async function buildState(fetchLive) {
  const cur = currentAccount();
  const names = listProfiles();
  const profiles = await Promise.all(names.map(async (name) => {
    let p = loadProfile(name);
    const isActive = !!cur && p.uuid === cur.uuid;
    if (isActive) {
      try { snapshotTo(name); p = loadProfile(name); } catch { /* ignore */ }
    }
    const expired = typeof p.expiresAt === 'number' && Date.now() > p.expiresAt;
    let usage = null;
    if (fetchLive && p.accessToken && !expired) usage = normalizeUsage(await fetchUsage(p.accessToken));
    if (!usage && isActive) usage = cachedLiveUsage(p.uuid);
    if (usage) { try { storeUsage(name, usage); } catch { /* ignore */ } p.usage = usage; }
    return {
      name: p.name, email: p.email, org: p.org, plan: p.plan, tier: p.tier,
      active: isActive, tokenExpired: expired && !isActive, usage: p.usage,
    };
  }));
  const saved = !!cur && profiles.some((p) => p.active);
  return { profiles, current: cur ? { ...cur, saved } : null, now: Date.now() };
}

// ---------- actions ----------

async function reloadPrompt(msg) {
  const pick = await vscode.window.showInformationMessage(msg, 'Reload Window');
  if (pick) vscode.commands.executeCommand('workbench.action.reloadWindow');
}

const validName = (v) => /^[\w .-]+$/.test(v ?? '') && v.trim().length > 0;

async function saveCurrent(name) {
  if (!name) {
    name = await vscode.window.showInputBox({
      prompt: 'Profile name (e.g. your first name)',
      value: currentAccount()?.email?.split('@')[0],
      validateInput: (v) => (validName(v) ? undefined : 'Letters, numbers, space, . _ - only'),
    });
  }
  if (!name) return;
  name = name.trim();
  if (!validName(name)) throw new Error('Invalid profile name.');
  const cur = currentAccount();
  if (!cur) throw new Error('Not signed in to Claude Code.');
  const existing = activeProfileName();
  if (existing && existing !== name) fs.rmSync(profileDir(existing), { recursive: true, force: true });
  snapshotTo(name);
  vscode.window.showInformationMessage(`Saved "${name}".`);
}

async function switchTo(name) {
  if (!name) {
    const names = listProfiles();
    if (!names.length) throw new Error('No saved profiles yet.');
    name = await vscode.window.showQuickPick(names, { placeHolder: 'Switch to Claude account' });
    if (!name) return;
  }
  if (name === activeProfileName()) return;
  saveBackActive();
  applyFrom(name);
  await reloadPrompt(`Switched to "${name}". Reload the window to apply.`);
}

async function addAccount() {
  const cur = currentAccount();
  if (cur && !activeProfileName()) {
    const choice = await vscode.window.showWarningMessage(
      `${cur.email} is not saved as a profile. Signing out will lose this login.`, { modal: true }, 'Save it first', 'Sign out anyway');
    if (!choice) return;
    if (choice === 'Save it first') { await saveCurrent(); if (!activeProfileName()) return; }
  }
  saveBackActive();
  if (fs.existsSync(CREDS)) fs.unlinkSync(CREDS);
  const cfg = readJson(GLOBAL_CFG);
  delete cfg.oauthAccount;
  writeJson(GLOBAL_CFG, cfg);
  await reloadPrompt('Signed out. Reload, log in with the new account, then save it from the Claude Accounts panel.');
}

async function deleteProfile(name) {
  if (!name) name = await vscode.window.showQuickPick(listProfiles(), { placeHolder: 'Delete which profile?' });
  if (!name) return;
  const ok = await vscode.window.showWarningMessage(`Delete saved profile "${name}"?`, { modal: true }, 'Delete');
  if (ok !== 'Delete') return;
  fs.rmSync(profileDir(name), { recursive: true, force: true });
}

// ---------- UI ----------

function updateStatusBar(state) {
  const a = state.profiles.find((p) => p.active);
  const w = a?.usage?.sevenDay;
  statusItem.text = a ? `$(account) ${a.name}${w ? ` · ${Math.round(w.pct)}%` : ''}` : `$(account) Claude: ${state.current?.email ?? 'signed out'}`;
  statusItem.tooltip = 'Claude accounts - click to open panel';
  statusItem.show();
}

class PanelProvider {
  constructor(extensionUri) {
    this.extensionUri = extensionUri;
    this.view = undefined;
    this.lastLive = 0;
  }

  resolveWebviewView(view) {
    this.view = view;
    view.webview.options = { enableScripts: true, localResourceRoots: [vscode.Uri.joinPath(this.extensionUri, 'media')] };
    view.webview.html = this.html(view.webview);
    view.webview.onDidReceiveMessage((m) => this.onMessage(m));
    view.onDidChangeVisibility(() => { if (view.visible) this.refresh(true); });
    this.refresh(true);
  }

  async onMessage(m) {
    try {
      switch (m.type) {
        case 'ready': case 'refresh': return await this.refresh(true);
        case 'switch': await switchTo(m.name); break;
        case 'add': await addAccount(); break;
        case 'save': await saveCurrent(m.name); break;
        case 'delete': await deleteProfile(m.name); break;
      }
      await this.refresh(false);
    } catch (e) {
      vscode.window.showErrorMessage(`Claude Switcher: ${e.message}`);
    }
  }

  async refresh(live) {
    if (live) this.lastLive = Date.now();
    const state = await buildState(live);
    updateStatusBar(state);
    this.view?.webview.postMessage({ type: 'state', state });
  }

  tick() {
    if (this.view?.visible && Date.now() - this.lastLive >= AUTO_REFRESH_MS) this.refresh(true);
  }

  html(webview) {
    const uri = (f) => webview.asWebviewUri(vscode.Uri.joinPath(this.extensionUri, 'media', f));
    const nonce = Math.random().toString(36).slice(2) + Date.now().toString(36);
    return `<!doctype html><html><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src ${webview.cspSource}; script-src 'nonce-${nonce}';">
<link rel="stylesheet" href="${uri('panel.css')}"></head>
<body><div id="app"></div><script nonce="${nonce}" src="${uri('panel.js')}"></script></body></html>`;
  }
}

function activate(context) {
  statusItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 100);
  statusItem.command = 'claudeSwitcher.panel.focus';
  panel = new PanelProvider(context.extensionUri);

  const wrap = (fn) => async () => {
    try { await fn(); await panel.refresh(false); } catch (e) { vscode.window.showErrorMessage(`Claude Switcher: ${e.message}`); }
  };
  const reg = (id, fn) => context.subscriptions.push(vscode.commands.registerCommand(id, wrap(fn)));
  reg('claudeSwitcher.switch', () => switchTo());
  reg('claudeSwitcher.saveCurrent', () => saveCurrent());
  reg('claudeSwitcher.logoutAndAdd', () => addAccount());
  reg('claudeSwitcher.delete', () => deleteProfile());

  const timer = setInterval(() => panel.tick(), 15_000);
  context.subscriptions.push(
    statusItem,
    vscode.window.registerWebviewViewProvider('claudeSwitcher.panel', panel),
    { dispose: () => clearInterval(timer) },
  );
  panel.refresh(true);
}

function deactivate() { saveBackActive(); }

module.exports = { activate, deactivate };
