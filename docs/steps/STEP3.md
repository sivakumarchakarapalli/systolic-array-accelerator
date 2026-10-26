# Step 3: Skew Logic in Hardware

In step 2 the testbench did the staggering. In step 3 we build it as real registers, so the array can be fed the simple way: one column of A and one row of B per clock, all N values at once.

## How to think about the hardware

To delay a signal by 1 clock, pass it through 1 flip-flop. To delay by i clocks, chain i flip-flops: a shift register. So:

```
lane 0 : in ----------------------> out   (wire, 0 clocks)
lane 1 : in --[R]-----------------> out   (1 clock)
lane 2 : in --[R]--[R]------------> out   (2 clocks)
lane 3 : in --[R]--[R]--[R]-------> out   (3 clocks)
```

That is the whole skew block: a triangle of registers. For N=4 it is 0+1+2+3 = 6 registers of 8 bits per matrix, 12 in total for A and B. That is tiny.

## What you give vs what the array gets

You give, on clock k+1, column k of A (all 4 rows at once):

| Clock | row 0 | row 1 | row 2 | row 3 |
| --- | --- | --- | --- | --- |
| 1 | a00 | a10 | a20 | a30 |
| 2 | a01 | a11 | a21 | a31 |
| 3 | a02 | a12 | a22 | a32 |
| 4 | a03 | a13 | a23 | a33 |

The skew block delivers the staircase to the array:

| Clock | row 0 | row 1 | row 2 | row 3 |
| --- | --- | --- | --- | --- |
| 1 | a00 | 0 | 0 | 0 |
| 2 | a01 | a10 | 0 | 0 |
| 3 | a02 | a11 | a20 | 0 |
| 4 | a03 | a12 | a21 | a30 |
| 5 | 0 | a13 | a22 | a31 |
| 6 | 0 | 0 | a23 | a32 |
| 7 | 0 | 0 | 0 | a33 |

The zeros come for free: the registers were reset to 0, and after the 4th column you send 0.

## The files

| File | What it is |
| --- | --- |
| `skew.v` | N lanes; lane i is an i-stage shift register (new) |
| `systolic_core.v` | top level: skew for A, skew for B, and the step 2 array (new) |
| `tb_skew.v` | unit test: random data every clock, checks lane i is delayed by exactly i (new) |
| `tb_systolic_core.v` | the step 2 testbench with the skew code removed; it now feeds plain columns and rows (new) |
| `../step1/pe.v`, `../step2/systolic_array.v` | unchanged |

## Key lines in skew.v

| Code | Why |
| --- | --- |
| `assign out_flat[0 +: DW] = in_flat[0 +: DW];` | Lane 0 needs no delay, so it is just a wire. |
| `for (i = 1; i < N; ...) begin : g_lane` | A `generate` loop builds one lane per row; lane i is different hardware from lane i+1. |
| `reg [DW-1:0] sr [0:i-1];` | Each lane declares exactly i registers. The size depends on the genvar, so lane 3 really has 3 registers. |
| `sr[0] <= in; sr[m] <= sr[m-1];` | A shift register: every clock each stage passes its value to the next. |
| `assign out = sr[i-1];` | The output is the last stage, i clocks after entry. |

## Results (Icarus, same code works in Vivado 2022.1)

```
PASS: skew N=4, lane i delayed by exactly i clocks (1000 clocks)

Test 1 walkthrough example, C from the array:
      5    0    1    6
      7    7    8    6
      3    8    3    5
      3    5    6    3
   finish-time check: 0 timing errors (PE(i,j) final after clock i+j+4, last = 10)
Test 2 random: 500 signed 4x4 matrix multiplies checked
PASS: systolic_core N=4, 0 errors
PASS: systolic_core N=8, 0 errors   (500 random 8x8)
```

- **Same C, same 10-clock latency** as step 2. Lane 0 is a wire, so the skew adds no extra clocks.
- **Bug check:** I made every lane delay by only 1 clock in a test copy. The testbench caught it with 5009 wrong values.

## Run it in Vivado 2022.1

1. Close any open simulation first (that avoids the `simulate.log` lock error).
2. Add Sources → design sources: `skew.v`, `systolic_core.v`. Keep `pe.v` and `systolic_array.v`.
3. Add Sources → simulation sources: `tb_skew.v`, `tb_systolic_core.v`.
4. Set `tb_skew` as Top, Run Behavioral Simulation, Run All. Expect `PASS: skew`.
5. Close the simulation, set `tb_systolic_core` as Top, run again. Expect the C matrix and `PASS: systolic_core N=4, 0 errors`.
6. Under Design Sources, `systolic_core` should now be the top (bold), with `u_skew_a`, `u_skew_b` and `u_array` under it. If not, right-click it → Set as Top.

## In the waveform, look for

- `dut.a_col_flat`: the 4 values change together on clocks 1 to 4.
- `dut.a_skewed`: the staircase. The byte for row 3 starts changing only on clock 4.
- `dut.u_skew_a.g_lane[3].sr[0..2]`: watch one value hop through the 3 registers.

## Interview chain on this step

1. *Why do you need skew?* Each PE passes data on one clock later, so row i reaches column j i+j clocks late. Input row i must start i clocks late so the right A and B pairs meet.
2. *How did you implement it?* With a triangle of shift registers: lane i has i flip-flops. That is N(N-1)/2 registers per matrix.
3. *Does the skew add latency?* No. Lane 0 is a wire. The total stays at 3N-2.
4. *Could memory provide skewed data instead?* Yes, by reading addresses staggered in time. But a shift register is simpler and keeps memory reads plain.
5. *How did you verify it?* With a unit test on the skew alone (random data, check delay = i), then the full core against a reference model, plus a deliberately broken skew to prove the testbench catches it.
