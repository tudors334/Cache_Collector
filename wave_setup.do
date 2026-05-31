# wave_setup.do  –  Compileaza, simuleaza si adauga semnale in wave
# Seed aleator generat la fiecare rulare din ora/minutul/secunda sistemului
# Folosire: do wave_setup.do

# =========================================================================
# Genereaza seed din timp (ora * 3600 + minute * 60 + secunde)
# Astfel fiecare rulare are un seed unic si reproductibil (daca stii ora)
# =========================================================================
set now      [clock seconds]
set hh       [clock format $now -format "%H"]
set mm       [clock format $now -format "%M"]
set ss       [clock format $now -format "%S"]
set run_seed [expr {int(($hh * 3600) + ($mm * 60) + $ss)}]

echo ""
echo "================================================================="
echo "  SEED generat din timp: ora=$hh min=$mm sec=$ss -> SEED=$run_seed"
echo "================================================================="
echo ""

# =========================================================================
# Compilare
# =========================================================================
vlog cache_controller.v cache_tb.v

# =========================================================================
# Simulare cu seed injectat ca parameter generic
# Nota: -GNAME=VALUE este sintaxa corecta pentru ModelSim 6.5b (fara spatiu)
# int() previne Tcl sa adauge '.' la numere floating point
# =========================================================================
onbreak {resume}
vsim -t 1ps -GSEED=$run_seed cache_tb
onbreak {}

wave zoom full

add wave -divider "=== CONTROL ==="
add wave -color Gold     -label "CLK"         /cache_tb/clk
add wave -color Red      -label "RST"         /cache_tb/rst

add wave -divider "=== CPU ==="
add wave -color Cyan     -label "cpu_req"     /cache_tb/cpu_req
add wave -color Cyan     -label "cpu_rw"      /cache_tb/cpu_rw
add wave -color Cyan     -label "cpu_addr"    /cache_tb/cpu_addr
add wave -color Cyan     -label "cpu_wr_data" /cache_tb/cpu_wr_data
add wave -color Yellow   -label "cpu_rd_data" /cache_tb/cpu_rd_data
add wave -color Green    -label "cpu_ready"   /cache_tb/cpu_ready

add wave -divider "=== MEMORIE PRINCIPALA ==="
add wave -color Orange   -label "mem_req"     /cache_tb/mem_req
add wave -color Orange   -label "mem_rw"      /cache_tb/mem_rw
add wave -color Orange   -label "mem_addr"    /cache_tb/mem_addr
add wave -color Red      -label "mem_ready"   /cache_tb/mem_ready

add wave -divider "=== FSM CACHE ==="
add wave -color Magenta  -label "FSM_state"   /cache_tb/w_fsm_state
add wave -color Magenta  -label "cache_hit"   /cache_tb/dut/cache_hit
add wave -color Magenta  -label "victim_way"  /cache_tb/dut/victim
add wave -color Magenta  -label "hit_way"     /cache_tb/dut/hit_way

add wave -divider "=== TRANZACTII ==="
add wave -color Cyan     -label "OP 0R-1W"    /cache_tb/w_op
add wave -color Yellow   -label "HIT-MISS"    /cache_tb/w_hit
add wave -color Red      -label "EVICT"       /cache_tb/w_evict
add wave -color White    -label "ADDR"        /cache_tb/w_addr
add wave -color LightBlue -label "WR_DATA"    /cache_tb/w_wdata
add wave -color LightBlue -label "RD_DATA"    /cache_tb/w_rdata

add wave -divider "=== STATISTICI ==="
add wave -color Green    -label "TOTAL"       /cache_tb/w_total
add wave -color Green    -label "HITS"        /cache_tb/w_hits
add wave -color Red      -label "MISSES"      /cache_tb/w_misses
add wave -color Orange   -label "EVACUARI"    /cache_tb/w_evictions
add wave -color Gold     -label "HIT RATE %"  /cache_tb/w_hitrate

add wave -divider "=== SEED (reproductibilitate) ==="
add wave -color White    -label "SEED"        /cache_tb/mem_seed

add wave -divider "=== ADRESA DECODATA ==="
add wave -color White    -label "TAG"         /cache_tb/dut/s_tag
add wave -color White    -label "INDEX"       /cache_tb/dut/s_index
add wave -color White    -label "WORD"        /cache_tb/dut/s_word

run -all

wave zoom full
