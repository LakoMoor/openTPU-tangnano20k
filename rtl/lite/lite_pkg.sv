// openTPU lite: a compact, sequential implementation of the openTPU ISA (docs/isa.md) for small
// FPGAs (the Tang Nano 20K's GW2AR-18: 20K LUT4, 46 block RAMs; docs/tangnano20k.md).
//
// The ISA's machine model is "every instruction completes before the next one starts", and the
// lite core does exactly that: one instruction at a time, one element at a time, through one
// shared fp32 multiply-add pipeline. The results are the ISA simulator's bit for bit
// (opentpu/isasim.py, tools/tang/cosim.py); only the speed differs from the card's design.
//
// Not implemented (the host reads it from CAPS): PAIR / DUP, DSTEP, STREAM, GATHER (S = 1), wait
// counts (SEQ_WC). Such instructions stop the run with ERROR.
package lite_pkg;
  localparam logic [7:0] OP_NOP = 8'h00, OP_HALT = 8'h01, OP_LI = 8'h02, OP_ADDI = 8'h03,
                         OP_LOOP = 8'h04, OP_BAR = 8'h05, OP_RLD = 8'h06, OP_WAITW = 8'h07,
                         OP_LD = 8'h10, OP_ST = 8'h11, OP_DSTEP = 8'h12, OP_STREAM = 8'h13,
                         OP_MM = 8'h20, OP_QACT = 8'h21, OP_QST = 8'h22, OP_VOP = 8'h30,
                         OP_GATHER = 8'h40;

  localparam logic [7:0] V_ADD = 0, V_SUB = 1, V_RSUB = 2, V_MUL = 3, V_MAX = 4, V_MIN = 5,
                         V_OUTER = 6, V_COPY = 8, V_EXP2 = 9, V_RECIP = 10, V_RSQRT = 11,
                         V_ABS = 12, V_FILL = 13, V_EXP2SUB = 14, V_LOG2 = 15, V_RSUM = 16,
                         V_RMAX = 17, V_RSSQ = 18, V_RDOT = 19, V_ARGMAX = 20;

  localparam logic [1:0] B_FULL = 0, B_ROW = 1, B_COL = 2, B_SCALAR = 3;

  // error codes (STATUS ERR field, the host prints them)
  localparam logic [3:0] E_NONE = 0, E_OPCODE = 1, E_VFUNC = 2, E_LOOP = 3, E_WAITW = 4,
                         E_CHAIN = 5, E_MM = 6, E_QUANT = 7, E_MEM = 8;

  // An instruction with its register-relative fields resolved (docs/isa.md "Encoding"):
  // f1 = R[ra] + w1 (LOOP: R[ra] + w2), f2 = R[rb] + w2, f3 = R[rc] + w3, f7 = R[rd] + w7.
  typedef struct packed {
    logic [7:0]  op;
    logic [7:0]  flags;
    logic [3:0]  rd;
    logic [31:0] f1, f2, f3;
    logic [31:0] w1, w2, w3, w4, w5, w6, w7;
    logic [31:0] f7;
  } cmd_t;
endpackage
