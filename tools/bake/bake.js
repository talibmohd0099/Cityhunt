// Exports the city, textures, data and characters from the browser game into godot/assets/baked/.
// Usage: cd tools/bake && npm install && node bake.js
// Needs Playwright with a Chromium build (PLAYWRIGHT_PATH can point at the playwright package).
const fs = require('fs'), path = require('path');
const { chromium } = require(process.env.PLAYWRIGHT_PATH || '/opt/node22/lib/node_modules/playwright');
const ROOT = path.resolve(__dirname, '..', '..');
const OUT = path.join(ROOT, 'godot', 'assets', 'baked');
const THREE_DIR = path.join(__dirname, 'node_modules', 'three');

const EXPOSE = `window.LC={__bake:{scene,renderer,camera,COL,SLABS,INTERIORS,UNDER,HOLE,LAMPS,HALOS,BLINK,STREAKS,STREAKS_N,POOLS,CONES,HIDES,FACES,CLUESPOTS,TREES,CARS,ALARMS,VSLOTS,EXITS,NODES,LOCS,STARTS,NEONS,
  XS,ZS,XW,ZW,BOUND,EXT,TXT,WX_STATES,WX_MSG,FAC,STORE,ASPH,CONC,TILE,GRASS,poolTex,glowTex,streakTex,printTex,
  matBuild,matStore,matGround,matSlab,matMark,matProps,matGlow,matTile,matGrass,concMat,matCarP,matCarT,FB_MESH,skyline,
  RP,RC,RB,RIG,shedLamp,aptLamp,roomLamp,rigRetarget},`;

(async () => {
  let html = fs.readFileSync(path.join(ROOT, 'index.html'), 'utf8');
  if (!html.includes('window.LC={')) throw new Error('test hook not found in index.html');
  // getters, so the characters built after loading are picked up
  html = html.replace('window.LC={', EXPOSE.replace('RP,RC,RB,', 'get RP(){return RP},get RC(){return RC},get RB(){return RB},'));
  html = html.replace('</body>', '<script src="http://t/_tools/GLTFExporter.js"></script><script src="http://t/_tools/BufferGeometryUtils.js"></script><script src="http://t/_tools/bake_page.js"></script></body>');

  const b = await chromium.launch({ args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const p = await b.newPage({ viewport: { width: 800, height: 450 } });
  await p.addInitScript(() => { window.__noAdapt = true; });
  p.on('pageerror', e => console.log('PAGEERR', e.message));
  p.on('console', m => { if (m.type() === 'error' && !m.text().includes('ERR_FAILED')) console.log('console', m.text().slice(0, 300)); });
  const ex = path.join(THREE_DIR, 'examples', 'js');
  await p.route('**/*', r => {
    const u = r.request().url();
    const send = (f, type) => r.fulfill({ body: fs.readFileSync(f), contentType: type || 'application/javascript' });
    if (u.includes('three.min.js')) return send(path.join(THREE_DIR, 'build', 'three.min.js'));
    if (u.includes('three@0.128.0/examples/js/')) return send(path.join(ex, u.split('/examples/js/')[1]));
    if (u === 'http://t/_tools/GLTFExporter.js') return send(path.join(ex, 'exporters', 'GLTFExporter.js'));
    if (u === 'http://t/_tools/BufferGeometryUtils.js') return send(path.join(ex, 'utils', 'BufferGeometryUtils.js'));
    if (u === 'http://t/_tools/bake_page.js') return send(path.join(__dirname, 'bake_page.js'));
    if (u === 'http://t/') return r.fulfill({ body: html, contentType: 'text/html' });
    if (u.startsWith('http://t/')) { const f = path.join(ROOT, decodeURIComponent(u.slice(9).split('?')[0])); return fs.existsSync(f) ? send(f, 'application/octet-stream') : r.abort(); }
    return r.abort();
  });
  await p.goto('http://t/');
  await p.waitForFunction(() => !document.getElementById('startBtn').disabled, null, { timeout: 120000 });
  await p.waitForFunction(() => window.LC && window.LC.__bake.RB && window.BAKE, null, { timeout: 60000 });
  console.log('game loaded, baking…');
  const list = await p.evaluate(() => window.BAKE());
  console.log((await p.evaluate(() => window.BAKE_LOG || [])).join('\n'));
  fs.mkdirSync(path.join(OUT, 'textures'), { recursive: true });
  for (const [name] of list) {
    const data = await p.evaluate(n => window.BAKE_OUT[n], name);
    const f = path.join(OUT, name); fs.mkdirSync(path.dirname(f), { recursive: true });
    fs.writeFileSync(f, Buffer.from(data, 'base64'));
    console.log(name.padEnd(28), (fs.statSync(f).size / 1024).toFixed(0).padStart(7), 'KB');
  }
  await b.close();
})().catch(e => { console.error(e); process.exit(1); });
