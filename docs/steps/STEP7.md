# Step 7: The Basys3 Build

Steps 1 to 6 proved the design is *correct*. Step 7 proves it is *real hardware*. It answers the three questions every hardware interviewer asks:

1. **Does it fit?** How many DSPs, LUTs and flip-flops does it use?
2. **How fast can it run?** What is the Fmax from timing analysis?
3. **Does it work on silicon?** A PC sends matrices to the FPGA and checks the answers.

Questions 1 and 2 need only Vivado. Question 3 needs the board.

## The full system on the FPGA

```
  PC: systolic_uart.py
        │  USB cable (the same one used for programming)
        ▼
  ┌──────────────────── basys3_systolic (NEW top) ─────────────────────┐
  │  uart_rx ─> uart_axil_bridge ─> axil_master ══AXI4-Lite══> axil_systolic │
  │  uart_tx <─────────┘     (from your AXI project)          (steps 1-5)  │
  │                                                                       │
  │  LEDs + 7-segment display                                             │
  └───────────────────────────────────────────────────────────────────────┘
```
This joins your two projects: the AXI4-Lite master and the UART bridge drive the accelerator.

**On the board:**

| What | Meaning |
| --- | --- |
| btnC (centre button) | reset |
| LED 15 | blinks about 1.5 times per second: the clock is running and the bitstream is loaded |
| LED 2 | flickers while the PC is talking |
| LED 0 / LED 1 | the last write or read got an error response, which should stay off |
| 7-segment | low 16 bits of the last value the PC read. After the demo it shows `0003`, which is C[3][3]. |

## Files

| File | Where it goes in Vivado | Status |
| --- | --- | --- |
| `basys3_systolic.v` | Design source, **the new Top** | new |
| `uart_rx.v`, `uart_tx.v`, `uart_axil_bridge.v` | Design sources | copied from your AXI project, unchanged apart from adding `timescale` |
| `axil_master.v` | **move it from Simulation to Design sources**, because it is now real hardware | from step 5 |
| `basys3_systolic.xdc` | Constraints | new: pins and the 100 MHz clock |
| `tb_basys3_systolic.v` | Simulation source (optional) | new: tests the whole board design through the UART pin |
| `systolic_uart.py` | runs on your PC, not in Vivado | new |

## What I checked here

**Board-level simulation.** The testbench acts as the PC and talks only through the UART pin. It runs the first 10 step-6 tests from NumPy, including all the corner cases:
```
Ping reply: 0x50   (ok)
ID over UART: 0x5a000408
  test  0 ok   (7-seg shows 0003 = C[3][3])
  ...
  test  9 ok   (7-seg shows 0df7 = C[3][3])
PASS: board design over UART, 10 jobs == NumPy
$finish called at time : 8694915 ns
```

**Trial synthesis with Yosys**, an open-source tool, for xc7. These are estimates. Your Vivado numbers are the ones to quote.

| Resource | Used (Yosys estimate) | Basys3 has | |
| --- | --- | --- | --- |
| DSP48E1 | **16** | 90 | one per PE: the 8×8 multiply plus the 32-bit add fit inside each DSP |
| LUTs | about 600, plus 64 as LUT-RAM | 20,800 | about 3% |
| Flip-flops | about 780 | 41,600 | about 2% |
| Block RAM | 0 | 50 | the A and B buffers are small, so they become LUT-RAM |

The most important line is **16 DSPs = 16 PEs**. Every multiply-accumulate maps onto a hard DSP slice, so the array scales: an 8x8 array would need 64 DSPs, which still fits in 90.

## Run it in Vivado 2022.1

### Part A: add the files (no board needed)

1. **Check the part.** Go to Settings (Flow Navigator) → General → Project device. It must be `xc7a35tcpg236-1`. If it isn't, click "..." and choose it.
2. **Add design sources.** Click Add Sources → *Add or create design sources* → Add Files. Add `basys3_systolic.v`, `uart_rx.v`, `uart_tx.v` and `uart_axil_bridge.v`. Tick *Copy sources into project* and click Finish.
3. **Move axil_master.v to design sources.** In the Sources window, under Simulation Sources, right-click `axil_master.v` and choose **Move to Design Sources**. It was only a test helper before; now it is real hardware between the UART bridge and the accelerator.
   * If your menu has no "Move to Design Sources", right-click → *Remove File from Project*, then add the same file again with *Add or create design sources*.
4. **Add the constraints.** Click Add Sources → *Add or create constraints* → Add Files → `basys3_systolic.xdc` → Finish.
5. **Set the top.** Right-click `basys3_systolic` under Design Sources → **Set as Top**. The tree should look like this:
   ```
   basys3_systolic
    ├─ u_rx : uart_rx
    ├─ u_tx : uart_tx
    ├─ u_bridge : uart_axil_bridge
    ├─ u_master : axil_master
    ├─ u_acc : axil_systolic
    │    └─ u_acc : systolic_top ─ u_core ─ skews + array (16 PEs)
    └─ u_7seg : sevenseg_hex4
   ```

