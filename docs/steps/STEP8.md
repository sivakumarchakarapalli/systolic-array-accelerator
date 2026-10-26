# Step 8: Handwritten-Digit Recognition (MNIST) on the Accelerator

Steps 1 to 7 multiplied random matrices. Step 8 runs a **real neural network** on the accelerator: it reads handwritten digits from the MNIST dataset and decides which digit each one is. This is the demo that makes people stop and look at the project.

## The network

```
 28x28 image ──2x2 average──> 14x14 = 196 pixels (INT8)
      │
      │  layer 1:  [196] x W1[196 x 32]   ← on the systolic array
      │  bias + ReLU + requantize to INT8 ← on the CPU / PC
      │  layer 2:  [32]  x W2[32 x 12]    ← on the systolic array
      ▼
 12 scores → the biggest one is the digit (10 real classes + 2 padding columns)
```

| | Float32 (Python) | **INT8 (what the FPGA computes)** |
| --- | --- | --- |
| Accuracy on all 10,000 MNIST test images | 97.03% | **97.00%** |

Quantizing to INT8 cost only 0.03%. This is why real AI accelerators (NVIDIA tensor cores, Google TPUs) use INT8 for inference.

## Two new ideas in this step

### 1. Tiling: big matrices on a small array

Our array only does 4x4 × 4x4. Layer 1 needs [4 images × 196] × [196 × 32]. The trick is to cut it into 4x4 **tiles**:

```
 C tile (4x4) = A(:, 0:3) x W(0:3, :)        ← run 1:  CTRL = 1  (clear, then compute)
              + A(:, 4:7) x W(4:7, :)        ← run 2:  CTRL = 3  (accumulate: C += A x B)
              + ...
              + A(:, 192:195) x W(192:195,:) ← run 49: CTRL = 3
```

- The K dimension (196) is split into 49 pieces. **Accumulate mode** adds each piece into the same 16 accumulators instead of clearing them.
- The output (32 wide) is split into 8 column tiles.
- So layer 1 takes 49 × 8 = **392 runs** and layer 2 takes 8 × 3 = **24 runs**, for 416 runs per batch of 4 images.

**The only hardware change:** `CTRL` bit 1 = *accumulate*. With it, the CLEAR state does not clear the PEs. That is a few lines in `systolic_top.v` and `axil_systolic.v`. Everything else is software. This is how real accelerators work: the hardware does one fixed tile size, and the software (a driver or compiler) tiles any matrix onto it.

### 2. Quantization: float → INT8 → INT32 → INT8

```
 x_q  = round(pixel / 255 x 127)                 INT8 inputs, 0..127
 acc1 = x_q · W1_q + b1_q                        INT32 (accelerator)
 h_q  = clamp( (max(acc1,0) x 40422) >> 24, 0, 127 )   ReLU + requantize to INT8 (CPU)
 acc2 = h_q · W2_q + b2_q                        INT32 (accelerator)
 digit = argmax(acc2)
```

The requantize step multiplies by an integer (40422) and shifts right by 24. That is equivalent to multiplying by 0.0024 without any floating-point hardware. **Every step is integer math**, so Python, the Verilog testbench and the FPGA give **bit-identical** scores.

## Results (Icarus; same code for Vivado 2022.1)

```
MNIST on the systolic array: 20 images, network 196 -> 32 -> 10, INT8
  first test image:
      |   ++.        |
      |   #######+   |
      |        .#.   |
      |       .#     |      (a 7)
      |      +#      |
      |     ##.      |
  image   0: FPGA says 7, label 7
  ...
  image   8: FPGA says 6, label 5  <-- wrong digit
  ...
Digits correct     : 19 / 20
Scores vs NumPy    : 0 mismatches (bit-exact check of all 240 scores)
Accelerator runs   : 2080 (416 per batch of 4 images)
Clocks per image   : 19000 over AXI4-Lite
Array busy         : 22880 of 380001 clocks = 6.0%
At 100 MHz         : 5263 images/s
AXI protocol check : 0 violations
PASS: MNIST on hardware == INT8 NumPy model on all 20 images
$finish called at time : 3800036 ns
```

