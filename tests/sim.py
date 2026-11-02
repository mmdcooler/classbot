"""Scenario test for bot_handle(): simulates Telegram updates and prints bot replies."""
import json, re, sys, psycopg2

conn = psycopg2.connect(host="/tmp", port=5433, user="postgres", dbname="classbot")
conn.autocommit = True
cur = conn.cursor()
UPD = [1000]
VERBOSE = "-v" in sys.argv
FAILS = []

def q(sql, *a):
    cur.execute(sql, a)
    try: return cur.fetchall()
    except psycopg2.ProgrammingError: return None

def strip(t): return re.sub(r"<[^>]+>", "", t or "")

def run(update, who=""):
    UPD[0] += 1
    update["update_id"] = UPD[0]
    acts = q("SELECT bot_handle(%s::jsonb)", json.dumps(update))[0][0]
    out = []
    for a in acts:
        m, p = a["method"], a["payload"]
        if m == "answerCallbackQuery": continue
        kb = [b["text"] + "→" + b.get("callback_data", b.get("url", "")) for row in p.get("reply_markup", {}).get("inline_keyboard", []) for b in row]
        out.append((m, p.get("chat_id"), strip(p.get("text") or p.get("caption") or p.get("document") or p.get("photo") or json.dumps(p, ensure_ascii=False)), kb))
        if VERBOSE:
            print(f"   [{m} → {p.get('chat_id')}] {strip(p.get('text',''))[:400]}")
            if kb: print("      KB:", " | ".join(kb))
        if "خطای داخلی" in (p.get("text") or ""):
            FAILS.append(f"internal error for {who}: {update}")
    return out

def user(uid, first="U"):
    return {"id": uid, "is_bot": False, "first_name": first, "username": f"user{uid}"}

def msg(uid, text=None, **extra):
    m = {"message_id": 1, "from": user(uid), "chat": {"id": uid, "type": "private"}, "date": 0}
    if text is not None: m["text"] = text
    m.update(extra)
    return run({"message": m}, f"msg {uid} {text}")

def cb(uid, data, mid=55):
    return run({"callback_query": {"id": "cb1", "from": user(uid), "data": data,
               "message": {"message_id": mid, "chat": {"id": uid, "type": "private"}}}}, f"cb {uid} {data}")

def step(title):
    print(f"\n=== {title}")

def expect(out, needle, label):
    joined = " ".join(o[2] + " " + " ".join(o[3]) for o in out)
    ok = needle in joined
    print(("  ✔ " if ok else "  ✘ ") + label)
    if not ok:
        FAILS.append(label); print("     got:", joined[:600])

# ------------------------------------------------------------------ reset
q("TRUNCATE users, classes, enrollments, assignments, submissions, submission_parts, processed_updates RESTART IDENTITY CASCADE")
q("UPDATE settings SET value='rakhsh_class_bot' WHERE key='bot_username'")
ADMIN, TEACH, S1, S2, OTHER = 1001, 2002, 3003, 3004, 4005

step("admin bootstrap")
q("SELECT make_admin(%s)", ADMIN)
expect(msg(ADMIN, "/start"), "نام و نام خانوادگی", "admin asked for name")
msg(ADMIN, "محمد مدیر"); out = cb(ADMIN, "rsk")
expect(out, "پنل مدیریت", "admin main menu shows panel")

step("teacher registration + approval")
expect(msg(TEACH, "/start"), "نام و نام خانوادگی", "teacher asked name")
expect(msg(TEACH, "دکتر <علی> & رضایی"), "شماره دانشجویی", "asked student number")
out = cb(TEACH, "rsk")
expect(out, "درخواست حساب استاد", "teacher can request")
out = cb(TEACH, "treq")
expect(out, "برای مدیر ارسال شد", "request sent")
expect(out, "ap:2002", "admin got approve button")
expect(cb(TEACH, "tc"), "دسترسی ندارید", "pending teacher blocked")
expect(cb(S1, "ap:2002"), "", "non-admin approve ignored (no crash)")
out = cb(ADMIN, "ap:2002")
expect(out, "تأیید شد", "teacher notified approval")

