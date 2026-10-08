/* Native R10 cartridge hook: tested R07 activation/loader plus scoped RW. */
#define r03_dispatch r03_core_dispatch
#include "core.c"
#include "program_loader.h"
#undef r03_dispatch
extern uint32_t r05_boot_drive(void);
extern void r05_publish_drive(void);
extern void r12_publish_settings(void);
extern void r20_install(void);
static unsigned settings_active;
extern void r13_publish(uint32_t mask);
static void r13_activate(void){
    if(r03_exchange(15,request,0,reply,&reply_len) || reply_len!=13 || be32(reply))return;
    uint8_t letters[9];copy(letters,reply+4,9);
    for(unsigned i=0;i<9;i++){
        unsigned d=letters[i];if(d<2 || d>=26 || d==15 || d==18 || (r03_drive_bits()&(1u<<d)))continue;
        selected=i+2;drive_numbers[selected]=(uint8_t)d;
        if(r03_prepare()==0){drive_active[selected]=1;r13_publish(1u<<d);}
    }
    selected=0;
}
/* 0 waiting for native boot; 1 active; 2 mount failed (native chain only). */
static unsigned activation;
#include "console.h"
#include "diagnostics.h"
uint32_t r06_diag[32]; /* initialized by the native entry, outside .data */
static int boot_search(const char *p){
    if(p[0] && p[1]==':'){
        unsigned d=upper((uint8_t)p[0]);
        if(d<'A' || d>'Z' || d-'A'!=r05_boot_drive())return 0;
        p+=2;
    }
    if(*p=='\\')p++;
    const char *q=p,*auto_prefix="AUTO\\";
    while(*auto_prefix && upper((uint8_t)*q)==(unsigned)*auto_prefix){q++;auto_prefix++;}
    if(!*auto_prefix)return 1;
    const char *acc="*.ACC";
    while(*acc && upper((uint8_t)*p)==(unsigned)*acc){p++;acc++;}
    return !*acc && !*p;
}
/* Desktop configuration reads provide a second late-startup candidate.
 * Match only root-level TOS desktop files on A/B, never arbitrary Fopen.
 * Never use this fallback when a native hard-disk drive is published. */
static int desktop_config(const char *p){
    if(p[0] && p[1]==':'){
        unsigned d=upper((uint8_t)p[0]);if(d!='A' && d!='B')return 0;
        p+=2;
    }
    if(*p=='\\')p++;
    static const char *const names[]={"DESKTOP.INF","NEWDESK.INF","DESKICON.RSC"};
    for(unsigned i=0;i<3;i++){
        const char *a=p,*n=names[i];
        while(*n && upper((uint8_t)*a)==(unsigned)*n){a++;n++;}
        if(!*a && !*n)return 1;
    }
    return 0;
}
extern int32_t r07_tos(const uint8_t *,uint32_t);
extern void r07_cache(void);
extern int r07_can_go(void);
/* Apply network time once, after activation, on a normal GEMDOS entry.
 * No waits for NTP. The nested native trap uses the hook's busy bypass. */
