/*
 * Combined: DVD Bouncing Flag Screensaver + PILIPINAS 7-Segment Display
 * SPDX-License-Identifier: Apache-2.0
 * Developed by Alexander Co Abad
 * ROM-free flag geometry revision
 */

`default_nettype none

parameter LOGO_WIDTH    = 128;
parameter LOGO_HEIGHT   = 64;
parameter DISPLAY_WIDTH  = 640;
parameter DISPLAY_HEIGHT = 480;

module tt_um_combined (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    // -------------------------------------------------------
    // VGA Sync Generator (shared)
    // -------------------------------------------------------
    wire hsync;
    wire vsync;
    wire video_active;
    wire [9:0] pix_x;
    wire [9:0] pix_y;

    vga_sync_generator vga_sync_gen (
        .clk(clk),
        .reset(~rst_n),
        .hsync(hsync),
        .vsync(vsync),
        .display_on(video_active),
        .hpos(pix_x),
        .vpos(pix_y)
    );

    // -------------------------------------------------------
    // BOUNCING POSITION STATE
    // -------------------------------------------------------
    reg [9:0] logo_left, logo_top;
    reg       dir_x, dir_y;
    reg [9:0] prev_y;
    reg [5:0] wave_timer;

    always @(posedge clk) begin
        if (~rst_n) begin
            logo_left  <= 200;
            logo_top   <= 100;
            dir_x      <= 1;
            dir_y      <= 0;
            wave_timer <= 0;
            prev_y     <= 0;
        end else begin
            prev_y <= pix_y;
            if (pix_y == 0 && prev_y != pix_y) begin
                wave_timer <= wave_timer + 1;
                logo_left  <= logo_left + (dir_x ? 10'd1 : -10'd1);
                logo_top   <= logo_top  + (dir_y ? 10'd1 : -10'd1);
                if (logo_left <= 1 && !dir_x)                             dir_x <= 1;
                if (logo_left >= DISPLAY_WIDTH - LOGO_WIDTH - 1 && dir_x) dir_x <= 0;
                if (logo_top  <= 1 && !dir_y)                             dir_y <= 1;
                if (logo_top  >= 390 - LOGO_HEIGHT - 1 && dir_y)          dir_y <= 0;
            end
        end
    end

    // -------------------------------------------------------
    // FLAG PIXEL COORDINATES
    // -------------------------------------------------------
    wire [7:0] logo_x = pix_x[7:0] - logo_left[7:0];
    wire [5:0] logo_y = pix_y[5:0] - logo_top[5:0];

    wire logo_region = (pix_x >= logo_left) && (pix_x < logo_left + LOGO_WIDTH) &&
                       (pix_y >= logo_top)  && (pix_y < logo_top  + LOGO_HEIGHT);

    // -------------------------------------------------------
    // WAVE ENGINE
    // -------------------------------------------------------
    wire [5:0] wave_index = logo_x[5:0] + wave_timer;
    reg signed [4:0] sine_offset;
    always @(*) begin
        case (wave_index[5:2])
            4'h0: sine_offset =  5'sb00000;
            4'h1: sine_offset =  5'sb00001;
            4'h2: sine_offset =  5'sb00010;
            4'h3: sine_offset =  5'sb00011;
            4'h4: sine_offset =  5'sb00100;
            4'h5: sine_offset =  5'sb00011;
            4'h6: sine_offset =  5'sb00010;
            4'h7: sine_offset =  5'sb00001;
            4'h8: sine_offset =  5'sb00000;
            4'h9: sine_offset = -5'sb00001;
            4'ha: sine_offset = -5'sb00010;
            4'hb: sine_offset = -5'sb00011;
            4'hc: sine_offset = -5'sb00100;
            4'hd: sine_offset = -5'sb00011;
            4'he: sine_offset = -5'sb00010;
            4'hf: sine_offset = -5'sb00001;
        endcase
    end

    wire signed [7:0] wy_signed  = $signed({2'b0, logo_y}) + sine_offset;
    wire              out_of_bounds = (wy_signed < 0) || (wy_signed > 63);
    wire [5:0]        wy          = wy_signed[5:0];

    // -------------------------------------------------------
    // FLAG GEOMETRY
    // -------------------------------------------------------
    // Triangle: base on left edge (x=0), tip at x=63 (left half of flag).
    // At row wy, triangle extends from x=0 to x = (31 - |wy-31|)*2
    // Fix white-edge: only draw if logo_x > 0 (skip leftmost column)
    //   Actually the issue is the triangle covers x=0 which is the
    //   flag border pixel. We gate: in_triangle requires logo_x >= 1.

    wire [4:0] dist_mid  = (wy[5:0] >= 6'd32) ? (wy[4:0] - 5'd31)
                                               : (5'd31   - wy[4:0]);
    wire [5:0] tri_limit = {1'b0, (5'd31 - dist_mid)} << 1; // 0..62

    // Require logo_x >= 1 to suppress the left-border white line
wire in_triangle = !out_of_bounds &&
                       (wy >= 6'd1) && (wy <= 6'd62) && 
                       (logo_x >= 8'd1) &&
                       (logo_x[6:0] <= {1'b0, tri_limit});

    // -------------------------------------------------------
    // SUN  (centre at lx=20, wy=31, radius 7 -> r^2=49)
    // -------------------------------------------------------
    wire signed [7:0] sdx = $signed({1'b0, logo_x[6:0]}) - 8'sd20;
    wire signed [7:0] sdy = $signed({2'b0, wy})           - 8'sd31;
    wire [13:0] sun_dsq   = sdx * sdx + sdy * sdy;
    wire        in_sun    = (sun_dsq <= 14'd49);

    // -------------------------------------------------------
    // 8 RAYS  (thin diamond/cross pattern radiating from sun)
    // Each ray: pixels where the ray direction dominates and
    // distance from centre is between r_inner (8) and r_outer (13).
    // We use the 4 axis + 4 diagonal directions.
    //
    // Ray is "on" when:
    //   dist_sq is in [64..169]  (between radius 8 and 13)
    //   AND the pixel is "on-axis":
    //     axis rays:     |dx|<=1 or |dy|<=1
    //     diagonal rays: |dx-dy|<=1 or |dx+dy|<=1
    // -------------------------------------------------------
    wire signed [7:0] adx = sdx;   // reuse sun offsets
    wire signed [7:0] ady = sdy;

    // Absolute values
    wire [6:0] abs_dx  = adx[7] ? (~adx[6:0] + 7'd1) : adx[6:0];
    wire [6:0] abs_dy  = ady[7] ? (~ady[6:0] + 7'd1) : ady[6:0];

    // Signed sums for diagonals
    wire signed [8:0] diag_p = $signed({adx[7], adx}) + $signed({ady[7], ady}); // dx+dy
    wire signed [8:0] diag_m = $signed({adx[7], adx}) - $signed({ady[7], ady}); // dx-dy
    wire [7:0] abs_dp = diag_p[8] ? (~diag_p[7:0] + 8'd1) : diag_p[7:0];
    wire [7:0] abs_dm = diag_m[8] ? (~diag_m[7:0] + 8'd1) : diag_m[7:0];

    wire in_ray_band = (sun_dsq >= 14'd64) && (sun_dsq <= 14'd169);

    // Axis rays: horizontal (|dy|<=1) or vertical (|dx|<=1)
    wire ray_axis = in_ray_band && ((abs_dy <= 7'd1) || (abs_dx <= 7'd1));

    // Diagonal rays: |dx+dy|<=1 or |dx-dy|<=1
    wire ray_diag = in_ray_band && ((abs_dp <= 8'd1) || (abs_dm <= 8'd1));

    wire in_ray = ray_axis | ray_diag;

    // -------------------------------------------------------
    // 3 STARS at 120-degree positions, r=10 from sun centre
    //   A: top         (20, 21)
    //   B: lower-right (29, 36)
    //   C: lower-left  (11, 36)
    // dot radius 2 -> r^2=4
    // -------------------------------------------------------
    wire signed [7:0] a_dx = $signed({1'b0, logo_x[6:0]}) - 8'sd20;
    wire signed [7:0] a_dy = $signed({2'b0, wy})           - 8'sd21;
    wire        in_sa = (a_dx*a_dx + a_dy*a_dy <= 14'd4);

    wire signed [7:0] b_dx = $signed({1'b0, logo_x[6:0]}) - 8'sd29;
    wire signed [7:0] b_dy = $signed({2'b0, wy})           - 8'sd36;
    wire        in_sb = (b_dx*b_dx + b_dy*b_dy <= 14'd4);

    wire signed [7:0] c_dx = $signed({1'b0, logo_x[6:0]}) - 8'sd11;
    wire signed [7:0] c_dy = $signed({2'b0, wy})           - 8'sd36;
    wire        in_sc = (c_dx*c_dx + c_dy*c_dy <= 14'd4);

    wire in_gold = in_triangle && (in_sun | in_ray | in_sa | in_sb | in_sc);

    // -------------------------------------------------------
    // FLAG RGB
    // -------------------------------------------------------
    reg flag_r, flag_g, flag_b;
    always @(*) begin
        if (!video_active || !logo_region || out_of_bounds) begin
            flag_r = 0; flag_g = 0; flag_b = 0;
        end else if (in_gold) begin
            flag_r = 1; flag_g = 1; flag_b = 0;        // gold
        end else if (in_triangle) begin
            flag_r = 1; flag_g = 1; flag_b = 1;        // white
        end else if (wy < 6'd32) begin
            flag_r = 0; flag_g = 0; flag_b = 1;        // blue
        end else begin
            flag_r = 1; flag_g = 0; flag_b = 0;        // red
        end
    end

    // -------------------------------------------------------
    // PILIPINAS 7-SEGMENT TEXT LOGIC
    // -------------------------------------------------------
    reg [11:0] seg_counter;
    wire [3:0] current_stage = seg_counter[6:3];
    wire       show_full_word = (current_stage >= 4'd9);

    reg [7:0] countdown [8:0];
    initial begin
        countdown[0] = 8'b01110011; // P
        countdown[1] = 8'b00000110; // I
        countdown[2] = 8'b00111000; // L
        countdown[3] = 8'b00000110; // I
        countdown[4] = 8'b01110011; // P
        countdown[5] = 8'b00000110; // I
        countdown[6] = 8'b00110111; // N
        countdown[7] = 8'b01110111; // A
        countdown[8] = 8'b01101101; // S
    end

    always @(posedge vsync, negedge rst_n) begin
        if (~rst_n) seg_counter <= 0;
        else        seg_counter <= seg_counter + 1;
    end

    // -------------------------------------------------------
    // 7-SEGMENT GEOMETRY
    // -------------------------------------------------------
    localparam TEXT_Y0 = 10'd390;
    localparam TEXT_Y1 = 10'd480;
    localparam CELL    = 10'd70;
    localparam MARGIN  = 10'd5;

    wire in_y_range     = (pix_y >= TEXT_Y0) && (pix_y < TEXT_Y1);
    wire in_x_range     = (pix_x >= MARGIN)  && (pix_x < MARGIN + 9*CELL);
    wire display_window = in_x_range && in_y_range;

    wire [3:0] digit_select =
        (pix_x < MARGIN +   CELL) ? 4'd0 :
        (pix_x < MARGIN + 2*CELL) ? 4'd1 :
        (pix_x < MARGIN + 3*CELL) ? 4'd2 :
        (pix_x < MARGIN + 4*CELL) ? 4'd3 :
        (pix_x < MARGIN + 5*CELL) ? 4'd4 :
        (pix_x < MARGIN + 6*CELL) ? 4'd5 :
        (pix_x < MARGIN + 7*CELL) ? 4'd6 :
        (pix_x < MARGIN + 8*CELL) ? 4'd7 : 4'd8;

    wire [9:0] xo      = MARGIN + digit_select * CELL;
    wire [9:0] rx_raw  = pix_x - xo;
    wire [9:0] ry_raw  = pix_y - TEXT_Y0;
    wire [11:0] rx     = (rx_raw << 2) + (rx_raw >> 1) + (rx_raw >> 4) + 191;
    wire [11:0] ry     = (ry_raw * 5)  + (ry_raw >> 2) + (ry_raw >> 4) + 7;

    wire [7:0] slot_led = show_full_word
                          ? countdown[digit_select]
                          : (current_stage == digit_select)
                            ? countdown[current_stage]
                            : 8'b00000000;

    localparam GAP = 12;
    wire j_a1 = rx < ry + 392 - GAP;
    wire j_a4 = rx > ry + 185 + GAP;
    wire j_a5 = rx > 247 - ry + GAP;
    wire j_a2 = 454 - rx > ry + GAP;
    wire j_b2 = 662 - rx > ry + GAP;
    wire j_b5 = 455 - rx < ry - GAP;
    wire j_c0 = rx < ry + 184 - GAP;
    wire j_c3 = rx + 23 > ry + GAP;
    wire j_c2 = 872 - rx > ry + GAP;
    wire j_c5 = 663 - rx < ry - GAP;
    wire j_d1 = ry > rx + 24 + GAP;

    wire seg_a = (ry > 3)   & j_a1 & j_a2 & (ry < 62)  & j_a4 & j_a5;
    wire seg_b = j_a1 & (rx < 448) & j_b2 & j_a4 & (rx > 399) & j_b5;
    wire seg_c = j_c0 & (rx < 448) & j_c2 & j_c3 & (rx > 399) & j_c5;
    wire seg_d = (ry > 418) & j_d1 & j_c2 & (ry < 477) & (rx > ry - 232) & j_c5;
    wire seg_e = j_d1 & (rx < 240) & j_b2 & (rx > ry - 232) & (rx > 191) & j_b5;
    wire seg_f = j_c0 & (rx < 240) & j_a2 & j_c3 & (rx > 191) & j_a5;
    wire seg_g = (ry > 210) & j_c0 & j_b2 & (ry < 267) & j_c3 & j_b5;

    wire text_pixel = display_window &&
                      ((seg_a & slot_led[0]) | (seg_b & slot_led[1]) |
                       (seg_c & slot_led[2]) | (seg_d & slot_led[3]) |
                       (seg_e & slot_led[4]) | (seg_f & slot_led[5]) |
                       (seg_g & slot_led[6]));

    // -------------------------------------------------------
    // PIXEL COMPOSITOR
    // -------------------------------------------------------
    wire r_out = text_pixel ? 1'b0 : flag_r;
    wire g_out = text_pixel ? 1'b1 : flag_g;
    wire b_out = text_pixel ? 1'b0 : flag_b;

    assign uo_out  = {hsync, b_out, g_out, r_out, vsync, b_out, g_out, r_out};
    assign uio_out = 8'b00000000;
    assign uio_oe  = 8'b00000000;

    wire _unused_ok = &{ena, ui_in, uio_in};

endmodule