### Part B (optional): simulate the board design

1. Add `tb_basys3_systolic.v` as a simulation source. The step 6 `.mem` files are already in the project, so it reuses them.
2. Set `tb_basys3_systolic` as the simulation Top and run Behavioral Simulation.
3. It simulates 8.7 ms of UART traffic, which can take a few minutes.
4. Expect `PASS: board design over UART, 10 jobs == NumPy`.

### Part C: synthesis, implementation and reports (no board needed)

1. In the Flow Navigator, click **Run Synthesis** and click OK. Wait for "Synthesis successfully completed".
2. Choose **Run Implementation** and click OK. This takes a few minutes.
3. Open the implemented design. Then:
   * **Reports → Report Utilization** gives the LUTs, FFs, DSPs and BRAM. Take a screenshot.
   * **Reports → Report Timing Summary** gives WNS (Worst Negative Slack). It must be **positive**, which means timing is met at 100 MHz.
4. **Calculate Fmax** from WNS:
   ```
   Fmax = 1000 / (10 - WNS)   MHz          (10 ns = the 100 MHz clock period)
   e.g. WNS = 4.0 ns  ->  Fmax = 1000 / 6.0 = 166 MHz
   ```
5. In the Timing Summary, click the worst path to see where it starts and ends. That is your **critical path**. Note it, because interviewers ask "what limits your clock?"
6. Click **Generate Bitstream**. This produces `basys3_systolic.bit` in `systolic_array.runs/impl_1/`.

**Send me:** the utilization table, the WNS, and the start and end points of the worst path.

### Part D: on the board

1. Connect the Basys3 with the micro-USB cable and turn the power switch ON.
2. Click **Open Hardware Manager → Open Target → Auto Connect**, then **Program Device** with the .bit file.
3. LED 15 should start blinking.
4. On the PC, run `pip install pyserial numpy`. Find the COM port in Device Manager → Ports (COM & LPT); it is usually the higher of the two numbers.
5. Run:
   ```
   python systolic_uart.py COM5 ping           -> ping: ok, ID: 0x5a000408
   python systolic_uart.py COM5 demo           -> C from the FPGA = walkthrough matrix, PASS
   python systolic_uart.py COM5 test -n 200    -> PASS: FPGA == NumPy on all 200 jobs
   ```
6. Replace COM5 with your port number.

## The lesson this step teaches: where the time goes

| Path | Time per 4x4 job |
| --- | --- |
| Compute inside the array | 11 clocks = **110 ns** |
| Over the AXI4-Lite bus (step 6) | 245 clocks = **2.45 µs** |
| Over UART from the PC at 115200 baud | about **50 ms**, roughly 10 to 20 jobs per second |

UART is about **450,000×** slower than the compute. The FPGA spends almost all its time waiting for data. This is the "memory wall" in miniature, and it is the reason real accelerators (GPUs, TPUs) put most of their design effort into data movement: HBM, DMA engines, on-chip buffers and wide buses.

## Interview chain on this step

1. *How many resources does it use?* Give your Vivado numbers. The key point is 16 DSP48 slices, one per PE: the multiply and the accumulate map onto the DSP's built-in multiply-add.
2. *What is your Fmax and what limits it?* Quote the number from WNS and name the critical-path start and end points.
3. *Did you run it on hardware?* Yes, on a Basys3 (Artix-7). A Python driver sends matrices over UART→AXI, and the results match NumPy on 200 random jobs.
4. *What would you change for a real product?* Replace UART with PCIe or Ethernet plus DMA, use AXI-Stream for bulk data, and double-buffer A and B so loading overlaps with compute.
5. *How did you reuse your earlier work?* The UART bridge and AXI master came from my AXI4-Lite project unchanged. Only the slave behind the bus is new.

## Results from Vivado 2022.1 (GJVS, 2026-10-25)

Timing closure, one fix at a time. Every version passed the same testbenches with the same 11-clock latency.

| Version | DSP48 | LUTs | FFs | WNS @100 MHz | Fmax | Critical path |
| --- | --- | --- | --- | --- | --- | --- |
| 1. Default synthesis | 0 | 2012 | 1411 | n/a | n/a | multipliers built from LUTs |
| 2. `use_dsp` in pe.v | 16 | 549 | 771 | +1.986 ns | 125 MHz | FSM `cnt` → buffer LUT-RAM → feed mux → DSP of PE(0,0) |
| 3. Registered lookahead feed | 16 | n/a | n/a | +3.142 ns | 146 MHz | reset LUT, fanout 714 → DSP reset pins |
| 4. Registered, replicated reset | 16 | n/a | n/a | **+4.233 ns** | **173 MHz** | (final) |

Fmax = 1000 / (10 − WNS). Peak compute at 173 MHz: 16 MAC/clock × 173 MHz ≈ **2.8 GMAC/s**.
