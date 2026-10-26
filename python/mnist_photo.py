#!/usr/bin/env python3
"""
mnist_photo.py : recognise YOUR handwritten digit (a photo) on the FPGA

    python mnist_photo.py COM12 my_digit.png        on the Basys3
    python mnist_photo.py sim   my_digit.png        no board (Python model)

Needs, in the same folder: mnist_uart.py and mnist_int8.npz
plus: pip install numpy pyserial pillow

How to take the photo:
    one digit, thick dark marker on white paper, good light,
    digit roughly in the middle, nothing else in the picture.

The photo is turned into what the network was trained on (MNIST style):
    grey -> invert (white digit on black) -> remove background
    -> crop to the digit -> scale to fit 20x20 -> centre in 28x28
    -> 2x2 average to 14x14 -> pixels 0..127 (INT8)
Then the same tiled matrix multiplies as mnist_uart.py run on the FPGA.
"""
import argparse
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import mnist_uart as mu                                # Board, SimBoard, classify, ascii_art


def photo_to_mnist(path):
    """Photo of a dark digit on light paper -> 196 INT8 pixels (0..127)."""
    from PIL import Image                              # pip install pillow
    img = Image.open(path).convert("L")
    img.thumbnail((400, 400))                          # big photos: work on a smaller copy
    g = np.asarray(img, dtype=np.float64)

    if g.mean() > 127:                                 # paper is bright: invert so ink is bright
        g = 255 - g
    bg = np.percentile(g, 50)                          # the paper level
    g = np.clip(g - bg, 0, None)
    if g.max() <= 0:
        raise ValueError("no digit found in the picture")
    g = g / g.max() * 255
    g[g < 40] = 0                                      # drop faint shadows and paper texture

    ys, xs = np.nonzero(g)
    g = g[ys.min():ys.max() + 1, xs.min():xs.max() + 1]   # crop to the digit

    h, w = g.shape                                     # longest side -> 20 px, like MNIST
    s = 20.0 / max(h, w)
    nh, nw = max(1, round(h * s)), max(1, round(w * s))
    small = np.asarray(Image.fromarray(g.astype(np.uint8)).resize((nw, nh), Image.LANCZOS),
                       dtype=np.float64)

    canvas = np.zeros((28, 28))                        # centre of mass at the middle
    top, left = (28 - nh) // 2, (28 - nw) // 2
    canvas[top:top + nh, left:left + nw] = small
    tot = canvas.sum()
    cy = (canvas.sum(1) * np.arange(28)).sum() / tot
    cx = (canvas.sum(0) * np.arange(28)).sum() / tot
    dy, dx = int(round(13.5 - cy)), int(round(13.5 - cx))
    canvas = np.roll(np.roll(canvas, dy, axis=0), dx, axis=1)
    canvas = np.clip(canvas, 0, 255)

    img14 = canvas.reshape(14, 2, 14, 2).mean(axis=(1, 3)).reshape(196)   # 28x28 -> 14x14
    return np.round(img14 / 255 * 127).astype(np.int64)                  # same as mnist_model.py


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("port", help="COM port of the Basys3, or 'sim'")
    ap.add_argument("images", nargs="+", help="photo(s) of one handwritten digit each")
    ap.add_argument("--unpacked", action="store_true", help="one element per write (step 8 style)")
    a = ap.parse_args()

    q = np.load(os.path.join(HERE, "mnist_int8.npz"))
    board = mu.SimBoard() if a.port == "sim" else mu.Board(a.port)
    if board.read(mu.ID) >> 16 != 0x5A00:
        print("No systolic array found on", a.port); return 1

    for path in a.images:
        x = photo_to_mnist(path)
        print("\n%s  ->  what the FPGA sees (14x14):" % os.path.basename(path))
        print("\n".join("   |%s|" % r for r in mu.ascii_art(x)))
        x4 = np.zeros((4, 196), dtype=np.int64)       # the array works on 4 rows: 1 image + 3 empty
        x4[0] = x
        pred, scores = mu.classify(board, q, x4, not a.unpacked)
        s = scores[0, :10]
        top = np.argsort(s)[::-1][:3]
        who = "Python model says" if a.port == "sim" else "FPGA says"
        print("   %s: %d     (runner-up %d, then %d)" % (who, pred[0], top[1], top[2]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
