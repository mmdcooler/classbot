-- =====================================================================
--  AI grading queue, reports, scheduler
-- =====================================================================

-- Claim up to n submissions for grading (safe for parallel runs)
CREATE OR REPLACE FUNCTION grading_claim(n int DEFAULT 3) RETURNS SETOF jsonb LANGUAGE plpgsql AS $$
DECLARE r record;
BEGIN
  FOR r IN
    WITH picked AS (
      SELECT s.id FROM submissions s
       WHERE s.attempts < 3
         AND (s.retry_at IS NULL OR s.retry_at <= now())
         AND (s.status = 'pending'
              OR (s.status = 'grading' AND s.grading_started_at < now() - interval '15 minutes'))
       ORDER BY s.submitted_at
       LIMIT n
       FOR UPDATE SKIP LOCKED)
    UPDATE submissions s SET status = 'grading', grading_started_at = now(), attempts = s.attempts + 1
      FROM picked WHERE s.id = picked.id
    RETURNING s.*
  LOOP
    RETURN NEXT (
      SELECT jsonb_build_object(
        'submission_id', r.id,
        'attempt', r.attempts,
        'student_name', u.full_name,
        'submitted_at', r.submitted_at,
        'assignment', jsonb_build_object(
            'id', a.id, 'session_no', a.session_no, 'title', a.title, 'description', a.description,
            'total', a.total_score, 'checklist', a.checklist,
            'attachment', CASE WHEN a.attach_file_id IS NULL THEN NULL ELSE jsonb_build_object(
                'file_id', a.attach_file_id, 'kind', a.attach_kind,
                'file_name', a.checklist->>'file_name', 'mime', a.checklist->>'file_mime') END,
            'answer_text', a.answer_text,
            'answer_file', CASE WHEN a.answer_file_id IS NULL THEN NULL ELSE jsonb_build_object(
                'file_id', a.answer_file_id, 'kind', a.answer_kind, 'file_name', a.answer_file_name, 'mime', a.answer_mime) END),
        'parts', coalesce((SELECT jsonb_agg(jsonb_build_object('kind', p.kind, 'text', p.text, 'file_id', p.file_id,
                                   'file_name', p.file_name, 'mime', p.mime, 'file_size', p.file_size) ORDER BY p.id)
                           FROM submission_parts p WHERE p.submission_id = r.id), '[]'),
        'models', jsonb_build_array(setting('ai_model'), setting('ai_fallback_model')),
        'max_file_mb', setting('max_file_mb')::int)
      FROM assignments a JOIN users u ON u.id = r.student_id
      WHERE a.id = r.assignment_id);
  END LOOP;
END $$;

