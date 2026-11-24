/*
  Tester content pack: the files a player needs to join a server running this addon, as a .gma
  to drop into garrysmod/addons/ (or a plain folder).

    node dev/package_testers.js [--with-sl65] [--folder] [--out <dir>] [--gmad <path to gmad.exe>]

  Players only need the content: the server sends all Lua itself (and the vehicle scripts are
  the server's alone). So the pack holds
    - sound/audio_engine/<folder>/ for every folder the bake manifest (lua/audio_engine/cl_baked.lua)
      names: an old bake's folder left on disk is not shipped (it's reported)
    - models/ and materials/ (the LED light bar and its repaintable textures)
    - with --with-sl65, the SL65 AMG RTU's model and materials (addons/sl65amg_rtu), for a test
      server that runs that addon too
  Nothing else: no lua/, scripts/, dev/ or notes.

  Output: dist/audio_engine_tester_content.gma (dist/ is gitignored). --folder leaves the folder
  instead (dist/audio_engine_tester_content/: copy it into garrysmod/addons/ as is).
  The staging folder is made of hard links where the disk allows it (no 190 MB copy written),
  then gmad (GarrysMod/bin/gmad.exe, found from this addon's place) packs it.
*/
const fs = require('fs')
const path = require('path')
const { execFileSync } = require('child_process')

const ADDON = path.resolve(__dirname, '..')
const args = process.argv.slice(2)
const flag = (name) => args.includes(name)
const option = (name, fallback) => {
  const index = args.indexOf(name)
  return index >= 0 && args[index + 1] ? args[index + 1] : fallback
}

const NAME = 'audio_engine_tester_content'
const OUT = path.resolve(option('--out', path.join(ADDON, 'dist')))
const STAGING = path.join(OUT, NAME)
const GMA = path.join(OUT, NAME + '.gma')
const GMAD = option('--gmad', path.resolve(ADDON, '..', '..', '..', 'bin', 'gmad.exe'))

// the file types gmad accepts in these folders (anything else would make it refuse the pack)
const CONTENT_TYPES = new Set(['.wav', '.mp3', '.ogg', '.mdl', '.vvd', '.vtx', '.phy', '.ani', '.vtf', '.vmt', '.png'])

let linked = 0, copied = 0, bytes = 0
function place(source, target) {
  fs.mkdirSync(path.dirname(target), { recursive: true })
  if (fs.existsSync(target)) fs.unlinkSync(target)
  bytes += fs.statSync(source).size
  try {
    fs.linkSync(source, target)
    linked++
  } catch (error) {
    fs.copyFileSync(source, target)
    copied++
  }
}

// every content file under root/relative (recursively) into the staging folder at the same path
function addTree(root, relative) {
  const directory = path.join(root, relative)
  if (!fs.existsSync(directory)) return 0
  let count = 0
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const entryPath = path.join(relative, entry.name)
    if (entry.isDirectory()) {
      count += addTree(root, entryPath)
    } else if (CONTENT_TYPES.has(path.extname(entry.name).toLowerCase())) {
      place(path.join(root, entryPath), path.join(STAGING, entryPath))
      count++
    } else {
      console.log(`  skipped ${entryPath.replace(/\\/g, '/')} (not a content file)`)
    }
  }
  return count
}

// a fresh staging folder (never anything but our own output)
if (fs.existsSync(STAGING)) fs.rmSync(STAGING, { recursive: true, force: true })
fs.mkdirSync(STAGING, { recursive: true })

// the baked engines the manifest uses
const manifest = fs.readFileSync(path.join(ADDON, 'lua', 'audio_engine', 'cl_baked.lua'), 'utf8')
const bakedFolders = new Set([...manifest.matchAll(/\bdir\s*=\s*"([^"]+)"/g)].map((match) => match[1]))
if (bakedFolders.size === 0) { console.error('no baked folders found in cl_baked.lua'); process.exit(1) }
const soundRoot = path.join('sound', 'audio_engine')
let soundFiles = 0
for (const entry of fs.readdirSync(path.join(ADDON, soundRoot), { withFileTypes: true })) {
  if (!entry.isDirectory()) continue
  if (!bakedFolders.has(entry.name)) { console.log(`  left out sound/audio_engine/${entry.name} (not in the bake manifest: an old bake)`); continue }
  soundFiles += addTree(ADDON, path.join(soundRoot, entry.name))
  bakedFolders.delete(entry.name)
}
if (bakedFolders.size > 0) {
  console.error(`the manifest names folders that aren't on disk: ${[...bakedFolders].join(', ')} (run the baker)`)
  process.exit(1)
}
const modelFiles = addTree(ADDON, 'models') + addTree(ADDON, 'materials')
let sl65Files = 0
if (flag('--with-sl65')) {
  const sl65 = path.join(ADDON, 'addons', 'sl65amg_rtu')
  sl65Files = addTree(sl65, 'models') + addTree(sl65, 'materials')
}

fs.writeFileSync(path.join(STAGING, 'addon.json'), JSON.stringify({
  title: 'Audio Engine - tester content',
  type: 'model',
  tags: ['realism'],
  ignore: [],
}, null, '\t') + '\n')

console.log(`${soundFiles} sound files, ${modelFiles} light bar model / material files` + (flag('--with-sl65') ? `, ${sl65Files} SL65 RTU files` : '') +
  ` (${(bytes / 1048576).toFixed(0)} MB; ${linked} hard-linked, ${copied} copied)`)

if (flag('--folder')) {
  console.log(`folder: ${STAGING}\n  testers copy it into garrysmod/addons/ and restart the game`)
  process.exit(0)
}
if (!fs.existsSync(GMAD)) {
  console.error(`gmad.exe not found at ${GMAD} (pass --gmad <path>, or --folder for a plain folder)`)
  process.exit(1)
}
if (fs.existsSync(GMA)) fs.unlinkSync(GMA)
execFileSync(GMAD, ['create', '-folder', STAGING, '-out', GMA, '-quiet'], { stdio: 'inherit' })
fs.rmSync(STAGING, { recursive: true, force: true })
console.log(`pack: ${GMA} (${(fs.statSync(GMA).size / 1048576).toFixed(0)} MB)\n  testers put it in garrysmod/addons/ and restart the game`)
