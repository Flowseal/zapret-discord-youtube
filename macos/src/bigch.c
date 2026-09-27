// bigch — проба «как браузер»: настоящее TLS-рукопожатие системным стеком
// Apple (Network.framework — тот же, что у Safari).
//
// curl шлёт ClientHello ~325 байт, он влезает в один TCP-сегмент. Браузеры шлют
// ~1500 байт и больше (основной объём — постквантовый key_share X25519MLKEM768),
// такой ClientHello рвётся на два сегмента, и DPI ведёт себя с ним иначе.
// В macOS 26 системный стек сам кладёт этот key_share — получается 1538 байт,
// как у браузера. В более старых macOS ClientHello меньше, и нужный размер
// добирается длинным списком ALPN (поле валидное, сервер его просто игнорирует).
//
//   bigch <хост> [порт] [размер] [таймаут] [ключи]
//   bigch --selfcheck [размер] [ключи]     — измерить реальный размер ClientHello
//
//   --small            без TLS 1.3 и постквантового ключа: маленький ClientHello
//                      в одном сегменте (как у curl); с размером — добитый ALPN
//   --sni <имя|none>   подставить другое имя в SNI или не отправлять SNI вовсе
//   --connect <адрес>  соединяться с этим адресом, а SNI взять из <хост>
//
//   код возврата: 0 — рукопожатие прошло (или сервер ответил ошибкой TLS: значит
//   DPI соединение не резал), 1 — не прошло, 2 — ошибка запуска
//
// Сборка: clang -O2 -fblocks bigch.c -framework Network -framework Security

#include <Network/Network.h>
#include <Security/Security.h>
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <unistd.h>
#include <pthread.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <netinet/in.h>

#define BIG_DEFAULT	1538	// размер браузерного ClientHello с X25519MLKEM768
#define PAD_ENTRY	23		// сколько байт добавляет одна запись ALPN "x-pad-..."
#define PAD_MAX		200

struct probe {
	const char *endpoint;	// куда соединяемся (имя или адрес)
	const char *port;
	const char *sni;		// NULL — не отправлять SNI
	bool small;
	int pad;				// сколько записей ALPN добавить
	double timeout;
};

struct result {
	bool done;
	int rc;
	char msg[256];
};

static bool is_ip(const char *s)
{
	struct in_addr a4;
	struct in6_addr a6;
	return inet_pton(AF_INET, s, &a4) == 1 || inet_pton(AF_INET6, s, &a6) == 1;
}

// без SNI можно только по адресу: для имени Network.framework сам подставит SNI
static bool resolve(const char *host, char *out, size_t outlen)
{
	struct addrinfo hints = { .ai_socktype = SOCK_STREAM }, *res, *p;
	bool ok = false;

	if (getaddrinfo(host, NULL, &hints, &res)) return false;
	// предпочитаем IPv4 — так же, как проверки в zapret.sh
	for (int pass = 0; pass < 2 && !ok; pass++)
		for (p = res; p && !ok; p = p->ai_next)
		{
			if (pass == 0 && p->ai_family != AF_INET) continue;
			const void *a = p->ai_family == AF_INET ?
				(const void*)&((struct sockaddr_in*)p->ai_addr)->sin_addr :
				(const void*)&((struct sockaddr_in6*)p->ai_addr)->sin6_addr;
			ok = inet_ntop(p->ai_family, a, out, (socklen_t)outlen) != NULL;
		}
	freeaddrinfo(res);
	return ok;
}

// Ошибки TLS, за которыми стоит обрыв транспорта, а не ответ сервера:
// errSSLClosedGraceful, errSSLClosedAbort, errSSLClosedNoNotify,
// errSSLTransportReset, errSSLNetworkTimeout
static bool tls_error_is_transport(int code)
{
	switch (code)
	{
	case -9805: case -9806: case -9816: case -9852: case -9853:
		return true;
	}
	return false;
}

static void finish(struct result *r, dispatch_semaphore_t sem, int rc, const char *fmt, ...)
{
	va_list ap;
	if (r->done) return;
	r->done = true;
	r->rc = rc;
	va_start(ap, fmt);
	vsnprintf(r->msg, sizeof(r->msg), fmt, ap);
	va_end(ap);
	dispatch_semaphore_signal(sem);
}

