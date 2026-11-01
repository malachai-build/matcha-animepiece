# Minimal client for the local Matcha MCP server (use when the session connector is down).
# Usage: python -I tools/matcha_mcp.py list | instructions | <tool> [json-args] [arg-name file]
#   e.g. python -I tools/matcha_mcp.py matcha_exec "{}" code probe.lua
import sys, io, json, urllib.request
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
URL="http://127.0.0.1:8765/mcp"
def post(body, sid=None):
    h={"Content-Type":"application/json","Accept":"application/json, text/event-stream"}
    if sid: h["mcp-session-id"]=sid
    r=urllib.request.urlopen(urllib.request.Request(URL,json.dumps(body).encode(),h),timeout=120)
    raw=r.read().decode("utf-8","replace"); s=r.headers.get("mcp-session-id")
    if raw.startswith("event:") or raw.startswith("data:"):
        raw="\n".join(l[5:] for l in raw.splitlines() if l.startswith("data:"))
    return (json.loads(raw) if raw.strip() else None), s
init,sid=post({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"cc","version":"1"}}})
try: post({"jsonrpc":"2.0","method":"notifications/initialized"},sid)
except Exception: pass
mode=sys.argv[1]
if mode=="instructions": print(init["result"].get("instructions",""))
elif mode=="list":
    res,_=post({"jsonrpc":"2.0","id":2,"method":"tools/list"},sid)
    for t in res["result"]["tools"]: print(t["name"],"-",t.get("description","")[:300].replace("\n"," "),"\n   args:",json.dumps(t.get("inputSchema",{}).get("properties",{}))[:400])
else:
    args=json.loads(sys.argv[2]) if len(sys.argv)>2 else {}
    if len(sys.argv)>3: args[sys.argv[3]]=open(sys.argv[4],encoding="utf-8").read()
    res,_=post({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":mode,"arguments":args}},sid)
    if "error" in res: print("ERROR",res["error"]); sys.exit()
    for c in res["result"].get("content",[]):
        print(c.get("text",c))
