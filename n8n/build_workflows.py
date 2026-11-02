"""Generates the importable n8n workflow JSON files from the code snippets.
Run:  python3 n8n/build_workflows.py
"""
import json, pathlib, uuid

ROOT = pathlib.Path(__file__).parent
CODE = ROOT / "code"
OUT = ROOT / "workflows"
OUT.mkdir(exist_ok=True)

TG_CRED = {"telegramApi": {"id": "", "name": "ClassBot Telegram"}}
PG_CRED = {"postgres": {"id": "", "name": "ClassBot Postgres"}}
OR_CRED = {"httpHeaderAuth": {"id": "", "name": "OpenRouter Header Auth"}}

def nid(): return str(uuid.uuid4())

def node(name, type_, ver, pos, params, **extra):
    n = {"parameters": params, "id": nid(), "name": name, "type": type_, "typeVersion": ver, "position": pos}
    n.update(extra)
    return n

def code(name, pos, js, each=False, **extra):
    p = {"jsCode": js}
    if each: p["mode"] = "runOnceForEachItem"
    return node(name, "n8n-nodes-base.code", 2, pos, p, **extra)

def pg(name, pos, query, **extra):
    return node(name, "n8n-nodes-base.postgres", 2.6, pos,
                {"operation": "executeQuery", "query": query, "options": {"queryBatching": "independently"}},
                credentials=PG_CRED, **extra)

def tg_send(name, pos):
    return node(name, "n8n-nodes-base.httpRequest", 4.2, pos, {
        "method": "POST",
        "url": "={{ ($env.TELEGRAM_API_BASE || 'https://api.telegram.org') + '/bot' + $env.TELEGRAM_BOT_TOKEN + '/' + $json.method }}",
        "sendBody": True, "specifyBody": "json",
        "jsonBody": "={{ JSON.stringify($json.payload) }}",
        "options": {"batching": {"batch": {"batchSize": 1, "batchInterval": 40}}, "timeout": 20000},
    }, onError="continueRegularOutput")

def connect(conns, a, b, out_index=0):
    conns.setdefault(a, {"main": []})
    while len(conns[a]["main"]) <= out_index: conns[a]["main"].append([])
    conns[a]["main"][out_index].append({"node": b, "type": "main", "index": 0})

def wf(name, nodes, conns, settings=None):
    return {"name": name, "nodes": nodes, "connections": conns, "active": False,
            "settings": {"executionOrder": "v1", **(settings or {})}, "pinData": {}, "tags": []}

SPLIT_JS = """// Each row carries a JSON array of Telegram actions -> one item per action
const out = [];
for (const item of $input.all()) {
  const acts = item.json.actions || [];
  for (const a of acts) out.push({ json: a });
}
return out;"""

def filter_js(cond, comment=""):
    # keep explicit pairedItem so later nodes can use $('...').item
    return (f"// {comment}\n" if comment else "") + \
        "return $input.all()\n  .map((it, idx) => ({ json: it.json, binary: it.binary, pairedItem: { item: idx } }))\n" + \
        f"  .filter(i => {cond});"

ONLY_TG_JS = filter_js("i.json.method && !i.json.method.startsWith('_')", 'Real Telegram API calls (internal actions start with "_")')
ONLY_EXCEL_JS = filter_js("i.json.method === '_excel'")

ENCODE_JS = """// Base64-encode the Telegram update so it can be passed to SQL safely (no SQL injection possible)
return $input.all().map(i => ({ json: { b64: Buffer.from(JSON.stringify(i.json), 'utf8').toString('base64') } }));"""

ROWS_JS = """// report_rows() -> one item per student with Persian column names (keeps column order)
const r = $input.first().json.r;
if (!r.rows.length) return [{ json: { 'پیام': 'این کلاس هنوز دانشجویی ندارد' } }];
return r.rows.map(row => {
  const o = {};
  r.columns.forEach((c, i) => { o[c] = row[i] === null || row[i] === undefined ? '' : row[i]; });
  return { json: o };
});"""

DECODE = "convert_from(decode('{{ $json.b64 }}', 'base64'), 'UTF8')::jsonb"

# ===================================================================== 1) BOT
n, c = [], {}
n.append(node("Telegram Trigger", "n8n-nodes-base.telegramTrigger", 1.2, [0, 300],
              {"updates": ["message", "callback_query"], "additionalFields": {}},
              credentials=TG_CRED, webhookId=nid()))
n.append(code("Encode update", [220, 300], ENCODE_JS))
n.append(pg("Bot logic (SQL)", [440, 300], f"=SELECT bot_handle({DECODE}) AS actions;"))
n.append(code("Split actions", [660, 300], SPLIT_JS))
n.append(code("Telegram actions", [880, 200], ONLY_TG_JS))
n.append(tg_send("Send to Telegram", [1100, 200]))
n.append(code("Excel actions", [880, 440], ONLY_EXCEL_JS))
n.append(pg("Excel data", [1100, 440],
            "=SELECT report_rows({{ parseInt($json.payload.assignment_id) }}) AS r, {{ parseInt($json.payload.chat_id) }}::bigint AS chat_id;"))
n.append(code("Rows to items", [1320, 440], ROWS_JS))
n.append(node("Convert to Excel", "n8n-nodes-base.convertToFile", 1.1, [1540, 440], {
    "operation": "xlsx", "binaryPropertyName": "data",
    "options": {"fileName": "={{ $('Excel data').first().json.r.file_name }}", "sheetName": "Report"}}))
