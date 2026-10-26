#!/usr/bin/env bash
# Runs every testbench with Icarus Verilog (iverilog/vvp). From the repo root:
#   bash scripts/run_sims.sh
set -e
cd "$(dirname "$0")/.."
ROOT=$PWD; OUT=$ROOT/build; mkdir -p "$OUT"
CORE="rtl/pe.v rtl/systolic_array.v rtl/skew.v rtl/systolic_core.v rtl/systolic_top.v"
AXI="rtl/axil_systolic.v fpga/axil_master.v sim/axil_checker.v"
UART="fpga/uart_rx.v fpga/uart_tx.v fpga/uart_axil_bridge.v fpga/basys3_systolic.v"
fail=0
run() {  # name, run-dir, sources...
  local name=$1 dir=$2; shift 2
  iverilog -g2005 -o "$OUT/$name" "$@" 2>/dev/null
  local res; res=$(cd "$dir" && vvp -n "$OUT/$name" | grep -E "^(PASS|FAIL)" | tail -1)
  printf "%-22s %s\n" "$name" "$res"
  [[ $res == PASS* ]] || fail=1
}
run tb_pe              .                    rtl/pe.v sim/tb_pe.v
run tb_systolic_array  .                    rtl/pe.v rtl/systolic_array.v sim/tb_systolic_array.v
run tb_skew            .                    rtl/skew.v sim/tb_skew.v
run tb_systolic_core   .                    rtl/pe.v rtl/systolic_array.v rtl/skew.v rtl/systolic_core.v sim/tb_systolic_core.v
run tb_systolic_top    .                    $CORE sim/tb_systolic_top.v
run tb_axil_systolic   .                    $CORE $AXI sim/tb_axil_systolic.v
run tb_packed          .                    $CORE $AXI sim/tb_packed.v
run tb_system          sim/vectors/system   $CORE $AXI sim/tb_system.v
run tb_basys3_systolic sim/vectors/system   $CORE rtl/axil_systolic.v fpga/axil_master.v $UART sim/tb_basys3_systolic.v
run tb_mnist           sim/vectors/mnist    $CORE $AXI sim/tb_mnist.v
run tb_mnist_fast      sim/vectors/mnist    $CORE $AXI sim/tb_mnist_fast.v
rm -f sim/vectors/system/hw_results.txt
[ $fail = 0 ] && echo "ALL TESTBENCHES PASS" || { echo "SOME TESTBENCHES FAILED"; exit 1; }
