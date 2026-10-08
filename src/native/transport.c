/* Same even-address/CRC wire as the tested R02a probe, executing in RAM. */
#include <stdint.h>
#include "diagnostics.h"
extern void r03_delay(void);
static uint8_t packet[265];
static uint16_t crc(const uint8_t *p,unsigned n){uint16_t c=0xffff;while(n--){c^=(uint16_t)*p++<<8;for(unsigned i=0;i<8;i++)c=(c&0x8000)?(c<<1)^0x1021:c<<1;}return c;}
static void word(uint8_t *p,uint16_t v){p[0]=v>>8;p[1]=v;}
static uint16_t readword(const uint8_t *p){return (uint16_t)((p[0]<<8)|p[1]);}
#ifndef R06_HOST
#define WORD(a) (*(volatile uint16_t *)(a))
#define LONG(a) (*(volatile uint32_t *)(a))
#define BYTE(a) (*(volatile uint8_t *)(a))
static void event(uint32_t a){(void)BYTE(a);r03_delay();}
#endif
static int exchange_locked(uint8_t op,const uint8_t *data,uint16_t len,uint8_t *reply,uint16_t *reply_len){
    r06_diag[D_LAST_OP]=op;r06_diag[D_STAGE]=W_NONE;r06_diag[D_SENT]=0;
    r06_diag[D_SEQ]=0;r06_diag[D_REPLY]=0;r06_diag[D_REPLY_LEN]=0;r06_diag[D_REPLY_RESULT]=0;
    if(len>256){r06_diag[D_STAGE]=W_ARGUMENT;return -1;}
    uint32_t ready=LONG(0xfbef00);
    if(op==16){
        uint32_t start=LONG(0x4ba),polls=1;
        r06_diag[D_START_TICK]=start;r06_diag[D_FIRST_READY]=ready;
        /* Read-only readiness polling, before START or any packet byte.
         * One second maximum by the TOS clock, plus a finite poll ceiling
         * if that clock cannot advance. Never retry an ambiguous request. */
        while(ready!=0x52324121u && (uint32_t)(LONG(0x4ba)-start)<200u && polls<65536u){
            r03_delay();ready=LONG(0xfbef00);polls++;
        }
        r06_diag[D_READY_READS]=polls;r06_diag[D_LAST_READY]=ready;
        r06_diag[D_END_TICK]=LONG(0x4ba);
    }
    if(ready!=0x52324121u){r06_diag[D_STAGE]=W_NOT_READY;return -1;}
    uint32_t sequence=LONG(0xfbf000)+1;if(!sequence)sequence=1;
    packet[0]=op;word(packet+1,len);word(packet+3,sequence>>16);word(packet+5,sequence);
    for(unsigned i=0;i<len;i++)packet[7+i]=data[i];
    word(packet+7+len,crc(packet,7+len));
    r06_diag[D_SEQ]=sequence;
    r06_diag[D_STAGE]=W_SENT;r06_diag[D_SENT]=1;
    event(0xfbd000);
    for(unsigned i=0;i<len+9u;i++)event(0xfbe200+2u*packet[i]);
    event(0xfbd002);
    uint32_t until=LONG(0x4ba)+(op>=48?2000:1000),loops=op>=48?4000000:500000;
    while(LONG(0xfbf000)!=sequence){r03_delay();if((int32_t)(LONG(0x4ba)-until)>=0 || !--loops){r06_diag[D_REPLY]=LONG(0xfbf000);r06_diag[D_STAGE]=W_TIMEOUT;return -1;}}
    /* Copy complete fixed response before validating it. */
    static uint8_t response[528];
    for(unsigned i=0;i<264;i++){word(response+2*i,WORD(0xfbf000+2*i));r03_delay();}
    r06_diag[D_REPLY]=((uint32_t)readword(response)<<16)|readword(response+2);
    if(readword(response)!=(sequence>>16) || readword(response+2)!=(sequence&0xffff) ||
       readword(response+4)!=op || readword(response+6)!=0 || readword(response+8)>512 ||
       readword(response+10)!=0 || crc(response,524)!=readword(response+524)){r06_diag[D_STAGE]=W_BAD_REPLY;return -1;}
    *reply_len=readword(response+8);
    r06_diag[D_REPLY_LEN]=*reply_len;r06_diag[D_STAGE]=W_VALID;
    if(*reply_len>=4)r06_diag[D_REPLY_RESULT]=((uint32_t)readword(response+12)<<16)|readword(response+14);
    for(unsigned i=0;i<*reply_len;i++)reply[i]=response[12+i];
    return 0;
}

/* SE20 shared RAM gate. SIDEETH timer callbacks defer while any native
 * transaction owns the bus; no interrupt masking during Pico waits. */
struct r20_api {uint32_t magic,version;volatile uint16_t busy;uint16_t reserved;};
struct r20_api r20_bus={0x53453230u,1,0,0};
struct r20_api *r20_bus_ptr=&r20_bus;
static uint32_t r20_cookie_jar[128];
extern void r20_publish_jar(uint32_t *jar);
void r20_install(void){
    const uint32_t *old=(const uint32_t *)(uintptr_t)LONG(0x5a0);
    unsigned n=0;
    if(old)while(n<124 && old[n]){
        if(old[n]==0x53453230u){
            uint32_t address=old[n+1];
            if(!(address&1) && address>=0x1000u && address<=LONG(0x42e)-12u){
                struct r20_api *other=(struct r20_api *)(uintptr_t)address;
                if(other->magic==0x53453230u && other->version==1)r20_bus_ptr=other;
            }
            return; /* A duplicate resident shares the advertised gate. */
        }
        r20_cookie_jar[n]=old[n];r20_cookie_jar[n+1]=old[n+1];n+=2;
    }
    if(old && old[n])return; /* preserve a full jar without truncation */
    r20_cookie_jar[n]=0x53453230u;r20_cookie_jar[n+1]=(uint32_t)(uintptr_t)&r20_bus;
    r20_cookie_jar[n+2]=0;r20_cookie_jar[n+3]=64;
    r20_publish_jar(r20_cookie_jar);
}
extern int r20_enter(void);
int r03_exchange(uint8_t op,const uint8_t *data,uint16_t len,uint8_t *reply,uint16_t *reply_len){
    if(!r20_enter())return -1;
    int result=exchange_locked(op,data,len,reply,reply_len);
    __asm__ volatile("" ::: "memory");r20_bus_ptr->busy=0;return result;
}
