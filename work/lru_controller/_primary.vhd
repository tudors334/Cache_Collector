library verilog;
use verilog.vl_types.all;
entity lru_controller is
    port(
        clk             : in     vl_logic;
        rst             : in     vl_logic;
        update_en       : in     vl_logic;
        update_index    : in     vl_logic_vector(6 downto 0);
        update_way      : in     vl_logic_vector(1 downto 0);
        query_index     : in     vl_logic_vector(6 downto 0);
        lru_way         : out    vl_logic_vector(1 downto 0)
    );
end lru_controller;
