#!/usr/bin/env python3
"""Generate neutral geometric PNGs from coordinates, without reading source images.

Run with --check to verify committed application icons contain only this geometry.
The Flutter template images are outside this generator's targets and are unchanged.
"""
import argparse
from pathlib import Path
import struct
import zlib

ROOT = Path(__file__).resolve().parents[1]
TARGETS = {
    'android-app/app/src/main/res/drawable-nodpi/brand_mark.png': 1254,
    'flutter/jinbao365_app/assets/brand_mark.png': 512,
    'ios-app/Jinbao365/Assets.xcassets/BrandMark.imageset/brand_mark.png': 1254,
    'ios-app/Jinbao365/Assets.xcassets/AppIcon.appiconset/AppIcon.png': 1024,
    'flutter/jinbao365_app/ios/Runner/Assets.xcassets/AppIcon.appiconset/AppIcon.png': 1024,
    **{f'flutter/jinbao365_app/android/app/src/main/res/mipmap-{density}/ic_launcher.png': size
       for density, size in [('mdpi', 48), ('hdpi', 72), ('xhdpi', 96), ('xxhdpi', 144), ('xxxhdpi', 192)]},
}

def chunk(kind, data):
    return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data))

def placeholder(size):
    """Two offset white rectangular frames on a solid slate background. No font or EXIF."""
    background, foreground = bytes((51, 65, 85)), bytes((248, 250, 252))
    def frame(x, y, left, top, right, bottom):
        return left <= x <= right and top <= y <= bottom and (
            x <= left + .055 or x >= right - .055 or y <= top + .055 or y >= bottom - .055)
    rows = []
    for py in range(size):
        row = bytearray(b'\x00')  # PNG filter: none
        for px in range(size):
            x, y = (px + .5) / size, (py + .5) / size
            ink = frame(x, y, .22, .23, .63, .64) or frame(x, y, .37, .38, .78, .79)
            row.extend(foreground if ink else background)
        rows.append(row)
    header = struct.pack('!2I5B', size, size, 8, 2, 0, 0, 0)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', header) + chunk(b'IDAT', zlib.compress(b''.join(rows), 9)) + chunk(b'IEND', b'')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    cache = {}
    failures = []
    for name, size in TARGETS.items():
        if size not in cache:
            cache[size] = placeholder(size)
        expected = cache[size]
        path = ROOT / name
        if args.check:
            if not path.exists() or path.read_bytes() != expected:
                failures.append(name)
        else:
            path.write_bytes(expected)
    if failures:
        raise SystemExit('Placeholder mismatch: ' + ', '.join(failures))
    print(f'{len(TARGETS)} generated placeholders ' + ('verified' if args.check else 'written'))

if __name__ == '__main__':
    main()
