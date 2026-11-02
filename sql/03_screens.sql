-- =====================================================================
--  Screens (each returns ONE action: sendMessage or editMessageText)
-- =====================================================================

CREATE OR REPLACE FUNCTION set_state(uid bigint, st text, data jsonb DEFAULT '{}'::jsonb) RETURNS void
LANGUAGE sql AS $$ UPDATE users SET state = st, state_data = coalesce(data,'{}'::jsonb) WHERE id = uid $$;

CREATE OR REPLACE FUNCTION is_teacher(u users) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(u.teacher_status = 'approved', false)
$$;

CREATE OR REPLACE FUNCTION back_kb(data text, label text DEFAULT '🔙 بازگشت') RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_array(jsonb_build_array(btn(label, data)))
$$;

CREATE OR REPLACE FUNCTION scr_denied(chat bigint, mid bigint) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT show(chat, mid, '⛔️ دسترسی ندارید یا این مورد پیدا نشد.', back_kb('m', '🏠 منوی اصلی'))
$$;

-- ---------------------------------------------------------------- main
CREATE OR REPLACE FUNCTION scr_main(u users, chat bigint, mid bigint) RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE kb jsonb := '[]'; t text;
BEGIN
  t := 'سلام <b>' || h(u.full_name) || E'</b> 👋\nبه ربات تکالیف کلاس خوش اومدی. یکی از گزینه‌ها رو انتخاب کن:';
  IF is_teacher(u) THEN
    kb := kb || jsonb_build_array(jsonb_build_array(btn('👨‍🏫 کلاس‌های من (استاد)', 'tc')));
  END IF;
  kb := kb || jsonb_build_array(jsonb_build_array(btn('🎓 کلاس‌های من', 'sc'), btn('➕ عضویت در کلاس', 'sj')));
  IF u.teacher_status IS NULL OR u.teacher_status = 'rejected' THEN
    kb := kb || jsonb_build_array(jsonb_build_array(btn('👨‍🏫 درخواست حساب استاد', 'treq')));
  ELSIF u.teacher_status = 'pending' THEN
    t := t || E'\n\n⏳ درخواست حساب استادی شما در انتظار تأیید مدیر است.';
  END IF;
  IF u.is_admin THEN
    kb := kb || jsonb_build_array(jsonb_build_array(btn('🛠 پنل مدیریت', 'ad')));
  END IF;
  RETURN show(chat, mid, t, kb);
END $$;

-- ---------------------------------------------------------------- admin
CREATE OR REPLACE FUNCTION scr_admin(chat bigint, mid bigint) RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE kb jsonb := '[]'; r record; t text;
BEGIN
  t := E'🛠 <b>پنل مدیریت</b>\n\n' ||
       '👨‍🏫 استادها: ' || fa((SELECT count(*) FROM users WHERE teacher_status='approved')::text) || E'\n' ||
       '🎓 کاربران: ' || fa((SELECT count(*) FROM users)::text) || E'\n' ||
       '🏫 کلاس‌های فعال: ' || fa((SELECT count(*) FROM classes WHERE NOT archived)::text) || E'\n' ||
       '📝 تکالیف: ' || fa((SELECT count(*) FROM assignments)::text) || E'\n' ||
       '📤 ارسال‌ها: ' || fa((SELECT count(*) FROM submissions WHERE status <> 'draft')::text) ||
       ' | ⚠️ خطادار: ' || fa((SELECT count(*) FROM submissions WHERE status = 'failed')::text) || E'\n' ||
       '🤖 مدل AI: <code>' || h(setting('ai_model')) || '</code> (پشتیبان: <code>' || h(setting('ai_fallback_model')) || E'</code>)\n' ||
       E'<i>تغییر مدل:</i> <code>/setmodel نام-مدل</code>\n\n';
  t := t || E'<b>درخواست‌های استادی در انتظار:</b>\n';
  FOR r IN SELECT * FROM users WHERE teacher_status = 'pending' ORDER BY created_at LIMIT 20 LOOP
    t := t || '• ' || h(r.full_name) || coalesce(' (@' || h(r.username) || ')', '') || E'\n';
    kb := kb || jsonb_build_array(jsonb_build_array(
            btn('✅ ' || trunc_text(r.full_name, 20), 'ap:' || r.id), btn('❌ رد', 'ar:' || r.id)));
  END LOOP;
  IF NOT FOUND THEN t := t || E'— درخواستی نیست\n'; END IF;
  kb := kb || jsonb_build_array(jsonb_build_array(btn('🔄 بروزرسانی', 'ad'), btn('🏠 منو', 'm')));
  RETURN show(chat, mid, t, kb);
