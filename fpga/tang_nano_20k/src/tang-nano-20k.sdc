# 24.576 MHz
# nextpnr does not propagate clocks through the rPLL, so constrain the PLL
# output net directly instead of using create_generated_clock.
create_clock -name sys_clk_in -period 40.690104166666664 [get_ports {sys_clk_in}]
create_clock -period 40.690104166666664 [get_nets {sys_clk}]
