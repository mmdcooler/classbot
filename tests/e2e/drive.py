"""End-to-end: post Telegram-like updates to the n8n webhook, let the grader run, inspect mock API calls."""
import json, sys, time, urllib.request, re
import psycopg2

LOG = sys.argv[1]
URL = "http://127.0.0.1:5678/webhook/tg"
db = psycopg2.connect(host="/tmp", port=5433, user="postgres", dbname="classbot"); db.autocommit = True
cur = db.cursor()
U = [5000]
fails = []

def calls():
    try: return [json.loads(l) for l in open(LOG)]
    except FileNotFoundError: return []

def post(upd):
    U[0] += 1; upd["update_id"] = U[0]
    n0 = len(calls())
    urllib.request.urlopen(urllib.request.Request(URL, json.dumps(upd).encode(), {"content-type": "application/json"}))
    for _ in range(40):
        time.sleep(0.25)
        if len(calls()) > n0: time.sleep(0.6); break
    return calls()[n0:]

def usr(i): return {"id": i, "is_bot": False, "first_name": "T", "username": f"u{i}"}
def msg(i, text=None, **kw):
    m = {"message_id": 1, "from": usr(i), "chat": {"id": i, "type": "private"}, "date": 0, **kw}
    if text is not None: m["text"] = text
    return post({"message": m})
def cb(i, data): return post({"callback_query": {"id": "c", "from": usr(i), "data": data, "message": {"message_id": 9, "chat": {"id": i, "type": "private"}}}})

def check(cond, label, info=""):
    print(("  ✔ " if cond else "  ✘ ") + label + ("" if cond else f"  {info}"))
    if not cond: fails.append(label)

def texts(cs): return " ".join(re.sub("<[^>]+>", "", (c.get("payload") or {}).get("text", "")) for c in cs)

T, S1 = 2002, 3003
cur.execute("SELECT make_admin(%s)", (T,))
print("teacher setup via webhook")
r = msg(T, "/start"); check(any(c.get("tgMethod") == "sendMessage" for c in r), "bot replies through n8n → Telegram API", r)
msg(T, "استاد تست"); cb(T, "rsk")
r = cb(T, "tn"); check("answerCallbackQuery" in [c.get("tgMethod") for c in r] and "editMessageText" in [c.get("tgMethod") for c in r], "callback answered + message edited in order",
                       [c.get("tgMethod") for c in r])
msg(T, "کلاس تست n8n")
cur.execute("SELECT id, join_code FROM classes"); cid, code = cur.fetchone()
msg(S1, f"/start join_{code}"); msg(S1, "دانشجو یک"); r = msg(S1, "981111")
check("عضو کلاس" in texts(r), "student joined via deep link", texts(r))
cb(T, f"an:{cid}"); cb(T, "asn:1"); msg(T, "تکلیف تست"); msg(T, "بیشینه آرایه را پیدا کنید"); cb(T, "dl:24")
cur.execute("SELECT checklist_sample()"); msg(T, cur.fetchone()[0])
r = cb(T, "ac:y"); check("تکلیف جدید" in texts(r), "publish → student notified", texts(r)[:300])
cur.execute("SELECT id FROM assignments"); aid = cur.fetchone()[0]

print("student submits text + code file + photo")
cb(S1, f"ss:{aid}"); msg(S1, "جواب متنی من")
msg(S1, document={"file_id": "DOC1", "file_name": "hw.py", "mime_type": "text/x-python", "file_size": 30})
msg(S1, photo=[{"file_id": "PH1", "file_size": 4}])
r = cb(S1, "sfy"); check("با موفقیت ثبت شد" in texts(r), "final submit", texts(r)[:200])

print("waiting for background grader (schedule: every minute)…")
for _ in range(150):
    time.sleep(1)
    cur.execute("SELECT status FROM submissions"); st = cur.fetchone()[0]
    if st not in ("pending", "grading"): break
cur.execute("SELECT status, ai_score, last_error FROM submissions"); st = cur.fetchone()
print("   submission:", st)
check(st[0] == "graded", "AI graded via OpenRouter node", st)
check(st[1] == 16.5, "score computed from criteria (16.5)", st)
time.sleep(2)
ai = [c for c in calls() if c.get("kind") == "ai"]
check(ai and ai[0]["auth"] == "Bearer sk-or-test", "OpenRouter header auth used")
check(ai and "image_url" in ai[0]["blocks"], "photo sent as image", ai and ai[0]["blocks"])
check(ai and "def mx(a)" in ai[0]["text"], "code file downloaded & inlined")
dl = [c for c in calls() if c.get("kind") == "download"]
check(len(dl) == 2 and all("TEST" in c["path"] for c in dl), "files downloaded from Telegram with token")
card = [c for c in calls() if c.get("kind") == "tg" and c["payload"] and c["payload"].get("chat_id") == T and "نمره‌دهی شد" in (c["payload"].get("text") or "")]
check(bool(card), "teacher received grading card")

print("teacher approves + excel")
cur.execute("SELECT id FROM submissions"); sid = cur.fetchone()[0]
r = cb(T, f"sap:{sid}"); check("نتیجه تکلیف شما اعلام شد" in texts(r), "student received score", texts(r)[:200])
r = cb(T, f"tax:{aid}")
time.sleep(3); r = [c for c in calls() if c.get("tgMethod") == "sendDocument"]
check(r and "multipart" in r[-1]["ctype"] and r[-1]["multipartHasXlsx"], "Excel file sent as multipart sendDocument", r[-1:] )

print("scheduler: close deadline → teacher report")
cur.execute("UPDATE assignments SET deadline = now() - interval '1 minute'")
for _ in range(330):
    time.sleep(1)
    cur.execute("SELECT status FROM assignments");
    if cur.fetchone()[0] == "closed": break
time.sleep(4)
rep = [c for c in calls() if c.get("kind") == "tg" and c["payload"] and "مهلت تکلیف تمام شد" in (c["payload"].get("text") or "")]
check(bool(rep), "closing report delivered by scheduler")
print("\n" + ("E2E ALL PASSED" if not fails else f"E2E FAILED: {fails}"))
