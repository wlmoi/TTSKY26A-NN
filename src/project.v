`default_nettype none

module tt_um_lstm_wakeword (
  input  wire [7:0] ui_in,
  output wire [7:0] uo_out,
  input  wire [7:0] uio_in,
  output wire [7:0] uio_out,
  output wire [7:0] uio_oe,
  input  wire       ena,
  input  wire       clk,
  input  wire       rst_n
`ifdef USE_POWER_PINS
  ,
  input  wire       VPWR,
  input  wire       VGND
`endif
);

  // ===== Port mapping =====
  // ui_in[6:0]  = audio_feature (7-bit signed MFCC feature)
  // ui_in[7]    = data_valid (strobe signal)
  // uio_in[0]   = reset (active high to clear LSTM state)
  // uio_in[1]   = debug_mode (bypass to check connectivity)
  // 
  // uo_out[0]   = trigger (keyword detected)
  // uo_out[6:1] = confidence (6-bit confidence score)
  // uo_out[7]   = busy (chip processing)
  //
  // uio_out[7]  = busy_flag (input port: don't send new data)
  // uio_out[6:0] = reserved

  wire [6:0] audio_feature;
  wire data_valid;
  wire reset_local;
  wire core_reset_n;
  wire debug_mode;

  wire [7:0] h_lstm;
  wire busy_lstm;
  wire [7:0] prob_out;
  wire valid_lstm;
  wire [5:0] confidence;
  wire trigger;
  wire busy_chip;

  // ===== Input Parsing =====
  assign audio_feature = ui_in[6:0];
  assign data_valid = ui_in[7];
  assign reset_local = uio_in[0];
  assign core_reset_n = rst_n & ~reset_local;
  assign debug_mode = uio_in[1];

  // ===== Debug Mode: Bypass Chain =====
  wire [7:0] debug_output;
  assign debug_output = { 1'b0, audio_feature };  // Sign-extend to 8-bit

  // ===== Input Synchronizer =====
  wire [7:0] audio_sync;
  wire valid_sync;
  
  nn_input_sync input_sync_inst (
    .clk(clk),
    .reset_n(core_reset_n),
    .audio_feature_in(audio_feature),
    .data_valid_in(data_valid),
    .audio_sync(audio_sync),
    .valid_sync(valid_sync)
  );

  // ===== LSTM Layer =====
  nn_lstm_layer lstm_layer_inst (
    .clk(clk),
    .reset_n(core_reset_n),
    .x_in(debug_mode ? debug_output : audio_sync),
    .valid_in(debug_mode ? data_valid : valid_sync),
    .h_out(h_lstm),
    .busy_out(busy_lstm)
  );

  // ===== Dense Output Layer =====
  nn_dense_layer dense_inst (
    .clk(clk),
    .reset_n(core_reset_n),
    .h_in(h_lstm),
    .valid_in(1'b1),  // Always process LSTM output
    .prob_out(prob_out),
    .valid_out(valid_lstm)
  );

  // ===== Confidence Calculator & Trigger Detection =====
  nn_confidence_calc confidence_inst (
    .clk(clk),
    .reset_n(core_reset_n),
    .prob_in(prob_out),
    .valid_in(valid_lstm),
    .confidence(confidence),
    .trigger(trigger),
    .valid_out()
  );

  // ===== Busy Controller =====
  nn_busy_controller busy_ctrl_inst (
    .clk(clk),
    .reset_n(core_reset_n),
    .valid_in(data_valid),
    .lstm_busy(busy_lstm),
    .busy_out(busy_chip)
  );

  // ===== Output Mapping =====
  // uo_out: {busy[7], confidence[6:1], trigger[0]}
  assign uo_out = debug_mode ? 
                  { 1'b0, debug_output[6:1], debug_output[0] } :
                  { busy_chip, confidence, trigger };

  // uio_out[7] = busy flag output
  assign uio_out = { busy_chip, 7'b0 };
  assign uio_oe = 8'b10000000;

  wire _unused = &{ena, ui_in[6:0], uio_in[7:2], 1'b0};
`ifdef USE_POWER_PINS
  wire _unused_power = &{VPWR, VGND, 1'b0};
`endif

endmodule
