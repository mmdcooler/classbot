// Mock Telegram Bot API + OpenRouter for local end-to-end tests of the n8n workflows.
const http = require('http');
const fs = require('fs');
const LOG = process.argv[2] || 'calls.jsonl';
const files = { DOCX1: (()=>{try{return fs.readFileSync(process.env.DOCX_FIXTURE)}catch(e){return Buffer.alloc(0)}})(), DOC1: Buffer.from('def mx(a):\n    return max(a)\n'), PH1: Buffer.from([0xff, 0xd8, 0xff, 0xe0]) };

http.createServer((req, res) => {
  let body = [];
  req.on('data', (c) => body.push(c));
  req.on('end', () => {
    body = Buffer.concat(body);
    const url = new URL(req.url, 'http://x');
    const rec = { at: Date.now(), method: req.method, path: url.pathname, ctype: req.headers['content-type'] || '', auth: req.headers.authorization || '' };
    const send = (o, code = 200) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(o)); };

    if (url.pathname.startsWith('/file/')) {
      const id = url.pathname.split('/').pop();
      fs.appendFileSync(LOG, JSON.stringify({ ...rec, kind: 'download', id }) + '\n');
      res.writeHead(200); return res.end(files[id] || Buffer.alloc(0));
    }
    if (url.pathname.endsWith('/getFile')) {
      const id = url.searchParams.get('file_id');
      return send({ ok: true, result: { file_id: id, file_path: `x/${id}` } });
    }
    if (url.pathname === '/api/v1/chat/completions') {
      const j = JSON.parse(body.toString());
      fs.appendFileSync(LOG, JSON.stringify({ ...rec, kind: 'ai', models: j.models || j.model,
        blocks: j.messages[1].content.map((b) => b.type), text: j.messages[1].content.filter((b) => b.type === 'text').map((b) => b.text).join('\n').slice(0, 3000) }) + '\n');
      return send({ id: 'x', model: 'mock/model', choices: [{ message: { role: 'assistant', content: JSON.stringify({
        criteria: [{ id: 1, score: 3.5, comment: 'ورودی/خروجی را خوب توضیح دادی' }, { id: 2, score: 8, comment: 'کد درست است' },
                   { id: 3, score: 2, comment: 'تحلیل حافظه نیامده' }, { id: 4, score: 2, comment: '' }, { id: 5, score: 1, comment: 'گزارش کوتاه بود' }],
        deductions: [], overall_feedback: 'کارت خوب بود؛ تحلیل حافظه رو اضافه کن.', needs_review: false, review_reason: '', confidence: 0.9 }) } }],
        usage: { prompt_tokens: 100, completion_tokens: 50 } });
    }
    // Telegram methods
    const method = url.pathname.split('/').pop();
    let payload = null;
    if (rec.ctype.includes('json')) payload = JSON.parse(body.toString() || '{}');
    fs.appendFileSync(LOG, JSON.stringify({ ...rec, kind: 'tg', tgMethod: method, payload, size: body.length,
      multipartHasXlsx: rec.ctype.includes('multipart') ? body.includes(Buffer.from('PK')) : undefined }) + '\n');
    send({ ok: true, result: { message_id: 1 } });
  });
}).listen(8081, () => console.log('mock on 8081'));
