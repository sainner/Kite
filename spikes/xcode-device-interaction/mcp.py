#!/usr/bin/env python3 -I
"""对 Xcode 的 MCP（xcrun mcpbridge）发一串请求：先 initialize，再按参数调工具，打印每步耗时和结果。
用法：mcp.py list                       列出工具
      mcp.py call <工具名> '<JSON 参数>' [<工具名> '<JSON 参数>' ...]   依次调用，结果里的 {{上一步字段}} 可引用前面结果的同名字段
"""
import json, subprocess, sys, time, re, os

started = time.time()
def log(text):
    sys.stderr.write(f"[{time.time() - started:7.3f}] {text}\n"); sys.stderr.flush()

proc = subprocess.Popen(["xcrun", "mcpbridge"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=sys.stderr, text=True, bufsize=1,
                        env={"PATH": "/usr/bin:/bin", "HOME": os.environ["HOME"], "MCP_XCODE_SESSION_ID": os.environ.get("MCP_XCODE_SESSION_ID", "")} if os.environ.get("MCP_XCODE_SESSION_ID") else {"PATH": "/usr/bin:/bin", "HOME": os.environ["HOME"]})
next_id = 0
def request(method, params=None, timeout=600):
    global next_id
    next_id += 1
    message = {"jsonrpc": "2.0", "id": next_id, "method": method}
    if params is not None: message["params"] = params
    proc.stdin.write(json.dumps(message) + "\n"); proc.stdin.flush()
    while True:
        line = proc.stdout.readline()
        if not line: raise SystemExit("mcpbridge 退出了")
        reply = json.loads(line)
        if reply.get("id") == next_id: return reply
        log(f"通知：{line.strip()[:300]}")

def notify(method, params=None):
    proc.stdin.write(json.dumps({"jsonrpc": "2.0", "method": method, **({"params": params} if params else {})}) + "\n"); proc.stdin.flush()

t = time.time()
init = request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "kite-spike", "version": "0"}})
log(f"initialize {time.time() - t:.2f}s：{json.dumps(init)[:400]}")
notify("notifications/initialized")

if sys.argv[1] == "list":
    t = time.time()
    tools = request("tools/list")
    log(f"tools/list {time.time() - t:.2f}s")
    for tool in tools.get("result", {}).get("tools", []):
        print(f"== {tool['name']}\n{tool.get('description', '')[:600]}\n参数：{json.dumps(tool.get('inputSchema', {}).get('properties', {}), ensure_ascii=False)[:800]}\n")
    if "error" in tools: print(tools["error"])
else:
    memory = {}
    args = sys.argv[2:]
    for name, raw in zip(args[0::2], args[1::2]):
        raw = re.sub(r"\{\{(\w+)\}\}", lambda m: str(memory.get(m.group(1), "")), raw)
        t = time.time()
        reply = request("tools/call", {"name": name, "arguments": json.loads(raw)})
        took = time.time() - t
        result = reply.get("result", reply.get("error"))
        text = json.dumps(result, ensure_ascii=False)
        log(f"{name} {took:.2f}s：{text[:1500]}")
        for item in (result or {}).get("content", []) if isinstance(result, dict) else []:
            if item.get("type") == "text":
                try:
                    data = json.loads(item["text"])
                    if isinstance(data, dict): memory.update(data)
                except Exception: pass
        sc = (result or {}).get("structuredContent") if isinstance(result, dict) else None
        if isinstance(sc, dict): memory.update(sc)
proc.stdin.close()
proc.wait(timeout=10)
