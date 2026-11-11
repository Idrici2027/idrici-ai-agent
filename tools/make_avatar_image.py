#!/usr/bin/env python3
"""Turn your avatar artwork into android_app/assets/avatar/avatar_image.js

Usage:  python tools/make_avatar_image.py my_avatar.png

Artwork tips: full figure (head to waist), glowing lines on a BLACK/very dark
background, portrait ratio (e.g. 1024x1536). Black is drawn as transparent
(additive blending), so no cut-out is needed.
"""
import base64, io, sys
from PIL import Image

src = sys.argv[1]
im = Image.open(src).convert("RGB")
im.thumbnail((1024, 1536))
buf = io.BytesIO()
im.save(buf, "WEBP", quality=88)
uri = "data:image/webp;base64," + base64.b64encode(buf.getvalue()).decode()
out = "android_app/assets/avatar/avatar_image.js"
open(out, "w").write('window.AVATAR_IMG = "%s";\n' % uri)
print("wrote", out, len(uri) // 1024, "KB")