END $$;

-- ---------------------------------------------------------------- teacher: classes
CREATE OR REPLACE FUNCTION scr_t_classes(u users, chat bigint, mid bigint) RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE kb jsonb := '[]'; r record; t text := E'👨‍🏫 <b>کلاس‌های شما</b>\n\n';
BEGIN
  FOR r IN SELECT c.*, (SELECT count(*) FROM enrollments e WHERE e.class_id = c.id) AS n
           FROM classes c WHERE c.teacher_id = u.id AND NOT c.archived ORDER BY c.id LOOP
    kb := kb || jsonb_build_array(jsonb_build_array(
            btn('🏫 ' || trunc_text(r.name, 30) || ' (' || fa(r.n::text) || ' نفر)', 'tc:' || r.id)));
  END LOOP;
  IF jsonb_array_length(kb) = 0 THEN t := t || E'هنوز کلاسی نساختی. با دکمه زیر اولین کلاس رو بساز.\n';
  ELSE t := t || 'یک کلاس را انتخاب کنید:'; END IF;
  kb := kb || jsonb_build_array(jsonb_build_array(btn('➕ ساخت کلاس جدید', 'tn')))
           || jsonb_build_array(jsonb_build_array(btn('🏠 منوی اصلی', 'm')));
  RETURN show(chat, mid, t, kb);
END $$;

CREATE OR REPLACE FUNCTION class_link(c classes) RETURNS text LANGUAGE sql STABLE AS $$
  SELECT 'https://t.me/' || setting('bot_username') || '?start=join_' || c.join_code
$$;

CREATE OR REPLACE FUNCTION scr_t_class(c classes, chat bigint, mid bigint) RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE t text; n_st int; n_as int; n_wait int;
BEGIN
  SELECT count(*) INTO n_st FROM enrollments WHERE class_id = c.id;
  SELECT count(*) INTO n_as FROM assignments WHERE class_id = c.id;
  SELECT count(*) INTO n_wait FROM submissions s JOIN assignments a ON a.id = s.assignment_id
   WHERE a.class_id = c.id AND s.status IN ('graded','failed');
  t := '🏫 <b>' || h(c.name) || E'</b>\n\n' ||
       '🔑 کد عضویت: <code>' || c.join_code || E'</code>\n' ||
       '🔗 لینک عضویت: ' || h(class_link(c)) || E'\n' ||
       '👥 دانشجوها: ' || fa(n_st::text) || E'\n' ||
       '📝 تکالیف: ' || fa(n_as::text) || E'\n' ||
       '⚙️ اعلام نمره: ' || CASE WHEN c.auto_release THEN '<b>خودکار</b> (بلافاصله برای دانشجو ارسال می‌شود)'
                                ELSE '<b>با تأیید استاد</b> (اول شما می‌بینید و تأیید می‌کنید)' END ||
       CASE WHEN n_wait > 0 THEN E'\n\n🟡 ' || fa(n_wait::text) || ' ارسال منتظر بررسی/تأیید شماست.' ELSE '' END ||
       E'\n\n<i>کد یا لینک بالا را برای دانشجوها بفرستید تا عضو کلاس شوند.</i>';
  RETURN show(chat, mid, t, jsonb_build_array(
    jsonb_build_array(btn('➕ تکلیف جدید', 'an:' || c.id), btn('📝 تکالیف', 'tca:' || c.id)),
    jsonb_build_array(btn('👥 دانشجوها', 'tcs:' || c.id),
                      btn(CASE WHEN c.auto_release THEN '⚙️ تغییر به «با تأیید استاد»' ELSE '⚙️ تغییر به «اعلام خودکار»' END, 'tcr:' || c.id)),
    jsonb_build_array(btn('🗄 بایگانی کلاس', 'tcd:' || c.id), btn('🔙 کلاس‌ها', 'tc'))));