step("create class")
out = cb(TEACH, "tn"); expect(out, "نام کلاس", "asked class name")
out = msg(TEACH, "ساختمان داده - گروه ۲")
expect(out, "کد عضویت", "class created")
code = q("SELECT join_code FROM classes")[0][0]
cid = q("SELECT id FROM classes")[0][0]
print("   join code:", code)
expect(cb(TEACH, f"tcr:{cid}"), "خودکار (بلافاصله", "toggle release -> auto")
expect(cb(TEACH, f"tcr:{cid}"), "با تأیید استاد", "toggle back -> manual")

step("students join (deep link + code)")
out = msg(S1, f"/start join_{code}")
expect(out, "نام و نام خانوادگی", "S1 asked name first")
msg(S1, "سارا احمدی")
out = msg(S1, "۹۸۱۲۳۴۵")
expect(out, "عضو کلاس", "S1 joined after registration via deep link")
assert q("SELECT student_no FROM users WHERE id=%s", S1)[0][0] == "9812345"
msg(S2, "/start"); msg(S2, "رضا کریمی"); msg(S2, "9900111")
cb(S2, "sj"); expect(msg(S2, "WRONG1"), "پیدا نشد", "wrong code rejected")
expect(msg(S2, code.lower()), "عضو کلاس", "S2 joined via lowercase code")
msg(OTHER, "/start"); msg(OTHER, "غریبه"); cb(OTHER, "rsk")

step("create assignment wizard")
out = cb(TEACH, f"an:{cid}"); expect(out, "جلسه ۱", "session suggestion")
expect(msg(TEACH, "abc"), "عدد صحیح", "invalid session rejected")
out = cb(TEACH, "asn:1"); expect(out, "عنوان تکلیف", "asked title")
out = msg(TEACH, "پیدا کردن بیشینه آرایه"); expect(out, "صورت تکلیف", "asked desc")
out = msg(TEACH, "تابعی بنویسید که بزرگ‌ترین عدد یک آرایه را برگرداند و پیچیدگی آن را تحلیل کنید.")
expect(out, "مهلت ارسال", "asked deadline")
out = cb(TEACH, "dl:c"); expect(out, "مدت مهلت", "custom deadline prompt")
expect(msg(TEACH, "۲۰۰"), "معتبر نیست", "too long deadline rejected")
out = msg(TEACH, "۱۲ ساعت"); expect(out, "چک‌لیست", "asked checklist")
expect(cb(TEACH, "cs"), "نمره کل: 20", "sample checklist shown")
expect(msg(TEACH, "یک چیز نامفهوم"), "قابل تشخیص نیست", "bad checklist rejected")
sample = q("SELECT checklist_sample()")[0][0]
out = msg(TEACH, sample); expect(out, "پاسخ‌نامه شما", "asked answer key after checklist")
expect(msg(TEACH, document={"file_id": "Z", "file_name": "a.zip", "mime_type": "application/zip"}), "پشتیبانی نمی‌شه", "bad answer-key file rejected")
out = msg(TEACH, "پاسخ: def mx(a): return max(a) — پیچیدگی O(n)"); expect(out, "پیش‌نمایش", "preview shown")
expect(out, "پاسخ‌نامه: متن", "preview shows answer key")
expect(out, "۱۲ ساعت", "deadline label 12h")
out = cb(TEACH, "ac:y")
expect(out, "منتشر شد و برای ۲ دانشجو", "published & 2 students notified")
aid = q("SELECT id FROM assignments")[0][0]
assert abs(q("SELECT extract(epoch from deadline-now())/3600 FROM assignments")[0][0] - 12) < 0.1

assert q("SELECT answer_text FROM assignments")[0][0].startswith("پاسخ:"), "answer saved"

