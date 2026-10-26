# Step 6: Full-System Test Against Python/NumPy

Until now, every testbench computed its own expected answer in Verilog. That has a hidden weakness: if you misunderstand the math, the design and the testbench can be wrong *in the same way* and still "pass". Step 6 fixes that with an **independent golden model**. NumPy computes C = A @ B. The hardware has to match it exactly, through the real AXI4-Lite bus.

This is how verification is done in industry: a reference model in a high-level language (Python, C++, SystemVerilog), test vectors, and the RTL is compared against it.

## How the pieces fit

```
 golden.py gen  (NumPy: C = A @ B)
      │ writes
      ▼
 meta.mem   a.mem   b.mem   c_expected.mem
      │ $readmemh
      ▼
 tb_system ──> axil_master ──AXI4-Lite──> axil_systolic   (steps 1 to 5, unchanged)
      │                          │
      │                     axil_checker (protocol rules)
      ├── compares every C with c_expected.mem          (check 1, inside the simulator)
      └── writes hw_results.txt ──> golden.py check     (check 2, outside, in Python)
```

The testbench contains **no math**. It only moves data and compares. Every expected number comes from NumPy.

## The test vectors

`golden.py gen` makes 1000 tests for N=4: 9 hand-picked corner cases first, then 991 random ones.

| Test | Case | Why it is there |
| --- | --- | --- |
| 0 | walkthrough example | the same matrices as the diagram, C must be 5 0 1 6 / 7 7 8 6 / ... |
| 1 | all zeros | the clear and reset paths |
| 2 | identity × B | C must equal B exactly, which is easy to see by eye |
| 3 | −128 × −128 | **the largest possible result**, 4 × 16384 = 65536. Needs 18 bits. |
| 4 | −128 × 127 | the most negative result, −65024 |
| 5 | 127 × 127 | large positive |
| 6 | −1 × −1 | sign extension: 0xFF must mean −1, not 255 |
| 7 | checkerboard of 127 / −128 | mixed signs in every dot product |
| 8 | only A[3][3] = 100 | data has to reach the farthest PE, which proves the DRAIN length |

File format: one value per line in hex. A and B are 2 hex digits (two's complement, so −1 is `ff`), and C is 8 hex digits. Order: test 0 row 0 col 0, row 0 col 1, ..., then test 1, and so on. `meta.mem` holds N and the number of tests, so the testbench refuses vectors made for the wrong N.

## Results (Icarus; same code for Vivado 2022.1)

```
Loaded 1000 tests for N=4 from the Python/NumPy model
  test    0 ok
  ...
  test  999 ok
----------------------------------------------------------
Tests run         : 1000 (0 failed)
Results compared  : 16000
Bus clocks / job  : 245   (compute only: 11)
MACs / job        : 64
At 100 MHz        : 408163 jobs/s, 26 MMAC/s over AXI4-Lite
AXI protocol check: 0 violations
Hardware C values written to hw_results.txt
PASS: system test N=4, hardware == NumPy on all 1000 tests
$finish called at time : 2450076 ns
```
Then, in Python:
```
> python golden.py check hw_results.txt
PASS: 1000 tests, 16000 results, hardware == NumPy
```
N=8 also passes: 300 tests, 19,200 results, 929 bus clocks per job, 55 MMAC/s.

## Proof that the test catches bugs

| Deliberate bug in `pe.v` | Tests failed (of 1000) | Caught by |
| --- | --- | --- |
| unsigned multiply (`signed` removed) | 997 | almost everything; the first failure is the walkthrough example |
| accumulator cut to 17 bits | **1** | **only test 3** (−128 × −128 = 65536) |

The second row is the most important lesson in this step. **991 random tests did not catch the overflow bug.** Random values almost never make all four products large with the same sign, so a sum never reached 65536. Only the hand-picked corner case did. This is why real verification plans always combine random tests with directed corner cases.

## Files

| File | What it is |
| --- | --- |
| `golden.py` | NumPy golden model: `gen` makes the vectors, `check` re-checks the hardware output |
| `vectors/meta.mem`, `a.mem`, `b.mem`, `c_expected.mem` | the 1000 generated tests (already made, so you don't need Python to run the simulation) |
| `tb_system.v` | new system testbench, which reads the vectors and drives AXI |
| steps 1 to 5 files | unchanged |

## Run it in Vivado 2022.1

1. Close any open simulation.
2. Click **Add Sources → Add or create simulation sources → Add Files**, and add `tb_system.v` plus the four files in `vectors/`: `meta.mem`, `a.mem`, `b.mem`, `c_expected.mem`. In the file dialog, set "Files of type" to **All Files**, or the .mem files won't show.
   * **Tick "Copy sources into project"** at the bottom of the dialog.
   * Vivado copies `.mem` files into the simulation run folder automatically. That is how `$readmemh("a.mem")` finds them.
3. No new design sources. Design Sources Top stays `axil_systolic`.
4. Under Simulation Sources, right-click `tb_system` and choose **Set as Top**.
5. Run Behavioral Simulation. This is the longest test so far: 2.45 ms of simulated time. It may take a minute.
6. Expect `PASS: system test N=4, hardware == NumPy on all 1000 tests`.

**If you see `FAIL: vector files missing`**, Vivado didn't copy the .mem files. Check that they are listed under Simulation Sources. Look under "Memory File" or "Text" in the Hierarchy or Compile Order tab.

## The second check, in Python (optional)

The simulation writes `hw_results.txt` to
`C:/Users/SHIVAKUMAR/verilog projects/systolic_array/systolic_array.sim/sim_1/behav/xsim/`.

If Python is installed (`pip install numpy`), copy that file next to `golden.py`, keeping `vectors/` beside it, and run:
```
python golden.py check hw_results.txt
```
You can also make new tests, for example `python golden.py gen --tests 2000 --seed 7`, and then re-add the new .mem files.

## Interview chain on this step

1. *How did you verify it?* With unit testbenches for each block, then a system test where a NumPy golden model generated 1000 tests (16,000 results) and the RTL had to match through the real AXI bus, with a protocol checker running.
2. *Why not compute the expected value in the testbench?* A Verilog model written by the same person can share the same misunderstanding. An independent reference model in another language removes that.
3. *Is random testing enough?* No. My accumulator-overflow bug failed only 1 of 1000 tests, and that was the directed −128 × −128 corner case. Random tests alone missed it.
4. *Why is the accumulator 32 bits?* The worst case for N=4 is 4 × 16384 = 65536, which needs 18 bits signed. 32 bits allows K up to about 131,000 with no overflow, enough for tiling large matrices.
5. *What is your throughput?* 64 MACs in 11 clocks of compute, but 245 clocks per job over AXI4-Lite. That is 26 MMAC/s at 100 MHz, so the bus is the bottleneck. Packed writes, DMA or double buffering would fix it.
