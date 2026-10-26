# Step 4: The Controller FSM

Until now the testbench did everything: clear the PEs, feed the columns at the right clocks, and decide when C was ready. Step 4 moves all of that into hardware. The design becomes a real accelerator with a simple interface:

1. Write A and B into on-chip buffers.
2. Pulse `start` for one clock.
3. Wait for `done`.
4. Read C.

That is exactly how software (or the AXI-Lite bus in step 5) will use it.

## Block diagram

```
 write port ──> [ A buffer 16x8b ]  [ B buffer 16x8b ]
                        │                   │
 start ──────> [ controller FSM ] ── picks column cnt of A, row cnt of B
                        │                   │
                [ systolic_core = skew + 4x4 array ]   (step 3, unchanged)
                        │
 read port <──  C (the 16 accumulators)            busy, done, cycles
```

## The state machine

```
          start                       cnt = N-1             cnt = 2N-3
  IDLE ─────────> CLEAR ──> FEED ───────────────> DRAIN ────────────────> DONE
   ^              1 clk     N clks                2N-2 clks               │
   └──────────────────────────── start (next run) ───────────────────────┘
```

| State | Clocks (N=4) | What it does | Why |
| --- | --- | --- | --- |
| IDLE | until start | waits; buffers can be written | nothing to do |
| CLEAR | 1 | drives `clear = 1` to all 16 PEs | removes the old result before a new run |
| FEED | N = 4 | sends column `cnt` of A and row `cnt` of B, cnt = 0..3 | the 4 inputs per lane, all at once (the skew staggers them) |
| DRAIN | 2N-2 = 6 | sends zeros | lets data travel to the far PEs; this is the (N-1)+(N-1) travel time |
| DONE | until next start | `done = 1`, C stays readable | software sees the result is ready |

**Total: 1 + 4 + 6 = 11 clocks from start to done (3N-1).** That is the ideal 10 plus the one CLEAR clock. This is the measured latency to quote.

## Key design decisions

| Decision | Why | What if not |
| --- | --- | --- |
| Inputs stored in on-chip buffers | The FSM can fetch column `cnt` itself, and the host only writes once. | The host would have to drive every clock exactly, which is the testbench's old job. |
| Writes ignored while `busy` | Data cannot change in the middle of a run. | A write during FEED would mix two different matrices into one result. Test 2 checks this. |
| `start` ignored while `busy` | A second start cannot restart a run halfway through. | A double-click on a button or a software bug would corrupt the result. |
| `done` stays high until the next start (a level, not a pulse) | Slow software can poll it at any time and not miss it. | A 1-clock pulse is easy to miss when polling over AXI. |
| `busy`/`done` decoded from the state | No extra flip-flops; they can never disagree with the FSM. | Separate registers can get out of sync. |
| `cycles` performance counter | Hardware measures its own latency. You quote the measured 11, not a calculated 10. | You would only have a paper number. |
| Feed mux is combinational from `cnt` | Column `cnt` is ready in the same clock the FSM is in FEED. | An extra register would add a clock and shift the timing. |

## Files

| File | Status |
| --- | --- |
| `systolic_top.v` | new: buffers, FSM, feed mux, read port, cycle counter |
| `tb_systolic_top.v` | new: write, start, wait, read, the same way software would |
| `pe.v`, `systolic_array.v`, `skew.v`, `systolic_core.v` | unchanged from steps 1 to 3 |

## Results (Icarus; same code for Vivado 2022.1)

```
Test 1 walkthrough example: start -> done in 11 clocks (expected 11)
   C read back through the read port:
      5    0    1    6
      7    7    8    6
      3    8    3    5
      3    5    6    3
Test 2 writes/start while busy ignored: ok
Test 3 random: 500 signed 4x4 runs, back to back, every run 11 clocks
PASS: systolic_top N=4, 0 errors
```

The 8x8 version also passes 500 runs, at 23 clocks each (3 x 8 - 1).

**The testbench catches bugs.** I tested two deliberate ones:
- Allowing writes while busy: caught with 4 errors.
- A DRAIN state one clock too short: caught with 503 errors, because the far PEs had not finished.

## Run it in Vivado 2022.1

1. Close any open simulation.
2. Add design source `systolic_top.v` and simulation source `tb_systolic_top.v`.
3. Under Design Sources, set `systolic_top` as Top. The hierarchy should show `u_core`, then `u_skew_a`, `u_skew_b` and `u_array`.
4. Under Simulation Sources, set `tb_systolic_top` as Top.
5. Run Behavioral Simulation, then `run -all`. This test is longer (about 392 µs of simulated time), so make sure the runtime is `-all`.
6. Expect `PASS: systolic_top N=4, 0 errors`.

## In the waveform, look for

Add `dut/state`, `dut/cnt`, `dut/busy`, `dut/done`, `dut/cycles`, `dut/a_col_flat` and `start`. For the first run:
- `start` is high for one clock, then `state` goes 1 → 2 (4 clocks) → 3 (6 clocks) → 4.
- `busy` is high for exactly 11 clocks, and `done` rises when `busy` falls.
- `a_col_flat` changes only while `state = 2` (FEED), and is 0 otherwise.
- `cycles` counts 1 to 11 and holds.

## Interview chain on this step

1. *Why do you need a controller?* The datapath needs exact timing: clear, N feed clocks, 2N-2 drain clocks. Software cannot drive signals clock by clock, so an FSM sequences it.
2. *Why is DRAIN 2N-2 clocks?* That is the time for data to travel N-1 PEs right plus N-1 PEs down to PE(N-1,N-1). A shorter DRAIN gives wrong results in the far corner (my test showed 503 errors).
3. *Why is done a level and not a pulse?* The host polls it over a bus. A level cannot be missed, and it clears on the next start.
4. *What protects against misuse?* Writes and start are ignored while busy. The testbench tries both mid-run and checks that the result is unaffected.
5. *What is the measured latency?* 11 clocks for 4x4 (3N-1): 1 clear + 4 feed + 6 drain. At 100 MHz that is 110 ns per 4x4 multiply.
6. *How would you get higher throughput?* Overlap runs: load the next A/B into a second buffer while the current one computes (double buffering), and unload C while the next run starts. That is upgrade step 9.
