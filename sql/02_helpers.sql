-- =====================================================================
--  Helpers: formatting, Jalali dates, Telegram action builders, checklist parser
-- =====================================================================

-- HTML escape for Telegram parse_mode=HTML
CREATE OR REPLACE FUNCTION h(t text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT replace(replace(replace(coalesce(t,''),'&','&amp;'),'<','&lt;'),'>','&gt;')
$$;

-- English digits -> Persian digits
CREATE OR REPLACE FUNCTION fa(t text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT translate(coalesce(t,''), '0123456789', '۰۱۲۳۴۵۶۷۸۹')
$$;
CREATE OR REPLACE FUNCTION fa(n numeric) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT fa(CASE WHEN n IS NULL THEN '-'
                 WHEN n = trunc(n) THEN trunc(n)::text
                 ELSE rtrim(rtrim(round(n, 2)::text, '0'), '.') END)
$$;

-- Persian/Arabic digits -> English digits (for parsing user input)
CREATE OR REPLACE FUNCTION en_digits(t text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT translate(coalesce(t,''), '۰۱۲۳۴۵۶۷۸۹٠١٢٣٤٥٦٧٨٩٫', '01234567890123456789.')
$$;

-- Parse a user-typed number (Persian digits, comma/slash decimal). NULL if invalid.
CREATE OR REPLACE FUNCTION parse_num(t text) RETURNS numeric LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE s text := btrim(replace(replace(en_digits(t), ',', '.'), '/', '.'));
BEGIN
  IF s ~ '^\d{1,6}(\.\d{1,3})?$' THEN RETURN s::numeric; END IF;
  RETURN NULL;
END $$;

-- Gregorian timestamptz -> Jalali string 'YYYY/MM/DD HH:MI' (Tehran time, Persian digits)
CREATE OR REPLACE FUNCTION jalali(ts timestamptz, with_time boolean DEFAULT true) RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE
  lt timestamp := ts AT TIME ZONE 'Asia/Tehran';
  gy int := extract(year FROM lt); gm int := extract(month FROM lt); gd int := extract(day FROM lt);
  gdm int[] := ARRAY[0,31,59,90,120,151,181,212,243,273,304,334];
  gy2 int; days int; jy int; jm int; jd int;
BEGIN
  IF ts IS NULL THEN RETURN '-'; END IF;
  gy2 := CASE WHEN gm > 2 THEN gy + 1 ELSE gy END;
  days := 355666 + 365*gy + div(gy2+3,4) - div(gy2+99,100) + div(gy2+399,400) + gd + gdm[gm];
  jy := -1595 + 33 * div(days, 12053); days := mod(days, 12053);
  jy := jy + 4 * div(days, 1461);      days := mod(days, 1461);
  IF days > 365 THEN jy := jy + div(days-1, 365); days := mod(days-1, 365); END IF;
  IF days < 186 THEN jm := 1 + div(days, 31); jd := 1 + mod(days, 31);
  ELSE jm := 7 + div(days-186, 30); jd := 1 + mod(days-186, 30); END IF;
  RETURN fa(format('%s/%s/%s', jy, lpad(jm::text,2,'0'), lpad(jd::text,2,'0'))
            || CASE WHEN with_time THEN ' ساعت ' || to_char(lt, 'HH24:MI') ELSE '' END);
END $$;

-- Human remaining time: "۲ روز و ۵ ساعت"
CREATE OR REPLACE FUNCTION remain_text(deadline timestamptz) RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE secs bigint := extract(epoch FROM deadline - now())::bigint; d int; hh int; mi int;
BEGIN
  IF secs <= 0 THEN RETURN 'مهلت تمام شده'; END IF;
  d := secs / 86400; hh := (secs % 86400) / 3600; mi := (secs % 3600) / 60;
  IF d > 0 THEN RETURN fa(d::text) || ' روز' || CASE WHEN hh > 0 THEN ' و ' || fa(hh::text) || ' ساعت' ELSE '' END; END IF;
  IF hh > 0 THEN RETURN fa(hh::text) || ' ساعت' || CASE WHEN mi > 0 THEN ' و ' || fa(mi::text) || ' دقیقه' ELSE '' END; END IF;
  RETURN fa(greatest(mi,1)::text) || ' دقیقه';
END $$;

-- Duration in hours -> Persian label
CREATE OR REPLACE FUNCTION hours_label(hrs numeric) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN hrs >= 24 AND mod(hrs, 168) = 0 THEN fa((hrs/168)::numeric) || ' هفته'
              WHEN hrs >= 24 THEN fa(round(hrs/24, 1)) || ' روز'
              ELSE fa(hrs) || ' ساعت' END
$$;

CREATE OR REPLACE FUNCTION status_label(s text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE s WHEN 'draft' THEN '📝 پیش‌نویس (ارسال نشده)'
                WHEN 'pending' THEN '⏳ در صف نمره‌دهی'
                WHEN 'grading' THEN '🤖 در حال نمره‌دهی'
                WHEN 'graded' THEN '🟡 نمره‌دهی شد (منتظر تأیید استاد)'
                WHEN 'released' THEN '✅ نمره اعلام شد'
                WHEN 'failed' THEN '⚠️ خطا در نمره‌دهی خودکار'
                ELSE '❌ ارسال نشده' END
$$;

CREATE OR REPLACE FUNCTION trunc_text(t text, n int) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN length(coalesce(t,'')) > n THEN left(t, n) || '…' ELSE coalesce(t,'') END
$$;

CREATE OR REPLACE FUNCTION setting(k text) RETURNS text LANGUAGE sql STABLE AS $$
  SELECT value FROM settings WHERE key = k
$$;

-- ----------------------------------------------------------------------
--  Telegram action builders. Every action = {"method": "...", "payload": {...}}
--  n8n posts payload to https://api.telegram.org/bot<TOKEN>/<method>
--  Internal actions start with "_" (e.g. _excel) and are handled inside n8n.
-- ----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION btn(label text, data text) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object('text', label, 'callback_data', data)
$$;
CREATE OR REPLACE FUNCTION url_btn(label text, url text) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object('text', label, 'url', url)
$$;
CREATE OR REPLACE FUNCTION act(method text, payload jsonb) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object('method', method, 'payload', payload)
$$;

-- Send a new message, or edit the message the user clicked on (mid not null)
CREATE OR REPLACE FUNCTION show(chat bigint, mid bigint, txt text, kb jsonb DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE p jsonb;
BEGIN
  IF length(txt) > 4000 THEN txt := left(txt, 3990) || E'\n…'; END IF;
  p := jsonb_build_object('chat_id', chat, 'text', txt, 'parse_mode', 'HTML',
                          'disable_web_page_preview', true);
  IF kb IS NOT NULL AND jsonb_array_length(kb) > 0 THEN
    p := p || jsonb_build_object('reply_markup', jsonb_build_object('inline_keyboard', kb));
  END IF;
  IF mid IS NULL THEN RETURN act('sendMessage', p); END IF;
  RETURN act('editMessageText', p || jsonb_build_object('message_id', mid));
END $$;

CREATE OR REPLACE FUNCTION send(chat bigint, txt text, kb jsonb DEFAULT NULL) RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$ SELECT show(chat, NULL, txt, kb) $$;

-- Random readable join code (no 0/O/1/I)
CREATE OR REPLACE FUNCTION new_join_code() RETURNS text LANGUAGE plpgsql VOLATILE AS $$
DECLARE alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; c text;
BEGIN
  LOOP
    c := '';
    FOR i IN 1..6 LOOP c := c || substr(alphabet, 1 + floor(random()*length(alphabet))::int, 1); END LOOP;
    EXIT WHEN NOT EXISTS (SELECT 1 FROM classes WHERE join_code = c);
  END LOOP;
  RETURN c;
END $$;

-- ----------------------------------------------------------------------
--  Checklist parser
--  Format (Persian or English digits):
--     نمره کل: 20
--     - [6] عنوان معیار
--       توضیح اضافه برای همین معیار (اختیاری)
--     - [4] معیار بعدی
--     قوانین:
--     - قانون/کسر نمره
--     پاسخ نمونه:
--     متن پاسخ صحیح (اختیاری)
-- ----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION parse_checklist(raw text) RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  line text; l text; m text[];
  mode text := 'criteria';
  crit jsonb := '[]'; rules jsonb := '[]'; ref text := '';
  total numeric := NULL; sum_pts numeric := 0; n int := 0; last_idx int;
BEGIN
  IF raw IS NULL OR btrim(raw) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'چک‌لیست خالی است.');
  END IF;
  FOREACH line IN ARRAY regexp_split_to_array(raw, E'\r?\n') LOOP
    l := btrim(en_digits(line));
    IF l = '' THEN
      IF mode = 'reference' THEN ref := ref || E'\n'; END IF;
      CONTINUE;
    END IF;

    IF mode <> 'reference' THEN
      m := regexp_match(l, '^(نمره\s*کل|بارم\s*کل|total)\s*[:：=]\s*(\d+(?:[.,/]\d+)?)', 'i');
      IF m IS NOT NULL THEN total := parse_num(m[2]); CONTINUE; END IF;

      IF l ~* '^(معیارها|معیار ها|چک ?لیست|criteria)\s*[:：]?\s*$' THEN mode := 'criteria'; CONTINUE; END IF;
      IF l ~* '^(قوانین|قواعد|نکات|کسر نمره|rules)\s*[:：]' THEN
        mode := 'rules';
        l := btrim(regexp_replace(l, '^[^:：]*[:：]', ''));
        IF l = '' THEN CONTINUE; END IF;
      ELSIF l ~* '^(پاسخ ?نامه|پاسخ صحیح|پاسخ نمونه|پاسخ|کلید|جواب|answer|reference)[^:：]{0,15}[:：]' THEN
        mode := 'reference';
        ref := btrim(regexp_replace(line, '^[^:：]*[:：]', ''));
        CONTINUE;
      END IF;
    END IF;

    IF mode = 'reference' THEN
      ref := ref || CASE WHEN ref = '' THEN '' ELSE E'\n' END || line;
    ELSIF mode = 'rules' THEN
      rules := rules || to_jsonb(btrim(regexp_replace(l, '^[-*•–]\s*', '')));
    ELSE
      m := regexp_match(l, '^[-*•–]?\s*(?:\d+\s*[.)-]\s*)?[\[(（]\s*(\d+(?:[.,/]\d+)?)\s*(?:نمره)?\s*[\])）]\s*[-:–]?\s*(.+)$');
      IF m IS NOT NULL AND parse_num(m[1]) IS NOT NULL AND parse_num(m[1]) > 0 THEN
        n := n + 1;
        IF n > 25 THEN RETURN jsonb_build_object('ok', false, 'error', 'حداکثر ۲۵ معیار مجاز است.'); END IF;
        crit := crit || jsonb_build_array(jsonb_build_object(
                  'id', n, 'title', btrim(m[2]), 'points', parse_num(m[1]), 'detail', ''));
        sum_pts := sum_pts + parse_num(m[1]);
      ELSIF n > 0 THEN
        last_idx := n - 1;   -- extra line = detail for previous criterion
        crit := jsonb_set(crit, ARRAY[last_idx::text, 'detail'],
                  to_jsonb(btrim(coalesce(crit->last_idx->>'detail','') || ' ' || regexp_replace(l, '^[-*•–]\s*', ''))));
      ELSE
        RETURN jsonb_build_object('ok', false, 'error',
          format('این خط قابل تشخیص نیست: «%s». هر معیار باید با بارم داخل کروشه شروع شود، مثل: - [5] عنوان معیار', left(l, 60)));
      END IF;
    END IF;
  END LOOP;

  IF n = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'هیچ معیاری پیدا نشد. هر معیار را به شکل «- [بارم] عنوان» بنویسید.');
  END IF;
  IF total IS NULL OR total <= 0 THEN total := sum_pts; END IF;
  RETURN jsonb_build_object('ok', true, 'total', total, 'criteria_sum', sum_pts,
                            'criteria', crit, 'rules', rules, 'reference', btrim(ref));
END $$;

CREATE OR REPLACE FUNCTION checklist_text(c jsonb) RETURNS text LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE r text := ''; e jsonb;
BEGIN
  FOR e IN SELECT * FROM jsonb_array_elements(c->'criteria') LOOP
    r := r || '▫️ ' || h(e->>'title') || ' — <b>' || fa((e->>'points')::numeric) || '</b>' ||
         CASE WHEN coalesce(e->>'detail','') <> '' THEN E'\n    <i>' || h(e->>'detail') || '</i>' ELSE '' END || E'\n';
  END LOOP;
  IF jsonb_array_length(coalesce(c->'rules','[]')) > 0 THEN
    r := r || E'\n<b>قوانین:</b>\n';
    FOR e IN SELECT * FROM jsonb_array_elements(c->'rules') LOOP r := r || '• ' || h(e #>> '{}') || E'\n'; END LOOP;
  END IF;
  IF coalesce(c->>'reference','') <> '' THEN r := r || E'\n<b>پاسخ نمونه:</b> دارد (' || fa(length(c->>'reference')::text) || ' کاراکتر)'; END IF;
  r := r || E'\n<b>نمره کل:</b> ' || fa((c->>'total')::numeric);
  IF (c->>'total')::numeric <> (c->>'criteria_sum')::numeric THEN
    r := r || ' <i>(جمع بارم‌ها ' || fa((c->>'criteria_sum')::numeric) || ' است و به نمره کل تبدیل می‌شود)</i>';
  END IF;
  RETURN r;
END $$;

CREATE OR REPLACE FUNCTION checklist_sample() RETURNS text LANGUAGE sql IMMUTABLE AS $$
SELECT 'نمره کل: 20
- [4] تعریف درست مسئله، ورودی‌ها و خروجی‌ها
  اگر ورودی یا خروجی ناقص بود نصف نمره
- [8] الگوریتم/کد صحیح که برای ورودی‌های نمونه جواب درست می‌دهد
- [4] تحلیل پیچیدگی زمانی و حافظه
- [2] خوانایی کد، نام‌گذاری و کامنت مناسب
- [2] گزارش کوتاه و مرتب
قوانین:
- اگر پاسخ کاملاً بی‌ربط به سؤال بود، نمره صفر
- اگر پاسخ ظاهراً کپی از منبع آماده است، برای بررسی استاد علامت بزن
- غلط املایی نمره کم نمی‌کند
پاسخ نمونه:
الگوریتم باید با یک حلقه آرایه را پیمایش کند و بیشینه را نگه دارد؛ پیچیدگی O(n) و حافظه O(1).'
$$;
