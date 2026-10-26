#!/usr/bin/env python3
"""
systolic_uart.py : use the systolic-array accelerator on the Basys3 from a PC

    python systolic_uart.py COM5 ping           board alive? reads the ID register
    python systolic_uart.py COM5 demo           the walkthrough example, printed
    python systolic_uart.py COM5 test -n 200    random matrices, every C checked vs NumPy
    python systolic_uart.py COM5 regs           STATUS, CYCLES, ID

COM5 is an example: use the port Windows shows in Device Manager under
"Ports (COM & LPT)" (the Basys3 shows as "USB Serial Port (COMx)").
Needs:  pip install pyserial numpy

Bridge frames (from the AXI4-Lite project, rtl/uart_axil_bridge.v):
    PC -> board   'W' A3 A2 A1 A0 D3 D2 D1 D0 S   |  'R' A3 A2 A1 A0   |  'P'
    board -> PC   ST                              |  ST D3 D2 D1 D0    |  'P'
    ST = 0 OKAY, 2 SLVERR, 3 DECERR
"""
import argparse
import struct
import sys
import time

import numpy as np

CTRL, STATUS, CYCLES, ID = 0x000, 0x004, 0x008, 0x00C
A_BASE, B_BASE, C_BASE = 0x400, 0x800, 0xC00
RESP = {0: "OKAY", 1: "EXOKAY", 2: "SLVERR", 3: "DECERR"}

A_EX = np.array([[1, 2, 0, -1], [3, 1, 2, 0], [0, 1, 1, 2], [2, 0, 1, 1]])
B_EX = np.array([[1, 0, 2, 1], [2, 1, 0, 3], [1, 3, 1, 0], [0, 2, 1, 1]])


class Board:
    def __init__(self, port, baud=115200):
        import serial                                  # pip install pyserial
        self.s = serial.Serial(port, baud, timeout=1.0)
        self.s.reset_input_buffer()

    def _xfer(self, frame, nreply):
        self.s.write(frame)
        r = self.s.read(nreply)
        if len(r) != nreply:
            raise IOError("timeout: expected %d reply bytes, got %d (%s)" % (nreply, len(r), r.hex()))
        return r

    def ping(self):
        return self._xfer(b"P", 1) == b"P"

    def write(self, addr, data):
        st = self._xfer(b"W" + struct.pack(">II", addr, data & 0xFFFFFFFF) + b"\x0f", 1)[0]
        if st != 0:
            raise IOError("write 0x%03x -> %s" % (addr, RESP.get(st, hex(st))))

    def read(self, addr):
        r = self._xfer(b"R" + struct.pack(">I", addr), 5)
        if r[0] != 0:
            raise IOError("read 0x%03x -> %s" % (addr, RESP.get(r[0], hex(r[0]))))
        return struct.unpack(">I", r[1:])[0]


class Accelerator:
    """The register-level 'driver': the same steps a CPU would do."""

    def __init__(self, board):
        self.b = board
        ident = board.read(ID)
        if ident >> 16 != 0x5A00:
            raise IOError("ID register 0x%08x: this is not the systolic array" % ident)
        self.n = (ident >> 8) & 0xFF
        self.dw = ident & 0xFF

    def matmul(self, a, b):
        n = self.n
        for i in range(n):
            for j in range(n):
                self.b.write(A_BASE + 4 * (i * n + j), int(a[i][j]))
                self.b.write(B_BASE + 4 * (i * n + j), int(b[i][j]))
        self.b.write(CTRL, 1)                          # start
        for _ in range(100):                           # poll STATUS.done
            if self.b.read(STATUS) & 0b11 == 0b10:
                break
        else:
            raise IOError("accelerator never reported done")
        cycles = self.b.read(CYCLES)
        c = np.zeros((n, n), dtype=np.int64)
        for i in range(n):
            for j in range(n):
                v = self.b.read(C_BASE + 4 * (i * n + j))
                c[i][j] = v - (1 << 32) if v >> 31 else v
        return c, cycles                               # C[n-1][n-1] read last -> 7-seg


def main():
    p = argparse.ArgumentParser()
    p.add_argument("port")
    p.add_argument("cmd", choices=["ping", "demo", "test", "regs"])
    p.add_argument("-n", type=int, default=100, help="number of random tests")
    p.add_argument("--seed", type=int, default=1)
    a = p.parse_args()

    board = Board(a.port)
    if a.cmd == "ping":
        print("ping:", "ok" if board.ping() else "NO REPLY")
        print("ID  : 0x%08x" % board.read(ID))
        return 0

    if a.cmd == "regs":
        s = board.read(STATUS)
        print("STATUS 0x%08x  (busy=%d done=%d)" % (s, s & 1, s >> 1 & 1))
        print("CYCLES %d" % board.read(CYCLES))
        print("ID     0x%08x" % board.read(ID))
        return 0

    acc = Accelerator(board)
    print("Found %dx%d INT%d systolic array" % (acc.n, acc.n, acc.dw))

    if a.cmd == "demo":
        if acc.n != 4:
            print("demo matrices are 4x4"); return 1
        c, cyc = acc.matmul(A_EX, B_EX)
        print("A =\n%s\nB =\n%s" % (A_EX, B_EX))
        print("C from the FPGA =\n%s" % c)
        print("NumPy says      =\n%s" % (A_EX @ B_EX))
        print("compute took %d clocks on the FPGA" % cyc)
        ok = np.array_equal(c, A_EX @ B_EX)
        print("PASS" if ok else "FAIL")
        return 0 if ok else 1

    # test: random matrices against NumPy
    rng = np.random.default_rng(a.seed)
    bad = 0
    t0 = time.time()
    for t in range(a.n):
        A = rng.integers(-128, 128, (acc.n, acc.n))
        B = rng.integers(-128, 128, (acc.n, acc.n))
        c, _ = acc.matmul(A, B)
        if not np.array_equal(c, A @ B):
            bad += 1
            if bad <= 3:
                print("FAIL test %d\nhw=\n%s\nnumpy=\n%s" % (t, c, A @ B))
        if (t + 1) % 25 == 0:
            print("  %d jobs, %d failed" % (t + 1, bad))
    dt = time.time() - t0
    print("%d jobs in %.1f s = %.1f jobs/s over UART (the FPGA computes each in 110 ns)"
          % (a.n, dt, a.n / dt))
    print("PASS: FPGA == NumPy on all %d jobs" % a.n if bad == 0 else "FAIL: %d jobs wrong" % bad)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