END $$;

CREATE OR REPLACE FUNCTION scr_t_students(c classes, chat bigint, mid bigint) RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE t text := '👥 <b>دانشجوهای ' || h(c.name) || E'</b>\n\n'; r record; i int := 0;
BEGIN
  FOR r IN SELECT u.* FROM enrollments e JOIN users u ON u.id = e.student_id
           WHERE e.class_id = c.id ORDER BY u.full_name LOOP
    i := i + 1;
    IF i <= 80 THEN
      t := t || fa(i::text) || '. ' || h(r.full_name) || coalesce(' — <code>' || h(r.student_no) || '</code>', '') || E'\n';
    END IF;
  END LOOP;
  IF i = 0 THEN t := t || 'هنوز کسی عضو نشده.';
  ELSIF i > 80 THEN t := t || E'…\nبرای فهرست کامل از خروجی اکسل تکالیف استفاده کنید.'; END IF;
  t := t || E'\n\nتعداد کل: ' || fa(i::text);
  RETURN show(chat, mid, t, back_kb('tc:' || c.id));
END $$;

CREATE OR REPLACE FUNCTION scr_t_asg_list(c classes, chat bigint, mid bigint) RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE kb jsonb := '[]'; r record; t text := '📝 <b>تکالیف ' || h(c.name) || E'</b>\n\n';
BEGIN
  FOR r IN SELECT * FROM assignments WHERE class_id = c.id ORDER BY session_no DESC LIMIT 40 LOOP
    kb := kb || jsonb_build_array(jsonb_build_array(btn(
            CASE WHEN r.status = 'open' THEN '🟢 ' ELSE '⚪️ ' END || 'جلسه ' || fa(r.session_no::text) || ': ' ||
            trunc_text(r.title, 28), 'ta:' || r.id)));
  END LOOP;
  t := t || CASE WHEN jsonb_array_length(kb) = 0 THEN 'هنوز تکلیفی تعریف نشده.' ELSE '🟢 باز   ⚪️ بسته شده' END;
  kb := kb || jsonb_build_array(jsonb_build_array(btn('➕ تکلیف جدید', 'an:' || c.id), btn('🔙 کلاس', 'tc:' || c.id)));
  RETURN show(chat, mid, t, kb);
END $$;

