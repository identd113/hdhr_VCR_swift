#!/usr/bin/env python3
# Builds a minimal multi-image .ico (16x16 + 32x32) from two source PNGs — used by both
# deploy.sh and deploy_release.sh so the web guide's browser-tab favicon matches the app icon.
# Previously a ~13-line heredoc duplicated verbatim in both scripts (TODO.md, "Code Quality");
# factored out here so a future fix to the ICO-writing logic only needs to land once.
import sys
import struct

paths_sizes = [(sys.argv[1], 16), (sys.argv[2], 32)]
images = [(sz, open(p, 'rb').read()) for p, sz in paths_sizes]
hdr = struct.pack('<HHH', 0, 1, len(images))
off = 6 + len(images) * 16
dirs, blobs = b'', b''
for sz, data in images:
    dirs += struct.pack('<BBBBHHII', sz, sz, 0, 0, 1, 32, len(data), off)
    off += len(data)
    blobs += data
open(sys.argv[3], 'wb').write(hdr + dirs + blobs)
