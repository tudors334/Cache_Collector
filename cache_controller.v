`timescale 1ns/1ps
// =============================================================================
// cache_controller.v
//
// Cache 4-way set-associative, 32KB, bloc 64B, write-back + write-allocate
// Politica inlocuire: LRU
//
// Adresa 32 biti: [31:14]=TAG(18b)  [13:7]=INDEX(7b)  [6:1]=OFFSET(6b) 
//                 Descompunere: tag=18b, index=7b, offset=6b (64B bloc)
//                 Cuvant in bloc: offset[5:2] = 4 biti (16 cuvinte x 4B)
//
// FSM States:
//   IDLE       - Asteapta cerere CPU
//   TAG_CHECK  - Stare de decizie centrala: decodifica adresa, interogheaza
//                toate cele 4 ways simultan, decide urmatoarea stare:
//                  hit  + READ   -> READ_HIT
//                  hit  + WRITE  -> WRITE_HIT
//                  miss + dirty  -> EVICT  (trebuie scris inainte)
//                  miss + clean  -> READ_MISS / WRITE_MISS
//   READ_HIT   - Returneaza cuvantul catre CPU, updateaza LRU
//   WRITE_HIT  - Scrie cuvantul in cache, marcheaza dirty, updateaza LRU
//   READ_MISS  - Aduce bloc din memorie, il aloca, returneaza cuvantul
//   WRITE_MISS - Write-allocate: aduce bloc, il aloca, aplica scrierea
//   EVICT      - Scrie bloc dirty in memorie, apoi merge in READ/WRITE_MISS
//   COMPLETE   - Aserta cpu_ready un ciclu, revine la IDLE
// =============================================================================

module cache_controller (
    input  wire        clk,
    input  wire        rst,

    // Interfata CPU
    input  wire        cpu_req,
    input  wire        cpu_rw,          // 0=Read  1=Write
    input  wire [31:0] cpu_addr,
    input  wire [31:0] cpu_wr_data,
    output reg  [31:0] cpu_rd_data,
    output reg         cpu_ready,

    // Interfata Memorie Principala
    output reg         mem_req,
    output reg         mem_rw,          // 0=Read(fetch)  1=Write(evict)
    output reg  [31:0] mem_addr,
    output reg  [511:0] mem_wr_data,    // date evacuate (512b = 64B bloc)
    input  wire [511:0] mem_rd_data,    // date aduse din memorie
    input  wire        mem_ready        // confirmare memorie
);

    // =========================================================================
    // Definitia starilor FSM
    // =========================================================================
    localparam [3:0]
        IDLE       = 4'd0,
        TAG_CHECK  = 4'd1,   // BONUS: stare de decizie centrala
        READ_HIT   = 4'd2,
        WRITE_HIT  = 4'd3,
        READ_MISS  = 4'd4,
        WRITE_MISS = 4'd5,
        EVICT      = 4'd6,
        COMPLETE   = 4'd7;

    reg [3:0] state;

    // =========================================================================
    // Campuri adresa (inregistrate la intrarea in TAG_CHECK)
    // =========================================================================
    reg [31:0] saved_addr;
    reg [31:0] saved_wrdata;
    reg        saved_rw;

    // Descompunere adresa: tag=18b [31:14], index=7b [13:7], offset=6b [6:1]
    // Selectia cuvantului (4B) in bloc: biti [5:2] din offset = 4b -> 16 cuvinte
    wire [17:0] s_tag   = saved_addr[31:14];
    wire [6:0]  s_index = saved_addr[13:7];
    wire [3:0]  s_word  = saved_addr[5:2];   // pozitia cuvantului in bloc (0-15)

    // =========================================================================
    // Array-uri interne de cache
    // 128 seturi x 4 ways
    // =========================================================================
    reg [511:0] ca_data  [0:127][0:3];
    reg [17:0]  ca_tag   [0:127][0:3];
    reg         ca_valid [0:127][0:3];
    reg         ca_dirty [0:127][0:3];

    // =========================================================================
    // LRU: varsta per (set, way) - 0=MRU cel mai recent, 3=LRU cel mai vechi
    // =========================================================================
    reg [1:0] lru_age [0:127][0:3];

    // =========================================================================
    // Variabile interne FSM
    // =========================================================================
    reg [1:0]  hit_way;     // way-ul pe care s-a gasit hit
    reg        cache_hit;   // 1 daca TAG_CHECK a gasit hit
    reg [1:0]  victim;      // way-ul ales pentru evictie/alocare (LRU)
    // after_evict indica ce stare urmeaza dupa EVICT
    reg [3:0]  after_evict;

    integer i, j;

    // =========================================================================
    // Functie: gaseste victim (way cu lru_age == 3, adica cel mai vechi)
    // =========================================================================
    function automatic [1:0] find_victim;
        input [6:0] idx;
        integer k;
        begin
            find_victim = 2'd0;
            for (k = 0; k < 4; k = k + 1)
                if (lru_age[idx][k] == 2'd3)
                    find_victim = k[1:0];
        end
    endfunction

    // =========================================================================
    // Task: actualizeaza LRU dupa acces pe 'way' din setul 'idx'
    // way accesat devine MRU (age=0), celelalte avansate daca erau mai tinere
    // =========================================================================
    task automatic lru_touch;
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
    // FSM principal - un singur bloc secvential
    // =========================================================================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state        <= IDLE;
            cpu_ready    <= 1'b0;
            cpu_rd_data  <= 32'b0;
            mem_req      <= 1'b0;
            mem_rw       <= 1'b0;
            mem_addr     <= 32'b0;
            mem_wr_data  <= 512'b0;
            saved_addr   <= 32'b0;
            saved_wrdata <= 32'b0;
            saved_rw     <= 1'b0;
            hit_way      <= 2'd0;
            cache_hit    <= 1'b0;
            victim       <= 2'd0;
            after_evict  <= IDLE;

            for (i = 0; i < 128; i = i + 1)
                for (j = 0; j < 4; j = j + 1) begin
                    ca_data [i][j] <= 512'b0;
                    ca_tag  [i][j] <= 18'b0;
                    ca_valid[i][j] <= 1'b0;
                    ca_dirty[i][j] <= 1'b0;
                    lru_age [i][j] <= j[1:0]; // initializare: 0,1,2,3
                end
        end else begin
            // De-assert implicit in fiecare ciclu
            cpu_ready <= 1'b0;
            mem_req   <= 1'b0;

            case (state)

                // =============================================================
                // IDLE: asteapta cerere CPU
                // =============================================================
                IDLE: begin
                    if (cpu_req) begin
                        saved_addr   <= cpu_addr;
                        saved_wrdata <= cpu_wr_data;
                        saved_rw     <= cpu_rw;
                        state        <= TAG_CHECK;
                    end
                end

                // =============================================================
                // TAG_CHECK (STARE BONUS - nod de decizie centrala)
                //
                // In acest ciclu:
                //   1. Adresa e deja inregistrata (saved_addr -> s_tag, s_index)
                //   2. Interogam simultan toate cele 4 ways ale setului s_index
                //   3. Comparam tag-ul cu fiecare way valid
                //   4. Determinam hit/miss si victim (LRU)
                //   5. Decidem urmatoarea stare dupa 4 scenarii:
                //      a) HIT  + READ            -> READ_HIT
                //      b) HIT  + WRITE           -> WRITE_HIT
                //      c) MISS + victim clean    -> READ_MISS sau WRITE_MISS
                //      d) MISS + victim dirty    -> EVICT (scrie mai intai!)
                // =============================================================
                TAG_CHECK: begin
                    // --- Detectie HIT: compara tag cu toate 4 ways simultan ---
                    cache_hit <= 1'b0;
                    hit_way   <= 2'd0;

                    if      (ca_valid[s_index][0] && ca_tag[s_index][0] == s_tag)
                        begin cache_hit <= 1'b1; hit_way <= 2'd0; end
                    else if (ca_valid[s_index][1] && ca_tag[s_index][1] == s_tag)
                        begin cache_hit <= 1'b1; hit_way <= 2'd1; end
                    else if (ca_valid[s_index][2] && ca_tag[s_index][2] == s_tag)
                        begin cache_hit <= 1'b1; hit_way <= 2'd2; end
                    else if (ca_valid[s_index][3] && ca_tag[s_index][3] == s_tag)
                        begin cache_hit <= 1'b1; hit_way <= 2'd3; end

                    // --- Gaseste victim LRU pentru cazul de miss ---
                    victim <= find_victim(s_index);

                    // --- Decizie tranzitie stare ---
                    // Nota: cache_hit/victim tocmai setate cu <=, deci in
                    // acelasi ciclu le citim direct din ca_* pentru decizie
                    if (   (ca_valid[s_index][0] && ca_tag[s_index][0] == s_tag)
                        || (ca_valid[s_index][1] && ca_tag[s_index][1] == s_tag)
                        || (ca_valid[s_index][2] && ca_tag[s_index][2] == s_tag)
                        || (ca_valid[s_index][3] && ca_tag[s_index][3] == s_tag))
                    begin
                        // --- SCENARIUL A/B: HIT ---
                        if (!saved_rw)
                            state <= READ_HIT;   // HIT + READ
                        else
                            state <= WRITE_HIT;  // HIT + WRITE
                    end else begin
                        // --- SCENARIUL C/D: MISS ---
                        // Victim dirty? Trebuie EVICT inainte
                        if (ca_valid[s_index][find_victim(s_index)] &&
                            ca_dirty[s_index][find_victim(s_index)])
                        begin
                            // SCENARIUL D: miss + dirty victim -> EVICT
                            // Retinem ce urmeaza dupa evictie
                            after_evict <= saved_rw ? WRITE_MISS : READ_MISS;
                            state       <= EVICT;
                        end else begin
                            // SCENARIUL C: miss + clean victim -> direct la MISS
                            state <= saved_rw ? WRITE_MISS : READ_MISS;
                        end
                    end
                end

                // =============================================================
                // READ_HIT: date gasite in cache pentru o citire
                // Returneaza cuvantul catre CPU, actualizeaza LRU
                // =============================================================
                READ_HIT: begin
                    cpu_rd_data <= ca_data[s_index][hit_way][s_word*32 +: 32];
                    lru_touch(s_index, hit_way);
                    state <= COMPLETE;
                end

                // =============================================================
                // WRITE_HIT: date gasite in cache pentru o scriere
                // Actualizeaza cuvantul in-place, marcheaza dirty, update LRU
                // (Write-back: nu scrie in memorie acum)
                // =============================================================
                WRITE_HIT: begin
                    ca_data [s_index][hit_way][s_word*32 +: 32] <= saved_wrdata;
                    ca_dirty[s_index][hit_way]                  <= 1'b1;
                    lru_touch(s_index, hit_way);
                    state <= COMPLETE;
                end

                // =============================================================
                // EVICT: scrie blocul dirty al victim-ului in memorie principala
                // Dupa confirmare (mem_ready), merge in after_evict (READ/WRITE_MISS)
                // =============================================================
                EVICT: begin
                    mem_req     <= 1'b1;
                    mem_rw      <= 1'b1;  // scriere in memorie
                    mem_addr    <= {ca_tag[s_index][victim], s_index, 6'b0};
                    mem_wr_data <= ca_data[s_index][victim];

                    if (mem_ready) begin
                        // Evacuarea s-a terminat: curata dirty bit
                        ca_dirty[s_index][victim] <= 1'b0;
                        mem_req <= 1'b0;
                        state   <= after_evict; // READ_MISS sau WRITE_MISS
                    end
                end

                // =============================================================
                // READ_MISS: aduce blocul din memorie, il aloca in victim,
                // returneaza cuvantul cerut catre CPU
                // =============================================================
                READ_MISS: begin
                    mem_req  <= 1'b1;
                    mem_rw   <= 1'b0;   // citire din memorie
                    mem_addr <= {s_tag, s_index, 6'b0};

                    if (mem_ready) begin
                        // Bloc sosit: aloca in victim way
                        ca_data [s_index][victim] <= mem_rd_data;
                        ca_tag  [s_index][victim] <= s_tag;
                        ca_valid[s_index][victim] <= 1'b1;
                        ca_dirty[s_index][victim] <= 1'b0;
                        lru_touch(s_index, victim);

                        // Returneaza cuvantul cerut
                        cpu_rd_data <= mem_rd_data[s_word*32 +: 32];

                        mem_req <= 1'b0;
                        state   <= COMPLETE;
                    end
                end

                // =============================================================
                // WRITE_MISS: write-allocate
                // Aduce blocul din memorie, il aloca in victim,
                // aplica scrierea (modifica cuvantul), marcheaza dirty
                // =============================================================
                WRITE_MISS: begin
                    mem_req  <= 1'b1;
                    mem_rw   <= 1'b0;   // citire din memorie (fetch pentru allocate)
                    mem_addr <= {s_tag, s_index, 6'b0};

                    if (mem_ready) begin
                        // Aloca blocul adus
                        ca_data [s_index][victim] <= mem_rd_data;
                        ca_tag  [s_index][victim] <= s_tag;
                        ca_valid[s_index][victim] <= 1'b1;
                        // Aplica scrierea ceruta (write-allocate in acelasi ciclu)
                        ca_data [s_index][victim][s_word*32 +: 32] <= saved_wrdata;
                        ca_dirty[s_index][victim] <= 1'b1;  // bloc modificat
                        lru_touch(s_index, victim);

                        mem_req <= 1'b0;
                        state   <= COMPLETE;
                    end
                end

                // =============================================================
                // COMPLETE: aserta cpu_ready un ciclu catre CPU, revine la IDLE
                // =============================================================
                COMPLETE: begin
                    cpu_ready <= 1'b1;
                    state     <= IDLE;
                end

                default: state <= IDLE;

            endcase
        end
    end

endmodule