n.append(node("Send Excel", "n8n-nodes-base.telegram", 1.2, [1760, 440], {
    "operation": "sendDocument",
    "chatId": "={{ $('Excel data').first().json.chat_id }}",
    "binaryData": True, "binaryPropertyName": "data",
    "additionalFields": {"caption": "={{ $('Excel data').first().json.r.caption }}"}},
    credentials=TG_CRED, onError="continueRegularOutput"))
for a, b in [("Telegram Trigger", "Encode update"), ("Encode update", "Bot logic (SQL)"),
             ("Bot logic (SQL)", "Split actions"), ("Split actions", "Telegram actions"),
             ("Split actions", "Excel actions"), ("Telegram actions", "Send to Telegram"),
             ("Excel actions", "Excel data"), ("Excel data", "Rows to items"),
             ("Rows to items", "Convert to Excel"), ("Convert to Excel", "Send Excel")]:
    connect(c, a, b)
n.append(node("Note", "n8n-nodes-base.stickyNote", 1, [-40, 20], {
    "content": "## ClassBot — ربات تکالیف\nهمه منطق ربات داخل تابع SQL `bot_handle()` است.\nاین ورک‌فلو فقط آپدیت تلگرام را به دیتابیس می‌دهد و اکشن‌های برگشتی (پیام، ویرایش پیام، فایل) را اجرا می‌کند.\n\nلازم: Credential تلگرام + Postgres و متغیر محیطی `TELEGRAM_BOT_TOKEN`",
    "height": 220, "width": 420}))
(OUT / "1_classbot_bot.json").write_text(json.dumps(wf("ClassBot — 1. Bot", n, c), ensure_ascii=False, indent=2))

# ===================================================================== 2) BACKGROUND (grader + scheduler)
n, c = [], {}
n.append(node("Every minute", "n8n-nodes-base.scheduleTrigger", 1.2, [0, 200],
              {"rule": {"interval": [{"field": "minutes", "minutesInterval": 1}]}}))
n.append(pg("Claim submissions", [220, 200], "SELECT grading_claim(3) AS job;"))
n.append(code("Build AI request", [440, 200], (CODE / "build_ai_request.js").read_text(), each=True))
n.append(code("Has AI request", [660, 100], filter_js("i.json.request")))
n.append(code("Build failed", [660, 320], filter_js("i.json.b64")))
n.append(node("OpenRouter", "n8n-nodes-base.httpRequest", 4.2, [880, 100], {
    "method": "POST", "url": "https://openrouter.ai/api/v1/chat/completions",
    "authentication": "genericCredentialType", "genericAuthType": "httpHeaderAuth",
    "sendHeaders": True,
    "headerParameters": {"parameters": [{"name": "X-Title", "value": "ClassBot Grader"}]},
    "sendBody": True, "specifyBody": "json",
    "jsonBody": "={{ JSON.stringify($json.request) }}",
    "options": {"batching": {"batch": {"batchSize": 1, "batchInterval": 500}}, "timeout": 180000}},
    credentials=OR_CRED, onError="continueRegularOutput", retryOnFail=True, maxTries=2, waitBetweenTries=5000))
n.append(code("Parse AI result", [1100, 100], (CODE / "parse_ai_result.js").read_text(), each=True))
n.append(pg("Save result", [1320, 200], f"=SELECT grading_result({DECODE}) AS actions;"))
n.append(code("Split grading actions", [1540, 200], SPLIT_JS))
n.append(tg_send("Notify via Telegram", [1760, 200]))

n.append(node("Every 5 minutes", "n8n-nodes-base.scheduleTrigger", 1.2, [0, 520],
              {"rule": {"interval": [{"field": "minutes", "minutesInterval": 5}]}}))
n.append(pg("Reminders & deadlines", [220, 520], "SELECT scheduler_tick() AS actions;"))
n.append(code("Split scheduler actions", [440, 520], SPLIT_JS))
n.append(tg_send("Send scheduler messages", [660, 520]))
for a, b in [("Every minute", "Claim submissions"), ("Claim submissions", "Build AI request"),
             ("Build AI request", "Has AI request"), ("Build AI request", "Build failed"),
             ("Has AI request", "OpenRouter"), ("OpenRouter", "Parse AI result"),
             ("Parse AI result", "Save result"), ("Build failed", "Save result"),
             ("Save result", "Split grading actions"), ("Split grading actions", "Notify via Telegram"),
             ("Every 5 minutes", "Reminders & deadlines"), ("Reminders & deadlines", "Split scheduler actions"),
             ("Split scheduler actions", "Send scheduler messages")]:
    connect(c, a, b)
n.append(node("Note", "n8n-nodes-base.stickyNote", 1, [-40, -120], {
    "content": "## ClassBot — نمره‌دهی AI و زمان‌بندی\n**بالا:** هر دقیقه ارسال‌های جدید را برمی‌دارد، فایل‌ها را از تلگرام دانلود می‌کند، با چک‌لیست استاد به OpenRouter می‌فرستد و نتیجه را ذخیره/اعلام می‌کند.\n**پایین:** هر ۵ دقیقه یادآوری مهلت و بستن تکالیف + ارسال گزارش به استاد.",
    "height": 200, "width": 520}))
(OUT / "2_classbot_background.json").write_text(json.dumps(
    wf("ClassBot — 2. AI Grader & Scheduler", n, c,
       {"saveDataSuccessExecution": "none", "saveManualExecutions": True}), ensure_ascii=False, indent=2))
print("written:", sorted(p.name for p in OUT.iterdir()))
