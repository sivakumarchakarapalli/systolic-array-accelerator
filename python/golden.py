#!/usr/bin/env python3
"""
golden.py : Python/NumPy golden model for the systolic-array accelerator

  python golden.py gen   [--n 4] [--tests 1000] [--seed 1]
      Makes the test vectors that tb_system.v reads:
        meta.mem        N, number of tests
        a.mem, b.mem    one INT8 per line (2 hex digits, two's complement)
        c_expected.mem  one INT32 per line (8 hex digits), C = A @ B by NumPy

  python golden.py check hw_results.txt [--n 4]
      Reads the C values the hardware produced (written by tb_system.v)
      and compares them with NumPy again, outside the simulator.

Order inside every file: test 0 row 0 col 0, row 0 col 1, ... row N-1 col N-1,
then test 1, and so on.
"""
import argparse
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "vectors")


def corner_cases(n):
    """Hand-picked matrices that random data rarely hits."""
    full = lambda v: np.full((n, n), v, dtype=np.int64)
    cases = []
    if n == 4:  # the walkthrough example
        cases.append(("walkthrough example",
                      np.array([[1, 2, 0, -1], [3, 1, 2, 0], [0, 1, 1, 2], [2, 0, 1, 1]]),
                      np.array([[1, 0, 2, 1], [2, 1, 0, 3], [1, 3, 1, 0], [0, 2, 1, 1]])))
    cases += [
        ("all zeros",                     full(0),    full(0)),
        ("identity x B  (C must equal B)", np.eye(n, dtype=np.int64),
                                           np.arange(n * n).reshape(n, n) - n * n // 2),
        ("-128 x -128  (largest positive)", full(-128), full(-128)),
        ("-128 x 127   (most negative)",    full(-128), full(127)),
        ("127 x 127",                       full(127),  full(127)),
        ("-1 x -1      (sign extension)",   full(-1),   full(-1)),
        ("checkerboard signs",
         np.fromfunction(lambda i, j: np.where((i + j) % 2 == 0, 127, -128), (n, n)).astype(np.int64),
         np.fromfunction(lambda i, j: np.where((i + j) % 2 == 0, -128, 127), (n, n)).astype(np.int64)),
        ("one-hot corner A[N-1][N-1]  (far PE path)",
         np.pad(np.array([[100]]), ((n - 1, 0), (n - 1, 0))), full(-3)),
    ]
    return cases


def gen(n, tests, seed):
    rng = np.random.default_rng(seed)
    cases = corner_cases(n)
    while len(cases) < tests:
        cases.append(("random",
                      rng.integers(-128, 128, (n, n)),
                      rng.integers(-128, 128, (n, n))))
    cases = cases[:tests]

    os.makedirs(OUT, exist_ok=True)
    fa = open(os.path.join(OUT, "a.mem"), "w")
    fb = open(os.path.join(OUT, "b.mem"), "w")
    fc = open(os.path.join(OUT, "c_expected.mem"), "w")
    for name, a, b in cases:
        c = a.astype(np.int64) @ b.astype(np.int64)         # the golden answer
        assert c.min() >= -2**31 and c.max() < 2**31
        for v in a.flatten():
            fa.write("%02x\n" % (int(v) & 0xFF))
        for v in b.flatten():
            fb.write("%02x\n" % (int(v) & 0xFF))
        for v in c.flatten():
            fc.write("%08x\n" % (int(v) & 0xFFFFFFFF))
    fa.close(); fb.close(); fc.close()
    with open(os.path.join(OUT, "meta.mem"), "w") as f:
        f.write("%08x\n%08x\n" % (n, len(cases)))

    print("N = %d, %d tests (%d corner cases + %d random), seed %d"
          % (n, len(cases), len(corner_cases(n)), len(cases) - len(corner_cases(n)), seed))
    for i, (name, _, _) in enumerate(cases[:len(corner_cases(n))]):
        print("  test %d: %s" % (i, name))
    print("wrote", OUT)


def check(path, n):
    exp = [int(l, 16) for l in open(os.path.join(OUT, "c_expected.mem")) if l.strip()]
    got = [int(l, 16) for l in open(path) if l.strip()]
    if len(got) != len(exp):
        print("FAIL: hardware gave %d values, expected %d" % (len(got), len(exp)))
        return 1
    bad = 0
    for k, (g, e) in enumerate(zip(got, exp)):
        if g != e:
            bad += 1
            if bad <= 10:
                t, r = divmod(k, n * n)
                sg = g - (1 << 32) if g >> 31 else g
                se = e - (1 << 32) if e >> 31 else e
                print("FAIL test %d C[%d][%d]: hw %d, numpy %d" % (t, r // n, r % n, sg, se))
    tests = len(exp) // (n * n)
    if bad == 0:
        print("PASS: %d tests, %d results, hardware == NumPy" % (tests, len(exp)))
    else:
        print("FAIL: %d of %d results differ" % (bad, len(exp)))
    return 1 if bad else 0


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("cmd", choices=["gen", "check"])
    p.add_argument("file", nargs="?")
    p.add_argument("--n", type=int, default=4)
    p.add_argument("--tests", type=int, default=1000)
    p.add_argument("--seed", type=int, default=1)
    a = p.parse_args()
    if a.cmd == "gen":
        gen(a.n, a.tests, a.seed)
    else:
        sys.exit(check(a.file or "hw_results.txt", a.n))
