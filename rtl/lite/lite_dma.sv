// LD, ST and WAITW (docs/isa.md). LD issues its n word reads back to back and writes each word
// to TMEM as it returns (the memory path answers in order); ST reads a TMEM word and writes it;
// WAITW reads its word every w5 cycles until the compare holds (then T[f2] = the word) or w6
// cycles have passed (0: never), which stops the run with E_WAITW.
module lite_dma
  import lite_pkg::*;
(
  input  logic        clk,
  input  logic        rst,
  input  logic        start,
  input  cmd_t        cmd,
  output logic        done,
  output logic        err,
  // TMEM
  output logic        t_re,
  output logic [31:0] t_ra,
  input  logic [31:0] t_rd,
  output logic        t_we,
  output logic [31:0] t_wa,
  output logic [31:0] t_wd,
  // DRAM
  output logic        m_req,
  output logic        m_we,
  output logic [31:0] m_addr,
  output logic [31:0] m_wd,
  output logic [3:0]  m_be,
  input  logic        m_rdy,
  input  logic        m_rv,
  input  logic [31:0] m_rd
);
  typedef enum logic [2:0] { S_IDLE, S_LD, S_ST_RD, S_ST_WR, S_W_RD, S_W_GET, S_W_GAP } st_t;
  st_t st;
  logic [31:0] n, iss, got, gap, elapsed;

  wire waitw_ok = (cmd.flags[1:0] == 2'd0) ? ((m_rd & cmd.w4) == cmd.f3) :
                  (cmd.flags[1:0] == 2'd1) ? ((m_rd & cmd.w4) != cmd.f3) :
                                             !(((m_rd & cmd.w4) - cmd.f3) >> 31);

  always_comb begin
    m_req = 1'b0; m_we = 1'b0; m_addr = '0; m_wd = '0; m_be = '0;
    t_re = 1'b0; t_ra = '0; t_we = 1'b0; t_wa = '0; t_wd = '0;
    case (st)
      S_LD: begin
        m_req = (iss != n);
        m_addr = cmd.f1 + {iss[29:0], 2'b00};
        t_we = m_rv;
        t_wa = 32'(cmd.f2[15:0] + got[15:0]);
        t_wd = m_rd;
      end
      S_ST_RD: begin
        t_re = 1'b1;
        t_ra = 32'(cmd.f2[15:0] + iss[15:0]);
      end
      S_ST_WR: begin
        m_req = 1'b1;
        m_we = 1'b1;
        m_addr = cmd.f1 + {iss[29:0], 2'b00};
        m_wd = t_rd;
        m_be = 4'hF;
      end
      S_W_RD: begin
        m_req = 1'b1;
        m_addr = cmd.f1;
      end
      S_W_GET: begin
        t_we = m_rv && waitw_ok;
        t_wa = cmd.f2;
        t_wd = m_rd;
      end
      default: ;
    endcase
  end

  // ST holds the TMEM word (t_rd is only valid the cycle after the read)
  logic [31:0] st_word;
  always_ff @(posedge clk) begin
    done <= 1'b0;
    err <= 1'b0;
    if (st != S_IDLE && st != S_LD) elapsed <= elapsed + 32'd1;
    if (rst) begin
      st <= S_IDLE;
    end else begin
      case (st)
        S_IDLE: if (start) begin
          n <= cmd.w3;
          iss <= '0;
          got <= '0;
          elapsed <= '0;
          case (cmd.op)
            OP_LD:  if (cmd.w3 == 0) done <= 1'b1; else st <= S_LD;
            OP_ST:  if (cmd.w3 == 0) done <= 1'b1; else st <= S_ST_RD;
            default: st <= S_W_RD;
          endcase
        end
        S_LD: begin
          if (m_req && m_rdy) iss <= iss + 32'd1;
          if (m_rv) begin
            got <= got + 32'd1;
            if (got + 32'd1 == n) begin done <= 1'b1; st <= S_IDLE; end
          end
        end
        S_ST_RD: st <= S_ST_WR;
        S_ST_WR: if (m_rdy) begin
          iss <= iss + 32'd1;
          if (iss + 32'd1 == n) begin done <= 1'b1; st <= S_IDLE; end
          else st <= S_ST_RD;
        end
        S_W_RD: if (m_rdy) st <= S_W_GET;
        S_W_GET: if (m_rv) begin
          if (waitw_ok) begin
            done <= 1'b1;
            st <= S_IDLE;
          end else if (cmd.w6 != 0 && elapsed >= cmd.w6) begin
            err <= 1'b1;
            st <= S_IDLE;
          end else begin
            gap <= cmd.w5;
            st <= S_W_GAP;
          end
        end
        default: begin                      // S_W_GAP
          if (gap == 0) st <= S_W_RD;
          else gap <= gap - 32'd1;
        end
      endcase
    end
  end
  assign st_word = t_rd;
endmodule
