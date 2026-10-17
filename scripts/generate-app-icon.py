#!/usr/bin/env python3
"""Generate a padded macOS icon, Xcode asset set, and ICNS from a square SVG."""

import argparse
import copy
import json
import math
from pathlib import Path
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path, help="New directory; existing output is never overwritten")
    args = parser.parse_args()
    magick = shutil.which("magick")
    iconutil = shutil.which("iconutil")
    if not magick or not iconutil:
        parser.error("ImageMagick (magick) and macOS iconutil must be installed")
    if args.output.exists():
        parser.error(f"Output already exists: {args.output}")

    source = ET.parse(args.source).getroot()
    view_box = [float(value) for value in source.attrib["viewBox"].replace(",", " ").split()]
    if len(view_box) != 4 or view_box[2] <= 0 or view_box[2] != view_box[3]:
        parser.error("The SVG must have a square, positive viewBox")
    namespace = "http://www.w3.org/2000/svg"
    ET.register_namespace("", namespace)
    ET.register_namespace("xlink", "http://www.w3.org/1999/xlink")
    icon = ET.Element(f"{{{namespace}}}svg", width="1024", height="1024", viewBox="0 0 1024 1024")
    defs = ET.SubElement(icon, f"{{{namespace}}}defs")
    clip = ET.SubElement(defs, f"{{{namespace}}}clipPath", id="ww-macos-icon")
    points = []
    for index in range(256):
        angle = index * math.tau / 256
        x, y = math.cos(angle), math.sin(angle)
        points.append((
            512 + 412 * math.copysign(abs(x) ** 0.5, x),
            512 + 412 * math.copysign(abs(y) ** 0.5, y),
        ))
    outline = "M " + " L ".join(f"{x:.5f},{y:.5f}" for x, y in points) + " Z"
    ET.SubElement(clip, f"{{{namespace}}}path", d=outline)
    group = ET.SubElement(icon, f"{{{namespace}}}g", {"clip-path": "url(#ww-macos-icon)"})
    artwork = copy.deepcopy(source)
    for metadata in artwork.findall(f"{{{namespace}}}metadata"):
        artwork.remove(metadata)
    artwork.attrib.update(x="100", y="100", width="824", height="824")
    group.append(artwork)

    args.output.mkdir(parents=True)
    svg = args.output / "WaveWrangler App Icon.svg"
    ET.ElementTree(icon).write(svg, encoding="utf-8", xml_declaration=True)
    iconset = args.output / "WaveWrangler.iconset"
    appiconset = args.output / "AppIcon.appiconset"
    iconset.mkdir()
    appiconset.mkdir()
    images = []
    with tempfile.TemporaryDirectory(prefix="ww-app-icon-") as temporary:
        master = Path(temporary) / "master.png"
        subprocess.run([
            magick, "-background", "none", "-density", "192", str(svg),
            "-resize", "2048x2048", "-strip", str(master),
        ], check=True)
        for size in [16, 32, 128, 256, 512]:
            for scale in [1, 2]:
                filename = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
                image = iconset / filename
                subprocess.run([
                    magick, str(master), "-resize", f"{size * scale}x{size * scale}",
                    "-depth", "8", "-strip", str(image),
                ], check=True)
                shutil.copy2(image, appiconset / filename)
                images.append({
                    "filename": filename, "idiom": "mac",
                    "scale": f"{scale}x", "size": f"{size}x{size}",
                })
    (appiconset / "Contents.json").write_text(
        json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n",
        encoding="utf-8",
    )
    subprocess.run([iconutil, "-c", "icns", str(iconset), "-o", str(args.output / "WaveWrangler.icns")], check=True)
    print(f"Created macOS SVG, 10-slot Xcode asset set, iconset, and ICNS in {args.output}")


if __name__ == "__main__":
    main()
