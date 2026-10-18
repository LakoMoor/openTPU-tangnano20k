// The lite core's sequencer: loads a program from DRAM into IMEM (RUN, HALT CHAIN), fetches,
// resolves the register-relative fields and runs one instruction at a time. LI, ADDI, LOOP,
// HALT, BAR (one slice: a no-op), NOP and RLD run here; LD / ST / WAITW, MM, QACT / QST and VOP
// go to their unit, which pulses done when every write of the instruction is issued (the memory
// path keeps requests in order). The loop stack and its checks are opentpu/isasim.py's.
module lite_seq
  import lite_pkg::*;
#(
  parameter int IMEM_N = 512                    // instructions (IMEM_WORDS / 8)
) (
  input  logic        clk,
  input  logic        rst,                      // high: stopped (RUN low)
  input  logic        start,                    // load prog_n instructions at prog_addr and run
  input  logic [31:0] prog_addr,
  input  logic [31:0] prog_n,
  input  logic [31:0] args [8],                 // R8..R15 at the start of every program
  output logic        halted,
  output logic        error,
  output logic [3:0]  ecode,
  output logic [31:0] icount,
  output logic        loading,
  // the units: 0 DMA, 1 MXU, 2 quantizer, 3 VPU
  output cmd_t        cmd,
  output logic [3:0]  u_start,
  input  logic        u_done,
  input  logic        u_err,
  input  logic [3:0]  u_ecode,
  // TMEM read (RLD)
  output logic        t_re,
  output logic [31:0] t_ra,
  input  logic [31:0] t_rd,
  // DRAM reads (the program loader)
  output logic        m_req,
  output logic [31:0] m_addr,
  input  logic        m_rdy,
  input  logic        m_rv,
  input  logic [31:0] m_rd
);
  localparam int PW = $clog2(IMEM_N);

  typedef enum logic [3:0] {
    S_IDLE, S_LOAD, S_FETCH, S_DEC, S_RES, S_EXEC, S_UNIT, S_RLD, S_RLDM, S_ADV, S_HALT
  } st_t;
  st_t st;

  logic [31:0] R [16];
  logic [15:0] pc;
  // loop stack (isasim: [start, end, count], depth 4)
  logic [2:0]  sp;
  logic [15:0] ls_start [4], ls_end [4];
  logic [31:0] ls_cnt [4];

  // IMEM: one RAM per instruction word, read together
  logic [31:0] iw [8];
  logic        i_we;
  logic [2:0]  i_wbank;
  logic [PW-1:0] i_waddr;
  logic [31:0] i_wdata;
  for (genvar b = 0; b < 8; b++) begin : g_imem
    logic [31:0] mem [IMEM_N];
    always_ff @(posedge clk) begin
      if (i_we && i_wbank == 3'(b)) mem[i_waddr] <= i_wdata;
      iw[b] <= mem[pc[PW-1:0]];
    end
  end

  // the loader
  logic [31:0] ld_addr, ld_words, ld_iss, ld_got;
  assign loading = (st == S_LOAD);
  assign m_req  = (st == S_LOAD) && (ld_iss != ld_words);
  assign m_addr = m_req ? ld_addr + {ld_iss[29:0], 2'b00} : 32'd0;
  assign i_we    = (st == S_LOAD) && m_rv;
  assign i_wbank = ld_got[2:0];
  assign i_waddr = ld_got[PW+2:3];
  assign i_wdata = m_rd;

  // the decoded instruction
  logic [7:0] op, flags;
  logic [3:0] ra, rb, rc, rd;
  assign op = iw[0][7:0];
  assign ra = iw[0][11:8];
  assign rb = iw[0][15:12];
  assign rc = iw[0][19:16];
  assign rd = iw[0][23:20];
  assign flags = iw[0][31:24];

  // RLD's multiply (shift and add; RLD is rare)
  logic [31:0] mul_a, mul_b, mul_p;
  logic [5:0]  mul_n;

  assign t_re = (st == S_EXEC) && (cmd.op == OP_RLD);
  assign t_ra = t_re ? cmd.f1 : 32'd0;

  logic [15:0] lend;
  logic        lnest;
  always_comb begin
    lend = pc + cmd.w1[15:0];
    lnest = 1'b0;
    for (int k = 0; k < 4; k++) if (3'(k) < sp && ls_end[k] == lend) lnest = 1'b1;
  end

  task automatic fail(input logic [3:0] c);
    error <= 1'b1;
    ecode <= c;
    halted <= 1'b1;
    st <= S_HALT;
  endtask

  task automatic begin_load(input logic [31:0] a, input logic [31:0] n);
    if (a[5:0] != 0 || n == 0 || n > IMEM_N) begin
      fail(E_CHAIN);
    end else begin
      ld_addr <= a;
      ld_words <= {n[28:0], 3'b000};
      ld_iss <= '0;
      ld_got <= '0;
      st <= S_LOAD;
    end
  endtask

  always_ff @(posedge clk) begin
    u_start <= '0;
    if (rst) begin
      st <= S_IDLE;
      halted <= 1'b0;
      error <= 1'b0;
      ecode <= E_NONE;
      sp <= '0;
    end else begin
      case (st)
        S_IDLE: if (start) begin
          icount <= '0;
          begin_load(prog_addr, prog_n);
        end
        S_LOAD: begin
          if (m_req && m_rdy) ld_iss <= ld_iss + 32'd1;
          if (m_rv) begin
            ld_got <= ld_got + 32'd1;
            if (ld_got + 32'd1 == ld_words) begin
              for (int k = 0; k < 8; k++) R[k] <= '0;
              for (int k = 0; k < 8; k++) R[8 + k] <= args[k];
              pc <= '0;
              sp <= '0;
              st <= S_FETCH;
            end
          end
        end
        S_FETCH: st <= S_DEC;               // IMEM read of pc
        S_DEC: begin
          if (pc >= 16'(ld_words >> 3)) begin
            fail(E_PC);
          end else begin
            cmd.op <= op;
            cmd.flags <= flags;
            cmd.rd <= rd;
            cmd.w1 <= iw[1]; cmd.w2 <= iw[2]; cmd.w3 <= iw[3]; cmd.w4 <= iw[4];
            cmd.w5 <= iw[5]; cmd.w6 <= iw[6]; cmd.w7 <= iw[7];
            cmd.f1 <= R[ra] + ((op == OP_LOOP) ? iw[2] : iw[1]);
            cmd.f2 <= R[rb] + iw[2];
            cmd.f3 <= R[rc] + iw[3];
            cmd.f7 <= R[rd] + iw[7];
            st <= S_EXEC;
          end
        end
        S_EXEC: begin
          icount <= icount + 32'd1;
          st <= S_ADV;
          case (cmd.op)
            OP_NOP, OP_BAR: ;
            OP_LI:   if (cmd.rd != 0) R[cmd.rd] <= cmd.w1;
            OP_ADDI: if (cmd.rd != 0) R[cmd.rd] <= cmd.f1;
            OP_HALT: begin
              if (cmd.flags[0]) begin
                logic [31:0] ca, cn;
                ca = R[iw[0][11:8]];
                cn = R[iw[0][15:12]];
                begin_load(ca, cn);
              end else begin
                halted <= 1'b1;
                st <= S_HALT;
              end
            end
            OP_LOOP: begin
              if (cmd.w1 == 0 || lnest) fail(E_LOOP);
              else if (cmd.f1 == 0) begin
                pc <= pc + 16'd1 + cmd.w1[15:0];
                st <= S_FETCH;
              end else if (sp == 3'd4) fail(E_LOOP);
              else begin
                ls_start[sp[1:0]] <= pc + 16'd1;
                ls_end[sp[1:0]] <= lend;
                ls_cnt[sp[1:0]] <= cmd.f1;
                sp <= sp + 3'd1;
                pc <= pc + 16'd1;
                st <= S_FETCH;
              end
            end
            OP_RLD: st <= S_RLD;            // t_re this cycle
            OP_LD, OP_ST, OP_WAITW: begin u_start[0] <= 1'b1; st <= S_UNIT; end
            OP_MM:                  begin u_start[1] <= 1'b1; st <= S_UNIT; end
            OP_QACT, OP_QST:        begin u_start[2] <= 1'b1; st <= S_UNIT; end
            OP_VOP:                 begin u_start[3] <= 1'b1; st <= S_UNIT; end
            default: fail(E_OPCODE);        // DSTEP, STREAM, GATHER: not in this build
          endcase
        end
        S_UNIT: if (u_err) fail(u_ecode);
                else if (u_done) st <= S_ADV;
        S_RLD: begin                        // t_rd holds T[f1]
          logic [31:0] v;
          v = cmd.flags[0] ? t_rd : f2i(t_rd);
          if (cmd.flags[1]) begin
            mul_a <= v;
            mul_b <= cmd.f2;
            mul_p <= '0;
            mul_n <= '0;
            st <= S_RLDM;
          end else begin
            if (cmd.rd != 0) R[cmd.rd] <= v;
            st <= S_ADV;
          end
        end
        S_RLDM: begin
          if (mul_n == 6'd32) begin
            if (cmd.rd != 0) R[cmd.rd] <= mul_p;
            st <= S_ADV;
          end else begin
            if (mul_b[0]) mul_p <= mul_p + mul_a;
            mul_a <= mul_a << 1;
            mul_b <= mul_b >> 1;
            mul_n <= mul_n + 6'd1;
          end
        end
        S_ADV: begin
          st <= S_FETCH;
          if (sp != 0 && ls_end[sp[1:0] - 2'd1] == pc) begin
            if (ls_cnt[sp[1:0] - 2'd1] > 32'd1) begin
              ls_cnt[sp[1:0] - 2'd1] <= ls_cnt[sp[1:0] - 2'd1] - 32'd1;
              pc <= ls_start[sp[1:0] - 2'd1];
            end else begin
              sp <= sp - 3'd1;
              pc <= pc + 16'd1;
            end
          end else begin
            pc <= pc + 16'd1;
          end
        end
        default: ;                          // S_HALT: until RUN falls (rst)
      endcase
    end
  end
endmodule
