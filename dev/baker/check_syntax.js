// Compiles (doesn't run) every Lua file of the addon (and of the addons in addons/), to catch syntax errors before going in game.
//   node check_syntax.js
const fs = require('fs')
const path = require('path')
const { LuaFactory } = require('wasmoon')

const ADDON = path.resolve(__dirname, '..', '..')
const ROOT = path.join(ADDON, 'lua')
function walk(d) {
  return fs.readdirSync(d, { withFileTypes: true }).flatMap((e) =>
    e.isDirectory() ? walk(path.join(d, e.name)) : e.name.endsWith('.lua') ? [path.join(d, e.name)] : [])
}

;(async () => {
  const L = await new LuaFactory().createEngine()
  let bad = 0
  L.global.set('__bad', (name, err) => { bad++; console.log('FAIL', name, err) })
  const extra = fs.existsSync(path.join(ADDON, 'addons')) ? fs.readdirSync(path.join(ADDON, 'addons')).map((d) => path.join(ADDON, 'addons', d, 'lua')).filter((d) => fs.existsSync(d)) : []
  for (const f of [ROOT, ...extra].flatMap(walk)) {
    L.global.set('__src', fs.readFileSync(f, 'utf8'))
    L.global.set('__name', path.relative(ADDON, f))
    await L.doString('local fn, err = load(__src, "=" .. __name) if not fn then __bad(__name, err) end')
  }
  console.log(bad ? `${bad} file(s) failed` : 'all Lua files compile')
  process.exit(bad ? 1 : 0)
})()
