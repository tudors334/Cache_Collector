`timescale 1ns/1ps
// =============================================================================
// cache_controller.v  –  FSM Cache Controller (rescris, fara race conditions)
//
// Arhitectura: un singur always @(posedge clk) secvential gestioneaza
// toata logica FSM, shadow registers si iesirile. Elimina conflictele
// intre blocuri always @(*) si always @(posedge clk) care cauzau
// comportament nedeterministic in ModelSim.
//
// Address: [31:13]=TAG(19b)  [12:6]=INDEX(7b)  [5:2]=WORD(4b)  [1:0]=BYTE(2b)
// =============================================================================

module cache_controller (
    input  wire        clk,
    input  wire        rst,

    // CPU
    input  wire        cpu_req,
    input  wire        cpu_rw,          // 0=Read  1=Write
    input  wire [31:0] cpu_addr,
    input  wire [31:0] cpu_wr_data,
    output reg  [31:0] cpu_rd_data,
    output reg         cpu_ready,

    // Main Memory
    output reg         mem_req,
    output reg         mem_rw,          // 0=Read  1=Write(evict)
    output reg  [31:0] mem_addr,
    output reg  [511:0] mem_wr_data,
    input  wire [511:0] mem_rd_data,
    input  wire        mem_ready
);

    // =========================================================================
    // Stari FSM
    // =========================================================================
    localparam IDLE       = 3'd0,
               LOAD_WAYS  = 3'd1,   // citeste cele 4 way-uri din set
               CHECK      = 3'd2,   // verifica hit/miss
               FETCH      = 3'd3,   // aduce bloc din memorie
               EVICT      = 3'd4,   // scrie bloc dirty inapoi in memorie
               WRITEBACK  = 3'd5,   // dupa fetch: aplica write-allocate
               COMPLETE   = 3'd6;   // semnalizeaza cpu_ready un ciclu

    reg [2:0] state;

    // =========================================================================
    // Adrese decodate (combinational din cpu_addr inregistrat)
    // =========================================================================
    reg [31:0] saved_addr;
    reg [31:0] saved_wrdata;
    reg        saved_rw;

    wire [18:0] s_tag   = saved_addr[31:13];
    wire [6:0]  s_index = saved_addr[12:6];
    wire [3:0]  s_word  = saved_addr[5:2];

    // =========================================================================
    // Shadow registers – copie locala a celor 4 way-uri din setul curent
    // =========================================================================
    reg [511:0] c_data  [0:3];
    reg [18:0]  c_tag   [0:3];
    reg         c_valid [0:3];
    reg         c_dirty [0:3];

    // =========================================================================
    // Memorie interna (array simplu – nu modul separat pentru a evita
    // latenta de citire care complica FSM-ul in ModelSim Altera Starter)
    // =========================================================================
    reg [511:0] mem_data  [0:127][0:3];
    reg [18:0]  mem_tag   [0:127][0:3];
    reg         mem_valid [0:127][0:3];
    reg         mem_dirty [0:127][0:3];

    // =========================================================================
    // LRU – contoare de varsta per set (0=MRU, 3=LRU)
    // =========================================================================
    reg [1:0] lru_age [0:127][0:3];

    function automatic [1:0] lru_victim;
        input [6:0] idx;
        integer k;
        begin
            lru_victim = 2'd0;
            for (k = 0; k < 4; k = k + 1)
                if (lru_age[idx][k] == 2'd3) lru_victim = k[1:0];
        end
    endfunction

    task automatic lru_update;
        input [6:0] idx;
        input [1:0] way;
        integer k;
        begin
            for (k = 0; k < 4; k = k + 1) begin
                if (k[1:0] == way)
                    lru_age[idx][k] <= 2'd0;
                else if (lru_age[idx][k] < lru_age[idx][way])
                    lru_age[idx][k] <= lru_age[idx][k] + 2'd1;
            end
        end
    endtask

    // =========================================================================
    // Variabile interne FSM
    // =========================================================================
    reg [1:0]  load_cnt;    // contor pentru citirea celor 4 way-uri
    reg [1:0]  hit_way;
    reg        cache_hit;
    reg [1:0]  victim;      // way evacuat

    integer i, j;

    // =========================================================================
    // FSM principal – un singur bloc secvential
    // =========================================================================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state       <= IDLE;
            cpu_ready   <= 1'b0;
            cpu_rd_data <= 32'b0;
            mem_req     <= 1'b0;
            mem_rw      <= 1'b0;
            mem_addr    <= 32'b0;
            mem_wr_data <= 512'b0;
            saved_addr  <= 32'b0;
            saved_wrdata<= 32'b0;
            saved_rw    <= 1'b0;
            load_cnt    <= 2'd0;
            hit_way     <= 2'd0;
            cache_hit   <= 1'b0;
            victim      <= 2'd0;

            for (i = 0; i < 128; i = i + 1)
                for (j = 0; j < 4; j = j + 1) begin
                    mem_data [i][j] <= 512'b0;
                    mem_tag  [i][j] <= 19'b0;
                    mem_valid[i][j] <= 1'b0;
                    mem_dirty[i][j] <= 1'b0;
                    lru_age  [i][j] <= j[1:0]; // 0,1,2,3
                end
        end else begin
            // De-assert implicit in fiecare ciclu
            cpu_ready <= 1'b0;
            mem_req   <= 1'b0;

            case (state)

                // -------------------------------------------------------------
                IDLE: begin
                    if (cpu_req) begin
                        saved_addr   <= cpu_addr;
                        saved_wrdata <= cpu_wr_data;
                        saved_rw     <= cpu_rw;
                        load_cnt     <= 2'd0;
                        state        <= LOAD_WAYS;
                    end
                end

                // -------------------------------------------------------------
                // Citeste cele 4 way-uri din setul curent in shadow registers
                // Dureaza 4 cicluri (load_cnt 0..3)
                // -------------------------------------------------------------
                LOAD_WAYS: begin
                    // Incarca shadow din memorie interna
                    c_data [load_cnt] <= mem_data [s_index][load_cnt];
                    c_tag  [load_cnt] <= mem_tag  [s_index][load_cnt];
                    c_valid[load_cnt] <= mem_valid[s_index][load_cnt];
                    c_dirty[load_cnt] <= mem_dirty[s_index][load_cnt];

                    if (load_cnt == 2'd3)
                        state <= CHECK;
                    else
                        load_cnt <= load_cnt + 2'd1;
                end

                // -------------------------------------------------------------
                // Verifica hit sau miss
                // -------------------------------------------------------------
                CHECK: begin
                    // Detectie hit
                    cache_hit <= 1'b0;
                    hit_way   <= 2'd0;
                    if      (c_valid[0] && c_tag[0]==s_tag) begin cache_hit<=1'b1; hit_way<=2'd0; end
                    else if (c_valid[1] && c_tag[1]==s_tag) begin cache_hit<=1'b1; hit_way<=2'd1; end
                    else if (c_valid[2] && c_tag[2]==s_tag) begin cache_hit<=1'b1; hit_way<=2'd2; end
                    else if (c_valid[3] && c_tag[3]==s_tag) begin cache_hit<=1'b1; hit_way<=2'd3; end

                    victim <= lru_victim(s_index);

                    state <= saved_rw ? WRITEBACK : FETCH;
                    // Nota: WRITEBACK si FETCH verifica cache_hit in ciclul urmator
                    // (cache_hit e inregistrat acum, stabil la intrarea in starea urmatoare)
                end

                // -------------------------------------------------------------
                // READ: hit sau fetch din memorie
                // -------------------------------------------------------------
                FETCH: begin
                    if (cache_hit) begin
                        // READ HIT
                        cpu_rd_data <= c_data[hit_way][s_word*32 +: 32];
                        lru_update(s_index, hit_way);
                        state <= COMPLETE;
                    end else begin
                        // READ MISS
                        if (c_valid[victim] && c_dirty[victim]) begin
                            // Victim dirty -> evacueaza mai intai
                            mem_req     <= 1'b1;
                            mem_rw      <= 1'b1;
                            mem_addr    <= {c_tag[victim], s_index, 6'b0};
                            mem_wr_data <= c_data[victim];
                            state       <= EVICT;
                        end else begin
                            // Victim curat -> aduce bloc nou
                            mem_req  <= 1'b1;
                            mem_rw   <= 1'b0;
                            mem_addr <= {s_tag, s_index, 6'b0};
                            state    <= EVICT; // refolosim EVICT pentru asteptare mem_ready
                            // marcam victim ca necurat pentru a diferentia calea
                            // (tratam in EVICT dupa mem_rw)
                        end
                    end
                end

                // -------------------------------------------------------------
                // WRITE: hit sau write-allocate
                // -------------------------------------------------------------
                WRITEBACK: begin
                    if (cache_hit) begin
                        // WRITE HIT – actualizeaza cuvantul, marcheaza dirty
                        mem_data [s_index][hit_way][s_word*32 +: 32] <= saved_wrdata;
                        mem_dirty[s_index][hit_way] <= 1'b1;
                        // Actualizeaza shadow
                        c_data [hit_way][s_word*32 +: 32] <= saved_wrdata;
                        c_dirty[hit_way] <= 1'b1;
                        lru_update(s_index, hit_way);
                        state <= COMPLETE;
                    end else begin
                        // WRITE MISS – write-allocate: evacueaza daca e necesar
                        if (c_valid[victim] && c_dirty[victim]) begin
                            mem_req     <= 1'b1;
                            mem_rw      <= 1'b1;
                            mem_addr    <= {c_tag[victim], s_index, 6'b0};
                            mem_wr_data <= c_data[victim];
                        end else begin
                            mem_req  <= 1'b1;
                            mem_rw   <= 1'b0;
                            mem_addr <= {s_tag, s_index, 6'b0};
                        end
                        state <= EVICT;
                    end
                end

                // -------------------------------------------------------------
                // EVICT: asteapta mem_ready, apoi aloca/continua
                // -------------------------------------------------------------
                EVICT: begin
                    mem_req <= 1'b1; // mentine cererea pana la confirmare
                    if (mem_ready) begin
                        mem_req <= 1'b0;
                        if (mem_rw) begin
                            // Tocmai am scris blocul dirty -> acum aducem bloc nou
                            mem_dirty[s_index][victim] <= 1'b0;
                            mem_rw   <= 1'b0;
                            mem_addr <= {s_tag, s_index, 6'b0};
                            // Ramanem in EVICT dar acum mem_rw=0 -> citire
                        end else begin
                            // Tocmai am primit blocul nou din memorie -> aloca
                            mem_data [s_index][victim] <= mem_rd_data;
                            mem_tag  [s_index][victim] <= s_tag;
                            mem_valid[s_index][victim] <= 1'b1;
                            mem_dirty[s_index][victim] <= 1'b0;
                            lru_update(s_index, victim);

                            // Actualizeaza shadow
                            c_data [victim] <= mem_rd_data;
                            c_tag  [victim] <= s_tag;
                            c_valid[victim] <= 1'b1;
                            c_dirty[victim] <= 1'b0;
                            hit_way         <= victim;
                            cache_hit       <= 1'b1;

                            if (saved_rw) begin
                                // Write-allocate: aplica scrierea
                                mem_data [s_index][victim][s_word*32 +: 32] <= saved_wrdata;
                                mem_dirty[s_index][victim] <= 1'b1;
                                state <= COMPLETE;
                            end else begin
                                // Read: returneaza cuvantul
                                cpu_rd_data <= mem_rd_data[s_word*32 +: 32];
                                state       <= COMPLETE;
                            end
                        end
                    end
                end

                // -------------------------------------------------------------
                // COMPLETE: semnalizeaza cpu_ready un ciclu
                // -------------------------------------------------------------
                COMPLETE: begin
                    cpu_ready <= 1'b1;
                    state     <= IDLE;
                end

            endcase
        end
    end

endmodule