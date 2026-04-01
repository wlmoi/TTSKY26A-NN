`default_nettype none

module adc_gain_offset_cal (
    input  wire [7:0] raw_code,
    input  wire [3:0] gain_trim,
    input  wire [3:0] offset_trim,
    output reg  [7:0] calibrated_code,
    output reg        clip_hi,
    output reg        clip_lo
);

    wire [4:0] gain_factor;
    wire signed [5:0] offset_signed;
    wire [13:0] mult_value;
    wire [13:0] mult_rounded;
    wire [9:0] scaled_code;
    reg signed [10:0] adjusted_code;

    assign gain_factor = 5'd16 + {1'b0, gain_trim};
    assign offset_signed = offset_trim[3]
        ? ($signed({2'b00, offset_trim}) - 6'sd16)
        : $signed({2'b00, offset_trim});

    assign mult_value = {6'b0, raw_code} * {9'b0, gain_factor};
    assign mult_rounded = mult_value + 14'd8;
    assign scaled_code = mult_rounded[13:4];

    always @(*) begin
        adjusted_code = $signed({1'b0, scaled_code}) + $signed(offset_signed);

        clip_hi = 1'b0;
        clip_lo = 1'b0;

        if (adjusted_code < 0) begin
            calibrated_code = 8'h00;
            clip_lo = 1'b1;
        end else if (adjusted_code > 11'sd255) begin
            calibrated_code = 8'hFF;
            clip_hi = 1'b1;
        end else begin
            calibrated_code = adjusted_code[7:0];
        end
    end

endmodule