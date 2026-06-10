set_property PACKAGE_PIN W10 [get_ports pdm_out_l]
set_property PACKAGE_PIN AA11 [get_ports pdm_out_r]

set_property IOSTANDARD LVCMOS33 [get_ports pdm_out_*]
set_property DRIVE 16 [get_ports pdm_out_*]
set_property SLEW FAST [get_ports pdm_out_*]

