set_property PACKAGE_PIN W10 [get_ports pdm_out_l]
set_property PACKAGE_PIN AA11 [get_ports pdm_out_r]

set_property IOSTANDARD LVCMOS33 [get_ports pdm_out_*]
set_property DRIVE 16 [get_ports pdm_out_*]
set_property SLEW SLOW [get_ports pdm_out_*]

set_property IOSTANDARD LVCMOS33 [get_ports s_i2s_*]
set_property PACKAGE_PIN Y12 [get_ports s_i2s_sck]
set_property PACKAGE_PIN AG13 [get_ports s_i2s_ws]
set_property PACKAGE_PIN AA12 [get_ports s_i2s_sd]


set_property IOSTANDARD LVDS [get_ports clk_200M_*]
set_property PACKAGE_PIN L3 [get_ports clk_200M_p]
set_property PACKAGE_PIN L2 [get_ports clk_200M_n]
set_property DIFF_TERM_ADV TERM_100 [get_ports clk_200M_*]
create_clock -name clk_200M -period 5.000 [get_ports clk_200M_p]
