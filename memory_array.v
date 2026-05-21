// =============================================================================
// memory_array.v
// Cache Memory Array Module
//
// Stores data, tags, valid bits, and dirty bits for a
// 4-way set-associative cache:
//   - 128 sets
//   -   4 ways per set
//   -  64 bytes per block (16 words x 4 bytes)
//   -  19-bit tag per block
// =============================================================================

module memory_array (
    input  wire        clk,
    input  wire        rst,

    // Read port
    input  wire [6:0]  rd_index,        // Set index (7 bits -> 128 sets)
    input  wire [1:0]  rd_way,          // Way select (2 bits -> 4 ways)
    output reg  [511:0] rd_data,        // 64-byte block data output
    output reg  [18:0] rd_tag,          // Tag output
    output reg         rd_valid,        // Valid bit output
    output reg         rd_dirty,        // Dirty bit output

    // Write port
    input  wire        wr_en,           // Write enable
    input  wire [6:0]  wr_index,        // Set index for write
    input  wire [1:0]  wr_way,          // Way select for write
    input  wire [511:0] wr_data,        // 64-byte block data input
    input  wire [18:0] wr_tag,          // Tag to write
    input  wire        wr_valid,        // Valid bit to write
    input  wire        wr_dirty,        // Dirty bit to write

    // Word-level write port (for write-hit: update only one word)
    input  wire        word_wr_en,      // Word write enable
    input  wire [6:0]  word_wr_index,   // Set index for word write
    input  wire [1:0]  word_wr_way,     // Way for word write
    input  wire [3:0]  word_wr_offset,  // Word offset within block (0-15)
    input  wire [31:0] word_wr_data,    // 32-bit word to write
    input  wire        word_wr_dirty    // Set dirty bit on word write
);

    // -------------------------------------------------------------------------
    // Storage arrays
    // -------------------------------------------------------------------------
    reg [511:0] data_mem  [0:127][0:3]; // [set][way] -> 64-byte block
    reg [18:0]  tag_mem   [0:127][0:3]; // [set][way] -> 19-bit tag
    reg         valid_mem [0:127][0:3]; // [set][way] -> valid bit
    reg         dirty_mem [0:127][0:3]; // [set][way] -> dirty bit

    integer i, j;

    // -------------------------------------------------------------------------
    // Reset and write logic (synchronous)
    // -------------------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            // Invalidate all entries on reset
            for (i = 0; i < 128; i = i + 1) begin
                for (j = 0; j < 4; j = j + 1) begin
                    data_mem[i][j]  <= 512'b0;
                    tag_mem[i][j]   <= 19'b0;
                    valid_mem[i][j] <= 1'b0;
                    dirty_mem[i][j] <= 1'b0;
                end
            end
        end else begin
            // Full block write (used on miss/allocate or evict)
            if (wr_en) begin
                data_mem [wr_index][wr_way] <= wr_data;
                tag_mem  [wr_index][wr_way] <= wr_tag;
                valid_mem[wr_index][wr_way] <= wr_valid;
                dirty_mem[wr_index][wr_way] <= wr_dirty;
            end

            // Word-level write (used on write-hit)
            if (word_wr_en) begin
                // Overwrite only the 32-bit word at the given offset
                data_mem[word_wr_index][word_wr_way][word_wr_offset*32 +: 32]
                    <= word_wr_data;
                dirty_mem[word_wr_index][word_wr_way] <= word_wr_dirty;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Read logic (combinational - registered output for stability)
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        rd_data  <= data_mem [rd_index][rd_way];
        rd_tag   <= tag_mem  [rd_index][rd_way];
        rd_valid <= valid_mem[rd_index][rd_way];
        rd_dirty <= dirty_mem[rd_index][rd_way];
    end

endmodule
