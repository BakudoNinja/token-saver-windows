param(
    [string]$DashboardPath = "",
    [string]$StatsPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = (Get-Item -LiteralPath ".").FullName
if ([string]::IsNullOrWhiteSpace($DashboardPath)) {
    $DashboardPath = Join-Path $root ".codex\dashboard.html"
}
if ([string]::IsNullOrWhiteSpace($StatsPath)) {
    $StatsPath = Join-Path $root ".codex\stats.json"
}

if (-not (Test-Path -LiteralPath $DashboardPath -PathType Leaf)) {
    throw "dashboard not found: $DashboardPath"
}
if (-not (Test-Path -LiteralPath $StatsPath -PathType Leaf)) {
    throw "stats not found: $StatsPath"
}

$node = Get-Command node -ErrorAction SilentlyContinue
if ($null -eq $node) {
    throw "node is required for dashboard JS smoke."
}

$script = @'
const fs = require('fs');
const vm = require('vm');

const dashboardPath = process.argv[2];
const statsPath = process.argv[3];
const html = fs.readFileSync(dashboardPath, 'utf8');
const statsJson = fs.readFileSync(statsPath, 'utf8').replace(/^\uFEFF/, '');
const appScriptMatch = html.match(/<script(?![^>]*type="application\/json")[^>]*>([\s\S]*?)<\/script>/);
if (!appScriptMatch) {
  throw new Error('dashboard app script not found');
}

class MiniStyle {
  constructor() { this.values = {}; }
  setProperty(key, value) { this.values[key] = value; }
}

class MiniElement {
  constructor(tagName = 'div', id = '') {
    this.tagName = tagName;
    this.id = id;
    this.children = [];
    this.attributes = {};
    this.style = new MiniStyle();
    this.className = '';
    this.title = '';
    this._textContent = '';
    this._innerHTML = '';
    this.listeners = {};
  }
  set textContent(value) { this._textContent = String(value ?? ''); }
  get textContent() {
    const childText = this.children.map((child) => child.textContent || '').join('');
    return this._textContent + childText;
  }
  set innerHTML(value) {
    this._innerHTML = String(value ?? '');
    this.children = [];
    const cellCount = (this._innerHTML.match(/<td\b/gi) || []).length;
    const spanCount = (this._innerHTML.match(/<span\b/gi) || []).length;
    const count = Math.max(cellCount, spanCount, 0);
    for (let i = 0; i < count; i++) this.children.push(new MiniElement('span'));
  }
  get innerHTML() { return this._innerHTML; }
  setAttribute(key, value) {
    this.attributes[key] = String(value);
    if (key === 'class') this.className = String(value);
    if (key === 'id') this.id = String(value);
  }
  appendChild(child) { this.children.push(child); return child; }
  addEventListener(name, handler) { this.listeners[name] = handler; }
  querySelector(selector) {
    if (!this._selectors) this._selectors = {};
    if (!this._selectors[selector]) this._selectors[selector] = new MiniElement('span');
    return this._selectors[selector];
  }
  querySelectorAll(selector) {
    const matches = [];
    const normalized = String(selector || '').trim();
    const visit = (node) => {
      const tag = String(node.tagName || '').toLowerCase();
      const cls = String(node.className || '').split(/\s+/).filter(Boolean);
      const ok = normalized.startsWith('#')
        ? node.id === normalized.slice(1)
        : normalized.startsWith('.')
          ? cls.includes(normalized.slice(1))
          : tag === normalized.toLowerCase();
      if (ok) matches.push(node);
      node.children.forEach(visit);
    };
    this.children.forEach(visit);
    return matches;
  }
}

const elements = new Map();
function elementForId(id) {
  if (!elements.has(id)) elements.set(id, new MiniElement('div', id));
  return elements.get(id);
}
elementForId('stats-data').textContent = statsJson;

const document = {
  getElementById: elementForId,
  createElement: (tag) => new MiniElement(tag),
  createElementNS: (_ns, tag) => new MiniElement(tag),
  querySelector: () => new MiniElement('div'),
  querySelectorAll: () => [],
  documentElement: new MiniElement('html'),
  body: new MiniElement('body'),
};

const errors = [];
const context = {
  console,
  document,
  Intl,
  Date,
  Math,
  Number,
  String,
  Array,
  Object,
  JSON,
  RegExp,
  Error,
  Promise,
  setInterval: () => 0,
  setTimeout,
  clearInterval: () => {},
  fetch: async (url) => {
    if (String(url).includes('/api/health')) {
      return {
        ok: true,
        json: async () => ({
          ok: true,
          status: 'ok',
          message: 'dashboard health is OK',
          checks: [{ name: 'stub', ok: true }],
          summary: {},
        }),
      };
    }
    if (String(url).includes('/api/stats')) {
      return { ok: true, json: async () => JSON.parse(statsJson) };
    }
    return { ok: true, json: async () => ({}) };
  },
  window: {
    addEventListener: (_name, handler) => { context.__windowHandler = handler; },
  },
  __errors: errors,
};
context.globalThis = context;

try {
  vm.createContext(context);
  vm.runInContext(appScriptMatch[1], context, { filename: dashboardPath, timeout: 5000 });
  if (typeof context.renderStats === 'function') {
    const stats = JSON.parse(statsJson);
    context.renderStats(stats, true);
    context.__stats = stats;
  }
  setTimeout(() => {
    const stats = context.__stats || JSON.parse(statsJson);
    const detection = (((stats || {}).globalHistory || {}).usageDetection || {});
    const sessionSeriesCount = Array.isArray(detection.sessionTokenLineSeries) ? detection.sessionTokenLineSeries.length : 0;
    const savedSeriesCount = Array.isArray(detection.savedLineSeries) ? detection.savedLineSeries.length : 0;
    const historicalCount = Number(detection.historicalRequestProjectCount || 0);
    const usageChart = elementForId('usageLineChart');
    const savedChart = elementForId('savedLineChart');
    const usageStatus = elementForId('usageDetectionStatus').textContent;
    const usageSummary = elementForId('usageDetectionSummary').textContent;
    const usageHint = elementForId('usageLineHint').textContent;
    const savedHint = elementForId('savedLineHint').textContent;
    const projectHint = elementForId('projectUsageHint').textContent;
    const appQuotaMeta = elementForId('appQuotaMeta').textContent;
    const assert = (condition, message) => {
      if (!condition) errors.push(message);
    };
    assert(usageChart.querySelectorAll('path').length >= 2, 'usageLineChart must render SVG area and line paths.');
    assert(usageChart.textContent.includes('Token'), 'usageLineChart must render a title. Actual=' + usageChart.textContent.slice(0, 120));
    assert(usageSummary.includes('\u4e3b\u56fe'), 'usage summary must name the primary chart source. Actual=' + usageSummary);
    assert(html.includes('\u7d2f\u8ba1\u51cf\u5c11'), 'dashboard must label cumulative project savings explicitly.');
    assert(html.includes('\u5f53\u524d\u53e3\u5f84\u51cf\u5c11'), 'dashboard must distinguish current-scope savings from cumulative project savings.');
    assert(projectHint.includes('\u7d2f\u8ba1\u51cf\u5c11') && projectHint.includes('\u6700\u540e\u4e00\u6b21\u51cf\u5c11'), 'project usage hint must explain cumulative vs latest savings. Actual=' + projectHint.slice(0, 220));
    if (savedSeriesCount > 0) {
      assert(savedChart.querySelectorAll('path').length >= 2, 'savedLineChart must render SVG area and line paths.');
      assert(savedChart.textContent.includes('Helper'), 'savedLineChart must render a title. Actual=' + savedChart.textContent.slice(0, 120));
      assert(savedHint.includes('helper actual') && savedHint.includes('refresh'), 'savedLineHint must explain actual-only savings. Actual=' + savedHint.slice(0, 160));
    }
    if (sessionSeriesCount > 0) {
      assert(usageHint.includes('session token_count'), 'usageLineHint must explain session token_count when session series are present.');
      assert(usageSummary.includes('session token_count'), 'usage summary must identify session token_count as the primary chart source. Actual=' + usageSummary);
      assert(usageStatus.includes('session token_count'), 'usage status must match the session token_count chart source. Actual=' + usageStatus.slice(0, 220));
      assert(!usageStatus.includes('主图当前使用 Codex completed usage'), 'usage status must not claim completed usage when session token_count is the chart source. Actual=' + usageStatus.slice(0, 220));
    }
    if (historicalCount > 0) {
      assert(usageStatus.includes('helper \u524d\u5386\u53f2\u8bf7\u6c42\u5df2\u4ece helper \u540e\u5b9e\u9645\u4e2d\u6392\u9664'), 'usage status must explain excluded pre-helper request history. Actual=' + usageStatus.slice(0, 220));
      assert(projectHint.includes('\u65e7\u8bf7\u6c42\u5ba1\u8ba1') && projectHint.includes('helper \u540e\u5b9e\u9645'), 'project usage hint must separate helper-after actual from old request audit. Actual=' + projectHint.slice(0, 220));
      assert(projectHint.includes('\u591a\u7ebf\u7a0b\u8bf7\u6c42\u7ebf') && projectHint.includes('\u5408\u5e76'), 'project usage hint must explain multi-thread request lines are merged by project. Actual=' + projectHint.slice(0, 260));
      assert(html.includes('\u65e7\u8bf7\u6c42\u5ba1\u8ba1') && html.includes('helper \u540e\u5b9e\u9645'), 'project table must include helper-after actual and old request audit columns.');
    }
    if (String((((stats || {}).appQuota || {}).quotaEstimateBasis || '')).startsWith('real_request_tokens_from_')) {
      assert(appQuotaMeta.includes('\u622a\u56fe\u951a\u70b9\u6362\u7b97'), 'app quota meta must explain screenshot-anchor conversion. Actual=' + appQuotaMeta.slice(0, 220));
    }
    if (errors.length) {
      console.error(errors.join('\n'));
      process.exit(1);
    }
    console.log(JSON.stringify({
      ok: true,
      elementCount: elements.size,
      overviewHealth: elementForId('overviewHealth').textContent,
      topAuditState: elementForId('topAuditState').textContent,
      usageStatus: elementForId('usageDetectionStatus').textContent,
    }, null, 2));
  }, 25);
} catch (error) {
  console.error(error && error.stack ? error.stack : String(error));
  process.exit(1);
}
'@

$output = $script | & $node.Source - $DashboardPath $StatsPath
if ($LASTEXITCODE -ne 0) {
    throw "dashboard JS smoke failed."
}

$output
