// Compiles (doesn't run) every Lua file of the addon, to catch syntax errors before going in game.
//   node check_syntax.js
const fs = require('fs')
const path = require('path')
const { LuaFactory } = require('wasmoon')

const ROOT = path.resolve(__dirname, '..', '..', 'lua')
function walk(d) {
  return fs.readdirSync(d, { withFileTypes: true }).flatMap((e) =>
    e.isDirectory() ? walk(path.join(d, e.name)) : e.name.endsWith('.lua') ? [path.join(d, e.name)] : [])
}

;(async () => {
  const L = await new LuaFactory().createEngine()
  let bad = 0
  L.global.set('__bad', (name, err) => { bad++; console.log('FAIL', name, err) })
  for (const f of walk(ROOT)) {
    L.global.set('__src', fs.readFileSync(f, 'utf8'))
    L.global.set('__name', path.relative(ROOT, f))
    await L.doString('local fn, err = load(__src, "=" .. __name) if not fn then __bad(__name, err) end')
  }
  console.log(bad ? `${bad} file(s) failed` : 'all Lua files compile')
  process.exit(bad ? 1 : 0)
})()
