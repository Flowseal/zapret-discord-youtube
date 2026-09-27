// macOS packet backend for nfqws (macws). See mac_backend.c
#pragma once
#ifdef __APPLE__

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <net/if.h>
#include <netinet/in.h>

// uplink (default route) interface: MACWS_UPLINK or `route -n get default`
bool mac_uplink_detect(char *ifname, size_t len);
bool mac_iface_addr4(const char *ifname, struct in_addr *addr);
bool mac_iface_has_addr4(const char *ifname, struct in_addr addr);
bool mac_iface_addr6(const char *ifname, struct in6_addr *addr);
bool mac_uplink_detect6(char *ifname, size_t len);
// предупреждает, если завёрнутый трафик принадлежит другому интерфейсу (VPN)
bool mac_check_source(const void *pkt, size_t len, const char *uplink);

// utun interface: created by us, pf sends diverted packets into it
int  mac_utun_open(char *ifname, size_t len);
bool mac_utun_config(const char *ifname);
const char *mac_utun_peer(void);
const char *mac_utun_peer6(void);
bool mac_ipv6_available(void);

// пересчёт контрольных сумм пакета из utun (ядро может отдать их неготовыми,
// если рассчитывало на offload). true = сумма уже была верной
bool mac_fix_csum4(void *pkt, size_t len);
bool mac_fix_csum6(void *pkt, size_t len);
bool mac_fix_csum(void *pkt, size_t len);      // по версии пакета
// служебный трафик интерфейса (NDP/MLD, multicast, link-local) обходить не нужно
bool mac_packet_routable(const void *pkt, size_t len);

// packet injection: raw socket (IP_HDRINCL) bound to the uplink
bool mac_inject_init(const char *uplink);
bool mac_inject4(void *pkt, size_t len);
bool mac_inject6(void *pkt, size_t len);       // только через bpf
bool mac_inject(void *pkt, size_t len);        // по версии пакета
bool mac_inject_overload(void);
const char *mac_inject_method(void);
bool inject_mode_is_bpf(void);   // bpf не проходит через pf -> петли быть не может
void mac_inject_cleanup(void);
void mac_inject_stats(uint64_t *ok, uint64_t *fail);
// аудит провода: реально ли отправленные кадры прошли через интерфейс
void mac_wire_audit_drain(void);
// следующий входящий пакет (SYN/RST) для движка: по нему считается autottl
bool mac_inbound_next(uint8_t *out, size_t outsize, size_t *len);
void mac_wire_audit_report(void);

// pf anchor: rules come from MACWS_PF_RULES with %UTUN% substituted
bool mac_pf_apply(const char *utun_if);
bool mac_pf_load_rules(const char *rules);
void mac_pf_flush(void);
bool mac_pf_enabled(void);

// end-to-end check of injection + utun + pf, run by `zapret.sh selftest`
int  mac_selftest(void);

#endif
