#ifndef ZAPRET_P2P_RELAY_H
#define ZAPRET_P2P_RELAY_H

#include <time.h>
#include <stdint.h>
#include "common.h"
#include "packet.h"

// структура пир узла с уровнем доверия
struct p2p_peer {
    uint32_t ip;
    uint16_t port;
    time_t last_seen;
    int trust_level; // 0 unknown, 1 verified, 2 trusted
    uint8_t pubkey[32]; // для шифрования
};

// конфигурация релея
struct p2p_config {
    int enabled;
    int secure_mode; // 1 = узел не видит контент
    int max_session_time; // минут
    char fake_domain[256]; // для маскировки под https
};

// инициализация модуля
int p2p_relay_init(struct p2p_config *cfg);

// обработка пакета, возвращает 0 если дроп, 1 если форвард
int p2p_relay_handle_packet(struct packet *pkt, struct p2p_peer *peer);

// проверка безопасности узла перед подключением
int p2p_verify_peer(struct p2p_peer *peer);

#endif