step("answer key management")
out = cb(TEACH, f"ta:{aid}"); expect(out, "پاسخ‌نامه: ✅ دارد", "asg view shows key")
out = cb(TEACH, f"tan:{aid}"); expect(out, "برای جایگزینی", "key screen")
out = msg(TEACH, caption="کلید جدید", photo=[{"file_id": "ANS_PH", "file_size": 9}])
expect(out, "پاسخ‌نامه ذخیره شد", "key replaced with photo+caption")
assert q("SELECT answer_kind, answer_text FROM assignments")[0] == ("photo", "کلید جدید")
out = cb(TEACH, f"tanf:{aid}"); assert out[0][0] == "sendPhoto", out; print("  ✔ teacher can download key (sendPhoto)")
expect(cb(S1, f"tanf:{aid}"), "دسترسی ندارید", "student cannot get key")
expect(cb(S1, f"sa:{aid}"), "ارسال تکلیف", "student view")
assert "ANS_PH" not in str(cb(S1, f"sa:{aid}")), "key not leaked to student"
cb(TEACH, f"tan:{aid}"); out = cb(TEACH, f"ta:{aid}")
expect(msg(TEACH, "متن تصادفی"), "کلاس‌های من", "leaving key screen clears state")
cb(TEACH, f"tan:{aid}"); msg(TEACH, "پاسخ: def mx(a): return max(a) — پیچیدگی O(n)")

step("duplicate session blocked")
cb(TEACH, f"an:{cid}")
expect(msg(TEACH, "1"), "قبلاً تکلیف تعریف شده", "duplicate session rejected")
cb(TEACH, "ac:n")

step("access control")
expect(cb(OTHER, f"sa:{aid}"), "دسترسی ندارید", "non-member can't view asg")
expect(cb(S1, f"ta:{aid}"), "دسترسی ندارید", "student can't open teacher view")
expect(cb(S1, f"tc:{cid}"), "دسترسی ندارید", "student can't open teacher class")
expect(cb(OTHER, f"ss:{aid}"), "دسترسی ندارید", "non-member can't submit")

step("student submits")
out = cb(S1, f"sa:{aid}"); expect(out, "ارسال تکلیف", "S1 sees submit button")
out = cb(S1, f"ss:{aid}"); expect(out, "پاسخت رو بفرست", "submit mode")
expect(cb(S1, "sfy"), "هنوز چیزی نفرستادی", "empty submit blocked")
out = msg(S1, "def mx(a): return max(a)  # O(n)"); expect(out, "۱ بخش", "text part saved")
out = msg(S1, caption="کد کامل", document={"file_id": "DOC1", "file_name": "hw1.py", "mime_type": "text/x-python", "file_size": 1200})
expect(out, "۲ بخش", "doc saved (+caption)")
expect(msg(S1, document={"file_id": "X", "file_name": "a.zip", "mime_type": "application/zip", "file_size": 10}), "پشتیبانی نمی‌شه", "zip rejected")
expect(msg(S1, document={"file_id": "X", "file_name": "big.pdf", "mime_type": "application/pdf", "file_size": 50*1024*1024}), "مگابایت", "big file rejected")
out = msg(S1, photo=[{"file_id": "small", "file_size": 10}, {"file_id": "PH_BIG", "file_size": 90000}])
expect(out, "۴ بخش", "photo saved (caption counts as a part)")
expect(cb(S1, "sf"), "بخش آماده ارسال", "confirm screen")
out = cb(S1, "sfy"); expect(out, "با موفقیت ثبت شد", "submitted")
assert q("SELECT status FROM submissions WHERE student_id=%s", S1)[0][0] == "pending"
expect(cb(S1, f"ss:{aid}"), "در صف نمره‌دهی", "cannot resubmit")
# S2 starts a draft but pauses
cb(S2, f"ss:{aid}"); msg(S2, "پیش‌نویس من"); expect(cb(S2, "sp"), "پیش‌نویس ذخیره شد", "S2 paused draft")

step("grading queue")
jobs = [r[0] for r in q("SELECT grading_claim(5)")]
assert len(jobs) == 1, jobs
j = jobs[0]
print("   job parts:", [p["kind"] for p in j["parts"]], "models:", j["models"])
assert j["assignment"]["answer_text"].startswith("پاسخ:"), "answer key in grading job"
assert q("SELECT count(*) FROM grading_claim(5)")[0][0] == 0, "should not double-claim"
res = {"submission_id": j["submission_id"], "ai_score": 17.5,
       "criteria": [{"id": 1, "score": 4, "comment": "کامل"}, {"id": 2, "score": 8, "comment": "درست"},
                    {"id": 3, "score": 2, "comment": "حافظه تحلیل نشده"}, {"id": 4, "score": 1.5, "comment": "کامنت کم"},
                    {"id": 5, "score": 2, "comment": ""}],
       "deductions": [], "overall_feedback": "کار خوبی بود؛ تحلیل حافظه را اضافه کن.",
       "needs_review": False, "review_reason": "", "confidence": 0.86, "model": "test"}
