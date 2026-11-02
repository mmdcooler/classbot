# ClassBot — ربات تلگرام تکالیف کلاس با نمره‌دهی هوش مصنوعی (n8n)

## این ربات چه کار می‌کند؟

**استاد**
- بعد از تأیید مدیر، هر تعداد کلاس می‌سازد؛ هر کلاس یک **کد/لینک عضویت** دارد.
- برای **هر جلسه یک تکلیف** تعریف می‌کند: عنوان، صورت سؤال (متن یا فایل PDF/عکس)، **مهلت** (۱ روز، ۲ روز، ۳ روز، ۱ هفته، ۲ هفته یا دلخواه) و **چک‌لیست نمره‌دهی**.
- برای هر کلاس انتخاب می‌کند نمره **خودکار** اعلام شود یا **اول خودش تأیید کند**.
- نمره و بازخورد هر دانشجو را می‌بیند، ویرایش می‌کند، نمره‌دهی مجدد می‌زند، پاسخ اصلی دانشجو را می‌بیند.
- **گزارش** کامل (میانگین، بیشینه/کمینه، میانگین هر معیار، فهرست ارسال‌نکرده‌ها) و **فایل اکسل** می‌گیرد. موقع بسته شدن مهلت، گزارش خودکار برایش می‌آید.

**دانشجو**
- با لینک یا کد عضو کلاس می‌شود (نام + شماره دانشجویی یک‌بار ثبت می‌شود).
- تکالیف را با وضعیت و زمان باقی‌مانده می‌بیند؛ پاسخ را به صورت **متن، PDF، Word، عکس دست‌نویس یا فایل کد** (چند بخش) می‌فرستد و «ارسال نهایی» می‌زند.
- یادآوری قبل از پایان مهلت می‌گیرد؛ نمره + بازخورد هر معیار را در ربات می‌گیرد.

**هوش مصنوعی** (از طریق OpenRouter) پاسخ را دقیقاً طبق چک‌لیست استاد، معیار به معیار نمره می‌دهد، بازخورد فارسی می‌نویسد و موارد مشکوک (کپی، ناخوانا، تلاش برای فریب AI، اطمینان پایین) را برای **بررسی استاد** علامت می‌زند.

## معماری

```
تلگرام ──webhook──► n8n «1. Bot» ──► Postgres: bot_handle(update) ──► لیست اکشن‌ها ──► Telegram API
                                                                                    └─► _excel ► فایل اکسل
n8n «2. Grader & Scheduler»
   هر ۱ دقیقه: grading_claim() ► دانلود فایل‌ها از تلگرام ► OpenRouter ► grading_result() ► پیام به دانشجو/استاد
   هر ۵ دقیقه: scheduler_tick() ► یادآوری مهلت + بستن تکلیف + گزارش به استاد
```
همه‌ی منطق ربات (منوها، مراحل، دسترسی‌ها) داخل توابع SQL است؛ n8n فقط پیام‌رسان است. این باعث می‌شود ورک‌فلوها ساده بمانند و تست‌پذیر باشند (`tests/sim.py` بیش از ۷۰ سناریو را تست می‌کند).

## فایل‌ها

| مسیر | توضیح |
|---|---|
| `sql/00…05` | ساخت دیتابیس n8n، جدول‌ها، توابع ربات، نمره‌دهی، گزارش، زمان‌بندی |
| `n8n/workflows/1_classbot_bot.json` | ورک‌فلو ربات (Import در n8n) |
| `n8n/workflows/2_classbot_background.json` | ورک‌فلو نمره‌دهی AI + یادآوری/بستن مهلت |
| `n8n/code/*.js` | کد Code nodeها (داخل JSONها هم هست) |
| `docker-compose.yml` و `.env.example` | راه‌اندازی n8n + Postgres |
| `checklist_samples.md` | نمونه چک‌لیست‌ها برای استادها |
| `tests/` | تست‌ها |

---

## راه‌اندازی (سرور آلمان)

### ۱. ربات تلگرام
در @BotFather: `/newbot` ← توکن را بردارید. بعد `/setcommands` و این را بفرستید:
```
start - شروع / منوی اصلی
menu - منوی اصلی
cancel - لغو عملیات
help - راهنما
myid - شناسه تلگرام من
```

### ۲. دامنه + HTTPS
یک ساب‌دامنه (مثلاً `bot.rakhshagc.ir`) را به IP سرور آلمان وصل کنید. تلگرام فقط به **HTTPS** وبهوک می‌زند. نمونه Nginx:
```nginx
server {
    server_name bot.example.com;
    location / {
        proxy_pass http://127.0.0.1:5678;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        client_max_body_size 25m;
        proxy_read_timeout 300s;
    }
    listen 80;
}
```
سپس: `sudo certbot --nginx -d bot.example.com`

### ۳. اجرای n8n + Postgres
```bash
git clone <repo> /opt/classbot && cd /opt/classbot
cp .env.example .env && nano .env        # دامنه، رمزها، توکن ربات
openssl rand -hex 32                      # خروجی را در N8N_ENCRYPTION_KEY بگذارید
docker compose up -d
docker compose logs -f postgres           # باید ساخت جدول‌ها بدون ERROR تمام شود
```
> **اگر n8n از قبل روی سرور دارید:** فقط یک دیتابیس `classbot` بسازید، فایل‌های `sql/01` تا `sql/05` را به ترتیب روی آن اجرا کنید و این env ها را به n8n اضافه کنید: `TELEGRAM_BOT_TOKEN`، `N8N_BLOCK_ENV_ACCESS_IN_NODE=false`، `NODE_FUNCTION_ALLOW_BUILTIN=zlib`. (دیتابیس ربات حتماً جدا از دیتابیس خود n8n باشد؛ نام جدول‌ها تداخل دارند.)