Image 8 really is misclassified by the network: Python gets it wrong too, which is part of the 3% error. "Bit-exact" means the hardware matches the model, mistakes included.

**Bug check:** if accumulate mode is broken (C cleared on every run), only 2 of 20 digits are correct and 199 of 240 scores mismatch.

## The key number: the array is busy only 6% of the time

| Where the time goes, per image | Clocks |
| --- | --- |
| Array computing (104 runs × 11 clocks) | 1,144 (6%) |
| Moving A and B over AXI4-Lite (32 writes per run), polling, reading C | about 17,850 (94%) |

This is the **memory wall** again, now on a real workload. The fixes are the topic of step 9:
- **Weight reuse:** W1 is the same for every batch, but we resend it every time.
- **Packed writes:** send 4 INT8 values per 32-bit write.
- **Double buffering:** load the next tile while the current one computes.

## Files

| File | Where in Vivado | Status |
| --- | --- | --- |
| `systolic_top.v` | Design (replace yours) | adds the `accumulate` input; keeps the step 7 lookahead feed |
| `axil_systolic.v` | Design (replace yours) | CTRL bit 1 = accumulate |
| `tb_systolic_top.v` | Simulation (replace yours) | one line added: `.accumulate(1'b0)` |
| `tb_mnist.v` | Simulation (new) | the MNIST test |
| `vectors/*.mem` (8 files) | Simulation (new) | network weights, 20 test images, expected scores |
| `mnist_model.py` | your PC | trains the network and makes the INT8 files |
| `mnist_uart.py` + `mnist_int8.npz` | your PC | runs the demo on the board, or `sim` without one |

## Run it in Vivado 2022.1

1. Close any open simulation.
2. **Replace three files.** Open `systolic_top.v`, `axil_systolic.v` and `tb_systolic_top.v` from the Sources window. Select all (Ctrl+A), paste the new version, and save (Ctrl+S).
3. **Add simulation sources:** `tb_mnist.v` and the 8 files `mnist_meta.mem`, `x.mem`, `w1.mem`, `b1.mem`, `w2.mem`, `b2.mem`, `scores.mem`, `labels.mem`. Use Add Sources → *simulation sources* → *Create File* with the same name, paste and save. Finish with **Finish**.
4. Set **`tb_mnist`** as the simulation Top. The design Top stays `basys3_systolic`.
5. Run Behavioral Simulation. It simulates 3.8 ms, which takes about 1 to 3 minutes. You will see the ASCII "7" first.
6. Expect `PASS: MNIST on hardware == INT8 NumPy model on all 20 images`.
7. Optional: re-run Synthesis and Implementation. The change is tiny, so DSPs should still be 16 and timing still met.

## Without a board, or with one

```
python mnist_uart.py sim -n 8     # no board: a Python model of the registers stands in
python mnist_uart.py COM5 -n 8    # Basys3 programmed with the step 8 bitstream
```
On the board, expect several seconds per image. The array computes for about 11 µs per image; everything else is the 115200-baud UART. That is the same lesson in a much more visible form.

## Interview chain on this step

1. *What does your accelerator run?* An INT8 MLP for MNIST, 196 → 32 → 10, at 97.0% accuracy, matching the float model within 0.03%.
2. *How do you run a 196-wide layer on a 4x4 array?* Tiling: 4x4 output tiles, with K split into 49 chunks summed in the accumulators using an accumulate mode. 416 array runs per batch of 4 images.
3. *How do you go from INT32 back to INT8?* Integer requantization: multiply by M and shift right by S, with rounding and a 0..127 clamp. No floating point anywhere, so the result is bit-exact to the Python model.
4. *How did you verify it?* The testbench compares all 240 output scores bit for bit with NumPy. Breaking the accumulate mode makes 18 of 20 digits wrong.
5. *What is your utilization?* Only 6%: the array computes for 1,144 of 19,000 clocks per image. The bus is the bottleneck; weight reuse, packed writes and double buffering are the fixes.
