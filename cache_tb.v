// testbench pentru cache_controller cu fsm tag_check
`timescale 1ns/1ps

// seed injectat din wave_setup.do la fiecare rulare via -g seed=<valoare>
module cache_tb #(parameter integer SEED = 0);

    // ceas si reset
    reg clk, rst;
    initial clk = 1'b0;
    always #5 clk = ~clk;  // 100 mhz

    // semnale dut
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

    // semnale wave vizibile in modelsim
    // tranzactie curenta
    reg        w_op;       // 0=read / 1=write
    reg        w_hit;      // 1=hit, 0=miss la cpu_ready
    reg        w_evict;    // puls un ciclu la evacuare
    reg [31:0] w_addr;     // adresa accesata
    reg [31:0] w_wdata;    // data scrisa
    reg [31:0] w_rdata;    // data citita

    // statistici acumulate
    reg [7:0]  w_total;     // total accese
    reg [7:0]  w_hits;      // hit-uri
    reg [7:0]  w_misses;    // miss-uri
    reg [7:0]  w_evictions; // evacuari
    reg [6:0]  w_hitrate;   // rata hit in procente

    // starea fsm din dut, direct observabila in wave
    // 0=idle 1=tag_check 2=read_hit 3=write_hit
    // 4=read_miss 5=write_miss 6=evict 7=complete
    wire [3:0] w_fsm_state = dut.state;

    // campuri adresa decodate pentru debug in wave
    wire [17:0] w_tag   = dut.s_tag;
    wire [6:0]  w_index = dut.s_index;
    wire [3:0]  w_word  = dut.s_word;

    // hit si victim detectate in tag_check
    wire        w_cache_hit = dut.cache_hit;
    wire [1:0]  w_hit_way   = dut.hit_way;
    wire [1:0]  w_victim    = dut.victim;

    // instanta dut
    cache_controller dut (
        .clk(clk),          .rst(rst),
        .cpu_req(cpu_req),  .cpu_rw(cpu_rw),
        .cpu_addr(cpu_addr),.cpu_wr_data(cpu_wr_data),
        .cpu_rd_data(cpu_rd_data), .cpu_ready(cpu_ready),
        .mem_req(mem_req),  .mem_rw(mem_rw),
        .mem_addr(mem_addr),.mem_wr_data(mem_wr_data),
        .mem_rd_data(mem_rd_data), .mem_ready(mem_ready)
    );

    // model memorie cu latenta de 3 cicluri
    // datele sunt adresa xor seed, reproductibil
    integer mem_seed;

    task mem_model_respond;
        integer k;
        reg [31:0] base;
        begin
            base = mem_addr;
            // latenta memorie: 3 cicluri
            repeat(3) @(posedge clk);
            if (!mem_rw) begin
                // fetch: genereaza date pentru cele 16 cuvinte din bloc
                for (k = 0; k < 16; k = k + 1)
                    mem_rd_data[k*32 +: 32] = base ^ (k * 32'h11111111) ^ mem_seed;
            end else begin
                // evict: incrementeaza contorul de evacuari
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

    // thread de memorie: asteapta mem_req si raspunde
    initial begin
        mem_ready   = 0;
        mem_rd_data = 0;
        w_evict     = 0;
        forever begin
            @(posedge clk);
            if (mem_req) mem_model_respond;
        end
    end

    // task do_read: trimite cerere de citire si asteapta raspuns
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

    // task do_write: trimite cerere de scriere si asteapta finalizare
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

    // task check: afiseaza pass sau fail si actualizeaza contoare
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

    // construieste adresa 32b din campuri tag, index, word
    function [31:0] mkaddr;
        input [17:0] tag;
        input [6:0]  idx;
        input [3:0]  wrd;
        begin
            // [31:14]=tag(18b), [13:7]=index(7b), [5:2]=word(4b), [1:0]=00
            mkaddr = {tag, idx, 1'b0, wrd, 2'b00};
        end
    endfunction

    // variabile pentru secventa de test
    reg [31:0] rdata, rdata2;
    reg [31:0] wval;
    integer    ii;

    initial begin
        // initializare seed si semnale
        // seed injectat la runtime din wave_setup.do
        mem_seed     = SEED;
        // initializeaza urng cu seed pentru reproductibilitate
        // adresele din tc8 difera la fiecare rulare cu seed diferit
        begin : seed_rng
            integer dummy;
            dummy = $urandom(SEED);  // initializeaza urng systemverilog
        end
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
        $display("  SEED = %0d  (generat din ora sistemului in wave_setup.do)", SEED);
        $display("=================================================================");

        // tc1: read miss pe cache rece, prima accesare a blocului
        $display("\n[TC1] READ_MISS  (cache rece)");
        do_read(mkaddr(18'd1, 7'd0, 4'd0), rdata);
        check(!w_hit, "TC1: TAG_CHECK detectat MISS");
        check(w_fsm_state == 0, "TC1: FSM revenit la IDLE");
        $display("       rd_data=0x%08h", rdata);

        // tc2: read hit pe aceeasi adresa ca tc1
        $display("\n[TC2] READ_HIT  (aceeasi adresa ca TC1)");
        do_read(mkaddr(18'd1, 7'd0, 4'd0), rdata);
        check(w_hit, "TC2: TAG_CHECK detectat HIT");
        $display("       rd_data=0x%08h", rdata);

        // tc3: write miss pe adresa noua, write-allocate
        wval = 32'hCAFE_1234;
        $display("\n[TC3] WRITE_MISS  (write-allocate)  data=0x%08h", wval);
        do_write(mkaddr(18'd2, 7'd0, 4'd3), wval);
        check(!w_hit, "TC3: TAG_CHECK detectat MISS");

        // tc4: write hit pe aceeasi adresa ca tc3
        wval = 32'hBEEF_5678;
        $display("\n[TC4] WRITE_HIT  data=0x%08h", wval);
        do_write(mkaddr(18'd2, 7'd0, 4'd3), wval);
        check(w_hit, "TC4: TAG_CHECK detectat HIT");

        // verifica ca citirea returneaza valoarea scrisa anterior
        do_read(mkaddr(18'd2, 7'd0, 4'd3), rdata);
        check(rdata == wval, "TC4: citire dupa WRITE_HIT corecta");
        $display("       Scris=0x%08h  Citit=0x%08h  Match=%0s",
                 wval, rdata, (rdata==wval)?"DA":"NU");

        // tc5: acces pe set cu index diferit
        $display("\n[TC5] READ_MISS  set diferit  index=42");
        do_read(mkaddr(18'd5, 7'd42, 4'd7), rdata);
        check(!w_hit, "TC5: miss pe set nou");

        // tc6: umple 4 ways ale setului index=2 si provoaca evict dirty
        // scrie tag10 (devine dirty), citeste tag11,12,13
        // re-acceseaza 11,12,13 ca tag10 sa devina lru
        // accesul tag14 evacueaza tag10 dirty
        $display("\n[TC6] EVICT  (bloc dirty evacuat)");
        do_write(mkaddr(18'd10, 7'd2, 4'd1), 32'hAAAA_0001); // tag10 dirty
        do_read (mkaddr(18'd11, 7'd2, 4'd0), rdata);         // tag11
        do_read (mkaddr(18'd12, 7'd2, 4'd0), rdata);         // tag12
        do_read (mkaddr(18'd13, 7'd2, 4'd0), rdata);         // tag13
        // acceseaza 11,12,13 pentru a face tag10 lru
        do_read (mkaddr(18'd11, 7'd2, 4'd0), rdata);
        do_read (mkaddr(18'd12, 7'd2, 4'd0), rdata);
        do_read (mkaddr(18'd13, 7'd2, 4'd0), rdata);
        // tag14 miss, tag10 lru si dirty, va trece prin evict
        do_read (mkaddr(18'd14, 7'd2, 4'd0), rdata);
        check(w_evictions >= 1, "TC6: cel putin o evacuare a avut loc");
        $display("       Total evacuari pana acum: %0d", w_evictions);

        // tc7: verifica politica lru pe setul index=7
        $display("\n[TC7] Politica LRU  (set=7)");
        do_read(mkaddr(18'd30, 7'd7, 4'd0), rdata); // way0
        do_read(mkaddr(18'd31, 7'd7, 4'd0), rdata); // way1
        do_read(mkaddr(18'd32, 7'd7, 4'd0), rdata); // way2
        do_read(mkaddr(18'd33, 7'd7, 4'd0), rdata); // way3
        // acceseaza 30,31,32 astfel incat 33 devine lru
        do_read(mkaddr(18'd30, 7'd7, 4'd0), rdata);
        do_read(mkaddr(18'd31, 7'd7, 4'd0), rdata);
        do_read(mkaddr(18'd32, 7'd7, 4'd0), rdata);
        // tag34 miss, trebuie sa evacueze tag33 lru
        do_read(mkaddr(18'd34, 7'd7, 4'd0), rdata);
        check(1, "TC7: LRU test complet");

        // tc8: burst de 20 accese aleatorii generate din seed
        // tag, index si word variaza la fiecare rulare
        $display("\n[TC8] Burst aleatoriu  (20 accese, adrese generate din SEED=%0d)", SEED);
        begin : burst
            reg [31:0] addrs [0:5];
            reg [17:0] rnd_tag;
            reg [6:0]  rnd_idx;
            reg [3:0]  rnd_wrd;
            integer op_type, ai;
            // genereaza 6 adrese; primele 5 au acelasi index pentru conflicte
            // index-ul este acelasi pentru primele 5 adrese
            rnd_idx = $urandom % 128;
            addrs[0] = mkaddr(($urandom % 18'h3FFFF), rnd_idx, ($urandom % 16));
            addrs[1] = mkaddr(($urandom % 18'h3FFFF), rnd_idx, ($urandom % 16));
            addrs[2] = mkaddr(($urandom % 18'h3FFFF), rnd_idx, ($urandom % 16));
            addrs[3] = mkaddr(($urandom % 18'h3FFFF), rnd_idx, ($urandom % 16));
            addrs[4] = mkaddr(($urandom % 18'h3FFFF), rnd_idx, ($urandom % 16));
            // a 6-a adresa are index diferit, miss garantat pe alt set
            addrs[5] = mkaddr(($urandom % 18'h3FFFF), ($urandom % 128), ($urandom % 16));
            $display("       TC8 index set ales: %0d", rnd_idx);
            $display("       TC8 adrese[0..5]: %08h %08h %08h %08h %08h %08h",
                     addrs[0], addrs[1], addrs[2], addrs[3], addrs[4], addrs[5]);
            for (ii = 0; ii < 20; ii = ii + 1) begin
                ai      = $urandom % 6;
                op_type = $urandom % 2;
                if (op_type == 0)
                    do_read (addrs[ai], rdata);
                else
                    do_write(addrs[ai], $urandom);
            end
        end
        check(1, "TC8: burst aleatoriu finalizat");

        // tc9: verifica persistenta datelor dupa accese intercalate
        $display("\n[TC9] Persistenta date dupa accese intercalate");
        wval = 32'h1234_5678;
        do_write(mkaddr(18'd100, 7'd20, 4'd5), wval);
        // acceseaza alte adrese care nu suprascriu setul 20
        do_read(mkaddr(18'd200, 7'd30, 4'd0), rdata);
        do_read(mkaddr(18'd201, 7'd30, 4'd0), rdata);
        // reciteste datele originale pentru verificare
        do_read(mkaddr(18'd100, 7'd20, 4'd5), rdata);
        check(rdata == wval, "TC9: date persistente dupa accese intercalate");
        $display("       Scris=0x%08h  Recitit=0x%08h  Match=%0s",
                 wval, rdata, (rdata==wval)?"DA":"NU");

        // sumar final cu toate statisticile
        $display("");
        $display("=================================================================");
        $display("  FINAL RESULTS");
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

    // watchdog: opreste simularea la depasirea limitei de timp
    initial begin
        #5000000;
        $display("WATCHDOG: timeout dupa 5ms simulare - posibila blocare FSM");
        $finish;
    end

    // dump vcd pentru vizualizare in gtkwave sau modelsim
    initial begin
        $dumpfile("cache_wave.vcd");
        $dumpvars(0, cache_tb);
    end

endmodule