acts = q("SELECT grading_save(%s::jsonb)", json.dumps(res))[0][0]
texts = [strip(a["payload"].get("text")) for a in acts]
expect([("", "", " ".join(texts), [])], "تکلیف جدید نمره‌دهی شد", "teacher card (manual mode)")
expect([("", "", " ".join(texts), [])], "بعد از تأیید استاد", "student told waiting")
sid = j["submission_id"]
assert q("SELECT grading_save(%s::jsonb)", json.dumps(res))[0][0] == [], "second save ignored"

step("teacher review")
out = cb(TEACH, f"ta:{aid}"); expect(out, "منتظر تأیید شما: ۱", "asg stats")
out = cb(TEACH, f"tsl:{aid}"); expect(out, "رضا کریمی", "S2 listed as not submitted"); expect(out, "۱۷.۵", "score in list")
out = cb(TEACH, f"tas:{sid}"); expect(out, "حافظه تحلیل نشده", "detail with comments")
out = cb(TEACH, f"tasf:{sid}"); expect(out, "DOC1", "files forwarded")
cb(TEACH, f"sed:{sid}")
expect(msg(TEACH, "۲۵"), "بین ۰ و ۲۰", "out-of-range score rejected")
out = msg(TEACH, "۱۸"); expect(out, "به ۱۸ تغییر کرد", "score edited")
out = cb(TEACH, f"sap:{sid}"); expect(out, "نتیجه تکلیف شما اعلام شد", "student got release")
expect(out, "نمره: ۱۸ از ۲۰", "released score 18")
cb(TEACH, f"sed:{sid}"); out = msg(TEACH, "19.25"); expect(out, "اصلاح شد", "post-release edit notifies student")
out = cb(S1, f"sr:{sid}"); expect(out, "۱۹.۲۵", "student sees updated score")

step("reports")
out = cb(TEACH, f"tar:{aid}"); expect(out, "میانگین هر معیار", "text report")
if VERBOSE: print(out[0][2])
out = cb(TEACH, f"tax:{aid}")
assert any(o[0] == "_excel" for o in out), out
rows = q("SELECT report_rows(%s)", aid)[0][0]
print("   excel cols:", rows["columns"][:6], "... rows:", len(rows["rows"]))
assert len(rows["rows"]) == 2

step("regrade all after key change")
out = cb(TEACH, f"targ:{aid}"); expect(out, "دوباره با چک‌لیست", "regrade-all confirm")
out = cb(TEACH, f"targy:{aid}"); expect(out, "۱ ارسال در صف", "regrade-all queued")
j = q("SELECT grading_claim(5)")[0][0]
q("SELECT grading_save(%s::jsonb)", json.dumps({**res, "submission_id": j["submission_id"]}))
cb(TEACH, f"sap:{sid}")
cb(TEACH, f"tanx:{aid}"); assert q("SELECT answer_text FROM assignments")[0][0] is None, "key deleted"

step("regrade + auto mode + needs_review + failure")
cb(TEACH, f"tcr:{cid}")  # auto
cb(TEACH, f"srg:{sid}")
j = q("SELECT grading_claim(5)")[0][0]
acts = q("SELECT grading_save(%s::jsonb)", json.dumps({**res, "submission_id": j["submission_id"]}))[0][0]
expect([("", "", " ".join(strip(a["payload"].get("text")) for a in acts), [])], "نتیجه تکلیف شما اعلام شد", "auto release to student")
cb(TEACH, f"srg:{sid}")
j = q("SELECT grading_claim(5)")[0][0]
acts = q("SELECT grading_save(%s::jsonb)", json.dumps({**res, "submission_id": j["submission_id"], "needs_review": True, "review_reason": "مشکوک به کپی"}))[0][0]
expect([("", "", " ".join(strip(a["payload"].get("text")) for a in acts), [])], "نیاز به بررسی شما دارد", "needs_review stops auto release")
cb(TEACH, f"srg:{sid}")
for i in range(3):
    j = q("SELECT grading_claim(5)")[0][0]
    acts = q("SELECT grading_fail(%s, %s)", j["submission_id"], "HTTP 500")[0][0]
