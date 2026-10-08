/* Run the actual guest routing code on the host, with controlled GEMDOS
 * and RPC adapters. Pointer IDs stand in for Atari's 32-bit addresses. */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
static void *pointers[16];
static uint8_t process_memory[4096];
static void *pointer(uint32_t id){if(id>=0x10000 && id<0x11000)return process_memory+id-0x10000;assert(id<16);return pointers[id];}
#define R03_POINTER(n) pointer(n)
static uint8_t low_memory[0x20000];
#define R26_MEMORY(n) (low_memory+(n))
#include "driver.c"
static unsigned gate_installs;
void r20_install(void){gate_installs++;}
static char console_output[8192];
void r18_console(const char *text){
    unsigned n=(unsigned)strlen(console_output),m=(unsigned)strlen(text);
    if(n+m<sizeof(console_output))memcpy(console_output+n,text,m+1);
}
static uint32_t drive=2,bits=0x3fc;
static uint8_t dta_a[44];static void *dta=dta_a;
static unsigned calls,last_op,last_slot;
static unsigned mock_failure;
static int mkdir_error,metadata_error;
static unsigned clock_ready,clock_sets;
static unsigned keep_search;
static uint8_t data[100000],source[71044],destination[71044];
static unsigned data_size=1200,uncertain,short_ack;
static unsigned pd_model,native_accept;
static int forced_drive=-1;
uint32_t r03_native_drive(void){return forced_drive>=0?(unsigned)forced_drive:pd_model?be16(low_memory+be32(low_memory+0x900)+56):drive;}
void *r03_native_dta(void){return dta;}
uint32_t r03_drive_bits(void){return bits;}
int r03_exchange(uint8_t op,const uint8_t *p,uint16_t len,uint8_t *out,uint16_t *n){
    calls++;last_op=op;clear(out,512);*n=4;
    if(op==14){if(clock_ready){*n=8;put16(out+4,0x5d33);put16(out+6,0x6200);}else put32(out,(uint32_t)-2);return 0;}
    if(op==15){*n=13;memset(out+4,255,9);out[4]=12;out[5]=14;out[6]=2;return 0;}
    if(op>=32)op=16+(op-16)%16;
    if(op==16){
        if(mock_failure){r06_diag[D_STAGE]=mock_failure==1?W_NOT_READY:mock_failure==2?W_TIMEOUT:W_VALID;r06_diag[D_SENT]=mock_failure!=1;
            if(mock_failure<3)return -1;
            if(mock_failure==3){put32(out,(uint32_t)-65);r06_diag[D_REPLY_RESULT]=(uint32_t)-65;return 0;}
            *n=4;return 0;
        }
        r06_diag[D_STAGE]=W_VALID;r06_diag[D_SENT]=1;put32(out+4,123);*n=8;return 0;
    }
    assert(be32(p)==123);
    if(op==17){
        assert(len>=6);
        if(!strcmp((const char *)p+4,"\\MISSING")){put32(out,(uint32_t)-34);return 0;}
        put16(out+4,strchr((const char *)p+4,'.')?0:16);put16(out+6,0x1234);put16(out+8,0x5678);put32(out+12,data_size);*n=16;
    }else if(op==18){
        last_slot=be16(p+4);*n=48;out[4+21]=0;copy(out+4+30,"FILE.TXT",9);
    }else if(op==19){if(keep_search){*n=48;copy(out+34,"NEXT.TXT",9);}else put32(out,(uint32_t)-49);}
    else if(op==20){uint32_t offset=be32(p+4);unsigned count=be16(p+8);assert(count<=508);if(offset>=data_size)count=0;else if(count>data_size-offset)count=data_size-offset;put32(out,count);copy(out+4,data+offset,count);*n=4+count;}
    else if(op==21){*n=20;}
    else if(op==22){data_size=0;}
    else if(op==23){unsigned offset=be32(p+4),pn=be16(p+8),count=be16(p+10);assert(len==12+pn+count && len<=256);assert(!strcmp((const char *)p+12,"\\R08TEST\\BIG.DAT"));
        if(uncertain)return -1;
        memcpy(data+offset,p+12+pn,count);if(offset+count>data_size)data_size=offset+count;put32(out,count);if(short_ack)*n=5;
    }else if(op>=24 && op<=26){if(op==24)put32(out,(uint32_t)mkdir_error);}
    else if(op==27 || op==28){put32(out,(uint32_t)metadata_error);}
    else assert(0);
    return 0;
}
static uint8_t a[20];
static void args(unsigned op){clear(a,sizeof(a));put16(a,op);}
static uint32_t boot=2;
uint32_t r05_boot_drive(void){return boot;}
void r05_publish_drive(void){bits|=1u<<15;}
void r12_publish_settings(void){bits|=1u<<18;}
void r13_publish(uint32_t mask){bits|=mask;}
static void reset(void){console_output[0]=0;activation=0;failed=0;session=0;bits=0x3fc;boot=2;drive=2;calls=0;mock_failure=0;clear(r06_diag,sizeof(r06_diag));}
static unsigned allocations,releases,flushes;
int r07_can_go(void){return 1;}
void r07_cache(void){flushes++;}
int32_t r07_tos(const uint8_t *p,uint32_t n){
    if(be16(p)==0x0e){assert(n==4);if(!native_accept)return -46;put16(low_memory+be32(low_memory+0x900)+56,be16(p+2));return bits;}
    if(be16(p)==0x2b || be16(p)==0x2d){assert(n==4);clock_sets++;return 0;}
    if(be16(p)==0x4b){assert(n==16 && be16(p+2)==5 && be32(p+4)==0);allocations++;clear(process_memory,sizeof(process_memory));put32(process_memory+4,0x11000);put32(process_memory+44,0x20000);return 0x10000;}
    assert(be16(p)==0x49 && n==6);releases++;return 0;
}
static void guards(void){r06_diag[0]=0x52313041;r06_diag[1]=2;r06_diag[2]=128;r06_diag[28]=0x13579bdf;r06_diag[29]=0x2468ace0;r06_diag[30]=0x55aa55aa;r06_diag[31]=0xaa55aa55;}
static void original_tests(void){
    reset();activation=1;session=123;guards();pointers[1]="P:\\HELLO.TOS";pointers[2]="C:\\HELLO.TOS";
    clear(data,sizeof(data));put16(data,0x601a);put32(data+2,512);put32(data+6,16);put32(data+10,32);put32(data+28+4,12);put32(data+556,4);data[560]=0;
    args(0x4b);put16(a+2,0);put32(a+4,1);put32(a+8,123);put32(a+12,456);
    assert(r03_dispatch(a)==PASS && be16(a+2)==6 && be32(a+8)==0x10000 && !be32(a+4) && !be32(a+12));
    assert(allocations==1 && flushes==1 && !releases && be32(process_memory+260)==0x1010c);
    args(0x4b);put16(a+2,3);put32(a+4,1);
    assert(r03_dispatch(a)==0x10000 && be16(a+2)==3 && allocations==2);
    args(0x4b);put32(a+4,2);unsigned before=calls;assert(r03_dispatch(a)==PASS && calls==before);
    put16(a+2,6);put32(a+4,0xffffffff);assert(r03_dispatch(a)==PASS && calls==before);
    args(0x4b);put32(a+4,1);r06_diag[28]^=1;assert(r03_dispatch(a)==-65 && calls==before);
    guards();put32(data+556,527);assert(r03_dispatch(a)==-66 && releases==2 && be16(a+2)==0);
    /* Actual RW dispatcher and chunk transfer across the 64 KB boundary. */
    guards();failed=0;clear(files,sizeof(files));pointers[3]="P:\\R08TEST\\BIG.DAT";pointers[4]=source;pointers[5]=destination;pointers[6]="P:\\OUT.DAT";
    args(0x3c);put32(a+2,6);before=calls;int32_t outside=r03_dispatch(a);assert(outside==(int32_t)HANDLE_BASE);
    args(0x3e);put16(a+2,outside);assert(!r03_dispatch(a));
    args(0x3c);put32(a+2,3);int32_t h=r03_dispatch(a);assert(h==(int32_t)HANDLE_BASE);
    args(0x3d);put32(a+2,3);put16(a+6,0);assert(r03_dispatch(a)==-36);
    args(0x4b);put32(a+4,3);assert(r03_dispatch(a)==-36); /* cannot execute a writer */
    for(unsigned i=0;i<sizeof(source);i++)source[i]=(uint8_t)(i*37u^(i>>8));
    args(0x40);put16(a+2,h);put32(a+4,sizeof(source));put32(a+8,4);assert(r03_dispatch(a)==sizeof(source));assert(data_size==sizeof(source) && !memcmp(source,data,sizeof(source)));
    args(0x42);put16(a+6,h);put32(a+2,0);assert(r03_dispatch(a)==0);
    args(0x3f);put16(a+2,h);put32(a+4,sizeof(destination));put32(a+8,5);assert(r03_dispatch(a)==sizeof(destination) && !memcmp(destination,source,sizeof(source)));
    args(0x3e);put16(a+2,h);assert(r03_dispatch(a)==0);
    args(0x3d);put32(a+2,3);put16(a+6,1);h=r03_dispatch(a);assert(h==(int32_t)HANDLE_BASE);
    args(0x3f);put16(a+2,h);put32(a+4,1);put32(a+8,5);before=calls;assert(r03_dispatch(a)==-36 && calls==before);
    args(0x42);put16(a+6,h);put32(a+2,data_size+1);assert(r03_dispatch(a)==(int32_t)data_size+1);
    args(0x40);put16(a+2,h);put32(a+4,1);put32(a+8,4);before=calls;assert(r03_dispatch(a)==-64 && calls==before);
    files[0].position=0;uncertain=1;before=calls;assert(r03_dispatch(a)==-65 && failed && calls==before+1);
    before=calls;assert(r03_dispatch(a)==-46 && calls==before); /* no retry */
    args(0x3e);put16(a+2,h);assert(r03_dispatch(a)==-65 && !files[0].used);
    failed=0;uncertain=0;args(0x3c);put32(a+2,3);h=r03_dispatch(a);short_ack=1;
    args(0x40);put16(a+2,h);put32(a+4,1);put32(a+8,4);assert(r03_dispatch(a)==-65 && failed);
    puts("R08 dispatch: scoped mutations, 71 KB write/read, access modes, open-file exclusion, bounds, malformed ACK and uncertain-write no-retry passed. R07 dispatch: native pass-through, load-only return, mode-0 handoff to native mode 6, malformed-load cleanup and diagnostic guard rejection passed.");
}

