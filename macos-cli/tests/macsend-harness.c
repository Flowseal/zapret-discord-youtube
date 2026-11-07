
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <assert.h>
#include <netinet/tcp.h>
#include <netinet/udp.h>
static unsigned char captured[65549];
static size_t captured_len;
static ssize_t capture_write(int fd,const void *p,size_t n) { assert(fd==123); memcpy(captured,p,n); captured_len=n; return n; }
#define write capture_write
#include "macsend.c"
#undef write
int main(void) {
 bpf_fd=123;
 memcpy(source_mac,"\x02\x00\x00\x00\x00\x01",6);
 memcpy(gateway4_mac,"\x02\x00\x00\x00\x00\x02",6);
 unsigned char packet[40]={0}; struct ip *ip=(struct ip*)packet;
 ip->ip_v=4; ip->ip_hl=5; ip->ip_len=htons(40); ip->ip_ttl=64; ip->ip_p=IPPROTO_TCP;
 ip->ip_src.s_addr=htonl(0xc0000201); ip->ip_dst.s_addr=htonl(0xc6336401);
 struct tcphdr *tcp=(struct tcphdr*)(packet+20); tcp->th_off=5; tcp->th_flags=TH_SYN;
 tcp4_fix_checksum(tcp,20,&ip->ip_src,&ip->ip_dst); unsigned short tcp_sum=tcp->th_sum;
 assert(macsend_packet(AF_INET,packet,40)); assert(captured_len==54);
 assert(!memcmp(captured,gateway4_mac,6)); assert(ntohs(((struct ether_header*)captured)->ether_type)==ETHERTYPE_IP);
 assert(ip4_compute_csum(captured+14,20)==0); assert(((struct tcphdr*)(captured+34))->th_sum==tcp_sum);
 tcp->th_sum^=1; assert(macsend_packet(AF_INET,packet,40)); assert(((struct tcphdr*)(captured+34))->th_sum!=tcp_sum);
 ip->ip_p=IPPROTO_UDP; ip->ip_len=htons(28); struct udphdr *udp=(struct udphdr*)(packet+20); memset(udp,0,8); udp->uh_ulen=htons(8); udp4_fix_checksum(udp,8,&ip->ip_src,&ip->ip_dst); unsigned short udp_sum=udp->uh_sum;
 assert(macsend_packet(AF_INET,packet,28)); assert(captured_len==42); assert(ip4_compute_csum(captured+14,20)==0); assert(((struct udphdr*)(captured+34))->uh_sum==udp_sum);
 assert(!macsend_packet(AF_UNIX,packet,28)); assert(!macsend_packet(AF_INET,NULL,28)); assert(!macsend_packet(AF_INET,packet,65536));
 puts("PASS: TCP/UDP Ethernet framing, IPv4 checksum repair, intentional badsum preserved, invalid family/length rejected");
}
