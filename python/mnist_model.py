#!/usr/bin/env python3
"""
mnist_model.py : train a tiny MNIST network and turn it into INT8 for the
                 systolic-array accelerator

  python mnist_model.py --mnist-dir path/to/mnist  [--sim-images 20]

Network (all matrix sizes are multiples of 4, so they tile onto the 4x4 array):

    image 28x28 --2x2 average--> 14x14 = 196 pixels (INT8, 0..127)
       |  layer 1:  [4 images x 196] @ W1 [196 x 32]   -> 49 x 8 = 392 tiles
       |  + bias, ReLU, requantize INT32 -> INT8          (done by the "CPU")
       |  layer 2:  [4 images x 32]  @ W2 [32 x 12]    ->  8 x 3 =  24 tiles
       v
    12 scores (10 digits + 2 padding columns that can never win) -> argmax

Everything after training is INTEGER math, written so the Verilog testbench
and the FPGA give bit-identical results:
    acc1 = x_q @ W1_q + b1_q                   (INT32, on the accelerator)
    h_q  = clamp((max(acc1,0) * M + 2^(S-1)) >> S, 0, 127)
    acc2 = h_q @ W2_q + b2_q                   (INT32, on the accelerator)
    digit = argmax(acc2)

Outputs (next to this script):
    mnist_int8.npz           weights + 200 test images, used by mnist_uart.py
    vectors/*.mem            what tb_mnist.v reads with $readmemh
Needs: numpy. MNIST files: the four *-ubyte.gz files from the MNIST site.
"""
import argparse
import gzip
import os

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
D_IN, HID, N_CLS, N_PAD = 196, 32, 10, 12
S_SHIFT = 24
PAD_BIAS = -(1 << 30)          # padding classes never win the argmax


# ----------------------------------------------------------------- data
def load_idx(path):
    with gzip.open(path, "rb") as f:
        data = f.read()
    ndim = data[3]
    dims = [int.from_bytes(data[4 + 4 * i: 8 + 4 * i], "big") for i in range(ndim)]
    return np.frombuffer(data, dtype=np.uint8, offset=4 + 4 * ndim).reshape(dims)


def load_mnist(d):
    xs = {}
    for split, pre in (("train", "train"), ("test", "t10k")):
        img = load_idx(os.path.join(d, pre + "-images-idx3-ubyte.gz")).astype(np.float64)
        lab = load_idx(os.path.join(d, pre + "-labels-idx1-ubyte.gz")).astype(np.int64)
        img = img.reshape(-1, 14, 2, 14, 2).mean(axis=(2, 4)).reshape(-1, D_IN)   # 28x28 -> 14x14
        xs[split] = (img, lab)
    return xs


# ----------------------------------------------------------------- float training
def train(x, y, epochs=12, lr=0.1, batch=64, seed=0):
    rng = np.random.default_rng(seed)
    w1 = rng.normal(0, np.sqrt(2 / D_IN), (D_IN, HID)); b1 = np.zeros(HID)
    w2 = rng.normal(0, np.sqrt(2 / HID), (HID, N_CLS)); b2 = np.zeros(N_CLS)
    vel = [np.zeros_like(p) for p in (w1, b1, w2, b2)]
    for ep in range(epochs):
        order = rng.permutation(len(x))
        for i in range(0, len(x), batch):
            idx = order[i:i + batch]
            xb, yb = x[idx], y[idx]
            h = np.maximum(xb @ w1 + b1, 0)
            z = h @ w2 + b2
            p = np.exp(z - z.max(1, keepdims=True)); p /= p.sum(1, keepdims=True)
            p[np.arange(len(yb)), yb] -= 1; p /= len(yb)
            gw2 = h.T @ p; gb2 = p.sum(0)
            dh = (p @ w2.T) * (h > 0)
            gw1 = xb.T @ dh; gb1 = dh.sum(0)
            for v, prm, g in zip(vel, (w1, b1, w2, b2), (gw1, gb1, gw2, gb2)):
                v *= 0.9; v -= lr * g; prm += v
        lr *= 0.7
    return w1, b1, w2, b2