static void new_features(void){
 reset();clear(contexts,sizeof(contexts));activation=1;selected=0;session=123;drive_numbers[0]=15;guards();
 pointers[1]="P:\\EMPTY";strcpy(cwd,"\\EMPTY");args(0x3a);put32(a+2,1);
 assert(!r03_dispatch(a) && !strcmp(cwd,"\\"));
 strcpy(cwd,"\\EMPTY\\CHILD");args(0x3a);put32(a+2,1);unsigned before=calls;assert(r03_dispatch(a)==-36 && calls==before);
 strcpy(cwd,"\\");pointers[1]="P:\\A.TXT";args(0x43);put32(a+2,1);put16(a+6,1);put16(a+8,1);assert(!r03_dispatch(a) && last_op==27);
 metadata_error=-36;assert(r03_dispatch(a)==-36 && !failed);metadata_error=0;
 args(0x3d);put32(a+2,1);int32_t h=r03_dispatch(a);assert(h==0x6000);
 uint8_t dt[4]={0x62,0,0x5d,0x33};pointers[7]=dt;
 args(0x57);put32(a+2,7);put16(a+6,h);put16(a+8,1);assert(!r03_dispatch(a) && last_op==28 && files[0].time==0x6200);
 metadata_error=-32;dt[0]=0x63;assert(r03_dispatch(a)==-32 && files[0].time==0x6200 && !failed);metadata_error=0;
 clock_ready=1;r14_clock_calls=127;r14_clock_done=0;args(0x2a);assert(r03_dispatch(a)==PASS && clock_sets==2 && r14_clock_done);
 r14_clock_calls=127;assert(r03_dispatch(a)==PASS && clock_sets==2);clock_ready=0;
 puts("R14 guest: expanded SD writes, cwd deletion, ancestor guard, metadata success/refusal and one-shot native clock update pass.");
}
static void standalone_boot(void){
    const char *searches[]={"A:\\AUTO\\*.PRG","A:\\*.ACC","B:\\*.ACC","\\*.ACC"};
    for(unsigned i=0;i<4;i++){
        reset();clear(contexts,sizeof(contexts));settings_active=0;
        boot=i==2?1:0;drive=boot;bits=0;gate_installs=0;
        pointers[1]="C:\\AUTO\\*.PRG";args(0x4e);put32(a+2,1);
        assert(r03_dispatch(a)==PASS && !activation && !gate_installs);
        pointers[1]="A:\\OTHER\\*.PRG";
        assert(r03_dispatch(a)==PASS && !activation);
        pointers[1]= (void *)searches[i];
        assert(r03_dispatch(a)==PASS && activation==1 && settings_active);
        assert((bits & ((1u<<15)|(1u<<18)))==((1u<<15)|(1u<<18)));
        assert(!(bits&3) && drive==boot && gate_installs==1);
        assert(r03_dispatch(a)==PASS && gate_installs==1);
    }
    reset();boot=2;bits=0;gate_installs=0;
    pointers[1]="C:\\AUTO\\*.PRG";args(0x4e);put32(a+2,1);
    assert(r03_dispatch(a)==PASS && !activation && !gate_installs);
    puts("F22: floppy/no-floppy AUTO and accessory searches activate once, preserve boot drive and floppy bits; hard-disk publication gate retained.");
}
static void desktop_fallback(void){
    const char *yes[]={"A:\\NEWDESK.INF","B:\\DESKTOP.INF","\\newdesk.inf","DESKTOP.INF","A:\\DESKICON.RSC","\\DESKICON.RSC","B:\\deskicon.rsc"};
    const char *no[]={"C:\\NEWDESK.INF","A:\\OTHER.INF","A:\\DIR\\NEWDESK.INF","NEWDESK.INF.BAK","C:\\DESKICON.RSC","A:\\DIR\\DESKICON.RSC","DESKICON.RSC.BAK"};
    for(unsigned i=0;i<7;i++){assert(desktop_config(yes[i]));assert(!desktop_config(no[i]));}
    for(unsigned op=0;op<2;op++)for(unsigned i=0;i<7;i++){
        reset();clear(contexts,sizeof(contexts));clear(drive_active,sizeof(drive_active));settings_active=0;selected=0;
        drive_numbers[0]=15;drive_numbers[1]=18;boot=i==3?0xffffu:0;drive=0;bits=0;gate_installs=0;
        args(op?0x4e:0x3d);put32(a+2,1);pointers[1]=(void *)no[i];
        assert(r03_dispatch(a)==PASS && !activation && !gate_installs);
        pointers[1]=(void *)yes[i];
        assert(r03_dispatch(a)==PASS && activation==1 && settings_active && gate_installs==1);
        assert(drive==0 && !(bits&3));
        assert(r03_dispatch(a)==PASS && gate_installs==1);
    }
    reset();boot=0;bits=1u<<2;gate_installs=0;pointers[1]="A:\\NEWDESK.INF";args(0x3d);put32(a+2,1);
    assert(r03_dispatch(a)==PASS && !activation && !gate_installs);
    puts("F25 desktop fallback: exact root filenames, A/B/no boot device, native hard-disk exclusion, one-shot publication and native Fopen/Fsfirst pass-through verified.");
}
static void extended_selection(void){
    reset();activation=1;settings_active=1;bits|=1u<<18;
    memset(low_memory,0,sizeof(low_memory));
    put32(low_memory+0x42e,sizeof(low_memory));put32(low_memory+0x4f2,0x800);
    put16(low_memory+0x802,0x0404);put32(low_memory+0x828,0x900);
    put32(low_memory+0x900,0x1000);put32(low_memory+0x1000,0x1000);put32(low_memory+0x1004,0x2000);
    /* Bytes +48..63 from the user's S27CHECK.LOG, TOS 4.04. */
    static const uint8_t captured[16]={0,0,0,0,0,0,0,0,0,15,0,25,0,3,11,0};
    memcpy(low_memory+0x1030,captured,sizeof(captured));pd_model=1;
    args(0x0e);put16(a+2,18);assert(r03_dispatch(a)==(int32_t)bits && r03_native_drive()==18);
    for(unsigned i=0;i<16;i++)if(i!=9)assert(low_memory[0x1030+i]==captured[i]);
    /* Native Pexec copies this field; changing the child's drive leaves the
     * parent intact. Model a child PD and a switch back on termination. */
    memcpy(low_memory+0x3000,low_memory+0x1000,256);put32(low_memory+0x3000,0x3000);
    put32(low_memory+0x3004,0x4000);put32(low_memory+0x900,0x3000);
    assert(r03_native_drive()==18);low_memory[0x3039]=15;
    assert(r03_dispatch(a)==(int32_t)bits && low_memory[0x3039]==18);
    low_memory[0x3039]=2;put32(low_memory+0x900,0x1000);assert(r03_native_drive()==18);
    /* Relative S paths now route through the settings backend. */
    selected=1;contexts[1].sid=123;contexts[1].broken=0;strcpy(contexts[1].directory,"\\");
    pointers[1]="README.TXT";args(0x3d);put32(a+2,1);
    int32_t h=r03_dispatch(a);assert(h>=0x6008 && h<0x6010);
    args(0x3e);put16(a+2,h);assert(!r03_dispatch(a));
    args(0x0e);put16(a+2,18);
    low_memory[0x1039]=15;put16(low_memory+0x802,0x0206);
    assert(r03_dispatch(a)==-46 && r03_native_drive()==15);
    put16(low_memory+0x802,0x0404);put32(low_memory+0x1000,0);
    assert(r03_dispatch(a)==-46 && r03_native_drive()==15);put32(low_memory+0x1000,0x1000);
    put32(low_memory+0x5a0,0xa00);put32(low_memory+0xa00,0x4d694e54);
    assert(r03_dispatch(a)==-46 && r03_native_drive()==15);put32(low_memory+0x5a0,0);
    put32(low_memory+0x900,0x1ff80);assert(r03_dispatch(a)==-46);put32(low_memory+0x900,0x1000);
    put32(low_memory+0x828,0x901);assert(r03_dispatch(a)==-46);put32(low_memory+0x828,0x900);
    forced_drive=2;assert(r03_dispatch(a)==-46 && low_memory[0x1039]==15);
    forced_drive=15;assert(r03_dispatch(a)==-46 && low_memory[0x1039]==15); /* post-write verification rolls back */
    forced_drive=-1;
    low_memory[0x1038]=1;assert(r03_dispatch(a)==-46 && low_memory[0x1038]==1 && low_memory[0x1039]==15);
    low_memory[0x1038]=0;
    put16(low_memory+0x802,0x0402);assert(r03_dispatch(a)==-46);put16(low_memory+0x802,0x0404);
    settings_active=0;assert(r03_dispatch(a)==PASS);settings_active=1;
    bits&=~(1u<<18);assert(r03_dispatch(a)==PASS);bits|=1u<<18;
    put16(a+2,19);assert(r03_dispatch(a)==PASS);put16(a+2,2);assert(r03_dispatch(a)==PASS);
    put16(a+2,18);native_accept=1;put32(low_memory+0x4f2,0); /* native success needs no layout */
    assert(r03_dispatch(a)==(int32_t)bits && r03_native_drive()==18);
    pd_model=0;native_accept=0;
    puts("F27: extended-drive selection, relative S reads, per-process drive model, native success and fail-closed guards pass.");
}
int main(void){
    extended_selection();desktop_fallback();standalone_boot();gate_installs=0;
    clear(contexts,sizeof(contexts));clear(drive_active,sizeof(drive_active));
    clear(drive_numbers,sizeof(drive_numbers));drive_numbers[0]=15;drive_numbers[1]=18;
    settings_active=0;selected=0;

    reset();pointers[1]="C:\\OTHER\\*.PRG";args(0x4e);put32(a+2,1);
    assert(r03_dispatch(a)==PASS && !gate_installs && !activation);
    pointers[1]="C:\\AUTO\\*.PRG";
    assert(r03_dispatch(a)==PASS && gate_installs==1);
    assert(r03_dispatch(a)==PASS && gate_installs==1);
    puts("F20A gate: no publication before native AUTO/ACC activation; one publication at activation.");
    r18_banner(0x0404);assert(strstr(console_output,"SideTNFS Version 1.1.0 (Falcon F33)") && strstr(console_output,"TOS version: 4.04"));console_output[0]=0;
 reset();mock_failure=1;pointers[1]="C:\\AUTO\\*.PRG";args(0x4e);put32(a+2,1);
 assert(r03_dispatch(a)==PASS && activation==2);
 assert(strstr(console_output,"[KO] microSD drive unavailable") && !strstr(console_output,"[OK]") && !strstr(console_output,"Drives installed"));
 puts("F18 console: TOS version, mount failure, published drive letters and one-shot boot output verified.");
 new_features(); original_tests();data_size=1200;uncertain=0;short_ack=0;
 reset();clear(contexts,sizeof(contexts));settings_active=0;guards();
 pointers[1]="C:\\AUTO\\*.PRG";args(0x4e);put32(a+2,1);
 assert(r03_dispatch(a)==PASS && activation==1 && settings_active && (bits&0x48000)==0x48000);
 assert(strstr(console_output,"[OK] Mounting microSD card") && strstr(console_output,"Drives installed: M: O: P: S: "));
 unsigned console_len=(unsigned)strlen(console_output);
 assert(r03_dispatch(a)==PASS && strlen(console_output)==console_len); /* no repeat banner */

 pointers[1]="S:\\FILE.TXT";args(0x3d);put32(a+2,1);int32_t sh=r03_dispatch(a);
 assert(sh==0x6008 && last_op==33);
 pointers[2]="P:\\FILE.TXT";args(0x3d);put32(a+2,2);int32_t ph=r03_dispatch(a);assert(ph==0x6000 && last_op==17);
 args(0x3f);put16(a+2,sh);put32(a+4,8);put32(a+8,5);assert(r03_dispatch(a)==8 && last_op==36);
 args(0x3f);put16(a+2,ph);put32(a+4,8);put32(a+8,5);assert(r03_dispatch(a)==8 && last_op==20);
 unsigned before=calls;args(0x40);put16(a+2,sh);put32(a+4,1);put32(a+8,4);assert(r03_dispatch(a)==-36 && calls==before);
 pointers[1]="S:\\R08TEST\\BAD.DAT";args(0x3c);put32(a+2,1);assert(r03_dispatch(a)==-36 && calls==before);
 pointers[1]="S:\\*.*";args(0x4e);put32(a+2,1);assert(r03_dispatch(a)==0 && last_op==34);
 args(0x4f);assert(r03_dispatch(a)==-49 && last_op==35);
 pointers[1]="S:\\*.*";args(0x4e);put32(a+2,1);assert(r03_dispatch(a)==0);
 pointers[1]="C:\\*.*";args(0x4e);put32(a+2,1);assert(r03_dispatch(a)==PASS);
 args(0x4f);assert(r03_dispatch(a)==PASS);
 drive=18;pointers[1]="FILE.TXT";args(0x3d);put32(a+2,1);assert(r03_dispatch(a)==0x6009 && last_op==33);
 /* S: Pexec uses the same checked loader and native GO handoff. */
 clear(data,sizeof(data));data_size=561;put16(data,0x601a);put32(data+2,512);put32(data+6,16);put32(data+10,32);put32(data+32,12);put32(data+556,4);
 pointers[1]="S:\\HELLO.TOS";args(0x4b);put16(a+2,3);put32(a+4,1);assert(r03_dispatch(a)==0x10000 && last_op==36);
 reset();clear(contexts,sizeof(contexts));settings_active=0;bits|=1u<<18;guards();
 pointers[1]="C:\\AUTO\\*.PRG";args(0x4e);put32(a+2,1);assert(r03_dispatch(a)==PASS && activation==1 && !settings_active);
 puts("R12S guest: independent handles/cursors, S read-only, DTA retirement, implicit S paths, program loading and occupied S preservation pass.");
 /* Network letters M/O are registered; occupied C remains native. */
 assert(drive_active[2] && drive_active[3] && !drive_active[4]);
 assert(strstr(console_output,"Drives installed: M: O: P: ") && !strstr(console_output,"S: ") && !strstr(console_output,"C: "));
 assert((bits&((1u<<12)|(1u<<14)))==((1u<<12)|(1u<<14)));
 data_size=1200;uncertain=short_ack=0;drive=2;
 /* Existing-directory and other ordinary TNFS refusals keep M usable. */
 pointers[1]="M:\\R13TEST";
 const int ordinary_errors[]={-36,-33,-34,-37,-39,-35,-64,-32};
 for(unsigned i=0;i<sizeof(ordinary_errors)/sizeof(ordinary_errors[0]);i++){
   mkdir_error=ordinary_errors[i];args(0x39);put32(a+2,1);
   assert(r03_dispatch(a)==mkdir_error);
   args(0x43);put32(a+2,1);assert(r03_dispatch(a)==16 && last_op==49);
 }
 mkdir_error=0;
 puts("R13B guest: ordinary directory errors preserve subsequent M stat and I/O.");

 pointers[1]="M:\\R08TEST\\BIG.DAT";args(0x3c);put32(a+2,1);
 int32_t mh=r03_dispatch(a);assert(mh==0x6010 && last_op==54);
 pointers[2]="O:\\FILE.TXT";args(0x3d);put32(a+2,2);
 int32_t oh=r03_dispatch(a);assert(oh==0x6018 && last_op==65);
 args(0x40);put16(a+2,mh);put32(a+4,16);put32(a+8,4);
 assert(r03_dispatch(a)==16 && last_op==55);
 args(0x3f);put16(a+2,oh);put32(a+4,8);put32(a+8,5);
 assert(r03_dispatch(a)==8 && last_op==68);
 pointers[1]="M:\\*.*";args(0x4e);put32(a+2,1);assert(r03_dispatch(a)==0 && last_op==50);
 args(0x4f);assert(r03_dispatch(a)==-49 && last_op==51);
 args(0x40);put16(a+2,mh);put32(a+4,1);put32(a+8,4);uncertain=1;
 assert(r03_dispatch(a)==-65);unsigned prior=calls;
 assert(r03_dispatch(a)==-46 && calls==prior);
 args(0x3f);put16(a+2,oh);put32(a+4,8);put32(a+8,5);
 assert(r03_dispatch(a)==8 && last_op==68); /* poison isolated to M */
 /* New exact lookups never allocate search slots and preserve active walks. */
 contexts[2].broken=0;uncertain=0;selected=2;clear(contexts[2].search_owners,sizeof(contexts[2].search_owners));
 static uint8_t many_dtas[80][44];
 dta=many_dtas[0];pointers[1]="M:\\*.*";args(0x4e);put32(a+2,1);assert(r03_dispatch(a)==0);
 void *active=contexts[2].search_owners[0];assert(active==dta);
 for(unsigned j=1;j<80;j++){
   dta=many_dtas[j];pointers[1]="M:\\FILE.TXT";args(0x4e);put32(a+2,1);
   assert(r03_dispatch(a)==0 && last_op==49 && !strcmp((char*)many_dtas[j]+30,"FILE.TXT"));
   unsigned sent=calls;args(0x4f);assert(r03_dispatch(a)==-49 && calls==sent);
   assert(contexts[2].search_owners[0]==active);
 }
 /* A native Fsfirst on the same DTA clears the virtual terminal marker. */
 pointers[1]="C:\\*.*";args(0x4e);put32(a+2,1);assert(r03_dispatch(a)==PASS);
 args(0x4f);assert(r03_dispatch(a)==PASS);
 /* Fill wildcard searches, touch slot 0, and evict an older other slot. */
 for(unsigned j=0;j<32;j++){
   dta=many_dtas[j];pointers[1]="M:\\*.*";args(0x4e);put32(a+2,1);assert(r03_dispatch(a)==0);
 }
 dta=many_dtas[0];keep_search=1;args(0x4f);assert(r03_dispatch(a)==0 && last_op==51);keep_search=0;
 dta=many_dtas[32];args(0x4e);put32(a+2,1);assert(r03_dispatch(a)==0);
 assert(contexts[2].search_owners[0]==many_dtas[0]);
 dta=many_dtas[1];unsigned sent=calls;args(0x4f);assert(r03_dispatch(a)==-49 && calls==sent);
 dta=many_dtas[0];args(0x4f);assert(r03_dispatch(a)==-49 && last_op==51);
 puts("R14 exact lookup churn, terminal Fsnext, native DTA reuse and active-search LRU preservation pass.");
 puts("R13 guest: configured letters, occupied letter exclusion, independent M/O handles and DTA routing, mutations and per-drive no-retry failure pass.");

}
