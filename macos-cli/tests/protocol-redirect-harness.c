#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../engine/params.h"
#include "../engine/protocol.h"
struct params_s params;
int main(int argc, char **argv)
{
    (void)argc; (void)argv;
    const char *values[] = {"", "h", "http:", "http://", "https://", "http://blocked.test/path", "https://www.example.test/path", "/relative", "ftp://other.test"};
    for (size_t i = 0; i < sizeof(values)/sizeof(*values); ++i) {
        char response[512];
        int n = snprintf(response, sizeof(response), "HTTP/1.1 302 Found\r\nLocation: %s\r\n\r\n", values[i]);
        bool result = HttpReplyLooksLikeDPIRedirect((const uint8_t *)response, n, "www.example.test");
        assert(result == (i == 5));
    }
    for (size_t n = 0; n <= 4096; ++n) {
        char *response = malloc(n + 128);
        assert(response);
        size_t offset = (size_t)snprintf(response, n + 128, "HTTP/1.1 307 Temporary Redirect\r\nLocation: https://");
        memset(response + offset, 'a', n);
        memcpy(response + offset + n, "\r\n\r\n", 4);
        (void)HttpReplyLooksLikeDPIRedirect((const uint8_t *)response, offset + n + 4, "www.example.test");
        free(response);
    }
    puts("PASS: real HTTP redirect parser; empty/prefix/relative/domain cases and lengths 0..4096");
}
