"""Builds test copies of the workflows (webhook instead of Telegram Trigger, mock OpenRouter) + credentials."""
import json, pathlib, sys
root = pathlib.Path(__file__).resolve().parents[2]
out = pathlib.Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)

creds = [
  {"id": "tgcred000000001", "name": "ClassBot Telegram", "type": "telegramApi",
   "data": {"accessToken": "TEST", "baseUrl": "http://127.0.0.1:8081"}},
  {"id": "pgcred000000001", "name": "ClassBot Postgres", "type": "postgres",
   "data": {"host": "127.0.0.1", "port": 5433, "database": "classbot", "user": "postgres", "password": "test", "ssl": "disable", "allowUnauthorizedCerts": False, "sshTunnel": False}},
  {"id": "orcred000000001", "name": "OpenRouter Header Auth", "type": "httpHeaderAuth",
   "data": {"name": "Authorization", "value": "Bearer sk-or-test"}},
]
ids = {c["type"]: c["id"] for c in creds}
(out / "creds.json").write_text(json.dumps(creds))

for i, f in enumerate(sorted((root / "n8n/workflows").glob("*.json"))):
    wf = json.loads(f.read_text())
    wf["id"] = f"classbotwf{i}000000"[:16]
    for n in wf["nodes"]:
        for t, c in n.get("credentials", {}).items():
            c["id"] = ids[t]
        if n["type"] == "n8n-nodes-base.telegramTrigger":
            n.update(type="n8n-nodes-base.webhook", typeVersion=2, credentials={},
                     parameters={"httpMethod": "POST", "path": "tg", "options": {}})
            n["webhookId"] = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        if n["name"] == "Encode update":
            n["parameters"]["jsCode"] = n["parameters"]["jsCode"].replace("JSON.stringify(i.json)", "JSON.stringify(i.json.body)")
        if n["name"] == "OpenRouter":
            n["parameters"]["url"] = "http://127.0.0.1:8081/api/v1/chat/completions"
    (out / f.name).write_text(json.dumps(wf, ensure_ascii=False))
print("ok", list(p.name for p in out.iterdir()))