-- Save AI grading result -> returns Telegram actions (release or teacher card)
CREATE OR REPLACE FUNCTION grading_save(res jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE s submissions; a assignments; c classes; t users; sc numeric; acts jsonb := '[]'; card jsonb; nr boolean;
BEGIN
  SELECT * INTO s FROM submissions WHERE id = (res->>'submission_id')::int FOR UPDATE;
  IF s.id IS NULL OR s.status <> 'grading' THEN RETURN '[]'; END IF;    -- stale / already handled
  SELECT * INTO a FROM assignments WHERE id = s.assignment_id;
  SELECT * INTO c FROM classes WHERE id = a.class_id;
  SELECT * INTO t FROM users WHERE id = c.teacher_id;
  sc := least(greatest(coalesce((res->>'ai_score')::numeric, 0), 0), a.total_score);
  nr := coalesce((res->>'needs_review')::boolean, false);
  UPDATE submissions SET status = 'graded', ai_result = res, ai_score = sc, final_score = sc,
         teacher_edited = false, needs_review = nr, graded_at = now(), last_error = NULL, retry_at = NULL, rate_hits = 0
   WHERE id = s.id;

  IF c.auto_release AND NOT nr THEN
    RETURN release_sub(s.id);
  END IF;

  card := scr_t_sub(s.id, t.chat_id, NULL);
  card := jsonb_set(card, '{payload,text}', to_jsonb(
            CASE WHEN nr AND c.auto_release THEN E'⚠️ <b>این ارسال نیاز به بررسی شما دارد</b> (اعلام خودکار متوقف شد)\n\n'
                 ELSE E'🆕 <b>تکلیف جدید نمره‌دهی شد</b>\n\n' END || (card->'payload'->>'text')));
  acts := jsonb_build_array(card,
    send((SELECT chat_id FROM users WHERE id = s.student_id),
         '🤖 تکلیف جلسه ' || fa(a.session_no::text) || ' («' || h(a.title) || '») بررسی شد. نمره بعد از تأیید استاد اعلام می‌شود.'));
  RETURN acts;
END $$;

-- Record a grading failure. After 3 attempts -> failed + teacher notified.
CREATE OR REPLACE FUNCTION grading_fail(sid int, err text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE s submissions; t users; card jsonb;
BEGIN
  SELECT * INTO s FROM submissions WHERE id = sid FOR UPDATE;
  IF s.id IS NULL OR s.status <> 'grading' THEN RETURN '[]'; END IF;
  -- AI busy / rate limited (429): not the student's fault -> wait and retry, don't burn an attempt
  IF err ~* '(\m429\M|rate.?limit|too many requests|temporarily|overloaded|\m50[234]\M)' AND s.rate_hits < 20 THEN
    UPDATE submissions SET status = 'pending', attempts = greatest(attempts - 1, 0), rate_hits = rate_hits + 1,
           retry_at = now() + make_interval(mins => least(2 * (s.rate_hits + 1), 30)), last_error = left(err, 2000)
     WHERE id = sid;
    RETURN '[]';
  END IF;
  IF s.attempts < 3 THEN
    UPDATE submissions SET status = 'pending', last_error = left(err, 2000) WHERE id = sid;
    RETURN '[]';
  END IF;
  UPDATE submissions SET status = 'failed', last_error = left(err, 2000) WHERE id = sid;
  SELECT tu.* INTO t FROM assignments a JOIN classes c ON c.id = a.class_id JOIN users tu ON tu.id = c.teacher_id
   WHERE a.id = s.assignment_id;
  card := scr_t_sub(sid, t.chat_id, NULL);
  card := jsonb_set(card, '{payload,text}', to_jsonb(E'⚠️ <b>نمره‌دهی خودکار ناموفق بود</b>\nمی‌توانید دستی نمره بدهید یا دوباره امتحان کنید.\n\n' || (card->'payload'->>'text')));
  RETURN jsonb_build_array(card);
END $$;

-- ---------------------------------------------------------------- reports
CREATE OR REPLACE FUNCTION report_text(aid int) RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE a assignments; c classes; st record; t text; r record; cr jsonb; i int := 0; miss text := ''; nm int := 0;
BEGIN
  SELECT * INTO a FROM assignments WHERE id = aid;
  SELECT * INTO c FROM classes WHERE id = a.class_id;
  SELECT count(*) AS enrolled,
         count(s.id) FILTER (WHERE s.status NOT IN ('draft')) AS sent,
         count(s.id) FILTER (WHERE s.status IN ('graded','released')) AS graded,
         count(s.id) FILTER (WHERE s.status IN ('pending','grading')) AS queue,
         count(s.id) FILTER (WHERE s.status = 'failed') AS failed,
         count(s.id) FILTER (WHERE s.needs_review AND s.status = 'graded') AS review,
         round(avg(coalesce(s.final_score, s.ai_score)) FILTER (WHERE s.status IN ('graded','released')), 2) AS avg,
         max(coalesce(s.final_score, s.ai_score)) FILTER (WHERE s.status IN ('graded','released')) AS mx,
         min(coalesce(s.final_score, s.ai_score)) FILTER (WHERE s.status IN ('graded','released')) AS mn,
         count(s.id) FILTER (WHERE s.status IN ('graded','released') AND coalesce(s.final_score, s.ai_score) >= a.total_score / 2) AS passed
    INTO st
    FROM enrollments e LEFT JOIN submissions s ON s.assignment_id = a.id AND s.student_id = e.student_id
   WHERE e.class_id = a.class_id;

  t := '📊 <b>گزارش جلسه ' || fa(a.session_no::text) || ': ' || h(a.title) || E'</b>\n🏫 ' || h(c.name) ||
       E'\n⏰ مهلت: ' || jalali(a.deadline) || CASE WHEN a.status = 'closed' THEN ' (بسته شد)' ELSE ' (باز)' END || E'\n\n' ||
       '👥 دانشجوها: ' || fa(st.enrolled::text) || ' | 📤 ارسال: ' || fa(st.sent::text) ||
       ' | ❌ ارسال‌نکرده: ' || fa((st.enrolled - st.sent)::text) || E'\n' ||
       '✅ نمره‌دار: ' || fa(st.graded::text) || ' | ⏳ در صف: ' || fa(st.queue::text) ||
       CASE WHEN st.failed > 0 THEN ' | ⚠️ خطا: ' || fa(st.failed::text) ELSE '' END ||
       CASE WHEN st.review > 0 THEN E'\n🔎 نیازمند بررسی شما: ' || fa(st.review::text) ELSE '' END;
  IF st.graded > 0 THEN
    t := t || E'\n\n📈 میانگین: <b>' || fa(st.avg) || '</b> از ' || fa(a.total_score) ||
         ' | بیشترین: ' || fa(st.mx) || ' | کمترین: ' || fa(st.mn) ||
         E'\n🎯 بالای نصف نمره: ' || fa(st.passed::text) || ' نفر (' || fa(round(100.0 * st.passed / st.graded)::text) || '٪)';
    -- per-criterion average (where students lose points)
    t := t || E'\n\n<b>میانگین هر معیار:</b>\n';
    FOR cr IN SELECT * FROM jsonb_array_elements(a.checklist->'criteria') LOOP
      SELECT round(avg((x->>'score')::numeric), 2) AS av INTO r
        FROM submissions s, jsonb_array_elements(s.ai_result->'criteria') x
       WHERE s.assignment_id = a.id AND s.status IN ('graded','released') AND (x->>'id')::int = (cr->>'id')::int;
      t := t || '▫️ ' || h(trunc_text(cr->>'title', 45)) || ': ' || fa(r.av) || '/' || fa((cr->>'points')::numeric) ||
           CASE WHEN r.av IS NOT NULL AND r.av < (cr->>'points')::numeric * 0.5 THEN ' 🔻' ELSE '' END || E'\n';
    END LOOP;
  END IF;

  t := t || E'\n<b>نمره‌ها:</b>\n';
  FOR r IN SELECT u.full_name, u.student_no, s.status, coalesce(s.final_score, s.ai_score) AS sc, s.needs_review
             FROM enrollments e JOIN users u ON u.id = e.student_id
             LEFT JOIN submissions s ON s.assignment_id = a.id AND s.student_id = u.id
            WHERE e.class_id = a.class_id
            ORDER BY coalesce(s.final_score, s.ai_score) DESC NULLS LAST, u.full_name LOOP
    IF r.status IS NULL OR r.status = 'draft' THEN
      nm := nm + 1;
      IF nm <= 30 THEN miss := miss || '• ' || h(r.full_name) || E'\n'; END IF;
      CONTINUE;
    END IF;
    i := i + 1;
    IF i <= 50 THEN
      t := t || fa(i::text) || '. ' || h(r.full_name) || ' — ' ||
           CASE WHEN r.status IN ('graded','released') THEN '<b>' || fa(r.sc) || '</b>' ||
                     CASE WHEN r.status = 'graded' THEN ' 🟡' ELSE '' END || CASE WHEN r.needs_review THEN ' 🔎' ELSE '' END
                ELSE status_label(r.status) END || E'\n';
    END IF;
  END LOOP;
  IF i > 50 THEN t := t || E'… (فهرست کامل در فایل اکسل)\n'; END IF;
  IF nm > 0 THEN t := t || E'\n<b>ارسال نکرده‌اند:</b>\n' || miss || CASE WHEN nm > 30 THEN E'…\n' ELSE '' END; END IF;
  t := t || E'\n🟡 منتظر تأیید  🔎 نیازمند بررسی';
  RETURN t;
END $$;

-- Excel rows: {"file_name":..., "columns":[...], "rows":[[...],...]}
CREATE OR REPLACE FUNCTION report_rows(aid int) RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE a assignments; c classes; cols jsonb; rows jsonb := '[]'; r record; row jsonb; cr jsonb; sc jsonb; i int := 0;
BEGIN
  SELECT * INTO a FROM assignments WHERE id = aid;
  SELECT * INTO c FROM classes WHERE id = a.class_id;
  cols := '["ردیف","نام و نام خانوادگی","شماره دانشجویی","وضعیت","زمان ارسال"]'::jsonb;
  FOR cr IN SELECT * FROM jsonb_array_elements(a.checklist->'criteria') LOOP
    cols := cols || to_jsonb(format('معیار %s: %s (%s)', cr->>'id', trunc_text(cr->>'title', 40), cr->>'points'));
  END LOOP;
  cols := cols || '["کسر نمره","نمره AI","نمره نهایی","ویرایش استاد","نیاز به بررسی","دلیل بررسی","بازخورد"]'::jsonb;

  FOR r IN SELECT u.full_name, u.student_no, s.*
             FROM enrollments e JOIN users u ON u.id = e.student_id
             LEFT JOIN submissions s ON s.assignment_id = a.id AND s.student_id = u.id
            WHERE e.class_id = a.class_id ORDER BY u.full_name LOOP
    i := i + 1;
    row := jsonb_build_array(i, r.full_name, coalesce(r.student_no, ''),
             regexp_replace(status_label(r.status), '^\S+\s', ''),
             CASE WHEN r.submitted_at IS NULL THEN '' ELSE translate(jalali(r.submitted_at), '۰۱۲۳۴۵۶۷۸۹', '0123456789') END);
    FOR cr IN SELECT * FROM jsonb_array_elements(a.checklist->'criteria') LOOP
      sc := NULL;
      IF r.ai_result IS NOT NULL THEN
        SELECT x INTO sc FROM jsonb_array_elements(r.ai_result->'criteria') x WHERE (x->>'id')::int = (cr->>'id')::int LIMIT 1;
      END IF;
      row := row || jsonb_build_array(CASE WHEN sc IS NULL THEN NULL ELSE (sc->>'score')::numeric END);
    END LOOP;
    row := row || jsonb_build_array(
      (SELECT sum((d->>'points')::numeric) FROM jsonb_array_elements(coalesce(r.ai_result->'deductions','[]')) d),
      r.ai_score,
      CASE WHEN r.status IN ('graded','released') THEN coalesce(r.final_score, r.ai_score) END,
      CASE WHEN r.teacher_edited THEN 'بله' ELSE '' END,
      CASE WHEN r.needs_review THEN 'بله' ELSE '' END,
      coalesce(r.ai_result->>'review_reason', ''),
      coalesce(r.ai_result->>'overall_feedback', ''));
    rows := rows || jsonb_build_array(row);
  END LOOP;
  RETURN jsonb_build_object(
    'file_name', regexp_replace(format('report_%s_session%s', c.join_code, a.session_no), '[^A-Za-z0-9_]', '', 'g') || '.xlsx',
    'caption', format('📥 گزارش جلسه %s: %s — %s', a.session_no, a.title, c.name),
    'columns', cols, 'rows', rows);
END $$;

-- ---------------------------------------------------------------- scheduler
CREATE OR REPLACE FUNCTION close_due_assignments() RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE a assignments; t users; acts jsonb := '[]';
BEGIN
  FOR a IN UPDATE assignments SET status = 'closed'
            WHERE status = 'open' AND deadline <= now() RETURNING * LOOP
    SELECT tu.* INTO t FROM classes c JOIN users tu ON tu.id = c.teacher_id WHERE c.id = a.class_id;
    acts := acts || jsonb_build_array(send(t.chat_id,
      E'⏰ <b>مهلت تکلیف تمام شد</b>\n\n' || report_text(a.id),
      jsonb_build_array(jsonb_build_array(btn('📥 خروجی اکسل', 'tax:' || a.id), btn('👀 مدیریت تکلیف', 'ta:' || a.id)))));
    UPDATE assignments SET closed_notified = true WHERE id = a.id;
  END LOOP;
  RETURN acts;
END $$;

CREATE OR REPLACE FUNCTION scheduler_tick() RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE acts jsonb := '[]'; a assignments; r record; sid int;
BEGIN
  -- 1) reminders before deadline (24h before, or 1/3 of the window for short assignments)
  FOR a IN SELECT * FROM assignments
            WHERE status = 'open' AND NOT reminded AND deadline > now()
              AND now() >= deadline - least(interval '24 hours', (deadline - created_at) / 3) LOOP
    FOR r IN SELECT u.chat_id, s.status
               FROM enrollments e JOIN users u ON u.id = e.student_id
               LEFT JOIN submissions s ON s.assignment_id = a.id AND s.student_id = u.id
              WHERE e.class_id = a.class_id AND (s.status IS NULL OR s.status = 'draft') LOOP
      acts := acts || jsonb_build_array(send(r.chat_id,
        '⏰ <b>یادآوری:</b> ' || remain_text(a.deadline) || ' تا پایان مهلت تکلیف «' || h(a.title) || '» مانده.' ||
        CASE WHEN r.status = 'draft' THEN E'\n📝 پیش‌نویس داری ولی هنوز «ارسال نهایی» نکردی!' ELSE '' END,
        back_kb('sa:' || a.id, '📤 رفتن به تکلیف')));
    END LOOP;
    UPDATE assignments SET reminded = true WHERE id = a.id;
  END LOOP;

  -- 2) close assignments whose deadline passed + send teacher the report
  acts := acts || close_due_assignments();

  -- 3) submissions stuck in "grading" after 3 attempts -> failed
  FOR sid IN SELECT id FROM submissions WHERE status = 'grading' AND attempts >= 3
              AND grading_started_at < now() - interval '15 minutes' LOOP
    acts := acts || grading_fail(sid, 'Timeout: grading did not finish');
  END LOOP;

  -- 4) housekeeping
  DELETE FROM processed_updates WHERE at < now() - interval '3 days';
  RETURN acts;
END $$;

-- Single entry for n8n: ok=true -> save, ok=false -> fail
CREATE OR REPLACE FUNCTION grading_result(res jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
  IF coalesce((res->>'ok')::boolean, false) THEN RETURN grading_save(res); END IF;
  RETURN grading_fail((res->>'submission_id')::int, coalesce(res->>'error', 'unknown error'));
END $$;
