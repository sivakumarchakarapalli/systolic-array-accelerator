#!/usr/bin/env python3
"""
mnist_uart.py : recognise handwritten digits on the Basys3 accelerator

    python mnist_uart.py COM5            5 images, ASCII art + the FPGA's answer
    python mnist_uart.py COM5 -n 20      more images
    python mnist_uart.py sim -n 8        no board: a Python model of the
                                         accelerator's registers stands in
    python mnist_uart.py COM5 --unpacked step 8 style, one element per write

Step 9a: by default each row of A and B (4 INT8 values) goes in ONE
write to 0x100 / 0x200, so a tile takes 8 writes instead of 32.
Needs the step 9 bitstream (the step 8 one answers DECERR there).

Needs mnist_int8.npz (made by mnist_model.py) in the same folder,
plus: pip install numpy pyserial

The PC does what a CPU would do: it splits every matrix multiply into 4x4
tiles, sends them over UART -> AXI4-Lite, starts the array (CTRL = 1 for
the first K-tile, CTRL = 3 = start + accumulate for the rest), reads C,
and does bias + ReLU + requantize between the layers.
"""
import argparse
import os
import struct
import sys
import time

import numpy as np

CTRL, STATUS, ID = 0x000, 0x004, 0x00C
A_BASE, B_BASE, C_BASE = 0x400, 0x800, 0xC00
A_PACK, B_PACK = 0x100, 0x200                      # step 9a: 4 INT8 per write
HERE = os.path.dirname(os.path.abspath(__file__))


class Board:
    """UART -> AXI4-Lite bridge frames (from the AXI4-Lite project)."""

    def __init__(self, port, baud=115200):
        import serial                                  # pip install pyserial
        self.s = serial.Serial(port, baud, timeout=1.0)
        self.s.reset_input_buffer()

    def _xfer(self, frame, n):
        self.s.write(frame)
        r = self.s.read(n)
        if len(r) != n:
            raise IOError("UART timeout: is the board programmed and the COM port right?")
        return r

    def write(self, addr, data):
        if self._xfer(b"W" + struct.pack(">II", addr, data & 0xFFFFFFFF) + b"\x0f", 1)[0]:
            raise IOError("write 0x%03x refused" % addr)

    def read(self, addr):
        r = self._xfer(b"R" + struct.pack(">I", addr), 5)
        if r[0]:
            raise IOError("read 0x%03x refused" % addr)
        return struct.unpack(">I", r[1:])[0]


class SimBoard:
    """Python stand-in for the accelerator's registers (no board needed)."""

    def __init__(self):
        self.a = np.zeros(16, np.int64); self.b = np.zeros(16, np.int64)
        self.c = np.zeros(16, np.int64)

    def write(self, addr, data):
        v = data & 0xFF; v = v - 256 if v > 127 else v
        if addr == CTRL:
            prod = (self.a.reshape(4, 4) @ self.b.reshape(4, 4)).flatten()
            self.c = self.c + prod if data & 2 else prod
        elif A_BASE <= addr < A_BASE + 64: self.a[(addr - A_BASE) // 4] = v
        elif B_BASE <= addr < B_BASE + 64: self.b[(addr - B_BASE) // 4] = v
        elif A_PACK <= addr < A_PACK + 16 or B_PACK <= addr < B_PACK + 16:
            dst = self.a if addr < B_PACK else self.b
            w = (addr & 0xFF) // 4
            for k in range(4):
                v = (data >> (8 * k)) & 0xFF
                dst[4 * w + k] = v - 256 if v > 127 else v

    def read(self, addr):
        if addr == ID: return 0x5A000408
        if addr == STATUS: return 2
        return int(self.c[(addr - C_BASE) // 4]) & 0xFFFFFFFF


def pack4(vals):
    """4 signed INT8 -> one 32-bit word, element 0 in the low byte."""
    return sum((int(v) & 0xFF) << (8 * k) for k, v in enumerate(vals))


def gemm(board, a, w, packed=True):
    """C[4 x n] = A[4 x k] @ W[k x n] with 4x4 tiles; returns INT32 C."""
    k, n = w.shape
    c = np.zeros((4, n), dtype=np.int64)
    for nt in range(n // 4):
        for kt in range(k // 4):
            for i in range(4):
                if packed:                                     # 2 writes per row
                    board.write(A_PACK + 4 * i, pack4(a[i, kt * 4: kt * 4 + 4]))
                    board.write(B_PACK + 4 * i, pack4(w[kt * 4 + i, nt * 4: nt * 4 + 4]))
                    continue
                for j in range(4):                             # 8 writes per row
                    board.write(A_BASE + 4 * (i * 4 + j), int(a[i, kt * 4 + j]))
                    board.write(B_BASE + 4 * (i * 4 + j), int(w[kt * 4 + i, nt * 4 + j]))
            board.write(CTRL, 1 if kt == 0 else 3)     # start, or start + accumulate
            while board.read(STATUS) & 3 != 2:
                pass
        for i in range(4):
            for j in range(4):
                v = board.read(C_BASE + 4 * (i * 4 + j))
                c[i, nt * 4 + j] = v - (1 << 32) if v >> 31 else v
    return c


def classify(board, q, x4, packed=True):
    acc1 = gemm(board, x4, q["w1"], packed) + q["b1"]                       # layer 1 on the FPGA
    v = np.maximum(acc1, 0)                                          # ReLU on the PC
    h = np.clip((v * int(q["m"]) + (1 << (int(q["s"]) - 1))) >> int(q["s"]), 0, 127)
    acc2 = gemm(board, h, q["w2"], packed) + q["b2"]                         # layer 2 on the FPGA
    return acc2.argmax(1), acc2


def ascii_art(img):
    rows = img.reshape(14, 14)
    return ["".join("#" if p > 80 else "+" if p > 30 else "." if p > 8 else " " for p in r) for r in rows]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("port", help="COM port of the Basys3, or 'sim'")
    ap.add_argument("-n", type=int, default=5, help="number of test images")
    ap.add_argument("--unpacked", action="store_true", help="one element per write (step 8 style)")
    a = ap.parse_args()

    q = np.load(os.path.join(HERE, "mnist_int8.npz"))
    board = SimBoard() if a.port == "sim" else Board(a.port)
    if board.read(ID) >> 16 != 0x5A00:
        print("No systolic array found on", a.port); return 1

    n = (a.n + 3) // 4 * 4
    x, y = q["x"][:n], q["y"][:n]
    correct, t0 = 0, time.time()
    for b in range(0, n, 4):
        pred, _ = classify(board, q, x[b:b + 4], not a.unpacked)
        for i in range(4):
            art = ascii_art(x[b + i])
            print("\n".join("   |%s|" % r for r in art))
            ok = pred[i] == y[b + i]
            correct += ok
            who = "Python model says" if a.port == "sim" else "FPGA says"
            print("   image %d: %s %d (label %d) %s\n" % (b + i, who, pred[i], y[b + i], "" if ok else "<-- wrong"))
    dt = time.time() - t0
    print("%d / %d correct, %.2f s per image. The array itself computes for only"
          " 104 runs x 11 clocks = 11.4 us per image at 100 MHz; the rest is UART."
          % (correct, n, dt / n))
    return 0


if __name__ == "__main__":
    sys.exit(main())