-- ---------------------------------------------------------------- teacher: assignment
CREATE OR REPLACE FUNCTION scr_t_asg(a assignments, chat bigint, mid bigint) RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE t text; c classes; n_st int; st record; kb jsonb;
BEGIN
  SELECT * INTO c FROM classes WHERE id = a.class_id;
  SELECT count(*) INTO n_st FROM enrollments WHERE class_id = a.class_id;
  SELECT count(*) FILTER (WHERE status <> 'draft') AS sent,
         count(*) FILTER (WHERE status IN ('pending','grading')) AS queue,
         count(*) FILTER (WHERE status = 'graded') AS waiting,
         count(*) FILTER (WHERE status = 'released') AS released,
         count(*) FILTER (WHERE status = 'failed') AS failed,
         avg(coalesce(final_score, ai_score)) FILTER (WHERE status IN ('graded','released')) AS avg
    INTO st FROM submissions WHERE assignment_id = a.id;
  t := '📝 <b>جلسه ' || fa(a.session_no::text) || ': ' || h(a.title) || E'</b>\n🏫 ' || h(c.name) || E'\n\n' ||
       '⏰ مهلت: ' || jalali(a.deadline) || ' (' || CASE WHEN a.status = 'open' AND a.deadline > now() THEN remain_text(a.deadline) || ' مانده' ELSE 'بسته شده' END || E')\n' ||
       '🎯 نمره کل: ' || fa(a.total_score) || E'\n\n' ||
       '📤 ارسال شده: ' || fa(st.sent::text) || ' از ' || fa(n_st::text) || E'\n' ||
       '⏳ در صف نمره‌دهی: ' || fa(st.queue::text) || E'\n' ||
       '🟡 منتظر تأیید شما: ' || fa(st.waiting::text) || E'\n' ||
       '✅ اعلام شده: ' || fa(st.released::text) ||
       CASE WHEN st.failed > 0 THEN E'\n⚠️ خطای نمره‌دهی: ' || fa(st.failed::text) ELSE '' END ||
       CASE WHEN st.avg IS NOT NULL THEN E'\n📈 میانگین: ' || fa(round(st.avg, 2)) ELSE '' END;
  kb := jsonb_build_array(
    jsonb_build_array(btn('👥 ارسال‌ها و نمره‌ها', 'tsl:' || a.id), btn('📊 گزارش', 'tar:' || a.id)),
    jsonb_build_array(btn('📥 خروجی اکسل', 'tax:' || a.id), btn('📋 چک‌لیست', 'tak:' || a.id)));
  IF st.waiting > 0 THEN
    kb := kb || jsonb_build_array(jsonb_build_array(btn('✅ تأیید و اعلام همه نمره‌ها (' || fa(st.waiting::text) || ')', 'tarel:' || a.id)));
  END IF;
  kb := kb || jsonb_build_array(jsonb_build_array(
      btn('⏳ تمدید ۱ روز', 'tae:' || a.id),
      CASE WHEN a.status = 'open' THEN btn('⛔️ بستن مهلت', 'tal:' || a.id) ELSE btn('🔄 بروزرسانی', 'ta:' || a.id) END))
    || jsonb_build_array(jsonb_build_array(btn('🔙 تکالیف', 'tca:' || a.class_id)));
  RETURN show(chat, mid, t, kb);
END $$;

CREATE OR REPLACE FUNCTION eff_score(s submissions) RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(s.final_score, s.ai_score)
$$;

CREATE OR REPLACE FUNCTION scr_t_sub_list(a assignments, chat bigint, mid bigint) RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE kb jsonb := '[]'; r record; t text; missing text := ''; nm int := 0; i int := 0;
BEGIN
  t := '👥 <b>ارسال‌های جلسه ' || fa(a.session_no::text) || ': ' || h(a.title) || E'</b>\n' ||
       E'روی هر دانشجو بزنید تا جزئیات نمره و بازخورد را ببینید.\n';
  FOR r IN SELECT u.full_name, u.student_no, s.*
           FROM enrollments e JOIN users u ON u.id = e.student_id
           LEFT JOIN submissions s ON s.assignment_id = a.id AND s.student_id = u.id
           WHERE e.class_id = a.class_id
           ORDER BY (s.status IS NULL OR s.status = 'draft'), u.full_name LOOP
    IF r.status IS NULL OR r.status = 'draft' THEN
      nm := nm + 1;
      IF nm <= 40 THEN missing := missing || '• ' || h(r.full_name) || E'\n'; END IF;
    ELSE
      i := i + 1;
      IF i <= 60 THEN
        kb := kb || jsonb_build_array(jsonb_build_array(btn(
          CASE r.status WHEN 'released' THEN '✅' WHEN 'graded' THEN '🟡' WHEN 'failed' THEN '⚠️' ELSE '⏳' END || ' ' ||
          trunc_text(r.full_name, 24) ||
          CASE WHEN coalesce(r.final_score, r.ai_score) IS NOT NULL THEN ' — ' || fa(coalesce(r.final_score, r.ai_score)) ELSE '' END,
          'tas:' || r.id)));
      END IF;
    END IF;
  END LOOP;
  IF i = 0 THEN t := t || E'\nهنوز کسی ارسال نکرده.'; END IF;
  IF nm > 0 THEN t := t || E'\n\n❌ <b>ارسال نکرده‌اند (' || fa(nm::text) || E'):</b>\n' || missing || CASE WHEN nm > 40 THEN '…' ELSE '' END; END IF;
  t := t || E'\n\n✅ اعلام شده  🟡 منتظر تأیید  ⏳ در صف  ⚠️ خطا';
  kb := kb || jsonb_build_array(jsonb_build_array(btn('🔄 بروزرسانی', 'tsl:' || a.id), btn('🔙 تکلیف', 'ta:' || a.id)));
  RETURN show(chat, mid, t, kb);
