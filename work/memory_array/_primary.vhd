library verilog;
use verilog.vl_types.all;
entity memory_array is
    port(
        clk             : in     vl_logic;
        rst             : in     vl_logic;
        rd_index        : in     vl_logic_vector(6 downto 0);
        rd_way          : in     vl_logic_vector(1 downto 0);
        rd_data         : out    vl_logic_vector(511 downto 0);
        rd_tag          : out    vl_logic_vector(18 downto 0);
        rd_valid        : out    vl_logic;
        rd_dirty        : out    vl_logic;
        wr_en           : in     vl_logic;
        wr_index        : in     vl_logic_vector(6 downto 0);
        wr_way          : in     vl_logic_vector(1 downto 0);
        wr_data         : in     vl_logic_vector(511 downto 0);
        wr_tag          : in     vl_logic_vector(18 downto 0);
        wr_valid        : in     vl_logic;
        wr_dirty        : in     vl_logic;
        word_wr_en      : in     vl_logic;
        word_wr_index   : in     vl_logic_vector(6 downto 0);
        word_wr_way     : in     vl_logic_vector(1 downto 0);
        word_wr_offset  : in     vl_logic_vector(3 downto 0);
        word_wr_data    : in     vl_logic_vector(31 downto 0);
        word_wr_dirty   : in     vl_logic
    );
end memory_array;
