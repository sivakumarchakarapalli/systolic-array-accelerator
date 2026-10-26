# Step 2: The 4x4 Array

Step 2 wires 16 copies of the step 1 PE into a grid. No new logic is added. The array is just PEs and wires.

## The wiring rule

```
            b_top[0]  b_top[1]  b_top[2]  b_top[3]
               |         |         |         |
  a_left[0] -> PE00 ---> PE01 ---> PE02 ---> PE03 -> (unused)
               |         |         |         |
  a_left[1] -> PE10 ---> PE11 ---> PE12 ---> PE13
               |         |         |         |
  a_left[2] -> PE20 ---> PE21 ---> PE22 ---> PE23
               |         |         |         |
  a_left[3] -> PE30 ---> PE31 ---> PE32 ---> PE33
               |         |         |         |
            (unused)
```

- `a_out` of PE(i,j) connects to `a_in` of PE(i,j+1), the PE on its right.
- `b_out` of PE(i,j) connects to `b_in` of PE(i+1,j), the PE below.
- The left edge takes `a_left[i]` and the top edge takes `b_top[j]`.
- The `acc` of PE(i,j) is C[i][j].

## How the code does it

| Code | Why |
| --- | --- |
| `wire [DW-1:0] a_h [0:N-1][0:N]` | One wire per horizontal hop. Row i has N+1 points: the input, the 3 links between PEs, and the output on the right edge. `a_h[i][j]` is the A value entering PE(i,j). |
| `wire [DW-1:0] b_v [0:N][0:N-1]` | The same idea, vertically. `b_v[i][j]` is the B value entering PE(i,j). |
| two nested `generate for` loops | Builds N x N PE instances. Change `N` and the whole grid is rebuilt; no copy-paste. |
| `.a_out(a_h[i][j+1])`, `.b_out(b_v[i+1][j])` | This single line pair is the systolic wiring. |
| flattened ports (`a_left_flat[i*DW +: DW]`) | Verilog-2005 ports cannot be 2-D arrays, so N values are packed into one wide bus. `+:` means "DW bits starting at this index". |
| `parameter N = 4` | The same file builds 8x8 or 16x16. The testbench proves 8x8 works too. |

## What is NOT in this step

The array does not delay its inputs. The testbench applies the skew itself: on clock t, row i gets `A[i][t-1-i]` and column j gets `B[t-1-j][j]`, with 0 outside the matrix. Step 3 moves that into hardware so the user can load A and B normally.

## Files

- `systolic_array.v`: the N x N array (uses `../step1/pe.v`)
- `tb_systolic_array.v`: a self-checking testbench
- `sim_n4.log`, `sim_n8.log`: my runs

## Run it

Icarus:
```
iverilog -g2005 -o sa ../step1/pe.v systolic_array.v tb_systolic_array.v
vvp sa
```
8x8 version:
```
iverilog -g2005 -Ptb_systolic_array.N=8 -o sa8 ../step1/pe.v systolic_array.v tb_systolic_array.v
vvp sa8
```
Vivado 2022.1: keep `pe.v`, add `systolic_array.v` as a design source and `tb_systolic_array.v` as a simulation source, set `tb_systolic_array` as top, run behavioral simulation, then Run All. For 8x8 in Vivado: Settings → Simulation → Simulation tab → Generics/Parameters, add `N` = 8 (the `-P` option above is Icarus only).

## Results

```
Test 1 walkthrough example, C from the array:
      5    0    1    6
      7    7    8    6
      3    8    3    5
      3    5    6    3
   finish-time check: 0 timing errors (PE(i,j) final after clock i+j+4, last = 10)
Test 2 random: 500 signed 4x4 matrix multiplies checked
PASS: systolic_array N=4, 0 errors
```
The 8x8 run also passes 500 random matrices.

- **C matches the walkthrough diagram and NumPy exactly.**
- **The finish-time table is confirmed in hardware.** Every PE(i,j) holds its final value exactly after clock i+j+4. The last one, PE(3,3), finishes on clock 10.

## Proof that the skew is needed

I removed the A skew in a copy of the testbench, so every row entered on clock 1. The array then reported **6012 wrong values and 252 timing errors**. That is the answer to "why not load everything at once": the wrong pairs meet.

## In the waveform, look for

- `dut.g_row[0].g_col[0].u_pe.acc` changes on clocks 1 to 4, then stays put.
- `dut.g_row[3].g_col[3].u_pe.acc` stays 0 until clock 7, then changes on clocks 7 to 10.
- Following one A value, `dut.a_h[0][0]` then `a_h[0][1]` and so on, it appears one clock later at each step to the right.

## Try this before step 3 (10 minutes)

Run with N=8 and confirm the last PE finishes after clock 22 (3 x 8 - 2).

## Interview chain on this step

1. *How do you build an N x N array in Verilog?* With nested `generate for` loops, using wire arrays for the links between neighbours.
2. *Why `genvar` and not `integer`?* `generate` loops build hardware at elaboration time, so the loop variable must be a `genvar`. It does not exist in the final circuit.
3. *How many DSPs does a 4x4 use?* 16, one per PE. An 8x8 uses 64. The Basys3 has 90, so a 9x9 array (81) is the largest that fits.
4. *What is the latency formula?* 3N-2 clocks for one N x N matrix, which the timing check confirmed.
5. *What happens to the A values leaving the right edge?* They are unused. Synthesis removes those last registers, so they cost nothing.
