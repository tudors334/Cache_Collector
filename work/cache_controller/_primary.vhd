library verilog;
use verilog.vl_types.all;
entity cache_controller is
    port(
        clk             : in     vl_logic;
        rst             : in     vl_logic;
        cpu_req         : in     vl_logic;
        cpu_rw          : in     vl_logic;
        cpu_addr        : in     vl_logic_vector(31 downto 0);
        cpu_wr_data     : in     vl_logic_vector(31 downto 0);
        cpu_rd_data     : out    vl_logic_vector(31 downto 0);
        cpu_ready       : out    vl_logic;
        mem_req         : out    vl_logic;
        mem_rw          : out    vl_logic;
        mem_addr        : out    vl_logic_vector(31 downto 0);
        mem_wr_data     : out    vl_logic_vector(511 downto 0);
        mem_rd_data     : in     vl_logic_vector(511 downto 0);
        mem_ready       : in     vl_logic
    );
end cache_controller;
