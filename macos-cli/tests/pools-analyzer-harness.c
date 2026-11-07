/* Local ASan/UBSan validation of analyzer pool teardown reports. */
#include <assert.h>
#include "../engine/pools.c"
static unsigned check_tree(struct kavl_bit_elem *n) {
    if(!n) return 0;
    unsigned left=check_tree(n->head.p[0]),right=check_tree(n->head.p[1]);
    assert(n->head.balance==(int)right-(int)left);
    assert(n->head.balance>=-1&&n->head.balance<=1);
    unsigned size=1;
    if(n->head.p[0])size+=n->head.p[0]->head.size;
    if(n->head.p[1])size+=n->head.p[1]->head.size;
    assert(n->head.size==size);
    return 1+(left>right?left:right);
}
int main(void) {
    for (unsigned round=0;round<100;round++) {
        hostlist_pool *hosts=NULL; hostfail_pool *fails=NULL;
        ip_cache cache={0};
        struct kavl_bit_elem *tree=NULL;
        for (unsigned i=0;i<256;i++) {
            char key[32]; snprintf(key,sizeof(key),"host-%u",i);
            assert(HostlistPoolAddStr(&hosts,key,0));
            assert(HostFailPoolAdd(&fails,key,-1));
            struct in_addr a={.s_addr=htonl(i+1)};
            struct in6_addr a6={0}; memcpy(a6.s6_addr+12,&a,4);
            assert(ipcacheTouch(&cache,&a,NULL,"en0"));
            assert(ipcacheTouch(&cache,NULL,&a6,"en0"));
            uint32_t *data=malloc(4); assert(data); *data=htonl((i*73+round)%256);
            assert(kavl_bit_add(&tree,data,32,0)); check_tree(tree);
        }
        HostlistPoolDestroy(&hosts); assert(!hosts);
        if(round&1) {HostFailPoolPurge(&fails);assert(!fails);} else HostFailPoolDestroy(&fails);
        if(round&1) {ipcache4_purge(&cache.ipcache4,-1);ipcache6_purge(&cache.ipcache6,-1);}
        ipcacheDestroy(&cache); assert(!cache.ipcache4&&!cache.ipcache6);
        for(unsigned i=0;i<128;i++) {
            uint32_t data=htonl((i*151+round)%256);
            kavl_bit_delete(&tree,&data,32); check_tree(tree);
        }
        kavl_bit_destroy(&tree); assert(!tree);
        HostFailPoolDestroy(&fails);
    }
    puts("pool teardown/purge and valid AVL destroy: PASS");
}