END $$;

-- Full result text for one submission (student or teacher view)
CREATE OR REPLACE FUNCTION sub_result_text(sid int, for_teacher boolean) RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE s submissions; a assignments; u users; t text; cr jsonb; ai jsonb; e jsonb; sc jsonb; d jsonb;
BEGIN
  SELECT * INTO s FROM submissions WHERE id = sid;
  SELECT * INTO a FROM assignments WHERE id = s.assignment_id;
  SELECT * INTO u FROM users WHERE id = s.student_id;
  ai := s.ai_result;
  t := '📝 <b>جلسه ' || fa(a.session_no::text) || ': ' || h(a.title) || E'</b>\n';
  IF for_teacher THEN
    t := t || '👤 ' || h(u.full_name) || coalesce(' — <code>' || h(u.student_no) || '</code>', '') || E'\n' ||
         '📮 ارسال: ' || jalali(s.submitted_at) || E'\n' ||
         '📌 وضعیت: ' || status_label(s.status) || E'\n';
  END IF;
  IF s.status IN ('graded','released') THEN
    t := t || E'\n🎯 <b>نمره: ' || fa(eff_score(s)) || ' از ' || fa(a.total_score) || '</b>';
    IF for_teacher AND s.teacher_edited THEN t := t || ' <i>(ویرایش‌شده توسط استاد؛ نمره AI: ' || fa(s.ai_score) || ')</i>'; END IF;
    t := t || E'\n';
    IF ai IS NOT NULL THEN
      t := t || E'\n<b>جزئیات بر اساس چک‌لیست:</b>\n';
      FOR cr IN SELECT * FROM jsonb_array_elements(a.checklist->'criteria') LOOP
        SELECT x INTO sc FROM jsonb_array_elements(ai->'criteria') x WHERE (x->>'id')::int = (cr->>'id')::int LIMIT 1;
        t := t || CASE WHEN sc IS NULL THEN '▫️'
                       WHEN (sc->>'score')::numeric >= (cr->>'points')::numeric THEN '✅'
                       WHEN (sc->>'score')::numeric <= 0 THEN '❌' ELSE '🟠' END || ' ' ||
             h(cr->>'title') || ': <b>' || fa(coalesce((sc->>'score')::numeric, 0)) || '/' || fa((cr->>'points')::numeric) || '</b>';
        IF coalesce(sc->>'comment','') <> '' THEN t := t || E'\n    <i>' || h(sc->>'comment') || '</i>'; END IF;
        t := t || E'\n';
      END LOOP;
      FOR d IN SELECT * FROM jsonb_array_elements(coalesce(ai->'deductions','[]')) LOOP
        t := t || '➖ ' || h(d->>'reason') || ': <b>-' || fa((d->>'points')::numeric) || E'</b>\n';
      END LOOP;
      IF coalesce(ai->>'overall_feedback','') <> '' THEN
        t := t || E'\n💬 <b>بازخورد:</b>\n' || h(ai->>'overall_feedback') || E'\n';
      END IF;
      IF for_teacher THEN
        IF coalesce((ai->>'needs_review')::boolean, false) THEN
          t := t || E'\n⚠️ <b>نیاز به بررسی استاد:</b> ' || h(coalesce(ai->>'review_reason','')) || E'\n';
        END IF;
        IF ai ? 'confidence' THEN t := t || '🤖 اطمینان AI: ' || fa(round((ai->>'confidence')::numeric * 100)) || E'٪\n'; END IF;
      END IF;
    END IF;
  ELSIF s.status = 'failed' AND for_teacher THEN
    t := t || E'\n⚠️ خطا: ' || h(trunc_text(s.last_error, 300));
  END IF;
  RETURN t;
