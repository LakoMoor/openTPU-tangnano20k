// The Tang Nano 20K build as a virtual board: the Verilator model of tb_board (the lite core,
// the SDRAM / SD memory system, the UART host link, with the SDRAM and SD card models) whose UART
// is a TCP socket. The host software connects to it as to the real board's serial port
// (opentpu/host/tang.py: TangTransport("tcp:127.0.0.1:PORT")).
//   tb_board <card.img> [port=5555] [+div=24]
// The card image is the SD card's contents (block 0 at byte 0).
#include "Vtb_board.h"
#include "verilated.h"
#include <winsock2.h>
#include <ws2tcpip.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <string>
#include <vector>

double sc_time_stamp() { return 0; }

static std::vector<uint8_t> card;
extern "C" int sd_byte(long long addr) {
    return (addr >= 0 && (size_t)addr < card.size()) ? card[addr] : 0;
}

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: tb_board <card.img> [port]\n"); return 2; }
    FILE* f = fopen(argv[1], "rb");
    if (!f) { perror("card"); return 2; }
    fseek(f, 0, SEEK_END);
    long long n = _ftelli64(f);
    fseek(f, 0, SEEK_SET);
    card.resize(n);
    if (fread(card.data(), 1, n, f) != (size_t)n) { fprintf(stderr, "short read\n"); return 2; }
    fclose(f);
    int port = argc > 2 ? atoi(argv[2]) : 5555;
    int div = 24;
    for (int i = 2; i < argc; i++) if (!strncmp(argv[i], "+div=", 5)) div = atoi(argv[i] + 5);

    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);
    SOCKET ls = socket(AF_INET, SOCK_STREAM, 0);
    sockaddr_in sa{};
    sa.sin_family = AF_INET;
    sa.sin_port = htons(port);
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    int one = 1;
    setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, (const char*)&one, sizeof one);
    if (bind(ls, (sockaddr*)&sa, sizeof sa) || listen(ls, 1)) { fprintf(stderr, "bind failed\n"); return 2; }
    printf("tb_board: card %lld bytes, listening on 127.0.0.1:%d\n", n, port);
    fflush(stdout);

    Vtb_board* t = new Vtb_board;
    auto half = [&](int c) { t->clk = c; t->clk_p = !c; t->eval(); };
    t->uart_rx = 1;
    t->rst = 1;
    for (int i = 0; i < 20; i++) { half(0); half(1); }
    t->rst = 0;

    SOCKET cs = INVALID_SOCKET;
    std::deque<uint8_t> rxq;                   // host -> board bytes
    int rx_bit = -1, rx_cnt = 0;               // the byte being sent on uart_rx
    uint16_t rx_sh = 0;
    int tx_state = -1, tx_cnt = 0;             // the board's uart_tx being received
    uint8_t tx_byte = 0;
    uint64_t cyc = 0;
    for (;; cyc++) {
        if ((cyc & 1023) == 0) {
            if (cs == INVALID_SOCKET) {
                fd_set fs; FD_ZERO(&fs); FD_SET(ls, &fs);
                timeval tv{0, 0};
                if (select(0, &fs, 0, 0, &tv) > 0) {
                    cs = accept(ls, 0, 0);
                    int nd = 1;
                    setsockopt(cs, IPPROTO_TCP, TCP_NODELAY, (const char*)&nd, sizeof nd);
                    u_long nb = 1; ioctlsocket(cs, FIONBIO, &nb);
                    printf("tb_board: host connected\n"); fflush(stdout);
                }
            } else {
                uint8_t buf[4096];
                int k = recv(cs, (char*)buf, sizeof buf, 0);
                if (k > 0) rxq.insert(rxq.end(), buf, buf + k);
                else if (k == 0 || (k < 0 && WSAGetLastError() != WSAEWOULDBLOCK)) {
                    closesocket(cs); cs = INVALID_SOCKET;
                    printf("tb_board: host disconnected\n"); fflush(stdout);
                }
            }
        }
        // uart_rx: 1 start, 8 data, 1 stop, div clocks each
        if (rx_bit < 0 && !rxq.empty()) {
            rx_sh = (uint16_t)(0x200 | (rxq.front() << 1)); rxq.pop_front(); rx_bit = 0; rx_cnt = 0;
        }
        if (rx_bit >= 0) {
            t->uart_rx = (rx_sh >> rx_bit) & 1;
            if (++rx_cnt == div) { rx_cnt = 0; if (++rx_bit == 10) rx_bit = -1; }
        } else t->uart_rx = 1;
        half(0); half(1);
        // uart_tx: sample mid-bit
        if (tx_state < 0) {
            if (!t->uart_tx) { tx_state = 0; tx_cnt = div / 2; }
        } else if (--tx_cnt == 0) {
            tx_cnt = div;
            if (tx_state == 0) { if (t->uart_tx) tx_state = -1; else tx_state = 1; }
            else if (tx_state <= 8) { tx_byte = (uint8_t)((tx_byte >> 1) | (t->uart_tx << 7)); tx_state++; }
            else {
                tx_state = -1;
                if (cs != INVALID_SOCKET) send(cs, (const char*)&tx_byte, 1, 0);
            }
        }
    }
}
