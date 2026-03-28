#include "relay.h"
#include <time.h>
#include <string.h>

// Глобальная конфигурация
static struct p2p_config config;

int p2p_relay_init(struct p2p_config *cfg) {
    if (!cfg) {
        return -1;
    }
    
    // Копируем конфигурацию
    memcpy(&config, cfg, sizeof(struct p2p_config));
    
    // Если режим безопасности включен - узел не расшифровывает трафик
    if (config.secure_mode) {
        // В реальном zapret здесь будет log_info
        // log_info("P2P relay started in secure mode - node sees only encrypted stream\n");
        return 0;
    }
    
    // log_info("P2P relay started in standard mode\n");
    return 0;
}

int p2p_relay_handle_packet(struct packet *pkt, struct p2p_peer *peer) {
    if (!pkt || !peer) {
        return 0; // дроп если null указатели
    }
    
    // Проверка доверия к узлу
    if (!p2p_verify_peer(peer)) {
        // log_warn("Untrusted peer, dropping packet\n");
        return 0; // дроп
    }
    
    // Если режим защиты узла включен - просто форвардим зашифрованные байты
    // Узел не видит контент, только поток до фейкового домена
    if (config.secure_mode) {
        // Здесь должна быть интеграция с DPI маскировкой
        // В реальном коде: return dpi_desync_fake(pkt, config.fake_domain);
        // Пока просто форвардим
        return 1; // форвард
    }
    
    // Стандартная логика - форвард
    return 1;
}

int p2p_verify_peer(struct p2p_peer *peer) {
    if (!peer) {
        return 0;
    }
    
    // Проверка времени сессии
    if (config.max_session_time > 0) {
        time_t now = time(NULL);
        if (difftime(now, peer->last_seen) > (config.max_session_time * 60)) {
            return 0; // сессия истекла
        }
    }
    
    // Проверка уровня доверия (0 = неизвестный, но допустимый)
    // В реальной реализации здесь была бы проверка криптографических ключей
    return 1;
}