END $$;

CREATE OR REPLACE FUNCTION scr_t_sub(sid int, chat bigint, mid bigint) RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE s submissions; kb jsonb := '[]';
BEGIN
  SELECT * INTO s FROM submissions WHERE id = sid;
  IF s.status = 'graded' THEN
    kb := kb || jsonb_build_array(jsonb_build_array(btn('✅ تأیید و اعلام به دانشجو', 'sap:' || sid)));
  END IF;
  IF s.status IN ('graded','released','failed') THEN
    kb := kb || jsonb_build_array(jsonb_build_array(btn('✏️ ویرایش نمره', 'sed:' || sid), btn('🔄 نمره‌دهی مجدد AI', 'srg:' || sid)));
  END IF;
  kb := kb || jsonb_build_array(jsonb_build_array(btn('📎 دیدن پاسخ دانشجو', 'tasf:' || sid), btn('🔙 لیست', 'tsl:' || s.assignment_id)));
  RETURN show(chat, mid, sub_result_text(sid, true), kb);
END $$;

-- ---------------------------------------------------------------- student
CREATE OR REPLACE FUNCTION scr_s_classes(u users, chat bigint, mid bigint) RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE kb jsonb := '[]'; r record; t text := E'🎓 <b>کلاس‌های شما</b>\n\n';
BEGIN
  FOR r IN SELECT c.*, tu.full_name AS teacher,
                  (SELECT count(*) FROM assignments a WHERE a.class_id = c.id AND a.status = 'open'
                     AND NOT EXISTS (SELECT 1 FROM submissions s WHERE s.assignment_id = a.id AND s.student_id = u.id AND s.status <> 'draft')) AS todo
           FROM enrollments e JOIN classes c ON c.id = e.class_id JOIN users tu ON tu.id = c.teacher_id
           WHERE e.student_id = u.id AND NOT c.archived ORDER BY c.name LOOP
    kb := kb || jsonb_build_array(jsonb_build_array(btn(
            '🏫 ' || trunc_text(r.name, 26) || CASE WHEN r.todo > 0 THEN ' 🔴' || fa(r.todo::text) ELSE '' END, 'sc:' || r.id)));
  END LOOP;
  IF jsonb_array_length(kb) = 0 THEN t := t || 'هنوز عضو کلاسی نیستی. کد کلاس رو از استادت بگیر و «عضویت در کلاس» رو بزن.';
  ELSE t := t || E'🔴 = تکلیف باز که هنوز نفرستادی'; END IF;
  kb := kb || jsonb_build_array(jsonb_build_array(btn('➕ عضویت در کلاس', 'sj'), btn('🏠 منو', 'm')));
  RETURN show(chat, mid, t, kb);
END $$;

CREATE OR REPLACE FUNCTION scr_s_class(u users, cid int, chat bigint, mid bigint) RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE c classes; kb jsonb := '[]'; r record; t text;
BEGIN
  SELECT c2.* INTO c FROM classes c2 JOIN enrollments e ON e.class_id = c2.id AND e.student_id = u.id WHERE c2.id = cid;
  IF c.id IS NULL THEN RETURN scr_denied(chat, mid); END IF;
  t := '🏫 <b>' || h(c.name) || E'</b>\n👨‍🏫 استاد: ' || h((SELECT full_name FROM users WHERE id = c.teacher_id)) || E'\n\nتکالیف:';
  FOR r IN SELECT a.*, s.status AS sst, coalesce(s.final_score, s.ai_score) AS sc
           FROM assignments a LEFT JOIN submissions s ON s.assignment_id = a.id AND s.student_id = u.id
           WHERE a.class_id = cid ORDER BY a.session_no DESC LIMIT 40 LOOP
    kb := kb || jsonb_build_array(jsonb_build_array(btn(
      CASE WHEN r.sst = 'released' THEN '✅ ' || fa(r.sc) || ' | '
           WHEN r.sst IN ('pending','grading','graded') THEN '⏳ '
           WHEN r.status = 'open' THEN '🔴 '
           ELSE '⚪️ ' END ||
      'جلسه ' || fa(r.session_no::text) || ': ' || trunc_text(r.title, 24), 'sa:' || r.id)));
  END LOOP;
  IF jsonb_array_length(kb) = 0 THEN t := t || E'\nهنوز تکلیفی تعریف نشده.';
  ELSE t := t || E'\n🔴 باز و ارسال‌نشده  ⏳ در حال بررسی  ✅ نمره اعلام‌شده  ⚪️ بسته'; END IF;
  kb := kb || back_kb('sc', '🔙 کلاس‌ها');
  RETURN show(chat, mid, t, kb);
