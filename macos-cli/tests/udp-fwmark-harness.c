// Exercise the real UDP cutoff path; intercept all sends before they reach BPF.
#include <assert.h>
#include <stdio.h>
#define rawsend harness_rawsend
#include "../engine/desync.c"
#undef rawsend
struct params_s params;
static unsigned int send_count;
static uint32_t seen_mark;
bool harness_rawsend(const struct sockaddr *dst, uint32_t mark, const char *iface, const void *data, size_t length)
{
    (void)dst; (void)iface; (void)data; (void)length;
    ++send_count; seen_mark = mark;
    return false;
}
int main(int argc, char **argv)
{
    (void)argc; (void)argv;
    LIST_INIT(&params.desync_profiles);
    struct desync_profile_list *profile = dp_list_add(&params.desync_profiles);
    assert(profile);
    params.ctrack_disable = true;
    params.desync_fwmark = 0x40000000;
    profile->dp.desync_start = 2;
    profile->dp.desync_start_mode = 'n';
    profile->dp.dup_repeats = 1;
    unsigned char packet[29] = {0};
    struct ip *ip = (struct ip *)packet;
    ip->ip_v = 4; ip->ip_hl = 5; ip->ip_len = htons(sizeof(packet));
    ip->ip_ttl = 64; ip->ip_p = IPPROTO_UDP;
    ip->ip_src.s_addr = htonl(0xc0000201); ip->ip_dst.s_addr = htonl(0xc6336401);
    struct udphdr *udp = (struct udphdr *)(packet + 20);
    udp->uh_sport = htons(12345); udp->uh_dport = htons(443); udp->uh_ulen = htons(9);
    struct dissect dis;
    proto_dissect_l3l4(packet, sizeof(packet), &dis);
    assert(dis.udp);
    uint32_t input_mark = 0x1234, expected = input_mark | params.desync_fwmark;
    dpi_desync_udp_packet_play(false, 0, input_mark, NULL, "test", &dis);
    dp_list_destroy(&params.desync_profiles);
    assert(send_count == 1);
    if (seen_mark != expected) {
        fprintf(stderr, "FAIL: UDP cutoff propagated mark 0x%08x; expected 0x%08x\n", seen_mark, expected);
        return 1;
    }
    puts("PASS: real UDP cutoff preserves initialized fwmark; all sends intercepted");
}
