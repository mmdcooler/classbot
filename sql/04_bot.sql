-- =====================================================================
--  Bot logic: bot_handle(update) -> jsonb array of actions
-- =====================================================================

-- Classify an uploaded document by extension / mime. NULL = not supported.
CREATE OR REPLACE FUNCTION file_kind(fname text, mime text) RETURNS text LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE ext text := lower(substring(coalesce(fname,'') FROM '\.([A-Za-z0-9]+)$'));
BEGIN
  IF ext = 'pdf' OR mime = 'application/pdf' THEN RETURN 'pdf'; END IF;
  IF ext = 'docx' THEN RETURN 'docx'; END IF;
  IF ext IN ('png','jpg','jpeg','webp') OR mime IN ('image/png','image/jpeg','image/webp') THEN RETURN 'image'; END IF;
  IF ext IN ('txt','md','py','c','cpp','cc','h','hpp','java','js','ts','jsx','tsx','cs','go','rs','php','rb','kt',
             'swift','sql','html','css','json','xml','ipynb','m','r','sh','csv','asm','pl','scala','dart','lua','v','vhd','yaml','yml')
     OR mime LIKE 'text/%' THEN RETURN 'text'; END IF;
  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION do_join(u users, chat bigint, code text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE c classes;
BEGIN
  SELECT * INTO c FROM classes WHERE join_code = upper(btrim(en_digits(code))) AND NOT archived;
  IF c.id IS NULL THEN
    RETURN jsonb_build_array(send(chat, '❌ کلاسی با این کد پیدا نشد. کد را دوباره بررسی کنید یا /cancel را بزنید.'));
  END IF;
  PERFORM set_state(u.id, NULL);
  IF c.teacher_id = u.id THEN
    RETURN jsonb_build_array(send(chat, 'ℹ️ شما استاد این کلاس هستید.', back_kb('tc:' || c.id, '🏫 رفتن به کلاس')));
  END IF;
  INSERT INTO enrollments(class_id, student_id) VALUES (c.id, u.id) ON CONFLICT DO NOTHING;
  RETURN jsonb_build_array(send(chat, '✅ عضو کلاس <b>' || h(c.name) || '</b> شدی.',
           jsonb_build_array(jsonb_build_array(btn('📚 تکالیف این کلاس', 'sc:' || c.id)), jsonb_build_array(btn('🏠 منو', 'm')))));
END $$;

-- Notify all students of a newly published assignment
CREATE OR REPLACE FUNCTION notify_new_asg(aid int) RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE a assignments; c classes; acts jsonb := '[]'; r record;
BEGIN
  SELECT * INTO a FROM assignments WHERE id = aid;
  SELECT * INTO c FROM classes WHERE id = a.class_id;
  FOR r IN SELECT u.chat_id FROM enrollments e JOIN users u ON u.id = e.student_id WHERE e.class_id = c.id LOOP
    acts := acts || jsonb_build_array(send(r.chat_id,
      '📢 <b>تکلیف جدید</b> در کلاس ' || h(c.name) || E'\n\n📝 جلسه ' || fa(a.session_no::text) || ': ' || h(a.title) ||
      E'\n⏰ مهلت: ' || jalali(a.deadline) || ' (' || remain_text(a.deadline) || ')',
      back_kb('sa:' || a.id, '👀 مشاهده و ارسال')));
  END LOOP;
  RETURN acts;
END $$;

-- Student-facing release message
CREATE OR REPLACE FUNCTION release_msg(sid int, updated boolean DEFAULT false) RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE u users;
BEGIN
  SELECT us.* INTO u FROM submissions s JOIN users us ON us.id = s.student_id WHERE s.id = sid;
  RETURN send(u.chat_id,
    CASE WHEN updated THEN E'✏️ <b>نمره شما توسط استاد اصلاح شد</b>\n\n' ELSE E'🎉 <b>نتیجه تکلیف شما اعلام شد</b>\n\n' END ||
    sub_result_text(sid, false), back_kb('m', '🏠 منو'));
END $$;

CREATE OR REPLACE FUNCTION release_sub(sid int) RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
  UPDATE submissions SET status = 'released', released_at = now(),
         final_score = coalesce(final_score, ai_score)
   WHERE id = sid AND status = 'graded';
  IF NOT FOUND THEN RETURN '[]'; END IF;
  RETURN jsonb_build_array(release_msg(sid));
END $$;

-- ---------------------------------------------------------------- text / file messages
CREATE OR REPLACE FUNCTION on_message(u users, chat bigint, msg jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  txt text := btrim(coalesce(msg->>'text', ''));
  cap text := btrim(coalesce(msg->>'caption', ''));
  payload text; d jsonb := u.state_data; c classes; a assignments; s submissions; x numeric; cl jsonb;
  doc jsonb := msg->'document'; ph jsonb := msg->'photo'; fk text; np int; aid int; k text;
BEGIN
  -- ---------- commands (always available)
  IF txt ~ '^/start' THEN
    payload := btrim(substring(txt FROM '^/start(?:@\w+)?\s*(.*)$'));
    PERFORM set_state(u.id, NULL);
    IF u.full_name IS NULL THEN
      PERFORM set_state(u.id, 'reg_name', CASE WHEN payload LIKE 'join\_%' THEN jsonb_build_object('join', substr(payload, 6)) ELSE '{}' END);
      RETURN jsonb_build_array(send(chat, E'سلام! 👋 به ربات تکالیف کلاس خوش اومدی.\n\nبرای شروع، <b>نام و نام خانوادگی</b> خودت رو بفرست:'));
    END IF;
    IF payload LIKE 'join\_%' THEN RETURN do_join(u, chat, substr(payload, 6)); END IF;
    RETURN jsonb_build_array(scr_main(u, chat, NULL));
  END IF;

  IF txt = '/myid' THEN
    RETURN jsonb_build_array(send(chat, 'شناسه عددی تلگرام شما: <code>' || u.id || '</code>'));
  END IF;

  IF u.full_name IS NULL AND coalesce(u.state,'') NOT IN ('reg_name','reg_stno') THEN
    PERFORM set_state(u.id, 'reg_name');
    RETURN jsonb_build_array(send(chat, 'برای شروع، <b>نام و نام خانوادگی</b> خودت رو بفرست:'));
  END IF;

  IF txt IN ('/menu', '/cancel') THEN
    -- leave an unfinished submission as draft; just exit the mode
    PERFORM set_state(u.id, NULL);
    RETURN jsonb_build_array(send(chat, CASE WHEN txt = '/cancel' THEN '❎ عملیات لغو شد.' ELSE '🏠' END))
           || jsonb_build_array(scr_main(u, chat, NULL));
  END IF;

  IF txt = '/help' THEN
    RETURN jsonb_build_array(send(chat, E'ℹ️ <b>راهنما</b>\n\n' ||
      E'🎓 دانشجو: با کد کلاس عضو شو، تکلیف هر جلسه رو باز کن و پاسخت رو (متن، PDF، Word، عکس یا فایل کد) بفرست و «ارسال نهایی» رو بزن. نمره و بازخورد همین‌جا برات میاد.\n\n' ||
      E'👨‍🏫 استاد: کلاس بساز، کد عضویت رو به دانشجوها بده، برای هر جلسه تکلیف + مهلت + چک‌لیست نمره‌دهی تعریف کن. هوش مصنوعی طبق چک‌لیست نمره می‌ده و گزارش کامل و اکسل می‌گیری.\n\n' ||
      E'/menu منوی اصلی\n/cancel لغو عملیات\n/myid شناسه شما'));
  END IF;

  IF txt = '/admin' AND u.is_admin THEN RETURN jsonb_build_array(scr_admin(chat, NULL)); END IF;

  IF txt ~ '^/setmodel\s' AND u.is_admin THEN
    payload := btrim(substring(txt FROM '^/setmodel\s+(.*)$'));
    IF payload ~ '^[A-Za-z0-9._:/-]+(\s+[A-Za-z0-9._:/-]+)?$' THEN
      UPDATE settings SET value = split_part(payload, ' ', 1) WHERE key = 'ai_model';
      IF split_part(payload, ' ', 2) <> '' THEN UPDATE settings SET value = split_part(payload, ' ', 2) WHERE key = 'ai_fallback_model'; END IF;
      RETURN jsonb_build_array(send(chat, '✅ مدل AI: <code>' || h(setting('ai_model')) || '</code> | پشتیبان: <code>' || h(setting('ai_fallback_model')) || '</code>'));
    END IF;
    RETURN jsonb_build_array(send(chat, 'فرمت: <code>/setmodel provider/model [fallback/model]</code>'));
  END IF;

  -- ---------- state machine
  CASE coalesce(u.state, '')

  WHEN 'reg_name' THEN
    IF char_length(txt) < 3 OR char_length(txt) > 60 OR txt LIKE '/%' THEN
      RETURN jsonb_build_array(send(chat, 'لطفاً نام و نام خانوادگی کامل رو (بین ۳ تا ۶۰ حرف) بفرست:'));
    END IF;
    UPDATE users SET full_name = txt, state = 'reg_stno' WHERE id = u.id;
    RETURN jsonb_build_array(send(chat, E'خوشبختم <b>' || h(txt) || E'</b> 🌱\n\nحالا <b>شماره دانشجویی</b>ت رو بفرست.\n(اگه استادی یا شماره دانشجویی نداری، دکمه زیر رو بزن)',
             back_kb('rsk', '⏭ رد کردن')));

  WHEN 'reg_stno' THEN
    txt := en_digits(txt);
    IF txt !~ '^[A-Za-z0-9-]{3,20}$' THEN
      RETURN jsonb_build_array(send(chat, 'شماره دانشجویی معتبر نیست (فقط عدد/حروف لاتین، ۳ تا ۲۰ کاراکتر). دوباره بفرست یا رد کن:', back_kb('rsk', '⏭ رد کردن')));
    END IF;
    UPDATE users SET student_no = txt WHERE id = u.id;
    SELECT * INTO u FROM users WHERE id = u.id;
    PERFORM set_state(u.id, NULL);
    IF d ? 'join' THEN RETURN do_join(u, chat, d->>'join'); END IF;
    RETURN jsonb_build_array(send(chat, '✅ ثبت‌نام کامل شد.')) || jsonb_build_array(scr_main(u, chat, NULL));

  WHEN 'join_code' THEN
    IF txt = '' THEN RETURN jsonb_build_array(send(chat, 'کد کلاس رو به صورت متن بفرست:')); END IF;
    RETURN do_join(u, chat, regexp_replace(txt, '^.*join_', ''));

  WHEN 'new_class' THEN
    IF NOT is_teacher(u) THEN PERFORM set_state(u.id, NULL); RETURN '[]'; END IF;
    IF char_length(txt) < 2 OR char_length(txt) > 100 THEN
      RETURN jsonb_build_array(send(chat, 'نام کلاس باید بین ۲ تا ۱۰۰ حرف باشه. دوباره بفرست:'));
    END IF;
    INSERT INTO classes(teacher_id, name, join_code) VALUES (u.id, txt, new_join_code()) RETURNING * INTO c;
    PERFORM set_state(u.id, NULL);
    RETURN jsonb_build_array(send(chat, '✅ کلاس ساخته شد.'), scr_t_class(c, chat, NULL));

  WHEN 'asg' THEN
    IF NOT is_teacher(u) THEN PERFORM set_state(u.id, NULL); RETURN '[]'; END IF;
    k := d->>'step';
    IF k = 'session' THEN
      x := parse_num(txt);
      IF x IS NULL OR x <> trunc(x) OR x < 1 OR x > 200 THEN
        RETURN jsonb_build_array(send(chat, 'شماره جلسه باید یک عدد صحیح بین ۱ تا ۲۰۰ باشه:'));
      END IF;
      IF EXISTS (SELECT 1 FROM assignments WHERE class_id = (d->>'cid')::int AND session_no = x) THEN
        RETURN jsonb_build_array(send(chat, '⚠️ برای جلسه ' || fa(x) || ' قبلاً تکلیف تعریف شده. شماره دیگری بفرستید:'));
      END IF;
      d := d || jsonb_build_object('session', x::int, 'step', 'title');
    ELSIF k = 'title' THEN
      IF char_length(txt) < 2 OR char_length(txt) > 150 THEN
        RETURN jsonb_build_array(send(chat, 'عنوان باید بین ۲ تا ۱۵۰ حرف باشه:'));
      END IF;
      d := d || jsonb_build_object('title', txt, 'step', 'desc');
    ELSIF k = 'desc' THEN
      IF doc IS NOT NULL THEN
        d := d || jsonb_build_object('file_id', doc->>'file_id', 'file_kind', 'document',
                                     'file_name', doc->>'file_name', 'file_mime', doc->>'mime_type');
        txt := cap;
      ELSIF ph IS NOT NULL THEN
        d := d || jsonb_build_object('file_id', ph->(jsonb_array_length(ph)-1)->>'file_id', 'file_kind', 'photo',
                                     'file_name', 'question.jpg', 'file_mime', 'image/jpeg');
        txt := cap;
      ELSIF txt = '' THEN
        RETURN jsonb_build_array(send(chat, 'صورت تکلیف رو به صورت متن یا فایل بفرست:'));
      END IF;
      IF char_length(txt) > 3500 THEN
        RETURN jsonb_build_array(send(chat, 'متن طولانی‌تر از ۳۵۰۰ حرفه. کوتاه‌ترش کن یا به صورت فایل PDF بفرست.'));
      END IF;
      IF doc IS NOT NULL AND file_kind(doc->>'file_name', doc->>'mime_type') IS NULL THEN
        RETURN jsonb_build_array(send(chat, 'فرمت فایل پشتیبانی نمی‌شه. لطفاً PDF، Word (docx)، عکس یا فایل متنی بفرست.'));
      END IF;
      d := d || jsonb_build_object('desc', nullif(txt, ''), 'step', 'deadline');
    ELSIF k = 'deadline_custom' THEN
      x := parse_num(regexp_replace(txt, '\s*(ساعت|h|hour|hours)\s*$', '', 'i'));
      IF x IS NOT NULL AND txt !~* '(ساعت|h|hour)' THEN x := x * 24; END IF;
      IF x IS NULL OR x < 1 OR x > 24*90 THEN
        RETURN jsonb_build_array(send(chat, 'مهلت معتبر نیست (حداقل ۱ ساعت، حداکثر ۹۰ روز). مثال: <code>۴</code> یا <code>۱۲ ساعت</code>'));
      END IF;
      d := d || jsonb_build_object('hours', round(x, 2), 'step', 'checklist');
    ELSIF k = 'checklist' THEN
      IF doc IS NOT NULL OR ph IS NOT NULL THEN
        RETURN jsonb_build_array(send(chat, 'چک‌لیست رو به صورت <b>متن</b> بفرست (نه فایل).'));
      END IF;
      cl := parse_checklist(msg->>'text');
      IF NOT (cl->>'ok')::boolean THEN
        RETURN jsonb_build_array(send(chat, '⚠️ ' || h(cl->>'error') || E'\n\nدوباره بفرست یا نمونه را ببین:',
                 jsonb_build_array(jsonb_build_array(btn('📋 نمونه چک‌لیست', 'cs'), btn('❌ لغو', 'ac:n')))));
      END IF;
      d := d || jsonb_build_object('checklist_raw', msg->>'text', 'step', 'confirm');
    ELSE
      RETURN jsonb_build_array(send(chat, 'از دکمه‌های پیام قبل استفاده کنید یا /cancel را بزنید.'));
    END IF;
    PERFORM set_state(u.id, 'asg', d);
    SELECT * INTO u FROM users WHERE id = u.id;
    RETURN jsonb_build_array(scr_asg_step(u, chat, NULL));

  WHEN 'sub' THEN
    SELECT * INTO s FROM submissions WHERE id = (d->>'sid')::int AND student_id = u.id;
    SELECT * INTO a FROM assignments WHERE id = s.assignment_id;
    IF s.id IS NULL OR s.status <> 'draft' THEN PERFORM set_state(u.id, NULL); RETURN jsonb_build_array(scr_main(u, chat, NULL)); END IF;
    IF a.status <> 'open' OR a.deadline <= now() THEN
      PERFORM set_state(u.id, NULL);
      RETURN jsonb_build_array(send(chat, '⛔️ مهلت این تکلیف تمام شده و دیگر امکان ارسال نیست.', back_kb('m', '🏠 منو')));
    END IF;
    SELECT count(*) INTO np FROM submission_parts WHERE submission_id = s.id;
    IF np >= setting('max_parts')::int THEN
      RETURN jsonb_build_array(send(chat, '⚠️ حداکثر ' || fa(setting('max_parts')) || ' بخش مجازه. «ارسال نهایی» رو بزن.',
               jsonb_build_array(jsonb_build_array(btn('✅ ارسال نهایی', 'sf'), btn('🗑 پاک کردن و شروع دوباره', 'sx')))));
    END IF;
    IF doc IS NOT NULL THEN
      fk := file_kind(doc->>'file_name', doc->>'mime_type');
      IF fk IS NULL THEN
        RETURN jsonb_build_array(send(chat, E'❌ این فرمت پشتیبانی نمی‌شه.\nفرمت‌های مجاز: PDF، Word (docx)، عکس (jpg/png)، فایل‌های متنی و کد (py, cpp, java, …).\nاگر فایل .doc قدیمیه، اون رو PDF یا docx کن.'));
      END IF;
      IF coalesce((doc->>'file_size')::bigint, 0) > setting('max_file_mb')::bigint * 1024 * 1024 THEN
        RETURN jsonb_build_array(send(chat, '❌ حجم فایل بیشتر از ' || fa(setting('max_file_mb')) || ' مگابایته. فشرده‌ترش کن یا چند تکه بفرست.'));
      END IF;
      INSERT INTO submission_parts(submission_id, kind, file_id, file_name, mime, file_size)
      VALUES (s.id, 'document', doc->>'file_id', doc->>'file_name', doc->>'mime_type', (doc->>'file_size')::bigint);
      np := np + 1;
    ELSIF ph IS NOT NULL THEN
      INSERT INTO submission_parts(submission_id, kind, file_id, file_name, mime, file_size)
      VALUES (s.id, 'photo', ph->(jsonb_array_length(ph)-1)->>'file_id', 'photo.jpg', 'image/jpeg',
              (ph->(jsonb_array_length(ph)-1)->>'file_size')::bigint);
      np := np + 1;
    END IF;
    IF (doc IS NOT NULL OR ph IS NOT NULL) AND cap <> '' THEN
      INSERT INTO submission_parts(submission_id, kind, text) VALUES (s.id, 'text', cap);
    ELSIF doc IS NULL AND ph IS NULL THEN
      IF txt = '' THEN
        RETURN jsonb_build_array(send(chat, '❌ فقط متن، فایل یا عکس قابل ارسال است (ویس/ویدیو پشتیبانی نمی‌شود).'));
      END IF;
      INSERT INTO submission_parts(submission_id, kind, text) VALUES (s.id, 'text', msg->>'text');
      np := np + 1;
    END IF;
    RETURN jsonb_build_array(send(chat, '📥 دریافت شد (' || fa(np::text) || E' بخش).\nاگه بخش دیگه‌ای هم داری بفرست؛ وقتی تموم شد «ارسال نهایی» رو بزن.',
             jsonb_build_array(jsonb_build_array(btn('✅ ارسال نهایی', 'sf')),
                               jsonb_build_array(btn('🗑 پاک کردن و شروع دوباره', 'sx'), btn('⏸ بعداً', 'sp')))));

  WHEN 'edit_score' THEN
    SELECT s2.* INTO s FROM submissions s2 JOIN assignments a2 ON a2.id = s2.assignment_id
      JOIN classes c2 ON c2.id = a2.class_id WHERE s2.id = (d->>'sid')::int AND c2.teacher_id = u.id;
    IF s.id IS NULL THEN PERFORM set_state(u.id, NULL); RETURN jsonb_build_array(scr_denied(chat, NULL)); END IF;
    SELECT * INTO a FROM assignments WHERE id = s.assignment_id;
    x := parse_num(txt);
    IF x IS NULL OR x < 0 OR x > a.total_score THEN
      RETURN jsonb_build_array(send(chat, 'نمره باید عددی بین ۰ و ' || fa(a.total_score) || ' باشه:', back_kb('tas:' || s.id, '❌ انصراف')));
    END IF;
    PERFORM set_state(u.id, NULL);
    UPDATE submissions SET final_score = x, teacher_edited = true,
           status = CASE WHEN status = 'failed' THEN 'graded' ELSE status END,
           graded_at = coalesce(graded_at, now())
     WHERE id = s.id;
    IF s.status = 'released' THEN
      RETURN jsonb_build_array(send(chat, '✅ نمره به ' || fa(x) || ' تغییر کرد و به دانشجو اطلاع داده شد.'),
                               release_msg(s.id, true), scr_t_sub(s.id, chat, NULL));
    END IF;
    RETURN jsonb_build_array(send(chat, '✅ نمره به ' || fa(x) || ' تغییر کرد. برای اعلام به دانشجو «تأیید» را بزنید.'),
                             scr_t_sub(s.id, chat, NULL));

  ELSE
    RETURN jsonb_build_array(scr_main(u, chat, NULL));
  END CASE;
END $$;

-- ---------------------------------------------------------------- button clicks
CREATE OR REPLACE FUNCTION on_callback(u users, chat bigint, mid bigint, data text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  cmd text := split_part(data, ':', 1);
  arg text := split_part(data, ':', 2);
  nid  int := CASE WHEN arg ~ '^\d{1,9}$' THEN arg::int END;
  c classes; a assignments; s submissions; tu users; d jsonb := u.state_data; acts jsonb := '[]'; r record; cl jsonb; aid int;
BEGIN
  IF u.full_name IS NULL THEN
    IF cmd = 'rsk' THEN NULL; ELSE
      PERFORM set_state(u.id, 'reg_name');
      RETURN jsonb_build_array(send(chat, 'برای شروع، <b>نام و نام خانوادگی</b> خودت رو بفرست:'));
    END IF;
  END IF;

  -- ===== teacher-only commands: load + verify ownership up front
  IF cmd IN ('tc','tn','tcs','tca','tcr','tcd','tcdy','an') AND (cmd <> 'tc' OR nid IS NOT NULL) AND cmd <> 'tn' THEN
    SELECT * INTO c FROM classes WHERE classes.id = nid AND teacher_id = u.id AND NOT archived;
    IF c.id IS NULL OR NOT is_teacher(u) THEN RETURN jsonb_build_array(scr_denied(chat, mid)); END IF;
  END IF;
  IF cmd IN ('ta','tsl','tar','tax','tak','tae','tal','taly','tarel') THEN
    SELECT a2.* INTO a FROM assignments a2 JOIN classes c2 ON c2.id = a2.class_id
     WHERE a2.id = nid AND c2.teacher_id = u.id;
    IF a.id IS NULL OR NOT is_teacher(u) THEN RETURN jsonb_build_array(scr_denied(chat, mid)); END IF;
  END IF;
  IF cmd IN ('tas','tasf','sap','sed','srg') THEN
    SELECT s2.* INTO s FROM submissions s2 JOIN assignments a2 ON a2.id = s2.assignment_id
      JOIN classes c2 ON c2.id = a2.class_id WHERE s2.id = nid AND c2.teacher_id = u.id;
    IF s.id IS NULL OR NOT is_teacher(u) THEN RETURN jsonb_build_array(scr_denied(chat, mid)); END IF;
  END IF;
  IF cmd IN ('ad','ap','ar') AND NOT u.is_admin THEN RETURN jsonb_build_array(scr_denied(chat, mid)); END IF;

  CASE cmd
  -- ---------------- general
  WHEN 'm' THEN
    PERFORM set_state(u.id, NULL);
    RETURN jsonb_build_array(scr_main(u, chat, mid));

  WHEN 'rsk' THEN
    IF u.state <> 'reg_stno' THEN RETURN jsonb_build_array(scr_main(u, chat, mid)); END IF;
    PERFORM set_state(u.id, NULL);
    IF d ? 'join' THEN RETURN do_join(u, chat, d->>'join'); END IF;
    RETURN jsonb_build_array(scr_main(u, chat, mid));

  -- ---------------- admin
  WHEN 'ad' THEN RETURN jsonb_build_array(scr_admin(chat, mid));
  WHEN 'ap', 'ar' THEN
    SELECT * INTO tu FROM users WHERE users.id = arg::bigint;
    IF tu.id IS NULL OR tu.teacher_status IS DISTINCT FROM 'pending' THEN RETURN jsonb_build_array(scr_admin(chat, mid)); END IF;
    UPDATE users SET teacher_status = CASE WHEN cmd = 'ap' THEN 'approved' ELSE 'rejected' END WHERE users.id = tu.id
      RETURNING * INTO tu;
    RETURN jsonb_build_array(
      scr_admin(chat, mid),
      send(tu.chat_id, CASE WHEN cmd = 'ap' THEN '🎉 حساب استادی شما تأیید شد! حالا می‌تونید کلاس بسازید.'
                            ELSE '❌ درخواست حساب استادی شما رد شد. برای پیگیری با مدیر تماس بگیرید.' END,
           back_kb('m', '🏠 منوی اصلی')));

  WHEN 'treq' THEN
    IF u.teacher_status = 'approved' THEN RETURN jsonb_build_array(scr_main(u, chat, mid)); END IF;
    IF u.teacher_status = 'pending' THEN
      RETURN jsonb_build_array(show(chat, mid, '⏳ درخواست شما قبلاً ثبت شده و در انتظار تأیید است.', back_kb('m')));
    END IF;
    UPDATE users SET teacher_status = 'pending' WHERE users.id = u.id;
    FOR r IN SELECT chat_id FROM users WHERE is_admin LOOP
      acts := acts || jsonb_build_array(send(r.chat_id,
        E'👨‍🏫 <b>درخواست حساب استاد</b>\n\n👤 ' || h(u.full_name) || coalesce(E'\n🆔 @' || h(u.username), '') || E'\n🔢 ' || u.id,
        jsonb_build_array(jsonb_build_array(btn('✅ تأیید', 'ap:' || u.id), btn('❌ رد', 'ar:' || u.id)))));
    END LOOP;
    IF jsonb_array_length(acts) = 0 THEN
      RAISE WARNING 'No admin configured: run SELECT make_admin(<telegram_id>)';
    END IF;
    RETURN jsonb_build_array(show(chat, mid, '✅ درخواست شما برای مدیر ارسال شد. بعد از تأیید، به شما اطلاع داده می‌شود.', back_kb('m'))) || acts;

  -- ---------------- teacher: classes
  WHEN 'tc' THEN
    IF NOT is_teacher(u) THEN RETURN jsonb_build_array(scr_denied(chat, mid)); END IF;
    IF nid IS NULL THEN RETURN jsonb_build_array(scr_t_classes(u, chat, mid)); END IF;
    RETURN jsonb_build_array(scr_t_class(c, chat, mid));
  WHEN 'tn' THEN
    IF NOT is_teacher(u) THEN RETURN jsonb_build_array(scr_denied(chat, mid)); END IF;
    PERFORM set_state(u.id, 'new_class');
    RETURN jsonb_build_array(show(chat, mid, E'➕ <b>کلاس جدید</b>\n\nنام کلاس را بفرستید (مثلاً: <i>ساختمان داده — گروه ۲ — نیم‌سال ۰۵۱</i>):', back_kb('tc', '❌ لغو')));
  WHEN 'tcs' THEN RETURN jsonb_build_array(scr_t_students(c, chat, mid));
  WHEN 'tca' THEN RETURN jsonb_build_array(scr_t_asg_list(c, chat, mid));
  WHEN 'tcr' THEN
    UPDATE classes SET auto_release = NOT auto_release WHERE classes.id = c.id RETURNING * INTO c;
    RETURN jsonb_build_array(scr_t_class(c, chat, mid));
  WHEN 'tcd' THEN
    RETURN jsonb_build_array(show(chat, mid, '🗄 کلاس <b>' || h(c.name) || E'</b> بایگانی شود؟\nدانشجوها دیگر آن را نمی‌بینند و کد عضویت غیرفعال می‌شود. اطلاعات و نمره‌ها حذف نمی‌شوند.',
      jsonb_build_array(jsonb_build_array(btn('✅ بله، بایگانی کن', 'tcdy:' || c.id), btn('❌ نه', 'tc:' || c.id)))));
  WHEN 'tcdy' THEN
    UPDATE classes SET archived = true WHERE classes.id = c.id;
    RETURN jsonb_build_array(scr_t_classes(u, chat, mid));

  -- ---------------- teacher: assignment wizard
  WHEN 'an' THEN
    PERFORM set_state(u.id, 'asg', jsonb_build_object('cid', c.id, 'step', 'session'));
    SELECT * INTO u FROM users WHERE users.id = u.id;
    RETURN jsonb_build_array(scr_asg_step(u, chat, mid));
  WHEN 'asn' THEN
    IF u.state <> 'asg' OR d->>'step' <> 'session' OR nid IS NULL THEN RETURN jsonb_build_array(scr_main(u, chat, mid)); END IF;
    IF EXISTS (SELECT 1 FROM assignments WHERE class_id = (d->>'cid')::int AND session_no = nid) THEN
      RETURN jsonb_build_array(send(chat, '⚠️ برای این جلسه قبلاً تکلیف تعریف شده. شماره دیگری بفرستید.'));
    END IF;
    d := d || jsonb_build_object('session', nid, 'step', 'title');
  WHEN 'dl' THEN
    IF u.state <> 'asg' OR d->>'step' NOT IN ('deadline','deadline_custom') THEN RETURN jsonb_build_array(scr_main(u, chat, mid)); END IF;
    IF arg = 'c' THEN d := d || jsonb_build_object('step', 'deadline_custom');
    ELSIF nid IS NOT NULL AND nid BETWEEN 1 AND 24*90 THEN d := d || jsonb_build_object('hours', nid, 'step', 'checklist');
    ELSE RETURN '[]'; END IF;
  WHEN 'cs' THEN
    RETURN jsonb_build_array(send(chat, E'📋 <b>نمونه چک‌لیست</b> — متن زیر را کپی کنید، تغییر دهید و بفرستید:\n\n<pre>' || h(checklist_sample()) || '</pre>' ||
      E'\n\n🔹 <b>[عدد]</b> = بارم هر معیار؛ خط بعد از معیار = توضیح همان معیار\n🔹 <b>نمره کل</b> اختیاری است (اگر با جمع بارم‌ها فرق کند، به آن تبدیل می‌شود)\n🔹 <b>قوانین</b> و <b>پاسخ نمونه</b> اختیاری‌اند و دقت نمره‌دهی را بالا می‌برند'));
  WHEN 'ac' THEN
    IF u.state <> 'asg' THEN RETURN jsonb_build_array(scr_main(u, chat, mid)); END IF;
    IF arg = 'n' THEN
      PERFORM set_state(u.id, NULL);
      RETURN jsonb_build_array(show(chat, mid, '❎ ساخت تکلیف لغو شد.', back_kb('tc:' || (d->>'cid'), '🔙 کلاس')));
    ELSIF arg = 'k' AND d->>'step' = 'confirm' THEN
      d := d || jsonb_build_object('step', 'checklist');
    ELSIF arg = 'y' AND d->>'step' = 'confirm' THEN
      SELECT * INTO c FROM classes WHERE classes.id = (d->>'cid')::int AND teacher_id = u.id AND NOT archived;
      IF c.id IS NULL THEN PERFORM set_state(u.id, NULL); RETURN jsonb_build_array(scr_denied(chat, mid)); END IF;
      IF EXISTS (SELECT 1 FROM assignments WHERE class_id = c.id AND session_no = (d->>'session')::int) THEN
        d := d || jsonb_build_object('step', 'session');
        PERFORM set_state(u.id, 'asg', d);
        RETURN jsonb_build_array(send(chat, '⚠️ در این فاصله برای این جلسه تکلیف ثبت شده. شماره جلسه دیگری بفرستید:'));
      END IF;
      cl := parse_checklist(d->>'checklist_raw');
      INSERT INTO assignments(class_id, session_no, title, description, attach_file_id, attach_kind,
                              checklist_raw, checklist, total_score, deadline)
      VALUES (c.id, (d->>'session')::int, d->>'title', d->>'desc', d->>'file_id', d->>'file_kind',
              d->>'checklist_raw', cl || jsonb_build_object('file_name', d->>'file_name', 'file_mime', d->>'file_mime'),
              (cl->>'total')::numeric, now() + make_interval(secs => (d->>'hours')::numeric * 3600))
      RETURNING * INTO a;
      PERFORM set_state(u.id, NULL);
      acts := notify_new_asg(a.id);
      RETURN jsonb_build_array(show(chat, mid, '✅ تکلیف منتشر شد و برای ' || fa(jsonb_array_length(acts)::text) || ' دانشجو اعلان رفت.', NULL),
                               scr_t_asg(a, chat, NULL)) || acts;
    ELSE
      RETURN '[]';
    END IF;

  -- ---------------- teacher: assignment management
  WHEN 'ta'  THEN RETURN jsonb_build_array(scr_t_asg(a, chat, mid));
  WHEN 'tsl' THEN RETURN jsonb_build_array(scr_t_sub_list(a, chat, mid));
  WHEN 'tar' THEN
    RETURN jsonb_build_array(show(chat, mid, report_text(a.id),
      jsonb_build_array(jsonb_build_array(btn('📥 خروجی اکسل', 'tax:' || a.id), btn('🔙 تکلیف', 'ta:' || a.id)))));
  WHEN 'tax' THEN
    RETURN jsonb_build_array(act('_excel', jsonb_build_object('chat_id', chat, 'assignment_id', a.id)));
  WHEN 'tak' THEN
    RETURN jsonb_build_array(show(chat, mid, '📋 <b>چک‌لیست جلسه ' || fa(a.session_no::text) || E'</b>\n\n' || checklist_text(a.checklist) ||
      E'\n\n<b>متن اصلی:</b>\n<pre>' || h(trunc_text(a.checklist_raw, 2500)) || '</pre>', back_kb('ta:' || a.id)));
  WHEN 'tae' THEN
    UPDATE assignments SET deadline = greatest(deadline, now()) + interval '1 day', status = 'open',
           closed_notified = false, reminded = false WHERE assignments.id = a.id RETURNING * INTO a;
    FOR r IN SELECT us.chat_id FROM enrollments e JOIN users us ON us.id = e.student_id
             WHERE e.class_id = a.class_id
               AND NOT EXISTS (SELECT 1 FROM submissions s2 WHERE s2.assignment_id = a.id AND s2.student_id = us.id AND s2.status <> 'draft') LOOP
      acts := acts || jsonb_build_array(send(r.chat_id, '⏳ مهلت تکلیف «' || h(a.title) || '» تا ' || jalali(a.deadline) || ' تمدید شد.', back_kb('sa:' || a.id, '👀 مشاهده')));
    END LOOP;
    RETURN jsonb_build_array(scr_t_asg(a, chat, mid)) || acts;
  WHEN 'tal' THEN
    RETURN jsonb_build_array(show(chat, mid, '⛔️ مهلت این تکلیف همین الان بسته شود؟ دانشجوهایی که ارسال نهایی نکرده‌اند دیگر نمی‌توانند بفرستند.',
      jsonb_build_array(jsonb_build_array(btn('✅ بله، ببند', 'taly:' || a.id), btn('❌ نه', 'ta:' || a.id)))));
  WHEN 'taly' THEN
    UPDATE assignments SET deadline = least(deadline, now()) WHERE assignments.id = a.id;
    acts := close_due_assignments();
    SELECT * INTO a FROM assignments WHERE assignments.id = a.id;
    RETURN jsonb_build_array(scr_t_asg(a, chat, mid)) || acts;
  WHEN 'tarel' THEN
    FOR r IN SELECT s2.id FROM submissions s2 WHERE s2.assignment_id = a.id AND s2.status = 'graded' LOOP
      acts := acts || release_sub(r.id);
    END LOOP;
    RETURN jsonb_build_array(show(chat, mid, '✅ ' || fa(jsonb_array_length(acts)::text) || ' نمره اعلام شد.', back_kb('ta:' || a.id))) || acts;

  -- ---------------- teacher: single submission
  WHEN 'tas' THEN
    PERFORM set_state(u.id, NULL);
    RETURN jsonb_build_array(scr_t_sub(s.id, chat, mid));
  WHEN 'tasf' THEN
    FOR r IN SELECT * FROM submission_parts WHERE submission_id = s.id ORDER BY submission_parts.id LOOP
      acts := acts || jsonb_build_array(CASE r.kind
        WHEN 'text'     THEN send(chat, '✍️ ' || h(r.text))
        WHEN 'photo'    THEN act('sendPhoto', jsonb_build_object('chat_id', chat, 'photo', r.file_id))
        ELSE act('sendDocument', jsonb_build_object('chat_id', chat, 'document', r.file_id)) END);
    END LOOP;
    RETURN jsonb_build_array(send(chat, '📎 <b>پاسخ ' || h((SELECT full_name FROM users WHERE users.id = s.student_id)) || ':</b>'))
           || acts || jsonb_build_array(scr_t_sub(s.id, chat, NULL));
  WHEN 'sap' THEN
    acts := release_sub(s.id);
    RETURN jsonb_build_array(scr_t_sub(s.id, chat, mid)) || acts;
  WHEN 'sed' THEN
    PERFORM set_state(u.id, 'edit_score', jsonb_build_object('sid', s.id));
    RETURN jsonb_build_array(send(chat, '✏️ نمره جدید را بفرستید (از ۰ تا ' ||
      fa((SELECT total_score FROM assignments WHERE assignments.id = s.assignment_id)) || '):', back_kb('tas:' || s.id, '❌ انصراف')));
  WHEN 'srg' THEN
    UPDATE submissions SET status = 'pending', attempts = 0, last_error = NULL WHERE submissions.id = s.id AND status IN ('graded','released','failed');
    RETURN jsonb_build_array(show(chat, mid, '🔄 ارسال در صف نمره‌دهی مجدد قرار گرفت. نتیجه تا چند دقیقه دیگر برای شما ارسال می‌شود.', back_kb('tsl:' || s.assignment_id)));

  -- ---------------- student
  WHEN 'sc' THEN
    IF nid IS NULL THEN RETURN jsonb_build_array(scr_s_classes(u, chat, mid)); END IF;
    RETURN jsonb_build_array(scr_s_class(u, nid, chat, mid));
  WHEN 'sj' THEN
    PERFORM set_state(u.id, 'join_code');
    RETURN jsonb_build_array(show(chat, mid, '🔑 <b>کد کلاس</b> را بفرستید (از استاد بگیرید):', back_kb('m', '❌ لغو')));
  WHEN 'sa' THEN
    IF u.state = 'sub' THEN PERFORM set_state(u.id, NULL); END IF;
    RETURN jsonb_build_array(scr_s_asg(u, nid, chat, mid));
  WHEN 'saf' THEN
    SELECT a2.* INTO a FROM assignments a2 JOIN enrollments e ON e.class_id = a2.class_id AND e.student_id = u.id WHERE a2.id = nid;
    IF a.id IS NULL OR a.attach_file_id IS NULL THEN
      -- teachers may also open their own file
      SELECT a2.* INTO a FROM assignments a2 JOIN classes c2 ON c2.id = a2.class_id WHERE a2.id = nid AND c2.teacher_id = u.id;
      IF a.id IS NULL OR a.attach_file_id IS NULL THEN RETURN jsonb_build_array(scr_denied(chat, mid)); END IF;
    END IF;
    RETURN jsonb_build_array(act(CASE WHEN a.attach_kind = 'photo' THEN 'sendPhoto' ELSE 'sendDocument' END,
             jsonb_build_object('chat_id', chat, CASE WHEN a.attach_kind = 'photo' THEN 'photo' ELSE 'document' END, a.attach_file_id,
                                'caption', 'جلسه ' || fa(a.session_no::text) || ': ' || a.title)));
  WHEN 'ss' THEN
    SELECT a2.* INTO a FROM assignments a2 JOIN enrollments e ON e.class_id = a2.class_id AND e.student_id = u.id WHERE a2.id = nid;
    IF a.id IS NULL THEN RETURN jsonb_build_array(scr_denied(chat, mid)); END IF;
    IF a.status <> 'open' OR a.deadline <= now() THEN
      RETURN jsonb_build_array(show(chat, mid, '⛔️ مهلت این تکلیف تمام شده.', back_kb('sa:' || a.id)));
    END IF;
    INSERT INTO submissions(assignment_id, student_id) VALUES (a.id, u.id) ON CONFLICT (assignment_id, student_id) DO NOTHING;
    SELECT * INTO s FROM submissions WHERE assignment_id = a.id AND student_id = u.id;
    IF s.status <> 'draft' THEN RETURN jsonb_build_array(scr_s_asg(u, a.id, chat, mid)); END IF;
    PERFORM set_state(u.id, 'sub', jsonb_build_object('sid', s.id));
    RETURN jsonb_build_array(show(chat, mid, '📤 <b>ارسال تکلیف جلسه ' || fa(a.session_no::text) || E'</b>\n\n' ||
      E'پاسخت رو بفرست. می‌تونی چند پیام پشت سر هم بفرستی:\n• متن\n• فایل PDF یا Word (docx)\n• عکس (مثلاً از برگه دست‌نویس)\n• فایل کد (py, cpp, java, …)\n\n' ||
      '⌛️ زمان باقی‌مانده: ' || remain_text(a.deadline) || E'\n\nبعد از فرستادن همه بخش‌ها، «ارسال نهایی» رو بزن. ⚠️ هر تکلیف فقط یک بار قابل ارسال نهایی است.',
      jsonb_build_array(jsonb_build_array(btn('❌ انصراف', 'sa:' || a.id)))));
  WHEN 'sf', 'sfy', 'sx', 'sp' THEN
    SELECT * INTO s FROM submissions WHERE submissions.id = (d->>'sid')::int AND student_id = u.id;
    IF u.state <> 'sub' OR s.id IS NULL OR s.status <> 'draft' THEN RETURN jsonb_build_array(scr_main(u, chat, mid)); END IF;
    SELECT * INTO a FROM assignments WHERE assignments.id = s.assignment_id;
    IF cmd = 'sp' THEN
      PERFORM set_state(u.id, NULL);
      RETURN jsonb_build_array(show(chat, mid, '⏸ پیش‌نویس ذخیره شد. قبل از پایان مهلت (' || remain_text(a.deadline) || E' دیگر) از صفحه تکلیف «ادامه ارسال» رو بزن.\n⚠️ پیش‌نویس بدون ارسال نهایی، نمره نمی‌گیرد.', back_kb('sa:' || a.id, '👀 صفحه تکلیف')));
    ELSIF cmd = 'sx' THEN
      DELETE FROM submission_parts WHERE submission_id = s.id;
      RETURN jsonb_build_array(show(chat, mid, '🗑 همه بخش‌ها پاک شد. از نو بفرست:', jsonb_build_array(jsonb_build_array(btn('❌ انصراف', 'sa:' || a.id)))));
    END IF;
    IF a.status <> 'open' OR a.deadline <= now() THEN
      PERFORM set_state(u.id, NULL);
      RETURN jsonb_build_array(show(chat, mid, '⛔️ مهلت این تکلیف تمام شده.', back_kb('m')));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM submission_parts WHERE submission_id = s.id) THEN
      RETURN jsonb_build_array(send(chat, '⚠️ هنوز چیزی نفرستادی! اول پاسخت رو بفرست.'));
    END IF;
    IF cmd = 'sf' THEN
      RETURN jsonb_build_array(show(chat, mid, '❓ ' || fa((SELECT count(*) FROM submission_parts WHERE submission_id = s.id)::text) ||
        E' بخش آماده ارسال است.\nبعد از ارسال نهایی امکان تغییر نیست. مطمئنی؟',
        jsonb_build_array(jsonb_build_array(btn('✅ بله، ارسال نهایی', 'sfy'), btn('➕ هنوز چیزی مونده', 'sp')))));
    END IF;
    -- sfy
    UPDATE submissions SET status = 'pending', submitted_at = now() WHERE submissions.id = s.id;
    PERFORM set_state(u.id, NULL);
    RETURN jsonb_build_array(show(chat, mid, E'✅ <b>تکلیفت با موفقیت ثبت شد.</b>\n🕒 ' || jalali(now()) ||
      E'\n\n🤖 پاسخت در صف نمره‌دهی قرار گرفت. ' ||
      CASE WHEN (SELECT auto_release FROM classes WHERE classes.id = a.class_id)
           THEN 'نتیجه تا چند دقیقه دیگر همین‌جا برات ارسال می‌شه.'
           ELSE 'بعد از تأیید استاد، نمره و بازخورد همین‌جا برات ارسال می‌شه.' END,
      back_kb('m', '🏠 منو')));
  WHEN 'sr' THEN
    SELECT * INTO s FROM submissions WHERE submissions.id = nid AND student_id = u.id AND status = 'released';
    IF s.id IS NULL THEN RETURN jsonb_build_array(scr_denied(chat, mid)); END IF;
    RETURN jsonb_build_array(show(chat, mid, sub_result_text(s.id, false), back_kb('sa:' || s.assignment_id)));
  ELSE
    RETURN jsonb_build_array(scr_main(u, chat, mid));
  END CASE;

  -- wizard steps that fall through here
  PERFORM set_state(u.id, 'asg', d);
  SELECT * INTO u FROM users WHERE users.id = u.id;
  RETURN jsonb_build_array(scr_asg_step(u, chat, mid));
END $$;

-- ---------------------------------------------------------------- entry point
CREATE OR REPLACE FUNCTION bot_handle(upd jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  msg jsonb := upd->'message'; cb jsonb := upd->'callback_query'; frm jsonb;
  chat bigint; mid bigint; u users; acts jsonb := '[]'; inserted int;
BEGIN
  IF upd ? 'update_id' THEN
    INSERT INTO processed_updates(update_id) VALUES ((upd->>'update_id')::bigint) ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS inserted = ROW_COUNT;
    IF inserted = 0 THEN RETURN '[]'; END IF;   -- duplicate delivery
  END IF;

  IF cb IS NOT NULL THEN
    frm := cb->'from';
    chat := (cb->'message'->'chat'->>'id')::bigint;
    mid := (cb->'message'->>'message_id')::bigint;
    acts := jsonb_build_array(act('answerCallbackQuery', jsonb_build_object('callback_query_id', cb->>'id')));
    IF chat IS NULL OR cb->'message'->'chat'->>'type' <> 'private' THEN RETURN acts; END IF;
  ELSIF msg IS NOT NULL THEN
    IF msg->'chat'->>'type' <> 'private' THEN RETURN '[]'; END IF;
    frm := msg->'from';
    chat := (msg->'chat'->>'id')::bigint;
  ELSE
    RETURN '[]';
  END IF;
  IF coalesce((frm->>'is_bot')::boolean, false) THEN RETURN acts; END IF;

  INSERT INTO users(id, chat_id, username, tg_name)
  VALUES ((frm->>'id')::bigint, chat, frm->>'username', btrim(coalesce(frm->>'first_name','') || ' ' || coalesce(frm->>'last_name','')))
  ON CONFLICT (id) DO UPDATE SET chat_id = EXCLUDED.chat_id, username = EXCLUDED.username,
                                 tg_name = EXCLUDED.tg_name, last_seen = now()
  RETURNING * INTO u;

  IF cb IS NOT NULL THEN
    RETURN acts || on_callback(u, chat, mid, cb->>'data');
  END IF;
  RETURN on_message(u, chat, msg);
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'bot_handle error: % (%)', SQLERRM, SQLSTATE;
  RETURN acts || jsonb_build_array(send(chat, '⚠️ خطای داخلی پیش آمد. لطفاً دوباره تلاش کنید یا /menu را بزنید.'));
END $$;

-- Make a user the super-admin (they must /start the bot first, or the row is created)
CREATE OR REPLACE FUNCTION make_admin(tg_id bigint) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO users(id, chat_id, is_admin, teacher_status) VALUES (tg_id, tg_id, true, 'approved')
  ON CONFLICT (id) DO UPDATE SET is_admin = true, teacher_status = 'approved';
  RETURN 'OK: ' || tg_id || ' is admin + teacher';
END $$;