END $$;

CREATE OR REPLACE FUNCTION scr_s_asg(u users, aid int, chat bigint, mid bigint) RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE a assignments; s submissions; kb jsonb := '[]'; t text; np int;
BEGIN
  SELECT a2.* INTO a FROM assignments a2 JOIN enrollments e ON e.class_id = a2.class_id AND e.student_id = u.id WHERE a2.id = aid;
  IF a.id IS NULL THEN RETURN scr_denied(chat, mid); END IF;
  SELECT * INTO s FROM submissions WHERE assignment_id = aid AND student_id = u.id;
  t := '📝 <b>جلسه ' || fa(a.session_no::text) || ': ' || h(a.title) || E'</b>\n\n' ||
       coalesce(h(a.description) || E'\n\n', '') ||
       '⏰ مهلت: ' || jalali(a.deadline) || E'\n' ||
       CASE WHEN a.status = 'open' AND a.deadline > now() THEN '⌛️ زمان باقی‌مانده: ' || remain_text(a.deadline) ELSE '⛔️ مهلت ارسال تمام شده' END || E'\n' ||
       '🎯 نمره کل: ' || fa(a.total_score) || E'\n' ||
       '📌 وضعیت شما: ' || status_label(s.status);
  IF s.status = 'draft' THEN
    SELECT count(*) INTO np FROM submission_parts WHERE submission_id = s.id;
    t := t || ' — ' || fa(np::text) || ' بخش ذخیره شده';
  END IF;
  IF a.attach_file_id IS NOT NULL THEN
    kb := kb || jsonb_build_array(jsonb_build_array(btn('📎 دریافت فایل تکلیف', 'saf:' || a.id)));
  END IF;
  IF a.status = 'open' AND a.deadline > now() AND (s.id IS NULL OR s.status = 'draft') THEN
    kb := kb || jsonb_build_array(jsonb_build_array(btn(CASE WHEN s.id IS NULL THEN '📤 ارسال تکلیف' ELSE '📤 ادامه ارسال' END, 'ss:' || a.id)));
  END IF;
  IF s.status = 'released' THEN
    kb := kb || jsonb_build_array(jsonb_build_array(btn('📊 مشاهده نمره و بازخورد', 'sr:' || s.id)));
  END IF;
  kb := kb || back_kb('sc:' || a.class_id);
  RETURN show(chat, mid, t, kb);
END $$;

