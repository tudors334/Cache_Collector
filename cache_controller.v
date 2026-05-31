`timescale 1ns/1ps
// cache controller 4-way set-associative, write-back, write-allocate, lru

module cache_controller (
    input  wire        clk,
    input  wire        rst,

    // interfata cpu
    input  wire        cpu_req,
    input  wire        cpu_rw,          // 0=read  1=write
    input  wire [31:0] cpu_addr,
    input  wire [31:0] cpu_wr_data,
    output reg  [31:0] cpu_rd_data,
    output reg         cpu_ready,

    // interfata memorie principala
    output reg         mem_req,
    output reg         mem_rw,          // 0=fetch  1=evict
    output reg  [31:0] mem_addr,
    output reg  [511:0] mem_wr_data,    // bloc de 64 bytes evacuat
    input  wire [511:0] mem_rd_data,    // bloc adus din memorie
    input  wire        mem_ready        // confirmare de la memorie
);

    // starile fsm
    localparam [3:0]
        IDLE       = 4'd0,
        TAG_CHECK  = 4'd1,   // nod central de decizie
        READ_HIT   = 4'd2,
        WRITE_HIT  = 4'd3,
        READ_MISS  = 4'd4,
        WRITE_MISS = 4'd5,
        EVICT      = 4'd6,
        COMPLETE   = 4'd7;

    reg [3:0] state;

    // adresa si datele salvate la intrarea in tag_check
    reg [31:0] saved_addr;
    reg [31:0] saved_wrdata;
    reg        saved_rw;

    // decompoziie adresa: tag 18b, index 7b, offset 6b
    // cuvantul in bloc se selecteaza din bitii [5:2]
    wire [17:0] s_tag   = saved_addr[31:14];
    wire [6:0]  s_index = saved_addr[13:7];
    wire [3:0]  s_word  = saved_addr[5:2];   // pozitia cuvantului in bloc

    // array-uri cache: 128 seturi x 4 ways
    reg [511:0] ca_data  [0:127][0:3];
    reg [17:0]  ca_tag   [0:127][0:3];
    reg         ca_valid [0:127][0:3];
    reg         ca_dirty [0:127][0:3];

    // varsta lru per set si way; 0=mru, 3=lru
    reg [1:0] lru_age [0:127][0:3];

    // variabile interne ale fsm-ului
    reg [1:0]  hit_way;     // way-ul unde s-a gasit hit
    reg        cache_hit;   // 1 daca tag_check a gasit hit
    reg [1:0]  victim;      // way-ul ales pentru alocare
    // starea urmatoare dupa terminarea evict
    reg [3:0]  after_evict;

    integer i, j;

    // returneaza way-ul cu lru_age egal cu 3
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

    // seteaza way accesat ca mru si avanseaza celelalte
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

    // bloc secvential principal al fsm
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
                    lru_age [i][j] <= j[1:0]; // varste initiale: 0,1,2,3
                end
        end else begin
            // de-assert implicit la fiecare ciclu
            cpu_ready <= 1'b0;
            mem_req   <= 1'b0;

            case (state)

                // asteapta cerere de la cpu
                IDLE: begin
                    if (cpu_req) begin
                        saved_addr   <= cpu_addr;
                        saved_wrdata <= cpu_wr_data;
                        saved_rw     <= cpu_rw;
                        state        <= TAG_CHECK;
                    end
                end

                // compara tag cu toate 4 ways si decide starea urmatoare
                TAG_CHECK: begin
                    // detectie hit: compara tag cu fiecare way valid
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

                    // selecteaza victim lru pentru cazul de miss
                    victim <= find_victim(s_index);

                    // decizie tranzitie; cache_hit/victim setate cu <=,
                    // deci citim direct din ca_* pentru decizie in acelasi ciclu
                    if (   (ca_valid[s_index][0] && ca_tag[s_index][0] == s_tag)
                        || (ca_valid[s_index][1] && ca_tag[s_index][1] == s_tag)
                        || (ca_valid[s_index][2] && ca_tag[s_index][2] == s_tag)
                        || (ca_valid[s_index][3] && ca_tag[s_index][3] == s_tag))
                    begin
                        // hit: merge la read_hit sau write_hit
                        if (!saved_rw)
                            state <= READ_HIT;
                        else
                            state <= WRITE_HIT;
                    end else begin
                        // miss: verifica daca victim e dirty
                        if (ca_valid[s_index][find_victim(s_index)] &&
                            ca_dirty[s_index][find_victim(s_index)])
                        begin
                            // victim dirty, trebuie evacuat mai intai
                            after_evict <= saved_rw ? WRITE_MISS : READ_MISS;
                            state       <= EVICT;
                        end else begin
                            // victim curat, merge direct la miss
                            state <= saved_rw ? WRITE_MISS : READ_MISS;
                        end
                    end
                end

                // returneaza cuvantul din cache si actualizeaza lru
                READ_HIT: begin
                    cpu_rd_data <= ca_data[s_index][hit_way][s_word*32 +: 32];
                    lru_touch(s_index, hit_way);
                    state <= COMPLETE;
                end

                // scrie cuvantul in cache, seteaza dirty, actualizeaza lru
                WRITE_HIT: begin
                    ca_data [s_index][hit_way][s_word*32 +: 32] <= saved_wrdata;
                    ca_dirty[s_index][hit_way]                  <= 1'b1;
                    lru_touch(s_index, hit_way);
                    state <= COMPLETE;
                end

                // scrie blocul dirty al victim in memorie si asteapta confirmare
                EVICT: begin
                    mem_req     <= 1'b1;
                    mem_rw      <= 1'b1;  // scriere in memorie
                    mem_addr    <= {ca_tag[s_index][victim], s_index, 6'b0};
                    mem_wr_data <= ca_data[s_index][victim];

                    if (mem_ready) begin
                        // evacuare terminata, curata dirty bit
                        ca_dirty[s_index][victim] <= 1'b0;
                        mem_req <= 1'b0;
                        state   <= after_evict;
                    end
                end

                // aduce bloc din memorie si returneaza cuvantul cerut
                READ_MISS: begin
                    mem_req  <= 1'b1;
                    mem_rw   <= 1'b0;   // citire din memorie
                    mem_addr <= {s_tag, s_index, 6'b0};

                    if (mem_ready) begin
                        // aloca blocul in victim way
                        ca_data [s_index][victim] <= mem_rd_data;
                        ca_tag  [s_index][victim] <= s_tag;
                        ca_valid[s_index][victim] <= 1'b1;
                        ca_dirty[s_index][victim] <= 1'b0;
                        lru_touch(s_index, victim);

                        // trimite cuvantul cerut catre cpu
                        cpu_rd_data <= mem_rd_data[s_word*32 +: 32];

                        mem_req <= 1'b0;
                        state   <= COMPLETE;
                    end
                end

                // aduce bloc, il aloca si aplica scrierea (write-allocate)
                WRITE_MISS: begin
                    mem_req  <= 1'b1;
                    mem_rw   <= 1'b0;   // fetch pentru alocare
                    mem_addr <= {s_tag, s_index, 6'b0};

                    if (mem_ready) begin
                        // aloca blocul adus din memorie
                        ca_data [s_index][victim] <= mem_rd_data;
                        ca_tag  [s_index][victim] <= s_tag;
                        ca_valid[s_index][victim] <= 1'b1;
                        // aplica scrierea in acelasi ciclu cu alocarea
                        ca_data [s_index][victim][s_word*32 +: 32] <= saved_wrdata;
                        ca_dirty[s_index][victim] <= 1'b1;  // bloc modificat
                        lru_touch(s_index, victim);

                        mem_req <= 1'b0;
                        state   <= COMPLETE;
                    end
                end

                // aserta cpu_ready un ciclu si revine la idle
                COMPLETE: begin
                    cpu_ready <= 1'b1;
                    state     <= IDLE;
                end

                default: state <= IDLE;

            endcase
        end
    end

endmodule