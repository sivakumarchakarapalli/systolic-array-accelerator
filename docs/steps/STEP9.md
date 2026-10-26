# Step 9a: Packed Writes (4 INT8 values per bus write)

Step 8 found that the array is busy only **6%** of the time. The other 94% goes on the AXI4-Lite bus. Step 9 attacks that bottleneck, one fix at a time, and measures each fix. Step 9a is the first fix: **stop wasting 3/4 of every bus write**.

## The problem

In step 8 every A or B element (8 bits) took a full 32-bit write:

```
 write 0x400  data = 0x000000_12     <- 8 useful bits, 24 bits wasted
 write 0x404  data = 0x000000_F3
 write 0x408  data = 0x000000_07
 write 0x40C  data = 0x000000_2A
```

A 4x4 tile has 16 A + 16 B elements, so it needed **32 writes**. Each write costs about 5 clocks on our bus.

## The fix: pack one row into one write

```
 write 0x100  data = 0x2A_07_F3_12   <- all 32 bits useful
                       │  │  │  └── byte 0 = A[0][0]
                       │  │  └───── byte 1 = A[0][1]
                       │  └──────── byte 2 = A[0][2]
                       └─────────── byte 3 = A[0][3]
```

Now a tile needs **8 writes** (4 rows of A + 4 rows of B). This is exactly how real accelerators and GPUs work: the bus carries full-width words, and the hardware unpacks them. NVIDIA tensor-core loads move 128 bits at a time for the same reason.

### New addresses (the old ones still work)

| Address | Register | Notes |
| --- | --- | --- |
| `0x100 + 4*w` | A packed, word w = 0..3 | byte k = element 4w+k (row-major), so word w = row w for 4x4 |
| `0x200 + 4*w` | B packed, word w = 0..3 | same layout |
| `0x400`, `0x800`, `0xC00` | unchanged from step 8 | every old testbench still passes |

**WSTRB is honoured per byte:** with WSTRB = `0101`, only bytes 0 and 2 are written. That is the AXI rule for partial writes.

## The hardware: a 4-lane sequencer

The A/B buffer inside `systolic_top` has **one write port** (one element per clock). Instead of redesigning it, `axil_systolic.v` gets a small sequencer:

```
 clock:          0        1        2        3        4
 bus write  ── [0x100] ─────────────────────────────── next write may commit
 sequencer        latch   lane 0   lane 1   lane 2   lane 3
 buffer write             A[0][0]  A[0][1]  A[0][2]  A[0][3]
 pk_busy          ───────1────────────────────────┐___
```

- A packed write is latched in `pk_data`, then written out one byte per clock.
- **While `pk_busy` is 1, the next bus write waits** (`do_write` gets `&& !pk_busy`). That stops a CTRL start from overtaking the last bytes of data. The AXI handshake handles the waiting: READY just stays low a little longer.
- It costs about 40 flip-flops and a few LUTs. No DSPs, no BRAM.

## Results (Icarus; same code for Vivado 2022.1)

```
Digits correct     : 19 / 20
Scores vs NumPy    : 0 mismatches (bit-exact check of all 240 scores)
Accelerator runs   : 2080 (416 per batch of 4 images)
Clocks per image   : 6520 over AXI4-Lite (step 8: 19000)
Bus per image      : 936 writes, 460 reads
Array busy         : 22880 of 130401 clocks = 17.5% (step 8: 6.0%)
At 100 MHz         : 15337 images/s (step 8: 5263)
Speed-up vs step 8 : 2.9 x
AXI protocol check : 0 violations
PASS: MNIST on hardware == INT8 NumPy model on all 20 images
```

| | Step 8 | **Step 9a** |
| --- | --- | --- |
| Data writes per tile | 32 | **8** |
| Bus writes per image | 3,432 | **936** |
| Clocks per image | 19,000 | **6,520** |
| Images/s at 100 MHz | 5,263 | **15,337** |
| Array busy | 6.0% | **17.5%** |

### Why 2.9x and not 4x?

From the two runs, a write costs **5 clocks** and a read **4 clocks**. Per image now:

| Where the time goes | Clocks | Share |
| --- | --- | --- |
| 936 writes (8 data + 1 CTRL per run) | 4,680 | 72% |
| 416 STATUS polls (about 4 per run, waiting for the array) | 1,664 | 26% |
| 44 C reads | 176 | 3% |