static int run_probe(const struct probe *pr, char *msg, size_t msglen)
{
	struct result *r = calloc(1, sizeof(*r));
	dispatch_semaphore_t sem = dispatch_semaphore_create(0);
	dispatch_queue_t q = dispatch_queue_create("bigch", DISPATCH_QUEUE_SERIAL);
	nw_endpoint_t ep = nw_endpoint_create_host(pr->endpoint, pr->port);
	nw_parameters_t params;
	nw_connection_t c;
	int rc;

	params = nw_parameters_create_secure_tcp(^(nw_protocol_options_t tls) {
		sec_protocol_options_t so = nw_tls_copy_sec_protocol_options(tls);
		if (pr->sni) sec_protocol_options_set_tls_server_name(so, pr->sni);
		// без TLS 1.3 нет и key_share — ClientHello маленький, как у curl
		if (pr->small) sec_protocol_options_set_max_tls_protocol_version(so, tls_protocol_version_TLSv12);
		sec_protocol_options_add_tls_application_protocol(so, "h2");
		sec_protocol_options_add_tls_application_protocol(so, "http/1.1");
		for (int i = 0; i < pr->pad; i++)
		{
			char p[32];
			snprintf(p, sizeof(p), "x-pad-%016d", i);
			sec_protocol_options_add_tls_application_protocol(so, p);
		}
		// сертификат не проверяем: важно только, дошло ли рукопожатие до сервера
		sec_protocol_options_set_verify_block(so,
			^(sec_protocol_metadata_t m, sec_trust_t t, sec_protocol_verify_complete_t done) { (void)m; (void)t; done(true); }, q);
		sec_release(so);
	}, NW_PARAMETERS_DEFAULT_CONFIGURATION);
	nw_parameters_set_prefer_no_proxy(params, true);

	c = nw_connection_create(ep, params);
	nw_connection_set_queue(c, q);
	nw_connection_set_state_changed_handler(c, ^(nw_connection_state_t st, nw_error_t err) {
		int dom = err ? (int)nw_error_get_error_domain(err) : 0;
		int code = err ? nw_error_get_error_code(err) : 0;
		if (st == nw_connection_state_ready)
			finish(r, sem, 0, "рукопожатие прошло");
		else if ((st == nw_connection_state_failed || st == nw_connection_state_waiting) && err)
		{
			if (dom == nw_error_domain_tls && !tls_error_is_transport(code))
				// сервер получил ClientHello и ответил — DPI соединение не резал
				finish(r, sem, 0, "сервер ответил ошибкой TLS (%d) — соединение не зарезано", code);
			else if (dom == nw_error_domain_dns)
				finish(r, sem, 1, "имя не разрешается (dns %d)", code);
			else if (dom == nw_error_domain_posix)
				finish(r, sem, 1, "обрыв: %s", strerror(code));
			else
				finish(r, sem, 1, "обрыв (ошибка %d/%d)", dom, code);
		}
		else if (st == nw_connection_state_failed)
			finish(r, sem, 1, "обрыв");
	});
	nw_connection_start(c);

	if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(pr->timeout * NSEC_PER_SEC))))
	{
		dispatch_sync(q, ^{ finish(r, sem, 1, "таймаут рукопожатия"); });
	}
	dispatch_sync(q, ^{ nw_connection_cancel(c); });
	rc = r->rc;
	snprintf(msg, msglen, "%s", r->msg);
	nw_release(c);
	nw_release(params);
	nw_release(ep);
	return rc;
}

// ---------------------------------------------------------- самопроверка ----
// Слушаем на 127.0.0.1, соединяемся туда же и читаем первый TLS-record целиком

struct capture {
	int lsock;
	uint8_t data[8192];
	size_t len;
};

static void *capture_thread(void *arg)
{
	struct capture *cp = arg;
	struct timeval tv = { 3, 0 };
	int s = accept(cp->lsock, NULL, NULL);
	if (s < 0) return NULL;
	setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
	while (cp->len < sizeof(cp->data))
	{
		ssize_t n = recv(s, cp->data + cp->len, sizeof(cp->data) - cp->len, 0);
		if (n <= 0) break;
		cp->len += (size_t)n;
		if (cp->len >= 5 && cp->len >= 5u + ((cp->data[3] << 8) | cp->data[4])) break;
	}
	close(s);
	return NULL;
}

