// n8n Code node — "Parse AI result"   (Mode: Run Once for Each Item)
// Input:  OpenRouter response (or error item from HTTP node with "continue on fail")
// Output: { b64 } -> base64 JSON for SELECT grading_result(...)
const meta = $('Build AI request').item.json.meta;
const sid = meta.submission_id;
const out = (obj) => ({ json: { b64: Buffer.from(JSON.stringify({ submission_id: sid, ...obj })).toString('base64') } });
const fail = (error) => out({ ok: false, error: String(error).slice(0, 1500) });

const r = $json;
if (r.error) return fail('AI request error: ' + (typeof r.error === 'string' ? r.error : JSON.stringify(r.error)));
const msg = r.choices && r.choices[0] && r.choices[0].message;
if (!msg || !msg.content) return fail('Empty AI response: ' + JSON.stringify(r).slice(0, 500));

// content can be a string or array of blocks
let text = Array.isArray(msg.content) ? msg.content.map((b) => b.text || '').join('') : String(msg.content);
text = text.replace(/^\s*```(?:json)?/i, '').replace(/```\s*$/, '').trim();
let ai;
try { ai = JSON.parse(text); }
catch (e) {
  const m = text.match(/\{[\s\S]*\}/);
  if (!m) return fail('AI did not return JSON: ' + text.slice(0, 300));
  try { ai = JSON.parse(m[0]); } catch (e2) { return fail('Invalid JSON from AI: ' + text.slice(0, 300)); }
}

const num = (v) => { const n = Number(String(v ?? '').replace(/[^\d.\-]/g, '')); return Number.isFinite(n) ? n : NaN; };
const q = (x) => Math.round(x * 4) / 4;            // 0.25 steps
const cl = meta.checklist;
let needsReview = ai.needs_review === true || ai.needs_review === 'true';
const reasons = [];
if (ai.review_reason) reasons.push(String(ai.review_reason));

const given = Array.isArray(ai.criteria) ? ai.criteria : [];
let sum = 0;
const criteria = cl.criteria.map((c) => {
  const max = Number(c.points);
  const g = given.find((x) => Number(x.id) === Number(c.id));
  let score = g ? num(g.score) : NaN;
  if (!Number.isFinite(score)) { needsReview = true; reasons.push(`معیار ${c.id} بدون نمره بود`); score = 0; }
  score = Math.min(Math.max(q(score), 0), max);
  sum += score;
  return { id: c.id, score, comment: g && g.comment ? String(g.comment).slice(0, 600) : '' };
});

const deductions = (Array.isArray(ai.deductions) ? ai.deductions : [])
  .map((d) => ({ reason: String(d.reason || '').slice(0, 300), points: Math.abs(num(d.points)) }))
  .filter((d) => Number.isFinite(d.points) && d.points > 0)
  .map((d) => ({ ...d, points: q(d.points) }));
const dedSum = deductions.reduce((s, d) => s + d.points, 0);

const total = Number(meta.total);
const critSum = Number(cl.criteria_sum) || cl.criteria.reduce((s, c) => s + Number(c.points), 0);
let score = critSum > 0 ? (sum / critSum) * total : 0;
score = Math.min(Math.max(q(score - dedSum), 0), total);

let confidence = num(ai.confidence);
if (!Number.isFinite(confidence)) confidence = 0.5;
confidence = Math.min(Math.max(confidence, 0), 1);
if (confidence < 0.5) { needsReview = true; reasons.push('اطمینان پایین هوش مصنوعی'); }

return out({
  ok: true,
  ai_score: score,
  criteria,
  deductions,
  overall_feedback: String(ai.overall_feedback || '').slice(0, 1500),
  needs_review: needsReview,
  review_reason: [...new Set(reasons)].join(' — ').slice(0, 500),
  confidence,
  model: r.model || null,
  usage: r.usage || null,
});
