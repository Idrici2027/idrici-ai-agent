# 3D avatar (three.js)

1. Put your model through:   python tools/make_avatar_model.py my_avatar.glb holo   (or: real)
2. Build the bundle:         cd android_app/web3d && npm install && npm run build
3. Rebuild the Flutter app.

Fallback order at runtime: 3D model -> artwork image (avatar_image.js) -> built-in wireframe woman.
