`default_nettype none

module adc_sigma_delta_top #(
    parameter WINDOW_BITS = 8,
    parameter ACTIVITY_THRESHOLD = 8
)(
    input  wire       clk,
    input  wire       reset_n,
    input  wire       enable,
    input  wire       bitstream_in,
    input  wire [3:0] gain_trim,
    input  wire [3:0] offset_trim,
    output wire [7:0] adc_code,
    output wire       adc_valid,
    output wire       adc_busy,
    output wire       adc_activity,
    output wire       adc_saturated
);

    wire enable_sync;
    wire bitstream_sync;
    wire sample_enable;
    wire [7:0] raw_code;
    wire raw_ready;
    wire raw_busy;
    wire raw_saturated;
    wire [7:0] calibrated_code;
    wire clip_hi;
    wire clip_lo;
    wire activity_now;
    wire [3:0] status_bits;
    wire [3:0] raw_nibble;
    reg [3:0] gain_trim_sync;
    reg [3:0] offset_trim_sync;
    reg [3:0] gain_trim_window;
    reg [3:0] offset_trim_window;

    adc_input_synchronizer u_sync (
        .clk            (clk),
        .reset_n        (reset_n),
        .enable_in      (enable),
        .bitstream_in   (bitstream_in),
        .enable_sync    (enable_sync),
        .bitstream_sync (bitstream_sync)
    );

    adc_control u_control (
        .clk            (clk),
        .reset_n        (reset_n),
        .enable         (enable_sync),
        .sample_enable  (sample_enable)
    );

    adc_decimator #(
        .WINDOW_BITS    (WINDOW_BITS)
    ) u_decimator (
        .clk            (clk),
        .reset_n        (reset_n),
        .sample_enable  (sample_enable),
        .bitstream      (bitstream_sync),
        .raw_code       (raw_code),
        .raw_ready      (raw_ready),
        .busy           (raw_busy),
        .raw_saturated  (raw_saturated)
    );

    // Synchronize external trims and only update active trim values at
    // window boundaries. This keeps calibration deterministic in GL timing.
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            gain_trim_sync <= 4'h0;
            offset_trim_sync <= 4'h0;
            gain_trim_window <= 4'h0;
            offset_trim_window <= 4'h0;
        end else begin
            gain_trim_sync <= gain_trim;
            offset_trim_sync <= offset_trim;

            if (!sample_enable || raw_ready) begin
                gain_trim_window <= gain_trim_sync;
                offset_trim_window <= offset_trim_sync;
            end
        end
    end

    adc_gain_offset_cal u_gain_offset (
        .raw_code        (raw_code),
        .gain_trim       (gain_trim_window),
        .offset_trim     (offset_trim_window),
        .calibrated_code (calibrated_code),
        .clip_hi         (clip_hi),
        .clip_lo         (clip_lo)
    );

    adc_activity_monitor #(
        .THRESHOLD       (ACTIVITY_THRESHOLD)
    ) u_activity (
        .clk            (clk),
        .reset_n        (reset_n),
        .sample_enable  (sample_enable),
        .bitstream      (bitstream_sync),
        .raw_ready      (raw_ready),
        .activity_now   (activity_now)
    );

    adc_output_registers u_output (
        .clk            (clk),
        .reset_n        (reset_n),
        .sample_enable  (sample_enable),
        .raw_ready      (raw_ready),
        .raw_code       (raw_code),
        .calibrated_code(calibrated_code),
        .activity_now   (activity_now),
        .saturated_now  (raw_saturated | clip_hi | clip_lo),
        .adc_code       (adc_code),
        .status_bits    (status_bits),
        .raw_nibble     (raw_nibble)
    );

    assign adc_valid = status_bits[0];
    assign adc_busy = status_bits[1] | raw_busy;
    assign adc_activity = status_bits[2];
    assign adc_saturated = status_bits[3];

    wire _unused = &{raw_nibble, 1'b0};

endmodule