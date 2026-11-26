// -----------------------------------------------------------------------------
// Self-checking testbench for stream_buf (plain Verilog-2001)
//
// Method : cycle-accurate reference model inside the monitor (wr_n / rd_n
//          counters + expected-data array). Every posedge the DUT outputs are
//          compared with the model BEFORE the model is updated.
// Drive  : stimulus changes on negedge, monitor samples on posedge (no races).
// Checks : count, s_ready (full), m_valid (empty), data order/integrity,
//          m_data stability under stall, almost flags, sticky errors + clear,
//          100% throughput, mid-run reset.
// To retarget: change DEPTH / AF_THRESH / AE_THRESH / OUT_REG below (AF_THRESH >= 1).
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb;

    parameter DATA_W    = 32;
    parameter DEPTH     = 16;
    parameter AF_THRESH = 14;
    parameter AE_THRESH = 2;
    parameter OUT_REG   = 0;   // 0: FWFT (latency 1), 1: output register (latency 2)

    function integer clog2;
        input integer value;
        integer v;
        begin
            v = value - 1;
            for (clog2 = 0; v > 0; clog2 = clog2 + 1)
                v = v >> 1;
        end
    endfunction

    localparam CNT_W = clog2(DEPTH + 1);

    // ------------------------------------------------------------------ DUT
    reg                 clk;
    reg                 rst_n;
    reg                 s_valid;
    wire                s_ready;
    reg  [DATA_W-1:0]   s_data;
    wire                m_valid;
    reg                 m_ready;
    wire [DATA_W-1:0]   m_data;
    wire [CNT_W-1:0]    count;
    wire                almost_full;
    wire                almost_empty;
    reg                 err_clr;
    wire                overflow;
    wire                underflow;

    stream_buf #(
        .DATA_W    (DATA_W),
        .DEPTH     (DEPTH),
        .AF_THRESH (AF_THRESH),
        .AE_THRESH (AE_THRESH),
        .OUT_REG   (OUT_REG)
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .s_valid      (s_valid),
        .s_ready      (s_ready),
        .s_data       (s_data),
        .m_valid      (m_valid),
        .m_ready      (m_ready),
        .m_data       (m_data),
        .count        (count),
        .almost_full  (almost_full),
        .almost_empty (almost_empty),
        .err_clr      (err_clr),
        .overflow     (overflow),
        .underflow    (underflow)
    );

    // ---------------------------------------------------------------- clock
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ------------------------------------------------------------ utilities
    integer errors;
    integer seed;
    integer prod_pct;
    integer cons_pct;

    task fail;
        input [8*48-1:0] msg;
        begin
            errors = errors + 1;
            $display("[%0t] ERROR: %0s", $time, msg);
        end
    endtask

    function rnd;
        input integer pct;
        begin
            rnd = ((($random(seed)) & 32'h7fffffff) % 100) < pct;
        end
    endfunction

    // ---------------------------------------------------------- ref model
    reg  [DATA_W-1:0] exp_mem [0:65535];
    integer           wr_n;
    integer           rd_n;
    integer           occ;
    reg               m_ovf;
    reg               m_unf;
    reg               started;
    reg               s_xfer;
    reg               m_xfer;
    reg               hold_chk;
    reg               lat_wait;
    reg  [DATA_W-1:0] hold_data;
    integer           s_xfers;
    integer           m_xfers;

    initial begin
        errors   = 0;
        started  = 1'b0;
        s_xfer   = 1'b0;
        m_xfer   = 1'b0;
        hold_chk = 1'b0;
        lat_wait = 1'b0;
        s_xfers  = 0;
        m_xfers  = 0;
        wr_n     = 0;
        rd_n     = 0;
        m_ovf    = 1'b0;
        m_unf    = 1'b0;
    end

    // monitor: compare first, update model second
    always @(posedge clk) begin
        if (!rst_n) begin
            wr_n     = 0;
            rd_n     = 0;
            m_ovf    = 1'b0;
            m_unf    = 1'b0;
            hold_chk = 1'b0;
            lat_wait = 1'b0;
            s_xfer   = 1'b0;
            m_xfer   = 1'b0;
            started  = 1'b1;
        end else if (started) begin
            occ = wr_n - rd_n;

            if (count !== occ)                     fail("count mismatch");
            if (s_ready !== (occ != DEPTH))        fail("s_ready mismatch (full)");
            if (OUT_REG == 0) begin
                // FWFT: m_valid is exactly 'not empty'
                if (m_valid !== (occ != 0))        fail("m_valid mismatch (empty)");
            end else begin
                // output register: read latency is 2, so m_valid may lag by 1 cycle
                if (m_valid !== 1'b0 && m_valid !== 1'b1) fail("m_valid is X");
                if (m_valid === 1'b1 && occ == 0)  fail("m_valid high while empty");
                if (occ >= 2 && m_valid !== 1'b1)  fail("m_valid low with 2+ words held");
                if (lat_wait && m_valid !== 1'b1)  fail("read latency exceeded 2 cycles");
                lat_wait = (occ != 0) && (m_valid !== 1'b1);
            end
            if (almost_full !== (occ >= AF_THRESH))  fail("almost_full mismatch");
            if (almost_empty !== (occ <= AE_THRESH)) fail("almost_empty mismatch");
            if (overflow !== m_ovf)                fail("overflow flag mismatch");
            if (underflow !== m_unf)               fail("underflow flag mismatch");

            if (m_valid === 1'b1) begin
                if (m_data !== exp_mem[rd_n % 65536])
                    fail("m_data mismatch (loss/dup/reorder)");
            end

            if (hold_chk) begin
                if (m_valid !== 1'b1 || m_data !== hold_data)
                    fail("m_data/m_valid not stable under stall");
            end

            // model update
            s_xfer = s_valid && (occ != DEPTH);
            m_xfer = m_ready && (m_valid === 1'b1);
            hold_chk  = m_valid && !m_ready;
            hold_data = m_data;

            if (s_xfer) begin
                exp_mem[wr_n % 65536] = s_data;
                wr_n    = wr_n + 1;
                s_xfers = s_xfers + 1;
            end
            if (m_xfer) begin
                rd_n    = rd_n + 1;
                m_xfers = m_xfers + 1;
            end

            if (err_clr) begin
                m_ovf = 1'b0;
                m_unf = 1'b0;
            end
            if (s_valid && occ == DEPTH) m_ovf = 1'b1;
            if (m_ready && (m_valid !== 1'b1)) m_unf = 1'b1;
        end
    end

    // ------------------------------------------------------ producer/consumer
    // Producer holds valid and data until the word is accepted (AXI-Stream rule)
    always @(negedge clk) begin
        if (!rst_n) begin
            s_valid = 1'b0;
            s_data  = {DATA_W{1'b0}};
            m_ready = 1'b0;
        end else begin
            if (!s_valid || s_xfer) begin
                if (rnd(prod_pct)) begin
                    s_valid = 1'b1;
                    s_data  = $random(seed);
                end else begin
                    s_valid = 1'b0;
                end
            end
            m_ready = rnd(cons_pct);
        end
    end

    // ---------------------------------------------------------------- tasks
    task run;
        input integer n;
        begin
            repeat (n) @(posedge clk);
            #1;
        end
    endtask

    task pulse_err_clr;
        begin
            @(negedge clk);
            err_clr = 1'b1;
            @(negedge clk);
            err_clr = 1'b0;
        end
    endtask

    task stress;
        input integer p;
        input integer c;
        input integer n;
        begin
            prod_pct = p;
            cons_pct = c;
            run(n);
        end
    endtask

    // ----------------------------------------------------------- test plan
    initial begin
        $dumpfile("dump.vcd");
        $dumpvars(1, tb);
        $dumpvars(1, tb.dut);

        seed     = 1;
        rst_n    = 1'b0;
        s_valid  = 1'b0;
        s_data   = {DATA_W{1'b0}};
        m_ready  = 1'b0;
        err_clr  = 1'b0;
        prod_pct = 0;
        cons_pct = 0;

        // T1: reset and idle
        run(4);
        @(negedge clk) rst_n = 1'b1;
        run(5);

        // T2: fill with no consumer -> full, backpressure, overflow warning
        stress(100, 0, DEPTH + 6);
        if (wr_n - rd_n != DEPTH) fail("T2: buffer did not reach full");

        // T3: sticky overflow cleared by err_clr
        pulse_err_clr;
        run(3);

        // T4: drain with no producer -> empty, underflow warning
        stress(0, 100, DEPTH + 6);
        if (wr_n - rd_n != 0) fail("T4: buffer did not drain");

        // T5: sticky underflow cleared (no new event while consumer is stalled)
        stress(0, 0, 2);
        pulse_err_clr;
        run(3);

        // T6: 100% throughput, simultaneous read and write at mid occupancy
        stress(100, 0, DEPTH / 2 + 1);
        stress(100, 100, 2);
        s_xfers = 0;
        m_xfers = 0;
        run(300);
        // OUT_REG=1 needs 2 <= occupancy <= DEPTH-1 to sustain 100%, so it
        // cannot at DEPTH=2 (documented limitation, see decision log D13)
        if (OUT_REG == 0 || DEPTH >= 3) begin
            if (s_xfers != 300) fail("T6: write throughput below 100%");
            if (m_xfers != 300) fail("T6: read throughput below 100%");
        end else begin
            $display("NOTE: T6 throughput check skipped (OUT_REG=1, DEPTH=2): %0d/300 writes, %0d/300 reads", s_xfers, m_xfers);
        end

        // stop recording waves here: keeps dump.vcd small for EPWave
        // (T7-T9 still run and are fully checked)
        $dumpoff;

        // T7: random stall mixes (producer %, consumer %)
        stress(30,  70, 2000);
        stress(70,  30, 2000);
        stress(50,  50, 2000);
        stress(90,  10, 2000);
        stress(10,  90, 2000);
        stress(100, 50, 2000);
        stress(50, 100, 2000);
        stress(95,  95, 2000);

        // T8: reset in the middle of traffic
        stress(70, 30, 40);
        @(negedge clk) rst_n = 1'b0;
        run(3);
        @(negedge clk) rst_n = 1'b1;
        run(3);
        stress(60, 60, 500);

        // T9: final drain
        stress(0, 100, DEPTH + 10);
        if (wr_n - rd_n != 0) fail("T9: buffer did not drain");

        if (errors == 0)
            $display("TEST PASSED (wr=%0d rd=%0d)", wr_n, rd_n);
        else
            $display("TEST FAILED: %0d error(s)", errors);
        $finish;
    end

endmodule
