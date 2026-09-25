/* Runs inside the browser game after it has built the city and loaded the characters.
   Collects everything the Godot version needs into window.BAKE_OUT: { path: base64 or text }. */
(function(){
'use strict';
const V3=THREE.Vector3;
const b64=buf=>{ const u=new Uint8Array(buf); let s=''; for(let i=0;i<u.length;i+=0x8000) s+=String.fromCharCode.apply(null,u.subarray(i,i+0x8000)); return btoa(s); };
const png=img=>img.toDataURL('image/png').split(',')[1];
const r3=v=>Math.round(v*1000)/1000;
const col3=c=>[r3(c.r),r3(c.g),r3(c.b)];
const exportGLB=(obj,animations)=>new Promise(res=>new THREE.GLTFExporter().parse(obj,r=>res(b64(r)),{binary:true,animations:animations||[],onlyVisible:false,trs:true,embedImages:true,forceIndices:true}));

function staticGeo(src){
  // position, normal, uv, color only; welded so the file stays small
  const g=new THREE.BufferGeometry();
  const n=src.attributes.position.count;
  g.setAttribute('position',src.attributes.position.clone());
  if(src.attributes.normal) g.setAttribute('normal',src.attributes.normal.clone());
  g.setAttribute('uv',src.attributes.uv?src.attributes.uv.clone():new THREE.Float32BufferAttribute(new Float32Array(n*2),2));
  // three.js puts v=0 at the bottom of a texture, glTF and Godot at the top
  { const uv=g.attributes.uv; for(let i=0;i<n;i++) uv.setY(i,1-uv.getY(i)); }
  g.setAttribute('color',src.attributes.color?src.attributes.color.clone():new THREE.Float32BufferAttribute(new Float32Array(n*3).fill(1),3));
  const w=THREE.BufferGeometryUtils.mergeVertices(g,1e-4);
  return w;
}

window.BAKE=async function(){
  const B=LC.__bake, OUT={};
  /* ---------- textures ---------- */
  const T=(name,tex)=>{ OUT['textures/'+name+'.png']=png(tex.image); };
  T('facade',B.FAC.map); T('facade_emi',B.FAC.emi); T('store',B.STORE.map); T('store_emi',B.STORE.emi);
  T('asphalt',B.ASPH.map); T('asphalt_rough',B.ASPH.rough); T('concrete',B.CONC.map); T('concrete_rough',B.CONC.rough);
  T('tiles',B.TILE); T('grass',B.GRASS); T('pool',B.poolTex); T('glow',B.glowTex); T('streak',B.streakTex); T('print',B.printTex);
  // the environment picture used for reflections (same recipe as the game)
  { const c=document.createElement('canvas'); c.width=1024; c.height=512; const g=c.getContext('2d');
    const gr=g.createLinearGradient(0,0,0,512); gr.addColorStop(0,'#030405'); gr.addColorStop(.46,'#16161a'); gr.addColorStop(.5,'#2a2420'); gr.addColorStop(.54,'#0c0c0d'); gr.addColorStop(1,'#050505'); g.fillStyle=gr; g.fillRect(0,0,1024,512);
    for(let i=0;i<900;i++){ const y=200+Math.random()*60, x=Math.random()*1024; g.fillStyle=Math.random()<.8?`rgba(255,${170+Math.random()*60|0},90,${.3+Math.random()*.7})`:`rgba(170,200,255,${.4+Math.random()*.6})`; g.fillRect(x,y,1+Math.random()*2,1+Math.random()*3); }
    for(let i=0;i<40;i++){ const x=Math.random()*1024,y=225+Math.random()*30; const rg=g.createRadialGradient(x,y,0,x,y,18); rg.addColorStop(0,'rgba(255,180,100,.9)'); rg.addColorStop(1,'rgba(255,180,100,0)'); g.fillStyle=rg; g.fillRect(x-18,y-18,36,36); }
    OUT['textures/env.png']=png(c); }

  /* ---------- static city meshes ---------- */
  const role=new Map([[B.matGround,'ground'],[B.matSlab,'slab'],[B.matMark,'mark'],[B.matBuild,'build'],[B.matStore,'store'],[B.matProps,'props'],[B.matGlow,'glow'],
    [B.matTile,'tile'],[B.concMat,'conc'],[B.matGrass,'grass'],[B.matCarP,'car_paint'],[B.matCarT,'car_trim']]);
  const fb=new Set(B.FB_MESH.filter(Boolean));
  const city=new THREE.Scene(); const counts={};
  const addStatic=(name,geo)=>{ const m=new THREE.Mesh(staticGeo(geo),new THREE.MeshStandardMaterial({name,vertexColors:true})); m.name=name; city.add(m); };
  for(const o of B.scene.children){
    if(!o.isMesh||o.isInstancedMesh||o.isSkinnedMesh) continue;
    let r=role.get(o.material);
    if(r){ if(fb.has(o)) r='fb_'+r; counts[r]=(counts[r]||0)+1; addStatic(counts[r]>1?r+'_'+counts[r]:r,o.geometry); continue; }
    if(o===B.skyline){ addStatic('skyline',o.geometry); continue; }
    if(o.material&&o.material.isMeshBasicMaterial&&o.material.vertexColors&&o.material.fog===false){ addStatic(o.material.toneMapped===false?'tower_crown':'tower_spire',o.geometry); continue; }
  }
  OUT['city.glb']=await exportGLB(city);

  /* ---------- trees: one template + instance transforms ---------- */
  const inst=B.scene.children.filter(o=>o.isInstancedMesh);
  const leaves=inst.find(o=>o.material.alphaTest>0.4&&o.material.map);
  const trunk=inst.find(o=>o.material.color&&o.material.color.getHex()===0x1d1611);
  const core=inst.find(o=>o.material.color&&o.material.color.getHex()===0x0e150d);
  const treeScene=new THREE.Scene();
  for(const [name,im] of [['trunk',trunk],['leaves',leaves],['core',core]]){ const m=new THREE.Mesh(staticGeo(im.geometry),new THREE.MeshStandardMaterial({name,vertexColors:false})); m.name=name; treeScene.add(m); }
  OUT['tree.glb']=await exportGLB(treeScene);
  OUT['textures/leaf.png']=png(leaves.material.map.image);
  const mats=im=>{ const a=[]; for(let i=0;i<im.count;i++) a.push(Array.from(im.instanceMatrix.array.slice(i*16,i*16+16)).map(r3)); return a; };

  /* ---------- neon signs ---------- */
  const neons=B.NEONS.map((n,i)=>{ OUT['textures/neon_'+i+'.png']=png(n.m.material.map.image); const p=n.m.geometry.parameters;
    return {tex:'neon_'+i+'.png',w:p.width,h:p.height,pos:n.m.position.toArray().map(r3),rotY:r3(n.m.rotation.y),double:n.m.material.side===THREE.DoubleSide,mode:n.mode,lamp:B.LAMPS.indexOf(n.L)}; });

  /* ---------- data ---------- */
  const alarmIdx=a=>B.ALARMS.indexOf(a);
  const box=b=>b?{x0:b.x0,x1:b.x1,z0:b.z0,z1:b.z1}:null;
  const txt={}; for(const k in B.TXT){ txt[k]={}; for(const f in B.TXT[k]){ const v=B.TXT[k][f]; txt[k][f]=typeof v==='function'?v('{d}'):v; } }
  const data={
    version:1,
    XS:B.XS,ZS:B.ZS,XW:B.XW,ZW:B.ZW,BOUND:B.BOUND,EXT:B.EXT,HOLE:B.HOLE,
    col:B.COL.map(c=>[r3(c.x0),r3(c.x1),r3(c.y0),r3(c.y1),r3(c.z0),r3(c.z1),(c.los?1:0)|(c.cam?2:0)|(c.mon?4:0)|(c.small?8:0)]),
    slabs:B.SLABS.map(box), interiors:B.INTERIORS.map(r=>Object.assign(box(r),{ceil:r.ceil})), under:B.UNDER.map(box),
    lamps:B.LAMPS.map(L=>({p:[r3(L.x),r3(L.y),r3(L.z)],c:col3(L.color),i:L.intensity,r:L.range,kind:L.kind,flicker:L.flicker||0})),
    locLamps:{park:B.LAMPS.indexOf(B.shedLamp),apartment:B.LAMPS.indexOf(B.aptLamp),subroom:B.LAMPS.indexOf(B.roomLamp)},
    halos:B.HALOS.map(h=>[r3(h.x),r3(h.y),r3(h.z),r3(h.c.r),r3(h.c.g),r3(h.c.b),h.s]),
    blink:B.BLINK.map(b=>({i:b.idx,kind:b.kind,ph:r3(b.ph||0),alarm:b.car?alarmIdx(b.car):-1})),
    pools:B.POOLS.map(p=>[r3(p.x),r3(p.z),p.r,...col3(p.c)]),
    streaks:B.STREAKS.map(s=>[r3(s.x),r3(s.z),...col3(s.c)]),
    streaksN:B.STREAKS_N.map(s=>[r3(s.x),r3(s.z),...col3(s.c)]),
    cones:B.CONES.map(c=>[r3(c.x),r3(c.y),r3(c.z),c.h,c.r,c.cool?1:0]),
    neons,
    trees:{trunk:mats(trunk),leaves:mats(leaves),core:mats(core)},
    hides:B.HIDES.map(h=>[r3(h.x),r3(h.z)]),
    faces:B.FACES.map(f=>({x:r3(f.x),z:r3(f.z),nx:f.nx,nz:f.nz,w:r3(f.w),h:r3(f.h)})),
    cluespots:B.CLUESPOTS.map(s=>({x:r3(s.x),z:r3(s.z),alley:!!s.alley,park:!!s.park,under:!!s.under})),
    cars:B.CARS.map(c=>({x:r3(c.x),z:r3(c.z),alongX:!!c.alongX,type:c.type,ry:r3(c.ry||0)})),
    alarms:B.ALARMS.map(a=>({x:r3(a.x),z:r3(a.z),hx:r3(a.hx),hz:r3(a.hz)})),
    vslots:B.VSLOTS.map(s=>({vm:s.vm,x:r3(s.x),z:r3(s.z),ry:r3(s.ry),col:s.col.map(r3),type:s.type,lit:s.lit,flash:s.flash,ph:r3(s.ph),alarm:s.alarm,door:s.door})),
    nodes:B.NODES.map(n=>({x:n.x,z:n.z,n:n.n})),
    exits:B.EXITS, starts:B.STARTS,
    locs:B.LOCS.map(l=>({id:l.id,spot:l.spot,y:l.y,ent:l.ent,trail:l.trail,box:box(l.box)})),
    txt, wxStates:B.WX_STATES, wxMsg:B.WX_MSG
  };
  OUT['city.json']=btoa(unescape(encodeURIComponent(JSON.stringify(data))));

  /* ---------- characters ---------- */
  OUT['player.glb']=await bakePlayer(B);
  OUT['child.glb']=await bakeRig(B,B.RC,'child',[['idle',{idle:1}],['walk',{walk:1}],['run',{run:1}],['crouch_idle',{idle:1,sneak_pose:1}],['crouch_walk',{walk:1,sneak_pose:1}],['sad_idle',{idle:1,sad_pose:1}],['crouch_sad',{idle:1,sneak_pose:1,sad_pose:1}]]);
  OUT['beast.glb']=await bakeRig(B,B.RB,'beast',[['idle',{idle:1}],['walk',{walk:1}],['run',{run:1}]]);
  window.BAKE_OUT=OUT; return Object.keys(OUT).map(k=>[k,OUT[k].length]);
};

/* ---- GLSL helpers from the game's character shader, ported to JS so colors can be baked per vertex ---- */
const fract=x=>x-Math.floor(x);
function lcHash(x,y,z){ x=fract(x*0.3183099+0.1)*17; y=fract(y*0.3183099+0.1)*17; z=fract(z*0.3183099+0.1)*17; return fract(x*y*z*(x+y+z)); }
function lcNoise(x,y,z){ const ix=Math.floor(x),iy=Math.floor(y),iz=Math.floor(z); let fx=x-ix,fy=y-iy,fz=z-iz; fx=fx*fx*(3-2*fx); fy=fy*fy*(3-2*fy); fz=fz*fz*(3-2*fz);
  const L=(a,b,t)=>a+(b-a)*t, h=(a,b,c)=>lcHash(ix+a,iy+b,iz+c);
  return L(L(L(h(0,0,0),h(1,0,0),fx),L(h(0,1,0),h(1,1,0),fx),fy),L(L(h(0,0,1),h(1,0,1),fx),L(h(0,1,1),h(1,1,1),fx),fy),fz); }
const lcG=x=>Math.exp(-x*x);
const sstep=(a,b,v)=>{ const t=Math.min(1,Math.max(0,(v-a)/(b-a))); return t*t*(3-2*t); };
const stp=(e,v)=>v<e?0:1;
function bulk(kind,x,y,z){ const ax=Math.abs(x); const arm=ax>(kind==='beast'?0.17:0.19)&&y>1.3&&y<(kind==='beast'?1.58:1.57); let b=0;
  if(kind==='child'){ if((y>0.62&&y<1.52&&!arm)||(arm&&ax<0.64)) b=0.012+0.022*sstep(1.0,0.62,y); if(y<0.2) b=0.01; }
  else if(kind==='beast'){
    b+=0.075*lcG((y-1.38)/0.12)*sstep(0.02,-0.12,z)*(1-sstep(0.1,0.3,ax));
    b+=0.05*lcG((ax-0.2)/0.07)*lcG((y-1.43)/0.08);
    if(arm) b+=0.03*lcG((ax-0.5)/0.1)+0.018;
    b+=0.03*lcG((y-1.28)/0.1)*(1-sstep(0.15,0.3,ax))*stp(0,z);
    b+=0.024*lcG((y-0.75)/0.18);
    b-=0.012*lcG((y-1.05)/0.06);
    const sp=sstep(0.05,0,ax)*stp(z,-0.03)*stp(1,y)*stp(y,1.62);
    b+=sp*0.06*Math.pow(Math.abs(Math.sin(y*62)),6);
    b+=0.005*lcNoise(x*60,y*60,z*60)+0.003*lcNoise(x*160,y*160,z*160); }
  return b; }
function region(kind,x,y,z){ // returns [r,g,b,rough]
  const ax=Math.abs(x);
  if(kind==='child'){ const n=lcNoise(x*160,y*160,z*160), n2=lcNoise(x*10,y*10,z*10);
    let c=[0.03,0.05,0.12], r=0.8; if(y<0.2){ c=[0.35,0.02,0.02]; r=0.25; }
    const arm=ax>0.19&&y>1.3&&y<1.57;
    if((y>0.62&&y<1.52&&!arm)||(arm&&ax<0.66)){ const k=0.85+0.3*n2; c=[0.62*k,0.40*k,0.02*k]; r=0.28; }
    if(arm&&ax>=0.66){ c=[0.52,0.3,0.2]; r=0.55; }
    if(!arm&&y>=1.52){ c=[0.52,0.3,0.2]; r=0.5; if(y>1.66||(y>1.58&&z<0.03)){ c=[0.07,0.035,0.015]; r=0.45; } }
    const k=0.9+0.2*n; return [c[0]*k,c[1]*k,c[2]*k,r]; }
  // beast
  const n=lcNoise(x*38,y*38,z*38), n2=lcNoise(x*9,y*9,z*9), n3=lcNoise(x*120,y*120,z*120);
  const ridge=Math.abs(Math.sin(y*70+n2*6)); const t=n2*0.8+ridge*0.25;
  const k=(0.7+0.5*n3)*0.6; return [(0.012+(0.05-0.012)*t)*k,(0.012+(0.042-0.012)*t)*k,(0.014+(0.038-0.014)*t)*k,0.42+(0.85-0.42)*n*n2]; }
function bakeSurface(geo,kind,doBulk){
  const g=geo.clone(); const P=g.attributes.position, N=g.attributes.normal; const C=new Float32Array(P.count*4);
  for(let i=0;i<P.count;i++){ const x=P.getX(i),y=P.getY(i),z=P.getZ(i);
    const c=region(kind,x,y,z); C.set(c,i*4);
    if(doBulk&&N){ const b=bulk(kind,x,y,z); if(b){ let nx=N.getX(i),ny=N.getY(i),nz=N.getZ(i); const l=Math.hypot(nx,ny,nz)||1; P.setXYZ(i,x+nx/l*b,y+ny/l*b,z+nz/l*b); } } }
  g.setAttribute('color',new THREE.Float32BufferAttribute(C,4)); return g; }

/* ---- characters: rebuilt as one clean skeleton in metres ----
   The game's rigs carry quirks that only three.js tolerates: bones scaled by 100 under a 0.01 parent,
   and the imported player model has a copy of its skeleton per mesh. So each character is re-exported
   from what three.js actually draws: every joint's skinning matrix is sampled per frame, turned into a
   single unscaled skeleton, and the meshes are re-bound to it. Things hung on bones (the beast's head,
   the backpack, the torch) move to the matching new joint. */
const baseName=n=>n.replace(/_\d+$/,'');
function ortho(m){ const p=new V3(), q=new THREE.Quaternion(), s=new V3(); m.decompose(p,q,s); return new THREE.Matrix4().compose(p,q,new V3(1,1,1)); }
function skinMat(m,j){ return new THREE.Matrix4().multiplyMatrices(m.matrixWorld,m.bindMatrixInverse).multiply(m.skeleton.bones[j].matrixWorld).multiply(m.skeleton.boneInverses[j]).multiply(m.bindMatrix); }
async function cleanRig(R,kind,list,prep){
  const root=R.root; root.position.set(0,0,0); root.rotation.set(0,0,0); root.updateMatrixWorld(true);
  const skinned=[]; root.traverse(o=>{ if(o.isSkinnedMesh) skinned.push(o); });
  skinned.sort((a,b)=>b.skeleton.bones.length-a.skeleton.bones.length);
  // which mesh joint drives each named joint (the mesh with the most joints wins)
  // Each mesh's rest shape is its bind pose as three.js would draw it (M * bindMatrixInverse * bindMatrix).
  const restOf=new Map();
  for(const m of skinned){ const K=new THREE.Matrix4().multiplyMatrices(m.matrixWorld,m.bindMatrixInverse).multiply(m.bindMatrix);
    restOf.set(m,{k:Math.cbrt(Math.abs(K.determinant())),K,Ki:K.clone().invert()}); }
  const ref={};
  for(const m of skinned) m.skeleton.bones.forEach((b,j)=>{ const n=baseName(b.name); if(!ref[n]) ref[n]={m,j,Ki:restOf.get(m).Ki,K:restOf.get(m).K}; });
  // joint order and parents from the bone tree (outermost copy of each name)
  const order=[], parentOf={}, attach=[];
  root.traverse(o=>{
    if(o.isBone){ const n=baseName(o.name); if(!ref[n]||order.includes(n)) return; order.push(n);
      let p=o.parent; while(p&&!(p.isBone&&ref[baseName(p.name)]&&baseName(p.name)!==n)) p=p.parent; parentOf[n]=p?baseName(p.name):null; }
    else if(o.parent&&o.parent.isBone&&!o.isSkinnedMesh) attach.push(o); });
  // bind pose of each joint in world space, scale removed
  const Jr={}; for(const n of order){ const r=ref[n], m=r.m;
    Jr[n]=ortho(new THREE.Matrix4().multiplyMatrices(m.matrixWorld,m.bindMatrixInverse).multiply(m.skeleton.boneInverses[r.j].clone().invert())); }
  const jointNow=()=>{ root.updateMatrixWorld(true); const J={}; for(const n of order){ const r=ref[n]; J[n]=skinMat(r.m,r.j).multiply(r.Ki).multiply(Jr[n]); } return J; };
  const localOf=(J,n)=>parentOf[n]?J[parentOf[n]].clone().invert().multiply(J[n]):J[n].clone();
  // sample every clip into position / rotation / scale tracks per joint
  const clips=[];
  for(const [name,W] of list){
    const base=Object.keys(W).find(k=>!k.endsWith('_pose')); const drv=prep?R.driver:R;
    const dur=drv.act[base].getClip().duration, n=Math.max(2,Math.round(dur*30));
    const times=[], P={}, Q={}, S={};
    for(let f=0;f<=n;f++){ const t=f/n*dur; times.push(t);
      for(const k in drv.act){ const a=drv.act[k]; a.setEffectiveWeight(W[k]||0); a.time=k.endsWith('_pose')?0:t; }
      drv.mixer.update(0); if(prep) prep();
      const J=jointNow();
      for(const j of order){ const p=new V3(), q=new THREE.Quaternion(), s=new V3(); localOf(J,j).decompose(p,q,s);
        const pq=Q[j]; if(pq&&pq.length){ const L=pq.length; if(q.x*pq[L-4]+q.y*pq[L-3]+q.z*pq[L-2]+q.w*pq[L-1]<0) q.set(-q.x,-q.y,-q.z,-q.w); }
        (P[j]=P[j]||[]).push(p.x,p.y,p.z); (Q[j]=Q[j]||[]).push(q.x,q.y,q.z,q.w); (S[j]=S[j]||[]).push(s.x,s.y,s.z); } }
    const tracks=[];
    for(const j of order){ const bn=j;
      tracks.push(new THREE.VectorKeyframeTrack(bn+'.position',times,P[j]));
      tracks.push(new THREE.QuaternionKeyframeTrack(bn+'.quaternion',times,Q[j]));
      tracks.push(new THREE.VectorKeyframeTrack(bn+'.scale',times,S[j])); }
    clips.push(new THREE.AnimationClip(name,dur,tracks)); }
  // the new rig in its bind pose
  const out=new THREE.Group(); out.name=kind; const nb={};
  for(const n of order){ const b=new THREE.Bone(); b.name=n;
    const L=parentOf[n]?Jr[parentOf[n]].clone().invert().multiply(Jr[n]):Jr[n].clone(); L.decompose(b.position,b.quaternion,b.scale);
    (parentOf[n]?nb[parentOf[n]]:out).add(b); nb[n]=b; }
  out.updateMatrixWorld(true);
  const bones=order.map(n=>nb[n]), skel=new THREE.Skeleton(bones,order.map(n=>Jr[n].clone().invert()));
  for(const m of skinned){ const g=m.geometry.clone(); g.applyMatrix4(restOf.get(m).K);
    const si=g.attributes.skinIndex, sw=g.attributes.skinWeight, map=m.skeleton.bones.map(b=>order.indexOf(baseName(b.name)));
    const G4=['getX','getY','getZ','getW'], S4=['setX','setY','setZ','setW'];
    for(let i=0;i<si.count;i++) for(let c=0;c<4;c++){ const k=map[si[G4[c]](i)]; if(k<0){ sw[S4[c]](i,0); si[S4[c]](i,0); } else si[S4[c]](i,k); }
    const sm=new THREE.SkinnedMesh(g,m.material); sm.name=m.name; out.add(sm); sm.bind(skel,new THREE.Matrix4()); }
  // check: the new rig posed like the last sampled frame must draw the same as the original
  const J=jointNow();
  { for(const n of order){ const L=localOf(J,n); L.decompose(nb[n].position,nb[n].quaternion,nb[n].scale); } out.updateMatrixWorld(true);
    const st=[]; out.children.filter(c=>c.isSkinnedMesh).forEach((sm,k)=>{ const m=skinned[k]; let err=0, lo=new V3(1e9,1e9,1e9), hi=new V3(-1e9,-1e9,-1e9);
      for(let i=0;i<m.geometry.attributes.position.count;i+=7){ const a=m.boneTransform(i,new V3()).applyMatrix4(m.matrixWorld), b=sm.boneTransform(i,new V3()).applyMatrix4(sm.matrixWorld);
        err=Math.max(err,a.distanceTo(b)); lo.min(a); hi.max(a); }
      st.push(m.name+' err '+err.toFixed(4)+' box '+lo.toArray().map(r3)+' .. '+hi.toArray().map(r3)); });
    (window.BAKE_LOG=window.BAKE_LOG||[]).push(kind+' (rest scale '+skinned.map(m=>r3(restOf.get(m).k)).join(',')+'): '+st.join(' | '));
    for(const n of order){ const L=parentOf[n]?Jr[parentOf[n]].clone().invert().multiply(Jr[n]):Jr[n].clone(); L.decompose(nb[n].position,nb[n].quaternion,nb[n].scale); } out.updateMatrixWorld(true); }
  // bone attachments, placed where they sit now relative to their joint
  for(const o of attach){ let b=o.parent; while(b&&!(b.isBone&&ref[baseName(b.name)])) b=b.parent; if(!b) continue; const n=baseName(b.name);
    const A=J[n].clone().invert().multiply(o.matrixWorld); o.parent.remove(o); A.decompose(o.position,o.quaternion,o.scale); nb[n].add(o); }
  return exportGLB(out,clips);
}

async function bakeRig(B,R,kind,list){
  R.root.position.set(0,0,0); R.root.rotation.set(0,0,0); R.root.updateMatrixWorld(true);
  // swap the shader-painted materials for baked vertex colours
  R.root.traverse(o=>{ if(!o.isMesh) return; const m=[].concat(o.material)[0];
    if(o.isSkinnedMesh){ o.geometry=bakeSurface(o.geometry,kind,true); o.material=new THREE.MeshStandardMaterial({name:kind+'_skin',vertexColors:true,roughness:1}); }
    else if(m&&m.onBeforeCompile&&m.customProgramCacheKey&&String(m.customProgramCacheKey()).startsWith('lc_')){ o.geometry=bakeSurface(o.geometry,kind,false); o.material=new THREE.MeshStandardMaterial({name:kind+'_skin',vertexColors:true,roughness:1}); } });
  if(R.jaw) R.jaw.name='jaw';
  if(R.head) R.head.name='head';
  if(R.glows) R.glows.forEach((g,i)=>{ const e=new THREE.Object3D(); e.name='eye_glow_'+i; e.position.copy(g.position); g.parent.add(e); g.parent.remove(g); });
  return cleanRig(R,kind,list,null);
}

async function bakePlayer(B){
  const RP=B.RP, D=RP.driver;
  RP.root.position.set(0,0,0); RP.root.rotation.set(0,0,0); RP.root.updateMatrixWorld(true);
  D.root.position.set(0,0,0); D.root.rotation.set(0,0,0); D.root.updateMatrixWorld(true);
  // name the torch so the game can find it
  RP.bones.RightHand.children.forEach(o=>{ if(!o.isBone) o.name='torch'; });
  RP.bones.Spine2.children.forEach(o=>{ if(!o.isBone) o.name='pack'; });
  const list=[['idle',{idle:1}],['walk',{walk:1}],['run',{run:1}],['crouch_idle',{idle:1,sneak_pose:1}],['crouch_walk',{walk:1,sneak_pose:1}]];
  RP.driver=D;
  return cleanRig(RP,'player',list,()=>{ D.root.updateMatrixWorld(true); B.rigRetarget(RP,D); });
}
})();
