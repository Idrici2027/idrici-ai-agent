// Idrici 3D avatar: loads a .glb (embedded as base64 in avatar_model.js), renders it with
// three.js to an offscreen canvas. avatar.html draws that canvas into its glow pipeline.
// API used by avatar.html:  window.Avatar3D = { ready, canvas, setSize(w,h), update(t, S, tint) }
import * as THREE from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';

const api = { ready: false, canvas: null, setSize: function () {}, update: function () {} };
window.Avatar3D = api;

function b64ToBuf(b64) {
  const bin = atob(b64), n = bin.length, u = new Uint8Array(n);
  for (let i = 0; i < n; i++) { u[i] = bin.charCodeAt(i); }
  return u.buffer;
}

const MOUTH = ['jawOpen', 'mouthOpen', 'viseme_aa', 'aa', 'A'];
const BLINK = ['eyeBlinkLeft', 'eyeBlinkRight', 'eyesClosed', 'blink', 'Blink', 'blinkLeft', 'blinkRight'];
const HEAD_NAMES = ['Head', 'head', 'mixamorigHead', 'J_Bip_C_Head'];

(function init() {
  const b64 = window.AVATAR_GLB_B64;
  if (!b64) { return; }
  const STYLE = window.AVATAR_STYLE || 'holo';     // 'holo' (grid overlay + tint) or 'real'

  let renderer;
  try {
    renderer = new THREE.WebGLRenderer({ antialias: true, alpha: false, powerPreference: 'high-performance' });
  } catch (e) { return; }
  renderer.setPixelRatio(1);
  renderer.setClearColor(0x000000, 1);
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  api.canvas = renderer.domElement;

  const scene = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(26, 1, 0.01, 200);
  const hemi = new THREE.HemisphereLight(0xbfa8ff, 0x120a40, 1.0);
  const key = new THREE.DirectionalLight(0xffffff, 1.5); key.position.set(-0.6, 1.0, 1.6);
  const rim = new THREE.DirectionalLight(0x8a63ff, 2.4); rim.position.set(1.2, 0.6, -1.2);
  scene.add(hemi, key, rim);

  const rig = new THREE.Group();
  scene.add(rig);

  const st = {
    box: null, size: new THREE.Vector3(), focusY: 0, w: 2, h: 2,
    morphs: [], mouth: [], blink: [], head: null, headBase: null, mixer: null, last: 0
  };

  function fit() {
    if (!st.box) { return; }
    const sy = st.size.y;
    const viewH = sy * 0.46;                                   // head to waist
    const needW = Math.min(st.size.x, sy * 0.40) * 1.15;
    const fov = THREE.MathUtils.degToRad(camera.fov);
    const aspect = st.w / st.h;
    const dH = (viewH / 2) / Math.tan(fov / 2);
    const dW = (needW / 2) / (Math.tan(fov / 2) * aspect);
    const d = Math.max(dH, dW);
    st.focusY = st.box.max.y - sy * 0.22;
    camera.aspect = aspect;
    camera.position.set(0, st.focusY, d);
    camera.lookAt(0, st.focusY, 0);
    camera.updateProjectionMatrix();
  }

  api.setSize = function (w, h) {
    st.w = Math.max(2, w); st.h = Math.max(2, h);
    renderer.setSize(st.w, st.h, false);
    fit();
  };

  function onLoaded(gltf) {
    const model = gltf.scene;
    rig.add(model);

    // centre horizontally, feet on y=0
    let box = new THREE.Box3().setFromObject(model);
    const c = box.getCenter(new THREE.Vector3());
    model.position.x -= c.x; model.position.z -= c.z; model.position.y -= box.min.y;
    box = new THREE.Box3().setFromObject(model);
    st.box = box; box.getSize(st.size);

    const tintCol = new THREE.Color(0x7a55ff);
    const overlays = [];
    model.traverse(function (o) {
      if (o.morphTargetDictionary && o.morphTargetInfluences) {
        st.morphs.push(o);
        MOUTH.forEach(function (n) { if (n in o.morphTargetDictionary) { st.mouth.push([o, o.morphTargetDictionary[n]]); } });
        BLINK.forEach(function (n) { if (n in o.morphTargetDictionary) { st.blink.push([o, o.morphTargetDictionary[n]]); } });
      }
      if (o.isMesh && STYLE === 'holo') {
        const mats = Array.isArray(o.material) ? o.material : [o.material];
        mats.forEach(function (m) {
          if (m.color) { m.color.multiplyScalar(0.45); }
          if (m.emissive) { m.emissive.copy(tintCol).multiplyScalar(0.18); }
          if ('roughness' in m) { m.roughness = 0.55; }
          if ('metalness' in m) { m.metalness = 0.0; }
        });
        // glowing grid on top of the surface (shares the skeleton for skinned meshes)
        const wm = new THREE.MeshBasicMaterial({
          color: tintCol, wireframe: true, transparent: true, opacity: 0.32,
          blending: THREE.AdditiveBlending, depthWrite: false
        });
        let ov;
        if (o.isSkinnedMesh) {
          ov = new THREE.SkinnedMesh(o.geometry, wm);
          ov.bind(o.skeleton, o.bindMatrix);
        } else {
          ov = new THREE.Mesh(o.geometry, wm);
        }
        ov.morphTargetInfluences = o.morphTargetInfluences;
        ov.morphTargetDictionary = o.morphTargetDictionary;
        ov.frustumCulled = false;
        overlays.push([o, ov]);
      }
    });
    overlays.forEach(function (p) { p[0].parent.add(p[1]); p[1].position.copy(p[0].position); p[1].quaternion.copy(p[0].quaternion); p[1].scale.copy(p[0].scale); });
    st.wires = overlays.map(function (p) { return p[1].material; });

    for (let i = 0; i < HEAD_NAMES.length && !st.head; i++) { st.head = model.getObjectByName(HEAD_NAMES[i]) || null; }
    if (st.head) { st.headBase = st.head.rotation.clone(); }

    if (gltf.animations && gltf.animations.length) {
      st.mixer = new THREE.AnimationMixer(model);
      st.mixer.clipAction(gltf.animations[0]).play();
    }

    fit();
    api.ready = true;
  }

  try {
    new GLTFLoader().parse(b64ToBuf(b64), '', onLoaded, function (e) {
      try { console.log('Avatar3D: glb error ' + (e && e.message)); } catch (x) {}
    });
  } catch (e) { return; }

  const tmpCol = new THREE.Color();

  api.update = function (t, S, tint) {
    if (!api.ready) { return; }
    const dt = st.last ? Math.min(0.05, t - st.last) : 0.016;
    st.last = t;

    if (st.mixer) { st.mixer.update(dt); }

    // gaze + breathing
    const lx = S.lx || 0, ly = S.ly || 0;
    rig.rotation.y = lx * 0.18;
    rig.position.y = Math.sin(t * 1.3) * st.size.y * 0.0015;
    if (st.head && st.headBase) {
      const hy = lx * 0.35, hx = -ly * 0.22;
      if (st.mixer) { st.head.rotation.y += hy; st.head.rotation.x += hx; }
      else { st.head.rotation.set(st.headBase.x + hx, st.headBase.y + hy, st.headBase.z); }
    }

    // mouth + blink
    const m = Math.max(0, Math.min(1, S.mouth || 0));
    for (let i = 0; i < st.mouth.length; i++) { st.mouth[i][0].morphTargetInfluences[st.mouth[i][1]] = m * 0.75; }
    const b = Math.max(0, Math.min(1, S.blink || 0));
    for (let i = 0; i < st.blink.length; i++) { st.blink[i][0].morphTargetInfluences[st.blink[i][1]] = b; }

    // tint follows the agent state (idle / listening / thinking / speaking)
    if (tint) {
      tmpCol.setRGB(tint[0] / 255, tint[1] / 255, tint[2] / 255);
      rim.color.copy(tmpCol); hemi.color.copy(tmpCol).lerp(new THREE.Color(0xffffff), 0.35);
      if (st.wires) { for (let i = 0; i < st.wires.length; i++) { st.wires[i].color.copy(tmpCol); } }
    }

    renderer.render(scene, camera);
  };
})();
