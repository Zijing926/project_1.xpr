set_property SRC_FILE_INFO {cfile:c:/ieeesp_prj/project_1.xpr/project_1/project_1.gen/sources_1/ip/clk_wiz_0/clk_wiz_0.xdc rfile:../project_1.gen/sources_1/ip/clk_wiz_0/clk_wiz_0.xdc id:1 order:EARLY scoped_inst:u_ref_clk_gen/u_clk_wizard/inst} [current_design]
set_property SRC_FILE_INFO {cfile:c:/ieeesp_prj/project_1.xpr/project_1/project_1.gen/sources_1/ip/clk_wiz_1/clk_wiz_1.xdc rfile:../project_1.gen/sources_1/ip/clk_wiz_1/clk_wiz_1.xdc id:2 order:EARLY scoped_inst:u_clk_wiz_1/inst} [current_design]
current_instance u_ref_clk_gen/u_clk_wizard/inst
set_property src_info {type:SCOPED_XDC file:1 line:54 export:INPUT save:INPUT read:READ} [current_design]
set_input_jitter [get_clocks -of_objects [get_ports clk_in1]] 0.080
current_instance
current_instance u_clk_wiz_1/inst
set_property src_info {type:SCOPED_XDC file:2 line:54 export:INPUT save:INPUT read:READ} [current_design]
set_input_jitter [get_clocks -of_objects [get_ports clk_in1_p]] 0.080