expect([("", "", " ".join(strip(a["payload"].get("text")) for a in acts), [])], "ناموفق بود", "failure after 3 attempts -> teacher")

step("rate limit (429) -> wait & retry, no attempt burned")
cb(TEACH, f"srg:{sid}")
j = q("SELECT grading_claim(5)")[0][0]
assert q("SELECT grading_fail(%s, %s)", j["submission_id"], 'AI request error: Request failed with status code 429')[0][0] == []
st = q("SELECT status, attempts, rate_hits, retry_at > now() FROM submissions WHERE id=%s", sid)[0]
assert st == ("pending", 0, 1, True), st
assert q("SELECT count(*) FROM grading_claim(5)")[0][0] == 0, "must wait until retry_at"
q("UPDATE submissions SET retry_at = now() - interval '1 second' WHERE id=%s", sid)
j = q("SELECT grading_claim(5)")[0][0]
q("SELECT grading_save(%s::jsonb)", json.dumps({**res, "submission_id": j["submission_id"]}))
assert q("SELECT status IN ('graded','released'), rate_hits, retry_at FROM submissions WHERE id=%s", sid)[0] == (True, 0, None)
print("  ✔ 429 backoff + recovery")

step("scheduler: reminder + close")
q("UPDATE assignments SET created_at = now() - interval '2 days', deadline = now() + interval '5 hours'")
acts = q("SELECT scheduler_tick()")[0][0]
t = " ".join(strip(a["payload"].get("text")) for a in acts)
expect([("", "", t, [])], "پیش‌نویس داری", "S2 reminded about draft")
assert sum(1 for a in acts if a["payload"]["chat_id"] == S1) == 0, "S1 already submitted -> no reminder"
assert q("SELECT scheduler_tick()")[0][0] == [], "reminder only once"
q("UPDATE assignments SET deadline = now() - interval '1 minute'")
acts = q("SELECT scheduler_tick()")[0][0]
expect([("", "", " ".join(strip(a["payload"].get("text")) for a in acts), [])], "مهلت تکلیف تمام شد", "teacher got closing report")
expect(cb(S2, f"ss:{aid}"), "مهلت این تکلیف تمام شده", "late submit blocked")
out = cb(TEACH, f"tae:{aid}"); expect(out, "تمدید شد", "extend notifies non-submitters")
expect(cb(TEACH, f"taly:{aid}"), "بسته شده", "close now")

step("misc")
expect(msg(S1, "/myid"), str(S1), "/myid")
expect(msg(S1, "سلام"), "کلاس‌های من", "free text -> menu")
expect(cb(S1, "garbage:xx"), "کلاس‌های من", "unknown callback -> menu")
expect(cb(TEACH, "tc:999999"), "دسترسی ندارید", "unknown class")
expect(msg(ADMIN, "/setmodel google/gemini-2.5-pro openai/gpt-4o"), "gemini-2.5-pro", "setmodel")
before = UPD[0]; UPD[0] -= 1
assert run({"message": {"message_id": 9, "from": user(S1), "chat": {"id": S1, "type": "private"}, "text": "/menu"}}) == [], "duplicate update ignored"
UPD[0] = before
expect(run({"message": {"message_id": 9, "from": user(S1), "chat": {"id": -5, "type": "group"}, "text": "/start"}}) or [("", "", "ignored", [])], "ignored", "group ignored")
out = cb(TEACH, f"tcd:{cid}"); cb(TEACH, f"tcdy:{cid}")
expect(cb(S1, "sc"), "هنوز عضو کلاسی نیستی", "archived class hidden")

print("\n" + ("ALL PASSED" if not FAILS else f"{len(FAILS)} FAILED:\n - " + "\n - ".join(FAILS)))
