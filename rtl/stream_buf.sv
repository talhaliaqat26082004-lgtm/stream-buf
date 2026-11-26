// -----------------------------------------------------------------------------
// stream_buf : parameterizable streaming buffer (valid/ready both sides)
//
// Coding standard : plain Verilog-2001 (file is named .sv per assessment layout)
// Reset           : synchronous, active-low, control state only (storage unreset)
// DEPTH           : any value >= 2 (non-power-of-2 supported)
// AF_THRESH       : must be >= 1 (almost_full resets to 0)
// OUT_REG = 0     : first-word-fall-through, read latency = 1 cycle,
//                   m_data = mem[rd_ptr] (long mux path to the output)
// OUT_REG = 1     : one-word output register, read latency = 2 cycles,
//                   m_valid/m_data come straight from flops. The core memory
//                   holds DEPTH-1 words; the output register is the DEPTH-th.
// count           : total words held (core + output register), full is
//                   count == DEPTH in both modes
// s_ready         : depends only on occupancy (never on m_ready)
// Errors          : sticky protocol-misuse warnings, cleared by err_clr.
//                   A new event in the same cycle as err_clr wins (not lost).
//                   NOTE: normal backpressure (valid held while full) also
//                   sets overflow; it is a warning, not a data-loss flag.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module stream_buf (
    clk, rst_n,
    s_valid, s_ready, s_data,
    m_valid, m_ready, m_data,
    count, almost_full, almost_empty,
    err_clr, overflow, underflow
);

    parameter DATA_W    = 32;
    parameter DEPTH     = 16;
    parameter AF_THRESH = 14;   // almost_full  when count >= AF_THRESH
    parameter AE_THRESH = 2;    // almost_empty when count <= AE_THRESH
    parameter OUT_REG   = 0;    // 1 = registered output stage

    // Verilog-2001 has no $clog2
    function integer clog2;
        input integer value;
        integer v;
        begin
            v = value - 1;
            for (clog2 = 0; v > 0; clog2 = clog2 + 1)
                v = v >> 1;
        end
    endfunction

    localparam CORE_D = (OUT_REG != 0) ? DEPTH - 1 : DEPTH;
    localparam PTR_W  = (CORE_D > 1) ? clog2(CORE_D) : 1;
    localparam CNT_W  = clog2(DEPTH + 1);

    input                   clk;
    input                   rst_n;
    input                   s_valid;
    output                  s_ready;
    input  [DATA_W-1:0]     s_data;
    output                  m_valid;
    input                   m_ready;
    output [DATA_W-1:0]     m_data;
    output [CNT_W-1:0]      count;
    output                  almost_full;
    output                  almost_empty;
    input                   err_clr;
    output                  overflow;
    output                  underflow;

    // ---------------------------------------------------------------- storage
    reg [DATA_W-1:0] mem [0:CORE_D-1];

    // ---------------------------------------------------------------- control
    reg  [PTR_W-1:0] wr_ptr;
    reg  [PTR_W-1:0] rd_ptr;
    reg  [CNT_W-1:0] cnt;        // total words held
    reg  [CNT_W-1:0] cnt_nxt;
    reg              af_q;
    reg              ae_q;
    reg              ovf_q;
    reg              unf_q;

    wire core_empty;             // core memory has no word to read
    wire core_rd_en;             // core word is consumed this cycle

    wire full   = (cnt == DEPTH);
    wire wr_en  = s_valid & ~full;
    wire rd_en  = m_valid & m_ready;

    wire [PTR_W-1:0] wr_ptr_nxt = (wr_ptr == CORE_D - 1) ? {PTR_W{1'b0}} : wr_ptr + 1'b1;
    wire [PTR_W-1:0] rd_ptr_nxt = (rd_ptr == CORE_D - 1) ? {PTR_W{1'b0}} : rd_ptr + 1'b1;

    wire ovf_evt = s_valid & full;
    wire unf_evt = m_ready & ~m_valid;

    // simultaneous read + write leaves occupancy unchanged
    always @* begin
        case ({wr_en, rd_en})
            2'b10:   cnt_nxt = cnt + 1'b1;
            2'b01:   cnt_nxt = cnt - 1'b1;
            default: cnt_nxt = cnt;
        endcase
    end

    // storage write: no reset, one write port
    always @(posedge clk) begin
        if (wr_en)
            mem[wr_ptr] <= s_data;
    end

    // ------------------------------------------------------------ read side
    generate
        if (OUT_REG != 0) begin : g_out
            // registered output stage
            reg                out_valid;
            reg [DATA_W-1:0]   out_data;

            // core is empty when every held word is the one in the output reg
            assign core_empty = (cnt == out_valid);
            assign core_rd_en = ~core_empty & (~out_valid | m_ready);

            always @(posedge clk) begin
                if (!rst_n)
                    out_valid <= 1'b0;
                else if (core_rd_en)
                    out_valid <= 1'b1;
                else if (m_ready)
                    out_valid <= 1'b0;
            end

            // no reset: stale data is never visible while out_valid is low
            always @(posedge clk) begin
                if (core_rd_en)
                    out_data <= mem[rd_ptr];
            end

            assign m_valid = out_valid;
            assign m_data  = out_data;
        end else begin : g_direct
            // first-word-fall-through
            assign core_empty = (cnt == 0);
            assign core_rd_en = ~core_empty & m_ready;
            assign m_valid    = ~core_empty;
            assign m_data     = mem[rd_ptr];
        end
    endgenerate

    // control state
    always @(posedge clk) begin
        if (!rst_n) begin
            wr_ptr <= {PTR_W{1'b0}};
            rd_ptr <= {PTR_W{1'b0}};
            cnt    <= {CNT_W{1'b0}};
            af_q   <= 1'b0;
            ae_q   <= 1'b1;
            ovf_q  <= 1'b0;
            unf_q  <= 1'b0;
        end else begin
            if (wr_en)      wr_ptr <= wr_ptr_nxt;
            if (core_rd_en) rd_ptr <= rd_ptr_nxt;
            cnt    <= cnt_nxt;
            af_q   <= (cnt_nxt >= AF_THRESH);
            ae_q   <= (cnt_nxt <= AE_THRESH);

            if (err_clr) begin
                ovf_q <= 1'b0;
                unf_q <= 1'b0;
            end
            if (ovf_evt) ovf_q <= 1'b1;
            if (unf_evt) unf_q <= 1'b1;
        end
    end

    // ---------------------------------------------------------------- outputs
    assign s_ready      = ~full;
    assign count        = cnt;
    assign almost_full  = af_q;
    assign almost_empty = ae_q;
    assign overflow     = ovf_q;
    assign underflow    = unf_q;

endmodule