-- ---------------------------------------------------------------- assignment wizard prompt
CREATE OR REPLACE FUNCTION scr_asg_step(u users, chat bigint, mid bigint) RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE d jsonb := u.state_data; step text := u.state_data->>'step'; c classes; nxt int; cl jsonb; cancel jsonb;
BEGIN
  SELECT * INTO c FROM classes WHERE id = (d->>'cid')::int;
  cancel := jsonb_build_array(btn('❌ لغو', 'ac:n'));
  IF step = 'session' THEN
    SELECT coalesce(max(session_no), 0) + 1 INTO nxt FROM assignments WHERE class_id = c.id;
    RETURN show(chat, mid, '➕ <b>تکلیف جدید — ' || h(c.name) || E'</b>\n\n۱/۵ — شماره جلسه را بفرستید (هر جلسه فقط یک تکلیف دارد):',
      jsonb_build_array(jsonb_build_array(btn('جلسه ' || fa(nxt::text), 'asn:' || nxt)), cancel));
  ELSIF step = 'title' THEN
    RETURN show(chat, mid, E'۲/۵ — <b>عنوان تکلیف</b> را بفرستید:\nمثال: <i>پیاده‌سازی مرتب‌سازی حبابی</i>', jsonb_build_array(cancel));
  ELSIF step = 'desc' THEN
    RETURN show(chat, mid, E'۳/۵ — <b>صورت تکلیف</b> را بفرستید.\n\nمی‌توانید متن بفرستید، یا فایل PDF/عکس صورت سؤال را (با کپشن دلخواه). ' ||
      E'هوش مصنوعی هنگام نمره‌دهی صورت سؤال را هم می‌بیند، پس هرچه دقیق‌تر باشد نمره‌دهی بهتر است.', jsonb_build_array(cancel));
  ELSIF step = 'deadline' THEN
    RETURN show(chat, mid, E'۴/۵ — <b>مهلت ارسال</b> را انتخاب کنید (از همین الان حساب می‌شود):',
      jsonb_build_array(
        jsonb_build_array(btn('۱ روز', 'dl:24'), btn('۲ روز', 'dl:48'), btn('۳ روز', 'dl:72')),
        jsonb_build_array(btn('۱ هفته', 'dl:168'), btn('۲ هفته', 'dl:336'), btn('✍️ دلخواه', 'dl:c')),
        cancel));
  ELSIF step = 'deadline_custom' THEN
    RETURN show(chat, mid, E'مدت مهلت را بفرستید:\n• عدد تنها = روز (مثلاً <code>۵</code> یا <code>۰.۵</code>)\n• عدد + «ساعت» = ساعت (مثلاً <code>۱۲ ساعت</code>)',
      jsonb_build_array(cancel));
  ELSIF step = 'checklist' THEN
    RETURN show(chat, mid, E'۵/۵ — <b>چک‌لیست نمره‌دهی</b> را بفرستید.\n\n' ||
      E'هر معیار در یک خط با بارم داخل کروشه:\n<code>- [5] عنوان معیار</code>\n' ||
      E'می‌توانید «نمره کل:»، بخش «قوانین:» و «پاسخ نمونه:» هم اضافه کنید.\n\nبرای دیدن یک نمونه کامل دکمه زیر را بزنید 👇',
      jsonb_build_array(jsonb_build_array(btn('📋 نمونه چک‌لیست', 'cs')), cancel));
  ELSIF step = 'confirm' THEN
    cl := parse_checklist(d->>'checklist_raw');
    RETURN show(chat, mid, E'👀 <b>پیش‌نمایش تکلیف</b>\n\n' ||
      '🏫 کلاس: ' || h(c.name) || E'\n' ||
      '📍 جلسه: ' || fa(d->>'session') || E'\n' ||
      '📝 عنوان: ' || h(d->>'title') || E'\n' ||
      '📄 صورت: ' || CASE WHEN d->>'file_id' IS NOT NULL THEN '📎 فایل پیوست + ' ELSE '' END || h(trunc_text(coalesce(d->>'desc','—'), 300)) || E'\n' ||
      '⏰ مهلت: ' || hours_label((d->>'hours')::numeric) || ' — تا ' || jalali(now() + make_interval(secs => (d->>'hours')::numeric * 3600)) || E'\n' ||
      '⚙️ اعلام نمره: ' || CASE WHEN c.auto_release THEN 'خودکار' ELSE 'با تأیید شما' END || E'\n\n' ||
      E'<b>چک‌لیست:</b>\n' || checklist_text(cl) ||
      E'\n\nبعد از انتشار، به همه دانشجوهای کلاس اطلاع داده می‌شود.',
      jsonb_build_array(jsonb_build_array(btn('✅ انتشار تکلیف', 'ac:y'), btn('✏️ چک‌لیست جدید', 'ac:k')), cancel));
  END IF;
  RETURN scr_main(u, chat, mid);
END $$;