// размер ClientHello при заданных параметрах; -1 — не удалось перехватить
static int measure(const struct probe *base, bool *pq)
{
	struct capture *cp = calloc(1, sizeof(*cp));
	struct sockaddr_in sa = { .sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
	socklen_t salen = sizeof(sa);
	struct probe pr = *base;
	char port[16], msg[256];
	pthread_t th;
	int size = -1;

	cp->lsock = socket(AF_INET, SOCK_STREAM, 0);
	if (cp->lsock < 0 || bind(cp->lsock, (struct sockaddr*)&sa, sizeof(sa)) || listen(cp->lsock, 1) ||
		getsockname(cp->lsock, (struct sockaddr*)&sa, &salen))
		goto out;
	snprintf(port, sizeof(port), "%u", ntohs(sa.sin_port));
	pthread_create(&th, NULL, capture_thread, cp);
	pr.endpoint = "127.0.0.1";
	pr.port = port;
	pr.timeout = 3;
	run_probe(&pr, msg, sizeof(msg));
	shutdown(cp->lsock, SHUT_RDWR);
	pthread_join(th, NULL);
	if (cp->len >= 5 && cp->data[0] == 0x16)
	{
		size = 5 + ((cp->data[3] << 8) | cp->data[4]);
		if (pq)
		{
			// 0x11EC — X25519MLKEM768 в supported_groups / key_share
			*pq = false;
			for (size_t i = 0; i + 1 < cp->len; i++)
				if (cp->data[i] == 0x11 && cp->data[i + 1] == 0xEC) { *pq = true; break; }
		}
	}
out:
	if (cp->lsock >= 0) close(cp->lsock);
	free(cp);
	return size;
}

// Сколько записей ALPN нужно, чтобы ClientHello дорос до target байт
static int calibrate(const struct probe *pr, int target)
{
	struct probe p = *pr;
	int native;
	p.pad = 0;
	native = measure(&p, NULL);
	if (native < 0 || target <= native) return 0;
	int n = (target - native + PAD_ENTRY - 1) / PAD_ENTRY;
	return n > PAD_MAX ? PAD_MAX : n;
}

static int usage(void)
{
	fprintf(stderr,
		"bigch <хост> [порт] [размер] [таймаут] [--small] [--sni <имя|none>] [--connect <адрес>]\n"
		"bigch --selfcheck [размер] [--small]\n");
	return 2;
}

int main(int argc, char **argv)
{
	const char *args[8], *sni_opt = NULL, *connect_to = NULL;
	char ipbuf[INET6_ADDRSTRLEN], msg[256];
	struct probe pr = { .port = "443", .timeout = 6 };
	int nargs = 0, size, target;
	bool selfcheck = false;

	for (int i = 1; i < argc; i++)
	{
		if (!strcmp(argv[i], "--small")) pr.small = true;
		else if (!strcmp(argv[i], "--selfcheck")) selfcheck = true;
		else if (!strcmp(argv[i], "--sni") && i + 1 < argc) sni_opt = argv[++i];
		else if (!strcmp(argv[i], "--connect") && i + 1 < argc) connect_to = argv[++i];
		else if (argv[i][0] == '-' && argv[i][1] == '-') return usage();
		else if (nargs < 8) args[nargs++] = argv[i];
	}

	if (selfcheck)
	{
		bool pq = false;
		size = nargs > 0 ? atoi(args[0]) : 0;
		target = size > 0 ? size : (pr.small ? 0 : BIG_DEFAULT);
		pr.sni = "www.youtube.com";
		pr.pad = target ? calibrate(&pr, target) : 0;
		int real = measure(&pr, &pq);
		if (real < 0) { printf("не удалось перехватить ClientHello\n"); return 2; }
		printf("запрошено ~%d, реальный ClientHello: %d байт (%s), постквантовый key_share: %s%s\n",
			target, real, real <= 1400 ? "влезает в один сегмент" : "рвётся на два сегмента",
			pq ? "есть" : "нет", pr.pad ? ", добито ALPN" : "");
		return 0;
	}

	if (nargs < 1) return usage();
	if (nargs > 1) pr.port = args[1];
	size = nargs > 2 ? atoi(args[2]) : 0;
	if (nargs > 3) pr.timeout = atof(args[3]);
	if (pr.timeout <= 0) pr.timeout = 6;

	// SNI: по умолчанию — сам хост; «none» — без SNI (соединяемся по адресу)
	pr.endpoint = connect_to ? connect_to : args[0];
	pr.sni = sni_opt ? (strcmp(sni_opt, "none") && strcmp(sni_opt, "-") ? sni_opt : NULL) : args[0];
	if (!pr.sni && !is_ip(pr.endpoint))
	{
		if (!resolve(pr.endpoint, ipbuf, sizeof(ipbuf))) { printf("имя не разрешается\n"); return 1; }
		pr.endpoint = ipbuf;
	}
	if (pr.sni && is_ip(pr.sni)) pr.sni = NULL;

	// большой ClientHello — браузерного размера; маленький — какой получится
	target = size > 0 ? size : (pr.small ? 0 : BIG_DEFAULT);
	pr.pad = target ? calibrate(&pr, target) : 0;

	int rc = run_probe(&pr, msg, sizeof(msg));
	printf("%s\n", msg);
	return rc;
}