Packing only shrinks the data writes. The CTRL write, the polling and the C reads are untouched, so the total speed-up is 2.9x. This is **Amdahl's law**: you only speed up the part you fixed.

The table also shows the **next target**: the CPU sits polling STATUS while the array computes. Step 9b (double buffering) lets the CPU load the next tile *while* the array computes the current one, so that waiting time disappears.

## Verification

`tb_packed.v` is a directed test of the new feature:

```
ok   1. packed A and B           (3 random tiles, including -128 x -128)
ok   2. WSTRB partial write
ok   3. mixed old + packed
ok   4. read A packed -> SLVERR
ok   4. read B packed -> SLVERR
ok   4. A packed word 4 (past end) -> DECERR
ok   4. B packed +0x40 (past end) -> DECERR
ok   4. misaligned packed write -> SLVERR
ok   4. packed write while busy -> SLVERR
ok   4. data unchanged by errors
ok   5. CTRL right after packed
ok   6. full-speed packed burst
AXI protocol check : 0 violations
PASS: packed writes
```

Test 6 matters. `axil_master` is slow (5 clocks per write), so it can never send writes faster than the 4-clock sequencer. Test 6 takes over the bus and sends a write **every 2 clocks**, with VALID always high.

**Mutation checks** (break the design on purpose; the tests must catch it):

| Bug planted | Caught by |
| --- | --- |
| Remove `!pk_busy` (no stall) | test 6 only: 16 errors |
| Ignore WSTRB | tests 2, 3, 4 |
| Bytes in reverse order | every test, 112 errors |

The first row is an interview story: **the bug was invisible with the normal master**. Only a test that drives the bus at full speed finds it.

**Regression:** all older testbenches pass with the new `axil_systolic.v`: `tb_systolic_top`, `tb_axil_systolic` (N=4 and N=8), `tb_system` (1000 tests), `tb_basys3_systolic` (over UART) and `tb_mnist` (the old one-element addresses).

## Files

| File | Where in Vivado | Status |
| --- | --- | --- |
| `axil_systolic.v` | Design (replace yours) | packed regions + sequencer |
| `tb_packed.v` | Simulation (new) | directed tests, no data files needed |
| `tb_mnist_fast.v` | Simulation (new) | MNIST with packed writes; uses the step 8 `.mem` files you already have |
| `mnist_uart.py` | your PC | packed by default; `--unpacked` for the step 8 way |

## Run it in Vivado 2022.1

1. Close any open simulation.
2. **Replace `axil_systolic.v`:** open it from the Sources window, Ctrl+A, paste the new version, Ctrl+S.
3. **Add simulation sources:** `tb_packed.v` and `tb_mnist_fast.v` (Add Sources → *Add or create simulation sources* → *Create File*, paste, save, **Finish**). The `.mem` files from step 8 are already in your project.
4. Set **`tb_packed`** as simulation Top, run Behavioral Simulation. Expect `PASS: packed writes` (about 10 µs of simulated time).
5. Set **`tb_mnist_fast`** as simulation Top and run. It simulates 1.3 ms. Expect `Clocks per image : 6520` and `PASS`.
6. Re-run Synthesis and Implementation. Check: DSPs still 16, a few more FFs than step 7 (about 40), timing still met. Send me the LUT/FF numbers and WNS.

## Interview chain on this step

1. *Your utilization was 6%. What did you do?* Measured where the time goes, then fixed the biggest piece first: data writes were 72% of bus traffic and 3/4 of each write was empty. Packed 4 INT8 values per 32-bit write.
2. *Result?* 2.9x faster (19,000 → 6,520 clocks per image), bit-exact, about 40 extra flip-flops.
3. *Why not 4x?* Amdahl's law: CTRL writes, STATUS polling and C reads were not packed. Polling is now 26% of the time, which motivates double buffering.
4. *The buffer has one write port. How do 4 bytes get in?* A 4-lane sequencer writes one byte per clock and back-pressures the bus with READY while busy, so ordering is preserved.
5. *How do you know the back-pressure works?* A full-speed bus test. With the normal master the bug is invisible; removing the stall fails only that test.
