import base64, html, os, sys
W = "/tmp/claude-0/-home-claude/32c57015-d001-5e0a-9afe-9d1dab07eb75/scratchpad/wm/node_modules/wasmoon/dist/"
A = "/home/claude/addon/sl65amg_rtu/lua/audio_engine/"
wasmoon = open(W + "index.js").read()
a = "function Ta(a,b){var c=M;return "
assert wasmoon.count(a) == 1
# hand emscripten the embedded wasm bytes instead of letting it fetch glue.wasm
wasmoon = wasmoon.replace(a, "function Ta(a,b){var c=M;if(globalThis.__WASMOON_BINARY)return WebAssembly.instantiate(globalThis.__WASMOON_BINARY,a).then(b);return ", 1)
wasm = base64.b64encode(open(W + "glue.wasm", "rb").read()).decode()
host = open("host.js").read()
files = [("gmod_shim.lua", open("gmod_shim.lua").read())]
for n in ["sh_config", "sh_presets", "sh_drivetrain", "cl_synth", "cl_soundbank", "cl_engine"]:
    files.append((n + ".lua", open(A + n + ".lua").read()))
files.append(("bridge.lua", open("bridge.lua").read()))
blocks = []
for name, src in files:
    assert "</script" not in src.lower(), name
    blocks.append(f'<script type="text/x-lua" data-name="{name}">{src}</script>')
t = open("template.html").read()
for k, v in [("{{WASM_B64}}", wasm), ("{{LUA_FILES}}", "\n".join(blocks)), ("{{WASMOON}}", wasmoon), ("{{HOST}}", host)]:
    assert k in t, k
    t = t.replace(k, v)
out = sys.argv[1] if len(sys.argv) > 1 else "rev_bench.html"
open(out, "w").write(t)
print(out, len(t) // 1024, "KB")
