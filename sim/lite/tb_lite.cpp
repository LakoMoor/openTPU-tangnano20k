// Verilator testbench of the openTPU lite core (rtl/lite): a flat DRAM with random ready stalls
// and random in-order read latency. tools/tang/cosim.py drives it:
//   tb_lite <dram.bin> <dram_bytes> <prog_addr> <prog_n> <out_dir> [arg0..arg7] [+seed=N]
// writes <out_dir>/tmem.bin, <out_dir>/dram.bin and prints "HALT cycles icount error ecode".
#include "Vlite_core.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <random>
#include <string>
#include <vector>

double sc_time_stamp() { return 0; }

int main(int argc, char** argv) {
    if (argc < 6) { fprintf(stderr, "usage\n"); return 2; }
    std::string dram_path = argv[1];
    size_t dram_bytes = strtoull(argv[2], 0, 0);
    uint32_t prog_addr = strtoul(argv[3], 0, 0), prog_n = strtoul(argv[4], 0, 0);
    std::string out = argv[5];
    uint32_t args[8] = {0};
    unsigned seed = 1;
    int na = 0;
    for (int i = 6; i < argc; i++) {
        if (!strncmp(argv[i], "+seed=", 6)) seed = atoi(argv[i] + 6);
        else if (na < 8) args[na++] = strtoul(argv[i], 0, 0);
    }
    std::vector<uint8_t> dram(dram_bytes, 0);
    FILE* f = fopen(dram_path.c_str(), "rb");
    if (!f) { perror("dram"); return 2; }
    size_t got = fread(dram.data(), 1, dram_bytes, f);
    (void)got;
    fclose(f);

    Vlite_core* t = new Vlite_core;
    std::mt19937 rng(seed);
    struct Rd { uint64_t due; uint32_t data; };
    std::deque<Rd> q;
    auto tick = [&]() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); };
    t->rst = 1; t->start = 0; t->dbg_re = 0; t->m_rdy = 0; t->m_rv = 0;
    for (int k = 0; k < 8; k++) t->args[k] = args[k];
    t->prog_addr = prog_addr; t->prog_n = prog_n;
    for (int i = 0; i < 5; i++) tick();
    t->rst = 0; tick();
    t->start = 1;
    uint64_t cyc = 0, max_cyc = 4000000000ull;
    bool stalls = (seed != 0);
    int err = 0;
    for (;; cyc++) {
        // inputs for this cycle (decided on the falling edge)
        t->clk = 0;
        t->m_rdy = stalls ? ((rng() % 4) != 0) : 1;
        t->m_rv = 0;
        if (!q.empty() && q.front().due <= cyc) { t->m_rv = 1; t->m_rd = q.front().data; q.pop_front(); }
        t->eval();
        bool req = t->m_req && t->m_rdy;
        uint32_t a = t->m_addr, wd = t->m_wd, be = t->m_be, we = t->m_we;
        t->clk = 1; t->eval();
        t->start = 0;
        if (req) {
            if (a % 4 || a + 4 > dram_bytes) { fprintf(stderr, "bad DRAM address %08x\n", a); err = 1; break; }
            if (we) {
                for (int b = 0; b < 4; b++) if (be >> b & 1) dram[a + b] = wd >> (8 * b);
            } else {
                uint32_t v; memcpy(&v, &dram[a], 4);
                uint64_t lat = stalls ? 1 + rng() % 12 : 1;
                uint64_t due = cyc + lat;
                if (!q.empty() && q.back().due > due) due = q.back().due;
                q.push_back({due, v});
            }
        }
        if (t->halted && q.empty()) break;
        if (cyc > max_cyc) { fprintf(stderr, "timeout\n"); err = 1; break; }
    }
    // TMEM dump through the debug port
    std::vector<uint32_t> tm(8192);
    for (uint32_t i = 0; i < 8192; i++) {      // the read registers at the edge
        t->dbg_re = 1; t->dbg_ra = i; tick();
        tm[i] = t->dbg_rd;
    }
    f = fopen((out + "/tmem.bin").c_str(), "wb"); fwrite(tm.data(), 4, tm.size(), f); fclose(f);
    f = fopen((out + "/dram.bin").c_str(), "wb"); fwrite(dram.data(), 1, dram.size(), f); fclose(f);
    printf("HALT %llu %u %d %d\n", (unsigned long long)cyc, t->icount, t->error | err, t->ecode);
    delete t;
    return 0;
}
