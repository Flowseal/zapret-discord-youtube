/* Local ASan/UBSan validation of analyzer conntrack teardown reports. */
#include <assert.h>
#include "../engine/conntrack.c"
int main(int argc, char **argv) {
    for(unsigned round=0;round<100;round++) {
        t_conntrack ct={0}; ConntrackPoolInit(&ct,0,0,0,0,0);
        for(unsigned i=0;i<256;i++) {
            t_conn c={0}; c.l4proto=IPPROTO_UDP; c.sport=i;
            assert(ConntrackNew(&ct.pool,&c));
        }
        if(round&1) {ConntrackPoolPurge(&ct);assert(!ct.pool);}
        ConntrackPoolDestroy(&ct); assert(!ct.pool);
    }
    puts("conntrack teardown/purge: PASS");
}