### ۴. تنظیمات اولیه دیتابیس
```bash
docker compose exec postgres psql -U classbot -d classbot
```
```sql
UPDATE settings SET value = 'MyClassBot' WHERE key = 'bot_username';   -- یوزرنیم ربات بدون @
```
(مدیر را بعد از مرحله ۶ تعیین می‌کنیم.)

### ۵. n8n
1. وارد `https://bot.example.com` شوید و حساب owner بسازید.
2. **Credentials** بسازید (نام‌ها را دقیقاً همین بگذارید تا خودکار وصل شوند):
   - **ClassBot Telegram** — نوع *Telegram API* — Access Token = توکن ربات
   - **ClassBot Postgres** — نوع *Postgres* — Host: `postgres`، Database: `classbot`، User/Password از `.env`، Port: 5432، SSL: disable
   - **OpenRouter Header Auth** — نوع *Header Auth* — Name: `Authorization`، Value: `Bearer sk-or-v1-...`
3. **Workflows → Import from File**: هر دو فایل `n8n/workflows/*.json`.
4. در هر ورک‌فلو روی نودهایی که علامت هشدار دارند (Telegram/Postgres/OpenRouter) کلیک کنید و credential مربوط را انتخاب کنید ← **Save**.
5. هر دو ورک‌فلو را **Active** کنید (Telegram Trigger وبهوک را خودکار ثبت می‌کند).

### ۶. مدیر کل و اولین استاد
1. در تلگرام به ربات `/start` بدهید، ثبت‌نام کنید و `/myid` بزنید.
2. در psql: `SELECT make_admin(123456789);` ← شما هم مدیر می‌شوید و هم استاد.
3. استادهای دیگر از منوی ربات «درخواست حساب استاد» می‌زنند؛ پیام تأیید/رد برای شما می‌آید (یا از `/admin`).

### ۷. مدل هوش مصنوعی
پیش‌فرض: `google/gemini-2.5-flash` و پشتیبان `openai/gpt-4o-mini`. مدل باید **تصویر و PDF** را پشتیبانی کند (برای عکس دست‌نویس و PDF). برای تغییر، مدیر در ربات می‌فرستد:
```
/setmodel google/gemini-2.5-flash openai/gpt-4o-mini
```
(شناسه دقیق مدل را از صفحه همان مدل در openrouter.ai کپی کنید.)

---

## تست سریع بعد از راه‌اندازی
1. استاد: «کلاس‌های من» ← «ساخت کلاس جدید» ← لینک عضویت را با یک اکانت دوم باز کنید.
2. استاد: «تکلیف جدید» ← مهلت «۱ روز» ← «نمونه چک‌لیست» را کپی و ارسال کنید ← انتشار.
3. دانشجو: تکلیف ← ارسال تکلیف ← یک متن یا عکس ← ارسال نهایی.
4. حداکثر یک دقیقه بعد کارت نمره برای استاد می‌آید ← «تأیید و اعلام» ← دانشجو نمره را می‌گیرد.
5. در n8n بخش **Executions** ورک‌فلو ۲ را ببینید؛ اگر خطایی بود همان‌جا مشخص است.

## نکته‌های مهم
- **سقف فایل:** ربات تلگرام فقط فایل‌های تا ۲۰ مگابایت را می‌تواند دانلود کند.
- **فرمت‌ها:** PDF، docx، jpg/png/webp، فایل‌های متنی و کد (py, cpp, java, js, ipynb, …). فایل `.doc` قدیمی و zip پذیرفته نمی‌شود (پیام راهنما می‌گیرد).
- **هزینه AI:** هر ارسال یک درخواست است؛ با Gemini Flash معمولاً کمتر از یک سنت. سقف هزینه را در خود OpenRouter تعیین کنید.
- **تلاش مجدد:** اگر AI خطا بدهد، تا ۳ بار دوباره تلاش می‌شود؛ بعد کارت «نمره‌دهی ناموفق» برای استاد می‌آید تا دستی نمره بدهد یا دوباره بزند.
- **امنیت:** توکن‌ها فقط در `.env`/Credential هستند؛ پیام‌ها base64 به SQL می‌روند (بدون SQL Injection)؛ هر دکمه مالکیت کلاس/تکلیف را چک می‌کند؛ پاسخ دانشجو برای AI «داده» علامت‌گذاری شده و تلاش برای فریب AI به بررسی استاد می‌رود.
- **پشتیبان‌گیری:**
  ```bash
  docker compose exec -T postgres pg_dump -U classbot classbot | gzip > backup_$(date +%F).sql.gz
  ```

## اجرای تست‌ها (برای توسعه)
```bash
python3 tests/sim.py            # سناریوی کامل ربات روی Postgres
node tests/test_code_nodes.js /tmp   # Code nodeهای نمره‌دهی
python3 n8n/build_workflows.py  # بعد از تغییر n8n/code/*.js، JSONها را دوباره بسازید
```
تست end-to-end (`tests/e2e/`) هر دو ورک‌فلو را روی n8n 2.45.7 واقعی با API تلگرام/OpenRouter شبیه‌سازی‌شده اجرا می‌کند: پیام و دکمه، ارسال متن/کد/عکس/Word، نمره‌دهی AI، کارت استاد، اعلام نمره، فایل اکسل و گزارش پایان مهلت.
