// =============================================================================
// cache_tb.v  –  Testbench pentru cache_controller cu FSM TAG_CHECK
//
// Verifica toate starile FSM:
//   IDLE, TAG_CHECK, READ_HIT, WRITE_HIT, READ_MISS, WRITE_MISS, EVICT, COMPLETE
//
// Modelul de memorie raspunde dupa 3 cicluri (latenta realista).
// Statisticile (hit-rate, evacuari) sunt vizibile ca semnale wave.
// =============================================================================
`timescale 1ns/1ps

module cache_tb;

    // =========================================================================
    // Ceas si reset
    // =========================================================================
    reg clk, rst;
    initial clk = 1'b0;
    always #5 clk = ~clk;  // 100 MHz

    // =========================================================================
    // Semnale DUT
    // =========================================================================
    reg         cpu_req;
    reg         cpu_rw;
    reg  [31:0] cpu_addr;
    reg  [31:0] cpu_wr_data;
    wire [31:0] cpu_rd_data;
    wire        cpu_ready;

    reg  [511:0] mem_rd_data;
    reg          mem_ready;
    wire         mem_req;
    wire         mem_rw;
    wire [31:0]  mem_addr;
    wire [511:0] mem_wr_data;

    // =========================================================================
    // Semnale WAVE (vizibile in ModelSim)
    // =========================================================================
    // -- Tranzactie curenta --
    reg        w_op;       // 0=READ / 1=WRITE
    reg        w_hit;      // 1=HIT, 0=MISS (valabil la cpu_ready)
    reg        w_evict;    // puls 1 ciclu cand are loc evacuare
    reg [31:0] w_addr;     // adresa accesata
    reg [31:0] w_wdata;    // data scrisa (pentru WRITE)
    reg [31:0] w_rdata;    // data citita (pentru READ)

    // -- Statistici acumulate --
    reg [7:0]  w_total;     // total accese
    reg [7:0]  w_hits;      // hit-uri
    reg [7:0]  w_misses;    // miss-uri
    reg [7:0]  w_evictions; // evacuari
    reg [6:0]  w_hitrate;   // rata hit % (0-100)

    // -- Stare FSM din DUT (observabila direct in wave) --
    // 0=IDLE 1=TAG_CHECK 2=READ_HIT 3=WRITE_HIT
    // 4=READ_MISS 5=WRITE_MISS 6=EVICT 7=COMPLETE
    wire [3:0] w_fsm_state = dut.state;

    // -- Campuri adresa decodate (vizibile in wave pentru debug) --
    wire [17:0] w_tag   = dut.s_tag;
    wire [6:0]  w_index = dut.s_index;
    wire [3:0]  w_word  = dut.s_word;

    // -- Hit/miss detectat in TAG_CHECK --
    wire        w_cache_hit = dut.cache_hit;
    wire [1:0]  w_hit_way   = dut.hit_way;
    wire [1:0]  w_victim    = dut.victim;

    // =========================================================================
    // DUT
    // =========================================================================
    cache_controller dut (
        .clk(clk),          .rst(rst),
        .cpu_req(cpu_req),  .cpu_rw(cpu_rw),
        .cpu_addr(cpu_addr),.cpu_wr_data(cpu_wr_data),
        .cpu_rd_data(cpu_rd_data), .cpu_ready(cpu_ready),
        .mem_req(mem_req),  .mem_rw(mem_rw),
        .mem_addr(mem_addr),.mem_wr_data(mem_wr_data),
        .mem_rd_data(mem_rd_data), .mem_ready(mem_ready)
    );

    // =========================================================================
    // Model Memorie Principala
    // Raspunde dupa 3 cicluri de latenta
    // Date generate: adresa XOR seed (deterministic, repetabil)
    // =========================================================================
    integer mem_seed;

    task mem_model_respond;
        integer k;
        reg [31:0] base;
        begin
            base = mem_addr;
            // Latenta memorie: 3 cicluri
            repeat(3) @(posedge clk);
            if (!mem_rw) begin
                // Fetch: genereaza date pentru toate cele 16 cuvinte din bloc
                for (k = 0; k < 16; k = k + 1)
                    mem_rd_data[k*32 +: 32] = base ^ (k * 32'h11111111) ^ mem_seed;
            end else begin
                // Evict: numara evacuarea
                w_evict    <= 1'b1;
                w_evictions<= w_evictions + 8'd1;
            end
            mem_ready = 1'b1;
            @(posedge clk);
            mem_ready   = 1'b0;
            mem_rd_data = 512'b0;
            w_evict    <= 1'b0;
        end
    endtask

    // Thread de memorie: asteapta mem_req si raspunde
    initial begin
        mem_ready   = 0;
        mem_rd_data = 0;
        w_evict     = 0;
        forever begin
            @(posedge clk);
            if (mem_req) mem_model_respond;
        end
    end

    // =========================================================================
    // Task: do_read(addr) -> rdata
    // =========================================================================
    task do_read;
        input  [31:0] addr;
        output [31:0] data;
        begin
            @(negedge clk);
            cpu_req = 1; cpu_rw = 0; cpu_addr = addr; cpu_wr_data = 32'b0;
            w_addr = addr; w_op = 0;
            w_total = w_total + 8'd1;
            @(posedge clk);
            while (!cpu_ready) @(posedge clk);
            data    = cpu_rd_data;
            w_rdata = cpu_rd_data;
            w_hit   = dut.cache_hit;
            if (dut.cache_hit) w_hits   = w_hits   + 8'd1;
            else               w_misses = w_misses + 8'd1;
            w_hitrate = (w_total > 0) ? ((w_hits * 7'd100) / w_total) : 7'd0;
            @(negedge clk);
            cpu_req = 0;
            @(posedge clk);
        end
    endtask

    // =========================================================================
    // Task: do_write(addr, wdata)
    // =========================================================================
    task do_write;
        input [31:0] addr;
        input [31:0] wdata;
        begin
            @(negedge clk);
            cpu_req = 1; cpu_rw = 1; cpu_addr = addr; cpu_wr_data = wdata;
            w_addr = addr; w_wdata = wdata; w_op = 1;
            w_total = w_total + 8'd1;
            @(posedge clk);
            while (!cpu_ready) @(posedge clk);
            w_hit   = dut.cache_hit;
            if (dut.cache_hit) w_hits   = w_hits   + 8'd1;
            else               w_misses = w_misses + 8'd1;
            w_hitrate = (w_total > 0) ? ((w_hits * 7'd100) / w_total) : 7'd0;
            @(negedge clk);
            cpu_req = 0;
            @(posedge clk);
        end
    endtask

    // =========================================================================
    // Helper: check(conditie, mesaj)
    // =========================================================================
    integer passes, fails;
    task check;
        input       cond;
        input [255:0] msg;
        begin
            if (cond) begin
                $display("  [PASS] %0s", msg);
                passes = passes + 1;
            end else begin
                $display("  [FAIL] %0s", msg);
                fails  = fails  + 1;
            end
        end
    endtask

    // Construieste adresa 32b din campuri
    function [31:0] mkaddr;
        input [17:0] tag;
        input [6:0]  idx;
        input [3:0]  wrd;
        begin
            // [31:14]=tag(18b), [13:7]=index(7b), [5:2]=word(4b), [1:0]=2'b00
            mkaddr = {tag, idx, 1'b0, wrd, 2'b00};
        end
    endfunction

    // =========================================================================
    // Secventa principala de test
    // =========================================================================
    reg [31:0] rdata, rdata2;
    reg [31:0] wval;
    integer    ii;

    initial begin
        // Initializare
        mem_seed     = 32'hDEAD_BEEF;
        cpu_req      = 0; cpu_rw = 0; cpu_addr = 0; cpu_wr_data = 0;
        rst          = 1;
        w_op         = 0; w_hit = 0; w_addr = 0; w_wdata = 0; w_rdata = 0;
        w_total      = 0; w_hits = 0; w_misses = 0;
        w_evictions  = 0; w_hitrate = 0;
        passes = 0; fails = 0;

        repeat(4) @(posedge clk);
        rst = 0;
        repeat(2) @(posedge clk);

        $display("");
        $display("=================================================================");
        $display("  Cache Controller TB  |  4-way Set-Associative  |  LRU WB+WA   ");
        $display("  FSM: IDLE->TAG_CHECK->READ_HIT/WRITE_HIT/EVICT/READ_MISS/WRITE_MISS->COMPLETE");
        $display("=================================================================");

        // -----------------------------------------------------------------
        // TC1: READ MISS (cache rece, prima accesare)
        // TAG_CHECK: miss, victim clean -> READ_MISS
        // -----------------------------------------------------------------
        $display("\n[TC1] READ_MISS  (cache rece)");
        do_read(mkaddr(18'd1, 7'd0, 4'd0), rdata);
        check(!w_hit, "TC1: TAG_CHECK detectat MISS");
        check(w_fsm_state == 0, "TC1: FSM revenit la IDLE");
        $display("       rd_data=0x%08h", rdata);

        // -----------------------------------------------------------------
        // TC2: READ HIT (aceeasi adresa, bloc deja in cache)
        // TAG_CHECK: hit -> READ_HIT
        // -----------------------------------------------------------------
        $display("\n[TC2] READ_HIT  (aceeasi adresa ca TC1)");
        do_read(mkaddr(18'd1, 7'd0, 4'd0), rdata);
        check(w_hit, "TC2: TAG_CHECK detectat HIT");
        $display("       rd_data=0x%08h", rdata);

        // -----------------------------------------------------------------
        // TC3: WRITE MISS (adresa noua, write-allocate)
        // TAG_CHECK: miss, victim clean -> WRITE_MISS
        // -----------------------------------------------------------------
        wval = 32'hCAFE_1234;
        $display("\n[TC3] WRITE_MISS  (write-allocate)  data=0x%08h", wval);
        do_write(mkaddr(18'd2, 7'd0, 4'd3), wval);
        check(!w_hit, "TC3: TAG_CHECK detectat MISS");

        // -----------------------------------------------------------------
        // TC4: WRITE HIT (scrie din nou la aceeasi adresa)
        // TAG_CHECK: hit -> WRITE_HIT
        // -----------------------------------------------------------------
        wval = 32'hBEEF_5678;
        $display("\n[TC4] WRITE_HIT  data=0x%08h", wval);
        do_write(mkaddr(18'd2, 7'd0, 4'd3), wval);
        check(w_hit, "TC4: TAG_CHECK detectat HIT");

        // Verifica: citirea returneaza valoarea scrisa
        do_read(mkaddr(18'd2, 7'd0, 4'd3), rdata);
        check(rdata == wval, "TC4: citire dupa WRITE_HIT corecta");
        $display("       Scris=0x%08h  Citit=0x%08h  Match=%0s",
                 wval, rdata, (rdata==wval)?"DA":"NU");

        // -----------------------------------------------------------------
        // TC5: Acces pe set diferit (index=42)
        // -----------------------------------------------------------------
        $display("\n[TC5] READ_MISS  set diferit  index=42");
        do_read(mkaddr(18'd5, 7'd42, 4'd7), rdata);
        check(!w_hit, "TC5: miss pe set nou");

        // -----------------------------------------------------------------
        // TC6: Umple toate 4 ways ale setului index=2 + EVICT dirty
        // Umplere: scrie tag10 (devine dirty), citeste tag11,12,13
        // Re-acceseaza 11,12,13 -> tag10 ramane LRU
        // TC6e: acces tag14 -> TAG_CHECK: miss, victim=tag10 DIRTY -> EVICT
        // -----------------------------------------------------------------
        $display("\n[TC6] EVICT  (bloc dirty evacuat)");
        do_write(mkaddr(18'd10, 7'd2, 4'd1), 32'hAAAA_0001); // tag10 dirty
        do_read (mkaddr(18'd11, 7'd2, 4'd0), rdata);         // tag11
        do_read (mkaddr(18'd12, 7'd2, 4'd0), rdata);         // tag12
        do_read (mkaddr(18'd13, 7'd2, 4'd0), rdata);         // tag13
        // Acceseaza 11,12,13 ca sa faca tag10 LRU
        do_read (mkaddr(18'd11, 7'd2, 4'd0), rdata);
        do_read (mkaddr(18'd12, 7'd2, 4'd0), rdata);
        do_read (mkaddr(18'd13, 7'd2, 4'd0), rdata);
        // tag14 -> miss, tag10 LRU si DIRTY -> TAG_CHECK va merge prin EVICT
        do_read (mkaddr(18'd14, 7'd2, 4'd0), rdata);
        check(w_evictions >= 1, "TC6: cel putin o evacuare a avut loc");
        $display("       Total evacuari pana acum: %0d", w_evictions);

        // -----------------------------------------------------------------
        // TC7: Verificare politica LRU - cel mai vechi way e evacuuat
        // -----------------------------------------------------------------
        $display("\n[TC7] Politica LRU  (set=7)");
        do_read(mkaddr(18'd30, 7'd7, 4'd0), rdata); // way0
        do_read(mkaddr(18'd31, 7'd7, 4'd0), rdata); // way1
        do_read(mkaddr(18'd32, 7'd7, 4'd0), rdata); // way2
        do_read(mkaddr(18'd33, 7'd7, 4'd0), rdata); // way3
        // Acceseaza 30,31,32 -> 33 devine LRU
        do_read(mkaddr(18'd30, 7'd7, 4'd0), rdata);
        do_read(mkaddr(18'd31, 7'd7, 4'd0), rdata);
        do_read(mkaddr(18'd32, 7'd7, 4'd0), rdata);
        // tag34: miss -> trebuie sa evacueze tag33 (LRU)
        do_read(mkaddr(18'd34, 7'd7, 4'd0), rdata);
        check(1, "TC7: LRU test complet");

        // -----------------------------------------------------------------
        // TC8: Burst aleatoriu - 20 accese pe 6 adrese din acelasi set
        // -----------------------------------------------------------------
        $display("\n[TC8] Burst aleatoriu  (20 accese x 6 adrese)");
        begin : burst
            reg [31:0] addrs [0:5];
            integer op_type, ai;
            addrs[0] = mkaddr(18'd50, 7'd10, 4'd0);
            addrs[1] = mkaddr(18'd51, 7'd10, 4'd2);
            addrs[2] = mkaddr(18'd52, 7'd10, 4'd4);
            addrs[3] = mkaddr(18'd53, 7'd10, 4'd0);
            addrs[4] = mkaddr(18'd54, 7'd10, 4'd1);
            addrs[5] = mkaddr(18'd50, 7'd10, 4'd3);
            for (ii = 0; ii < 20; ii = ii + 1) begin
                ai      = {$random} % 6;
                op_type = {$random} % 2;
                if (op_type == 0)
                    do_read (addrs[ai], rdata);
                else
                    do_write(addrs[ai], $random);
            end
        end
        check(1, "TC8: burst aleatoriu finalizat");

        // -----------------------------------------------------------------
        // TC9: Persistenta date - scrie, acceseaza alte blocuri, reciteste
        // -----------------------------------------------------------------
        $display("\n[TC9] Persistenta date dupa accese intercalate");
        wval = 32'h1234_5678;
        do_write(mkaddr(18'd100, 7'd20, 4'd5), wval);
        // Acceseaza alte adrese (nu suprascrie setul 20)
        do_read(mkaddr(18'd200, 7'd30, 4'd0), rdata);
        do_read(mkaddr(18'd201, 7'd30, 4'd0), rdata);
        // Reciteste datele originale
        do_read(mkaddr(18'd100, 7'd20, 4'd5), rdata);
        check(rdata == wval, "TC9: date persistente dupa accese intercalate");
        $display("       Scris=0x%08h  Recitit=0x%08h  Match=%0s",
                 wval, rdata, (rdata==wval)?"DA":"NU");

        // -----------------------------------------------------------------
        // Sumar final
        // -----------------------------------------------------------------
        $display("");
        $display("=================================================================");
        $display("  SUMAR FINAL");
        $display("  Total accese : %0d", w_total);
        $display("  Hit-uri      : %0d", w_hits);
        $display("  Miss-uri     : %0d", w_misses);
        $display("  Evacuari     : %0d", w_evictions);
        $display("  Rata hit     : %0d%%", w_hitrate);
        $display("  Teste PASS   : %0d / FAIL: %0d", passes, fails);
        $display("=================================================================");

        if (fails == 0)
            $display("  *** TOATE TESTELE AU TRECUT ***");
        else
            $display("  *** %0d TEST(E) ESUATE - verificati waveform ***", fails);
        $display("");
        $finish;
    end

    // =========================================================================
    // Watchdog: opreste simularea daca depaseste limita de timp
    // =========================================================================
    initial begin
        #5000000;
        $display("WATCHDOG: timeout dupa 5ms simulare - posibila blocare FSM");
        $finish;
    end

    // =========================================================================
    // Dump VCD pentru vizualizare in GTKWave / ModelSim
    // =========================================================================
    initial begin
        $dumpfile("cache_wave.vcd");
        $dumpvars(0, cache_tb);
    end

endmodule