static unsigned r14_clock_done,r14_clock_calls;
static void r14_clock_poll(void){
    if(r14_clock_done || (++r14_clock_calls&127))return;
    uint8_t in[1]={0},out[512],a[4];uint16_t n=0;
    if(r03_exchange(14,in,0,out,&n) || n!=8 || be32(out))return;
    put16(a,0x2b);put16(a+2,be16(out+4));if(r07_tos(a,4))return;
    put16(a,0x2d);put16(a+2,be16(out+6));if(r07_tos(a,4))return;
    r14_clock_done=1;
}
static char exec_path[PATHLEN];
static int32_t exec_read(void *unused,uint32_t offset,uint8_t *dest,uint32_t count){
    (void)unused;uint32_t done=0;
    while(done<count){unsigned chunk=count-done>508?508:(unsigned)(count-done);
        put32(request+4,offset+done);put16(request+8,(uint16_t)chunk);
        unsigned n=length(exec_path)+1;copy(request+10,exec_path,n);
        int32_t got=command(20,10+n);if(got<0)return got;
        if((unsigned)got>chunk || reply_len!=4+(unsigned)got){failed=1;return -65;}
        copy(dest+done,reply+4,(unsigned)got);done+=(unsigned)got;if((unsigned)got<chunk)break;
    }return (int32_t)done;
}
static int32_t exec_create(void *unused,uint32_t tail,uint32_t env){
    (void)unused;uint8_t a[16];put16(a,0x4b);put16(a+2,5);put32(a+4,0);put32(a+8,tail);put32(a+12,env);
    return r07_tos(a,16);
}
static uint8_t *exec_pointer(void *unused,uint32_t address){(void)unused;return R03_POINTER(address);}
static void exec_free(void *unused,uint32_t bp){
    (void)unused;uint8_t a[6];uint32_t env=be32((uint8_t *)R03_POINTER(bp)+44);
    put16(a,0x49);if(env){put32(a+2,env);r07_tos(a,6);}put32(a+2,bp);r07_tos(a,6);
}
static void exec_cache(void *unused){(void)unused;r07_cache();}
static int r08_busy(const char *,int);
static int32_t load_program(uint8_t *a){
    unsigned mode=be16(a+2);if(mode!=0 && mode!=3)return PASS;
    const char *name=R03_POINTER(be32(a+4));if(!virtual_path(name))return PASS;
    if(mode==0 && !r07_can_go())return -32;
    if(r06_diag[0]!=0x52313041u || r06_diag[1]!=2 || r06_diag[2]!=128 ||
       r06_diag[28]!=0x13579bdfu || r06_diag[29]!=0x2468ace0u ||
       r06_diag[30]!=0x55aa55aau || r06_diag[31]!=0xaa55aa55u)return -65;
    if(normalize(name,path))return -34;
    if(r08_busy(path,1))return -36;
    int32_t result=stat_path();if(result)return result;
    if(be16(reply+4)&16)return -36;
    uint32_t size=be32(reply+12);copy(exec_path,path,length(path)+1);
    static r07_io io={NULL,exec_read,exec_create,exec_pointer,exec_free,exec_cache};
    result=r07_load(&io,size,be32(a+8),be32(a+12));
    if(result<0 || mode==3)return result;
    /* Re-enter the original TOS handler with GO_AND_FREE. The assembly
     * releases the private stack/busy guard before chaining; child traps
     * therefore use the ordinary GEMDOS path. No return-PC rewrite. */
    put16(a+2,6);put32(a+4,0);put32(a+8,(uint32_t)result);put32(a+12,0);return PASS;
}
#include "filesystem.h"
#include "drive_select.h"
/* Choose drive by path/handle/DTA, never by whichever drive ran last. */
static unsigned path_drive(const char *p){
    if(p[0] && p[1]==':')return upper((uint8_t)p[0])-'A';
    return r03_native_drive();
}
static unsigned select_call(const uint8_t *a){
    unsigned op=be16(a),d=15;
    if(op==0x4e || op==0x3b || op==0x3d || op==0x43 || op==0x39 || op==0x3a || op==0x3c || op==0x41)
        d=path_drive(R03_POINTER(be32(a+2)));
    else if(op==0x4b && (be16(a+2)==0 || be16(a+2)==3))d=path_drive(R03_POINTER(be32(a+4)));
    else if(op==0x56){
        d=path_drive(R03_POINTER(be32(a+4)));
        unsigned found=0;for(unsigned j=0;j<11;j++)if(d==drive_numbers[j] && (j<2 || drive_active[j]))found=1;
        if(!found)d=path_drive(R03_POINTER(be32(a+8)));
    }else if(op==0x47 || op==0x36){unsigned n=be16(a+6);d=n?n-1:r03_native_drive();}
    else if(op==0x4f){
        void *dt=r03_native_dta();
        int marked=tnfs_dta_drive(dt);if(marked>=2)d=drive_numbers[marked];
        for(unsigned j=0;j<11;j++)for(unsigned i=0;i<SEARCHES;i++)if(contexts[j].search_owners[i]==dt && dt)d=drive_numbers[j];
    }else if(op==0x3e || op==0x3f || op==0x40 || op==0x45 || op==0x42 || op==0x57 || op==0x46){
        unsigned h=be16(a+((op==0x42 || op==0x57)?6:2));
        if(h>=0x6000 && h<0x6000+11*HANDLES)d=drive_numbers[(h-0x6000)/HANDLES];
        if(op==0x46){h=be16(a+4);if(h>=0x6000 && h<0x6000+11*HANDLES)d=drive_numbers[(h-0x6000)/HANDLES];}
    }
    for(unsigned j=0;j<11;j++)if(d==drive_numbers[j] && (j<2 || drive_active[j]))return j;
    return 0;
}
int32_t r03_dispatch(const uint8_t *a){
    selected=0;
    if(!activation && (be16(a)==0x4e || be16(a)==0x3d)){
        uint32_t boot=r05_boot_drive();
        /* TOS may search A: even with no physical floppy. Do not require
         * an A/B bitmap bit, and never synthesize a floppy or change bootdev.
         * Existing hard-disk activation still requires its published bit. */
        unsigned desktop= (boot<2 || boot==0xffffu) &&
            !(r03_drive_bits()&0x03fffffcu) && desktop_config(R03_POINTER(be32(a+2)));
        if(desktop || (be16(a)==0x4e && boot<26 &&
           (boot<2 || (r03_drive_bits()&(1u<<boot))) &&
           boot_search(R03_POINTER(be32(a+2))))){
            r18_console(desktop ? "[F33] Activation: desktop file lookup\r\n" :
                "[F33] Activation: AUTO/ACC search\r\n");
            r06_diag[D_GATES]++;
            r06_diag[D_BOOT]=boot;
            r06_diag[D_BITS_BEFORE]=r03_drive_bits();
            activation=2;
            /* Publish SIDEETH only after native disk detection reaches AUTO/ACC.
             * Cartridge entry must leave the boot-time cookie jar untouched. */
            r20_install();
            r06_diag[D_PREPARES]++;
            r18_console("[..] Mounting microSD card...");
            int32_t result=r03_prepare();
            r06_diag[D_MOUNT_RESULT]=(uint32_t)result;
            r06_diag[D_MOUNT_STAGE]=r06_diag[D_STAGE];
            r06_diag[D_MOUNT_SENT]=r06_diag[D_SENT];
            r06_diag[D_MOUNT_SEQ]=r06_diag[D_SEQ];
            r06_diag[D_MOUNT_REPLY]=r06_diag[D_REPLY];
            if(result==0){
                r18_console("\r[OK] Mounting microSD card... ready\r\n");
                r05_publish_drive();activation=1;r06_diag[D_REASON]=A_ACTIVE;
                selected=1;
                if(r03_prepare()==0){settings_active=1;r12_publish_settings();}
                r18_console("[..] Checking drive table...\r\n");
                selected=0;r13_activate();
                r18_drives();
            }
            else if(r06_diag[D_BITS_BEFORE]&0x8000)r06_diag[D_REASON]=A_OCCUPIED;
            else if(r06_diag[D_STAGE]==W_NOT_READY)r06_diag[D_REASON]=A_READY_EXHAUSTED;
            else if(r06_diag[D_STAGE]!=W_VALID)r06_diag[D_REASON]=A_TRANSPORT;
            else if(r06_diag[D_REPLY_RESULT])r06_diag[D_REASON]=A_SERVICE;
            else r06_diag[D_REASON]=A_BAD_MOUNT;
            if(result!=0)r18_console("\r[KO] microSD drive unavailable; native drives retained.\r\n");
            r06_diag[D_STATE]=activation;
            r06_diag[D_BITS_AFTER]=r03_drive_bits();
            r06_diag[D_FAILED]=failed;
        }
    }
    if(be16(a)==0x4e){
        /* A reused DTA retires both drives' previous search ownership. */
        void *dt=r03_native_dta();
        if(tnfs_dta_drive(dt)>=2)clear(dt,9);
        for(unsigned d=0;d<11;d++)for(unsigned i=0;i<SEARCHES;i++)
            if(contexts[d].search_owners[i]==dt){contexts[d].search_owners[i]=NULL;contexts[d].ended[i]=0;}
    }
    if(activation==1){if(be16(a)==0x2a || be16(a)==0x2c)r14_clock_calls=127;r14_clock_poll();}
    if(activation==1 && be16(a)==0x0e)return r26_select_drive(a);
    selected=select_call(a);
    if(selected==1 && !settings_active)return PASS;
    if(activation==1 && be16(a)==0x4b)return load_program((uint8_t *)a);
    if(activation==1){int32_t rw=selected==1?PASS:r08_dispatch(a);return rw==PASS?r03_core_dispatch(a):rw;}
    return PASS;
}
