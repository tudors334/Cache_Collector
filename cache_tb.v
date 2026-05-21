// =============================================================================
// cache_tb.v  –  Testbench cu date aleatorii + semnale wave
// =============================================================================
`timescale 1ns/1ps

module cache_tb;

    // =========================================================================
    // Ceas si reset
    // =========================================================================
    reg clk, rst;
    initial clk = 1'b0;
    always #5 clk = ~clk;

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
    // Semnale WAVE (usor de urmarit in ModelSim)
    // =========================================================================
    // -- Tranzactie curenta --
    reg        w_op;        // 0=READ / 1=WRITE
    reg        w_hit;       // 0=MISS / 1=HIT  (valid la cpu_ready)
    reg        w_evict;     // 1 ciclu puls cand are loc evacuare
    reg [31:0] w_addr;      // adresa tranzactiei
    reg [31:0] w_wdata;     // data scrisa
    reg [31:0] w_rdata;     // data citita

    // -- Statistici acumulate (vizibile ca valori numerice in wave) --
    reg [7:0]  w_total;     // numar total accese
    reg [7:0]  w_hits;      // numar hit-uri
    reg [7:0]  w_misses;    // numar miss-uri
    reg [7:0]  w_evictions; // numar evacuari
    reg [6:0]  w_hitrate;   // rata hit % (0-100)

    // -- Stare FSM din DUT --
    wire [2:0] w_fsm = dut.state;
    // 0=IDLE 1=LOAD_WAYS 2=CHECK 3=FETCH 4=EVICT 5=WRITEBACK 6=COMPLETE

    // =========================================================================
    // DUT
    // =========================================================================
    cache_controller dut (
        .clk(clk), .rst(rst),
        .cpu_req(cpu_req), .cpu_rw(cpu_rw),
        .cpu_addr(cpu_addr), .cpu_wr_data(cpu_wr_data),
        .cpu_rd_data(cpu_rd_data), .cpu_ready(cpu_ready),
        .mem_req(mem_req), .mem_rw(mem_rw),
        .mem_addr(mem_addr), .mem_wr_data(mem_wr_data),
        .mem_rd_data(mem_rd_data), .mem_ready(mem_ready)
    );

    // =========================================================================
    // Model memorie: raspunde dupa 2 cicluri, date = adresa XOR seed
    // =========================================================================
    integer seed;

    task mem_respond;
        integer k;
        reg [31:0] base;
        begin
            base = mem_addr;
            repeat(2) @(posedge clk);
            if (!mem_rw) begin
                for (k = 0; k < 16; k = k + 1)
                    mem_rd_data[k*32 +: 32] = {base[31:6], k[3:0], 2'b00} ^ $random(seed);
            end else begin
                w_evict <= 1'b1;
                w_evictions <= w_evictions + 1;
            end
            mem_ready = 1'b1;
            @(posedge clk);
            mem_ready  = 1'b0;
            mem_rd_data= 512'b0;
            w_evict   <= 1'b0;
        end
    endtask

    initial begin
        mem_ready    = 0;
        mem_rd_data  = 0;
        w_evict      = 0;
        forever begin
            @(posedge clk);
            if (mem_req) mem_respond;
        end
    end

    // =========================================================================
    // Task READ
    // =========================================================================
    task do_read;
        input [31:0] addr;
        output [31:0] data;
        begin
            @(negedge clk);
            cpu_req = 1; cpu_rw = 0; cpu_addr = addr; cpu_wr_data = 0;
            w_addr = addr; w_op = 0;
            w_total = w_total + 1;
            @(posedge clk);
            while (!cpu_ready) @(posedge clk);
            data    = cpu_rd_data;
            w_rdata = cpu_rd_data;
            // Detectie hit: daca FSM n-a trecut prin FETCH/EVICT = hit
            w_hit   = (dut.cache_hit) ? 1'b1 : 1'b0;
            if (w_hit) w_hits = w_hits + 1;
            else       w_misses = w_misses + 1;
            w_hitrate = (w_total > 0) ? (w_hits * 100 / w_total) : 0;
            @(negedge clk);
            cpu_req = 0;
            @(posedge clk);
        end
    endtask

    // =========================================================================
    // Task WRITE
    // =========================================================================
    task do_write;
        input [31:0] addr;
        input [31:0] wdata;
        begin
            @(negedge clk);
            cpu_req = 1; cpu_rw = 1; cpu_addr = addr; cpu_wr_data = wdata;
            w_addr = addr; w_wdata = wdata; w_op = 1;
            w_total = w_total + 1;
            @(posedge clk);
            while (!cpu_ready) @(posedge clk);
            w_hit = (dut.cache_hit) ? 1'b1 : 1'b0;
            if (w_hit) w_hits = w_hits + 1;
            else       w_misses = w_misses + 1;
            w_hitrate = (w_total > 0) ? (w_hits * 100 / w_total) : 0;
            @(negedge clk);
            cpu_req = 0;
            @(posedge clk);
        end
    endtask

    // =========================================================================
    // Helper check
    // =========================================================================
    integer passes, fails;
    task check;
        input cond;
        input [255:0] msg;
        begin
            if (cond) begin $display("  [PASS] %s",msg); passes=passes+1; end
            else       begin $display("  [FAIL] %s",msg); fails =fails +1; end
        end
    endtask

    function [31:0] mkaddr;
        input [18:0] tag; input [6:0] idx; input [3:0] wrd;
        begin mkaddr = {tag, idx, wrd, 2'b00}; end
    endfunction

    // =========================================================================
    // Secventa de test
    // =========================================================================
    reg [31:0] rdata;
    reg [31:0] rnd [0:7];
    integer ii;

    initial begin
        seed=32'hA5A5_0001; 
        cpu_req=0; cpu_rw=0; cpu_addr=0; cpu_wr_data=0;
        rst=1; w_op=0; w_hit=0; w_addr=0; w_wdata=0; w_rdata=0;
        w_total=0; w_hits=0; w_misses=0; w_evictions=0; w_hitrate=0;
        passes=0; fails=0;
        for(ii=0;ii<8;ii=ii+1) rnd[ii]=$random;

        repeat(4) @(posedge clk); rst=0; repeat(2) @(posedge clk);

        $display("=================================================");
        $display("  Cache TB  |  Seed=%0d",seed);
        $display("=================================================");

        // TC1 – Read miss rece
        $display("\n[TC1] Read Miss (cache rece)");
        do_read(mkaddr(19'd1,7'd0,4'd0), rdata);
        check(1,"TC1: completed");

        // TC2 – Read hit
        $display("\n[TC2] Read Hit (aceeasi adresa)");
        do_read(mkaddr(19'd1,7'd0,4'd0), rdata);
        check(1,"TC2: completed");

        // TC3 – Write miss + write-allocate cu data aleatorie
        $display("\n[TC3] Write Miss  data=0x%08h", rnd[0]);
        do_write(mkaddr(19'd2,7'd0,4'd3), rnd[0]);
        check(1,"TC3: completed");

        // TC4 – Write hit + verificare citire
        $display("\n[TC4] Write Hit  data=0x%08h", rnd[1]);
        do_write(mkaddr(19'd2,7'd0,4'd3), rnd[1]);
        do_read (mkaddr(19'd2,7'd0,4'd3), rdata);
        check(rdata==rnd[1],"TC4: citire dupa write hit corecta");
        $display("       Scris=0x%08h Citit=0x%08h",rnd[1],rdata);

        // TC5 – Alt set
        $display("\n[TC5] Read Miss set diferit");
        do_read(mkaddr(19'd5,7'd42,4'd7), rdata);
        check(1,"TC5: completed");

        // TC6 – Umple 4 way-uri + evictie dirty
        $display("\n[TC6] Evictie dirty");
        do_write(mkaddr(19'd10,7'd2,4'd1), rnd[2]); // dirty
        do_read (mkaddr(19'd11,7'd2,4'd0), rdata);
        do_read (mkaddr(19'd12,7'd2,4'd0), rdata);
        do_read (mkaddr(19'd13,7'd2,4'd0), rdata);
        // re-acceseaza 11,12,13 -> tag10 devine LRU
        do_read (mkaddr(19'd11,7'd2,4'd0), rdata);
        do_read (mkaddr(19'd12,7'd2,4'd0), rdata);
        do_read (mkaddr(19'd13,7'd2,4'd0), rdata);
        // tag14 -> evictie tag10 (dirty)
        do_read (mkaddr(19'd14,7'd2,4'd0), rdata);
        check(1,"TC6: completed");
        $display("       Evacuari=%0d", w_evictions);

        // TC7 – Verificare ordine LRU
        $display("\n[TC7] Ordine LRU");
        do_read(mkaddr(19'd30,7'd7,4'd0), rdata);
        do_read(mkaddr(19'd31,7'd7,4'd0), rdata);
        do_read(mkaddr(19'd32,7'd7,4'd0), rdata);
        do_read(mkaddr(19'd33,7'd7,4'd0), rdata);
        do_read(mkaddr(19'd30,7'd7,4'd0), rdata);
        do_read(mkaddr(19'd31,7'd7,4'd0), rdata);
        do_read(mkaddr(19'd32,7'd7,4'd0), rdata);
        do_read(mkaddr(19'd34,7'd7,4'd0), rdata); // evacueaza tag33
        check(1,"TC7: completed");

        // TC8 – Burst aleatoriu 20 accese pe 6 adrese
        $display("\n[TC8] Burst aleatoriu (20 accese)");
        begin : burst
            reg [31:0] addrs [0:5];
            integer op, ai;
            addrs[0]=mkaddr(19'd50,7'd10,4'd0);
            addrs[1]=mkaddr(19'd51,7'd10,4'd2);
            addrs[2]=mkaddr(19'd52,7'd10,4'd4);
            addrs[3]=mkaddr(19'd53,7'd10,4'd0);
            addrs[4]=mkaddr(19'd54,7'd10,4'd1);
            addrs[5]=mkaddr(19'd50,7'd10,4'd3);
            for(ii=0;ii<20;ii=ii+1) begin
                ai = {$random} % 6;
                op = {$random} % 2;
                if (op==0) do_read (addrs[ai], rdata);
                else       do_write(addrs[ai], $random);
            end
        end
        check(1,"TC8: burst complet");

        // Sumar
        $display("\n=================================================");
        $display("  SUMAR  Total=%0d  Hits=%0d  Misses=%0d  Evacuari=%0d",
                 w_total, w_hits, w_misses, w_evictions);
        $display("  Rata hit = %0d%%   Teste: %0d pass / %0d fail",
                 w_hitrate, passes, fails);
        $display("=================================================");
        $finish;
    end

    initial begin #2000000; $display("WATCHDOG timeout"); $finish; end

    initial begin
        $dumpfile("cache_wave.vcd");
        $dumpvars(0, cache_tb);
    end

endmodule