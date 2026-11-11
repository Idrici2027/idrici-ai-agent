#!/usr/bin/env python3
"""Embed a .glb model into android_app/assets/avatar/avatar_model.js (base64).

Usage:  python tools/make_avatar_model.py my_avatar.glb [real|holo]

Why base64? The WebView loads the page from file:// where fetching a separate
.glb file is blocked, but a script file works everywhere.
Export the model UNCOMPRESSED (no Draco/meshopt), ideally < 15 MB, with a head
bone named "Head" and (for lip-sync) a jawOpen / viseme_aa / mouthOpen morph target.
"""
import base64, sys
src = sys.argv[1]
style = sys.argv[2] if len(sys.argv) > 2 else "holo"
data = open(src, "rb").read()
out = "android_app/assets/avatar/avatar_model.js"
with open(out, "w") as f:
    f.write('window.AVATAR_STYLE = "%s";\n' % style)
    f.write('window.AVATAR_GLB_B64 = "%s";\n' % base64.b64encode(data).decode())
print("wrote", out, round(len(data) / 1048576, 1), "MB model")
