"""Gateway tree + compact listing for one image, OCR lines given (Vision on the Mac in place of PP-OCRv5).
usage (the UITreeTests fixture):
  swiftc -O -o /tmp/vision_ocr vision_ocr.swift && /tmp/vision_ocr <540-wide.jpg> > lines.json
  uv run --no-project --with opencv-python-headless --with numpy python -I compact_fixture.py \
      <handsy-trial-gateway checkout> <540-wide.jpg> lines.json <out.json>"""
import json, sys
sys.path.insert(0, sys.argv[1])
from handsy_trial import tree, treetext

lines = json.load(open(sys.argv[3]))

class Out:  # the RapidOCR result shape ocr_lines reads
    def __init__(self, lines):
        self.boxes = [[(b[0], b[1]), (b[2], b[1]), (b[2], b[3]), (b[0], b[3])] for _, b in lines]
        self.txts = [t for t, _ in lines]

t = tree.build(open(sys.argv[2], "rb").read(), lambda img: Out(lines))
for k in ("ocr_ms", "cv_ms", "separators"):
    t.pop(k)
listing = treetext.listing(t, compact=True)
json.dump({"tree": t, "compact": listing}, open(sys.argv[4], "w"), ensure_ascii=False, separators=(",", ":"))
print(len(listing), "chars,", listing.count("\n#"), "lines,", len(list(treetext.walk(t["tree"]))), "nodes")