# ----------------------------------------------------------------- integer model
def quantize(w1, b1, w2, b2, x_calib):
    s_x = 1 / 127                                     # pixel/255 in [0,1] -> 0..127
    s_w1 = np.abs(w1).max() / 127
    s_w2 = np.abs(w2).max() / 127
    w1_q = np.round(w1 / s_w1).astype(np.int64)
    w2_q = np.round(w2 / s_w2).astype(np.int64)
    b1_q = np.round(b1 / (s_x * s_w1)).astype(np.int64)
    h_float = np.maximum(x_calib @ w1 + b1, 0)
    s_h = np.percentile(h_float, 99.9) / 127          # hidden scale from real data
    m = int(round(s_x * s_w1 / s_h * (1 << S_SHIFT)))
    b2_q = np.round(b2 / (s_h * s_w2)).astype(np.int64)
    # pad 10 classes -> 12 so layer 2 is a multiple of 4 wide
    w2_p = np.zeros((HID, N_PAD), dtype=np.int64); w2_p[:, :N_CLS] = w2_q
    b2_p = np.full(N_PAD, PAD_BIAS, dtype=np.int64); b2_p[:N_CLS] = b2_q
    return dict(w1=w1_q, b1=b1_q, w2=w2_p, b2=b2_p, m=m, s=S_SHIFT)


def quant_input(img):                                 # 0..255 -> 0..127
    return np.round(img / 255 * 127).astype(np.int64)


def requant(acc, m, s):
    v = np.maximum(acc, 0)
    return np.clip((v * m + (1 << (s - 1))) >> s, 0, 127)


def int_forward(xq, q):
    acc1 = xq @ q["w1"] + q["b1"]
    h = requant(acc1, q["m"], q["s"])
    acc2 = h @ q["w2"] + q["b2"]
    return acc1, h, acc2, acc2.argmax(1)


# ----------------------------------------------------------------- outputs
def write_mem(path, vals, digits):
    mask = (1 << (4 * digits)) - 1
    with open(path, "w") as f:
        for v in np.asarray(vals).flatten():
            f.write("%0*x\n" % (digits, int(v) & mask))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mnist-dir", required=True)
    ap.add_argument("--sim-images", type=int, default=20, help="images for tb_mnist.v (multiple of 4)")
    a = ap.parse_args()
    assert a.sim_images % 4 == 0

    data = load_mnist(a.mnist_dir)
    xtr, ytr = data["train"]; xte, yte = data["test"]
    w1, b1, w2, b2 = train(xtr / 255, ytr)
    acc_f = ((np.maximum(xte / 255 @ w1 + b1, 0) @ w2 + b2).argmax(1) == yte).mean()

    q = quantize(w1, b1, w2, b2, xtr[:5000] / 255)
    xq = quant_input(xte)
    _, _, acc2, pred = int_forward(xq, q)
    acc_q = (pred == yte).mean()
    assert np.abs(acc2).max() < 2**31
    print("float32 model : %.2f%% on 10,000 test images" % (100 * acc_f))
    print("INT8 model    : %.2f%% (this is what the FPGA computes)" % (100 * acc_q))
    print("requant       : M = %d, S = %d" % (q["m"], q["s"]))

    np.savez(os.path.join(HERE, "mnist_int8.npz"), w1=q["w1"], b1=q["b1"], w2=q["w2"],
             b2=q["b2"], m=q["m"], s=q["s"], x=xq[:200], y=yte[:200])

    n = a.sim_images
    out = os.path.join(HERE, "vectors"); os.makedirs(out, exist_ok=True)
    write_mem(os.path.join(out, "mnist_meta.mem"), [n, D_IN, HID, N_PAD, q["m"], q["s"]], 8)
    write_mem(os.path.join(out, "x.mem"), xq[:n], 2)
    write_mem(os.path.join(out, "w1.mem"), q["w1"], 2)
    write_mem(os.path.join(out, "b1.mem"), q["b1"], 8)
    write_mem(os.path.join(out, "w2.mem"), q["w2"], 2)
    write_mem(os.path.join(out, "b2.mem"), q["b2"], 8)
    write_mem(os.path.join(out, "scores.mem"), acc2[:n], 8)
    write_mem(os.path.join(out, "labels.mem"), yte[:n], 2)
    print("first %d test images: labels %s" % (n, yte[:n].tolist()))
    print("                INT8 says %s" % pred[:n].tolist())
    print("wrote", out)


if __name__ == "__main__":
    main()
