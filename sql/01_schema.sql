-- =====================================================================
--  ClassBot (ربات تکالیف کلاس) — Database schema
--  PostgreSQL 14+
-- =====================================================================
SET client_min_messages = warning;

CREATE TABLE IF NOT EXISTS settings (
  key   text PRIMARY KEY,
  value text NOT NULL
);

INSERT INTO settings(key, value) VALUES
  ('bot_username',      'YOUR_BOT_USERNAME'),          -- بدون @
  ('ai_model',          'google/gemini-2.5-flash'),     -- مدل اصلی OpenRouter (باید تصویر و PDF بخواند)
  ('ai_fallback_model', 'openai/gpt-4o-mini'),          -- مدل پشتیبان
  ('max_file_mb',       '20'),                          -- سقف دانلود فایل ربات تلگرام ۲۰ مگابایت است
  ('max_parts',         '10')                           -- حداکثر تعداد بخش (پیام/فایل) در هر ارسال
ON CONFLICT (key) DO NOTHING;

CREATE TABLE IF NOT EXISTS users (
  id             bigint PRIMARY KEY,                    -- Telegram user id
  chat_id        bigint NOT NULL,
  username       text,
  tg_name        text,
  full_name      text,
  student_no     text,
  is_admin       boolean NOT NULL DEFAULT false,
  teacher_status text CHECK (teacher_status IN ('pending','approved','rejected')),
  state          text,
  state_data     jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at     timestamptz NOT NULL DEFAULT now(),
  last_seen      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS classes (
  id           serial PRIMARY KEY,
  teacher_id   bigint NOT NULL REFERENCES users(id),
  name         text NOT NULL,
  join_code    text NOT NULL UNIQUE,
  auto_release boolean NOT NULL DEFAULT false,          -- true: نمره مستقیم برای دانشجو / false: اول تأیید استاد
  archived     boolean NOT NULL DEFAULT false,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS classes_teacher_idx ON classes(teacher_id);

CREATE TABLE IF NOT EXISTS enrollments (
  class_id   int    NOT NULL REFERENCES classes(id) ON DELETE CASCADE,
  student_id bigint NOT NULL REFERENCES users(id),
  joined_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (class_id, student_id)
);

CREATE TABLE IF NOT EXISTS assignments (
  id               serial PRIMARY KEY,
  class_id         int NOT NULL REFERENCES classes(id) ON DELETE CASCADE,
  session_no       int NOT NULL,
  title            text NOT NULL,
  description      text,
  attach_file_id   text,
  attach_kind      text,                                  -- document | photo
  checklist_raw    text NOT NULL,
  checklist        jsonb NOT NULL,                        -- {total, criteria:[{id,title,points,detail}], rules:[], reference}
  total_score      numeric NOT NULL,
  deadline         timestamptz NOT NULL,
  status           text NOT NULL DEFAULT 'open' CHECK (status IN ('open','closed')),
  reminded         boolean NOT NULL DEFAULT false,
  closed_notified  boolean NOT NULL DEFAULT false,
  created_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (class_id, session_no)                           -- هر جلسه فقط یک تکلیف
);

CREATE TABLE IF NOT EXISTS submissions (
  id                 serial PRIMARY KEY,
  assignment_id      int    NOT NULL REFERENCES assignments(id) ON DELETE CASCADE,
  student_id         bigint NOT NULL REFERENCES users(id),
  status             text   NOT NULL DEFAULT 'draft'
                     CHECK (status IN ('draft','pending','grading','graded','released','failed')),
  submitted_at       timestamptz,
  grading_started_at timestamptz,
  attempts           int NOT NULL DEFAULT 0,
  ai_result          jsonb,
  ai_score           numeric,
  final_score        numeric,
  needs_review       boolean NOT NULL DEFAULT false,
  teacher_edited     boolean NOT NULL DEFAULT false,
  last_error         text,
  graded_at          timestamptz,
  released_at        timestamptz,
  created_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (assignment_id, student_id)                       -- هر دانشجو یک ارسال برای هر تکلیف
);
CREATE INDEX IF NOT EXISTS submissions_status_idx ON submissions(status);

CREATE TABLE IF NOT EXISTS submission_parts (
  id            serial PRIMARY KEY,
  submission_id int NOT NULL REFERENCES submissions(id) ON DELETE CASCADE,
  kind          text NOT NULL CHECK (kind IN ('text','document','photo')),
  text          text,
  file_id       text,
  file_name     text,
  mime          text,
  file_size     bigint,
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS parts_sub_idx ON submission_parts(submission_id);

-- جلوگیری از پردازش دوباره‌ی یک آپدیت (تلگرام در صورت خطا آپدیت را دوباره می‌فرستد)
CREATE TABLE IF NOT EXISTS processed_updates (
  update_id bigint PRIMARY KEY,
  at        timestamptz NOT NULL DEFAULT now()
);

-- v2: پاسخ‌نامه استاد (اختیاری) — متن و/یا فایل
ALTER TABLE assignments ADD COLUMN IF NOT EXISTS answer_text      text;
ALTER TABLE assignments ADD COLUMN IF NOT EXISTS answer_file_id   text;
ALTER TABLE assignments ADD COLUMN IF NOT EXISTS answer_kind      text;
ALTER TABLE assignments ADD COLUMN IF NOT EXISTS answer_file_name text;
ALTER TABLE assignments ADD COLUMN IF NOT EXISTS answer_mime      text;
