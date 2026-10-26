# Step 1: The Processing Element (PE)

The PE is the only "smart" block in the array. The full 4x4 array is just 16 copies of it wired together, so if the PE is right, most of the design is right.

## What the PE does every clock

```
            b_in (from the PE above)
              |
a_in  ---->[ acc = acc + a_in*b_in ]----> a_out (to the PE on the right)
              |
            b_out (to the PE below)
```

1. Multiply the A value and the B value arriving this cycle.
2. Add the product into its own accumulator `acc`.
3. Register A and B and hand them to the right and bottom neighbours.

## Why each design choice

| Choice | Why | What if we didn't |
| --- | --- | --- |
| `signed` on every port and on `prod` | INT8 values are -128..127. Verilog multiplies as unsigned unless both operands are signed. | -1 x -1 would come out as 255 x 255 = 65025. The testbench catches this: making the multiply unsigned gives 999 errors out of 1000. |
| 16-bit product, 32-bit accumulator | 8b x 8b fits in 16b. A 4-term sum needs at most 18b, so 32b leaves room for bigger arrays later (up to 65,536 terms). | A 16b accumulator overflows: 4 x 16384 = 65536 does not fit. |
| `a_out <= a_in`, `b_out <= b_in` (registered) | The one-cycle delay per PE is what makes it systolic. Data moves one PE per clock, and every wire is short (neighbour to neighbour). | Without the register, A would ripple through all 4 PEs in one cycle. That makes a long combinational path, so Fmax drops and the timing alignment breaks. |
| `clear` input | Zeroes `acc` at the start of a new matrix without a full reset. | Old results from the last matrix would be added to the new one. |
| Synchronous active-high reset | Matches your AXI-Lite code and maps cleanly onto FPGA flip-flops. | An async reset is fine too, but keep one style across the whole design. |

## Files

- `pe.v`: the PE (about 50 lines)
- `tb_pe.v`: a self-checking testbench. It prints PASS or FAIL, not just values.
- `sim.log`: my run of it

## Run it yourself

Icarus:
```
iverilog -g2005 -o pe_sim tb_pe.v pe.v
vvp pe_sim
gtkwave pe.vcd
```
Vivado: add `pe.v` as a design source and `tb_pe.v` as a simulation source, set `tb_pe` as top, then Run Behavioral Simulation.

Expected output:
```
Test 1 corner cases : acc = 129 (expected 129)
Test 2 pass-through : a_out=37 b_out=-90 one clock later
Test 3 random       : 1000 dot products checked
PASS: pe, 0 errors
```

Test 1 works out as (-128)(-128) + (127)(-128) + (-1)(-1) + 0 = 16384 - 16256 + 1 = 129.

## In the waveform, look for

- `a_out` is `a_in` shifted right by exactly one clock.
- `acc` goes to 0 the cycle after `clear`, then steps by one product per clock.

## Try this before step 2 (5 minutes)

Remove `signed` from the `prod` line and rerun. Watch the errors appear, then put it back. This is the most common bug in INT8 MAC designs, and interviewers love it.

## Interview chain on this step

1. *What is a PE?* One MAC plus registers that pass the operands to its neighbours.
2. *Why register the outputs?* Data moves one hop per clock and wires stay local, so Fmax does not depend on array size.
3. *Why 32-bit accumulators?* Product is 16b. Summing K terms needs 16 + log2(K) bits. 32b is safe and standard.
4. *How does Verilog handle signed multiply?* Both operands must be signed. One unsigned operand makes the whole expression unsigned.
5. *On an FPGA, where does the multiply go?* Into a DSP48 slice. Step 7 will show 16 DSPs used, one per PE.
