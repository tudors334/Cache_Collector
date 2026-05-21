// =============================================================================
// lru_controller.v
// LRU Replacement Policy Controller
//
// Implements a 4-way LRU tracker using age counters per set.
// Each way holds a 2-bit age value (0 = MRU, 3 = LRU).
// On every access the accessed way is reset to 0 (MRU) and
// all other ways whose age was less than the accessed way's
// old age are incremented by 1.
// =============================================================================

module lru_controller (
    input  wire        clk,
    input  wire        rst,

    // Update port - called on every cache hit or allocation
    input  wire        update_en,       // Pulse to update LRU state
    input  wire [6:0]  update_index,    // Set to update
    input  wire [1:0]  update_way,      // Way that was just accessed/allocated

    // Query port - returns the LRU way for a given set
    input  wire [6:0]  query_index,     // Set to query
    output reg  [1:0]  lru_way          // Way with highest age (LRU victim)
);

    // -------------------------------------------------------------------------
    // Age storage: 2 bits per way, 4 ways, 128 sets
    // age=0 -> MRU, age=3 -> LRU
    // -------------------------------------------------------------------------
    reg [1:0] age [0:127][0:3]; // [set][way]

    integer i, j;

    // -------------------------------------------------------------------------
    // Reset and update logic
    // -------------------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            // Initialise ages so way 0 is MRU and way 3 is LRU
            for (i = 0; i < 128; i = i + 1) begin
                age[i][0] <= 2'd0;
                age[i][1] <= 2'd1;
                age[i][2] <= 2'd2;
                age[i][3] <= 2'd3;
            end
        end else if (update_en) begin
            // Promote update_way to MRU (age = 0)
            // Increment age of every other way that was younger (lower age)
            // than update_way's current age to maintain relative order.
            for (j = 0; j < 4; j = j + 1) begin
                if (j[1:0] == update_way) begin
                    age[update_index][j] <= 2'd0; // Mark as MRU
                end else if (age[update_index][j] < age[update_index][update_way]) begin
                    age[update_index][j] <= age[update_index][j] + 2'd1;
                end
                // Ways already older than update_way stay unchanged
            end
        end
    end

    // -------------------------------------------------------------------------
    // LRU way query (combinational) - find way with age == 3
    // -------------------------------------------------------------------------
    always @(*) begin
        lru_way = 2'd0; // Default fallback
        for (i = 0; i < 4; i = i + 1) begin
            if (age[query_index][i] == 2'd3) begin
                lru_way = i[1:0];
            end
        end
    end

endmodule