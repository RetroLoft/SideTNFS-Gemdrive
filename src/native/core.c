/* R03 single-task TOS read-only P: driver. GPL-3.0.
 * Loaded as a desktop TSR; assembly provides private supervisor stack and
 * transparent chaining. No filesystem call here executes programs. */
#include <stdint.h>
#include <stddef.h>
#define PASS ((int32_t)0x80000000u)
#define HANDLES 8
#define SEARCHES 32
#define PATHLEN 128
#define HANDLE_BASE (0x6000+selected*HANDLES)
extern uint32_t r03_native_drive(void);
extern void *r03_native_dta(void);
extern int r03_exchange(uint8_t,const uint8_t *,uint16_t,uint8_t *,uint16_t *);
extern uint32_t r03_drive_bits(void);

#ifndef R03_POINTER
#define R03_POINTER(n) ((void *)(uintptr_t)(n))
#endif
static uint16_t be16(const uint8_t *p){return (uint16_t)((p[0]<<8)|p[1]);}
static uint32_t be32(const uint8_t *p){return ((uint32_t)be16(p)<<16)|be16(p+2);}
static void put16(uint8_t *p,uint16_t n){p[0]=n>>8;p[1]=n;}
static void put32(uint8_t *p,uint32_t n){put16(p,n>>16);put16(p+2,n);}
static void copy(void *v,const void *s,unsigned n){uint8_t *d=v;const uint8_t *p=s;while(n--)*d++=*p++;}
static unsigned length(const char *s){unsigned n=0;while(s[n])n++;return n;}
static void clear(void *v,unsigned n){uint8_t *d=v;while(n--)*d++=0;}
static unsigned upper(unsigned c){return c>='a' && c<='z'?c-32:c;}
typedef struct {uint32_t position,size;uint16_t time,date;uint8_t used,mode;char path[PATHLEN];} file_handle;
/* Each drive owns handles, searches, cwd and session independently. */
static struct {file_handle handles[HANDLES];void *search_owners[SEARCHES];
    uint32_t touched[SEARCHES];uint8_t ended[SEARCHES],broken;char directory[PATHLEN];uint32_t sid;} contexts[11];
static unsigned selected;
static uint32_t search_clock;
/* TOS reserves DTA bytes 0..20 for search state. Preserve a terminal marker
 * without retaining every exact lookup in the bounded active-search table. */
static int tnfs_dta_drive(const void *v){
    if(!v)return -1;const uint8_t *p=v;
    return be32(p)==0x52313345u && be32(p+4)==0xadceccbAu && p[8]>=2 && p[8]<11?(int)p[8]:-1;
}
static void tnfs_dta_mark(void *v){uint8_t *p=v;put32(p,0x52313345u);put32(p+4,0xadceccbaU);p[8]=(uint8_t)selected;}
static int exact_name(const char *s){for(;*s;s++)if(*s=='*' || *s=='?')return 0;return 1;}

static uint8_t drive_numbers[11]={15,18};
static uint8_t drive_active[11];
#define files (contexts[selected].handles)
#define owners (contexts[selected].search_owners)
#define terminal (contexts[selected].ended)
#define cwd (contexts[selected].directory)
#define session (contexts[selected].sid)
#define failed (contexts[selected].broken)
static char path[PATHLEN];
static uint8_t request[256],reply[512];
static uint16_t reply_len;
static unsigned drive_number(void){return drive_numbers[selected];}

static int virtual_path(const char *p){
    if(p[0] && p[1]==':')return upper((uint8_t)p[0])=='A'+drive_number();
    return r03_native_drive()==drive_number();
}
/* Pure canonicalizer, also compiled into the host regression tests. */
static int normalize(const char *input,char *out){
    unsigned used=1;out[0]='\\';out[1]=0;
    if(input[0] && input[1]==':')input+=2;
    if(*input!='\\' && *input!='/'){used=length(cwd);copy(out,cwd,used+1);}
    while(*input){
        while(*input=='\\' || *input=='/')input++;
        if(!*input)break;
        const char *start=input;unsigned n=0;
        while(*input && *input!='\\' && *input!='/'){
            unsigned c=(uint8_t)*input++;
            if(c<32 || c>=127 || c==':' || ++n>=PATHLEN)return -34;
        }
        if(n==1 && start[0]=='.')continue;
        if(n==2 && start[0]=='.' && start[1]=='.'){
            if(used>1){while(used>1 && out[used-1]!='\\')used--;if(used>1)used--;}
            out[used]=0;continue;
        }
        if(used>1){if(used>=PATHLEN-1)return -34;out[used++]='\\';}
        if(used+n>=PATHLEN)return -34;
        for(unsigned i=0;i<n;i++)out[used++]=(char)upper((uint8_t)start[i]);
        out[used]=0;
    }
    return 0;
}
static int32_t command(uint8_t op,unsigned n){
    if(failed)return -46;
    if(op!=16)put32(request,session);
    if(r03_exchange((uint8_t)(op+selected*16),request,(uint16_t)n,reply,&reply_len) || reply_len<4){failed=1;return -65;}
    int32_t result=(int32_t)be32(reply);
    if(result==-46 || (selected>=2 && result==-65))failed=1; /* Never keep using stale state after Pico reset. */
    return result;
}
static int32_t stat_path(void){
    unsigned n=length(path)+1;copy(request+4,path,n);
    int32_t result=command(17,4+n);
    if(result==0 && reply_len!=16){failed=1;return -65;}
    return result;
}
int32_t r03_prepare(void){
    if(r03_drive_bits()&(1u<<drive_number()))return -46;
    cwd[0]='\\';cwd[1]=0;
    int32_t result=command(16,0);
    if(result)return result;
    if(reply_len!=8 || !(session=be32(reply+4)))return -65;
    return 0;
}
static int handle_index(uint16_t h){
    if(h<HANDLE_BASE || h>=HANDLE_BASE+HANDLES)return -1;
    return files[h-HANDLE_BASE].used?(int)(h-HANDLE_BASE):-1;
}
static int owner_index(void *dta){for(unsigned i=0;i<SEARCHES;i++)if(owners[i]==dta)return (int)i;return -1;}
static int drive_arg(uint16_t n){return n==0?r03_native_drive()==drive_number():n==drive_number()+1;}

int32_t r03_dispatch(const uint8_t *a){
    unsigned op=be16(a);const char *name;int index;int32_t result;
    /* Fsfirst is the ownership boundary even when its new path is native.
     * Retiring locally needs no cartridge transaction on that native path.
     * Remote DIR slots are bounded and closed before their next reuse. */
    if(op==0x4e){
        void *dta=r03_native_dta();index=owner_index(dta);
        if(index>=0){owners[index]=NULL;terminal[index]=0;}
        name=R03_POINTER(be32(a+2));if(!virtual_path(name))return PASS;
        if(!dta)return -65;
        if(selected>=2){
            tnfs_dta_mark(dta);
            if(normalize(name,path))return -34;
            if(exact_name(path)){
                /* STAT avoids a directory walk and consumes no search handle,
                 * regardless of the file's position in a large directory. */
                result=stat_path();if(result)return result;
                unsigned attr=be16(reply+4),wanted=be16(a+6);
                if((wanted&8) || (attr&0x16&~wanted))return -33;
                const char *base=path;for(const char *q=path;*q;q++)if(*q=='\\')base=q+1;
                if(!*base || length(base)>12)return -33;
                clear((uint8_t *)dta+21,23);((uint8_t *)dta)[21]=(uint8_t)attr;
                copy((uint8_t *)dta+22,reply+6,4);copy((uint8_t *)dta+26,reply+12,4);
                copy((uint8_t *)dta+30,base,length(base)+1);return 0;
            }
        }
        if(index<0)for(unsigned i=0;i<SEARCHES;i++)if(!owners[i]){index=(int)i;break;}
        if(index<0 && selected>=2){
            /* Prefer ended searches; otherwise evict the least recently used.
             * Never write through an old DTA pointer: its owner may have exited. */
            uint32_t age=0;index=0;
            for(unsigned i=0;i<SEARCHES;i++){
                if(terminal[i]){index=(int)i;break;}
                uint32_t candidate=search_clock-contexts[selected].touched[i];
                if(candidate>=age){age=candidate;index=(int)i;}
            }
        }
        if(index<0)return -39;
        contexts[selected].touched[index]=++search_clock;
        owners[index]=dta;terminal[index]=1;
        if(normalize(name,path))return -34;
        put16(request+4,(uint16_t)index);put16(request+6,be16(a+6));
        unsigned n=length(path)+1;copy(request+8,path,n);
        result=command(18,8+n);
        if(result==0){if(reply_len!=48)return -65;copy(dta,reply+4,44);terminal[index]=0;if(selected>=2)tnfs_dta_mark(dta);}
        return result;
    }
    if(op==0x4f){
        void *dta=r03_native_dta();index=owner_index(dta);
        if(index<0)return tnfs_dta_drive(dta)==(int)selected?-49:PASS;
        contexts[selected].touched[index]=++search_clock;
        if(terminal[index])return -49;
        put16(request+4,(uint16_t)index);result=command(19,6);
        if(result==0){if(reply_len!=48)return -65;copy(dta,reply+4,44);if(selected>=2)tnfs_dta_mark(dta);}
        else terminal[index]=1;
        return result;
    }
    if(op==0x3b || op==0x3d || op==0x43 || op==0x39 || op==0x3a || op==0x3c || op==0x41){
        name=R03_POINTER(be32(a+2));if(!virtual_path(name))return PASS;
        if(op==0x39 || op==0x3a || op==0x3c || op==0x41 ||
           (op==0x3d && be16(a+6)!=0) || (op==0x43 && be16(a+6)!=0))return -36;
        if(normalize(name,path))return -34;
        result=stat_path();if(result)return op==0x3b && result==-33?-34:result;
        if(op==0x43)return be16(reply+4);
        if(op==0x3b){if(!(be16(reply+4)&16))return -34;copy(cwd,path,length(path)+1);return 0;}
        if(be16(reply+4)&16)return -36;
        if(be32(reply+12)>0x7fffffffu)return -36;
        for(unsigned i=0;i<HANDLES;i++)if(!files[i].used){
            files[i].mode=0;files[i].used=1;files[i].position=0;files[i].size=be32(reply+12);
            files[i].time=be16(reply+6);files[i].date=be16(reply+8);
            copy(files[i].path,path,length(path)+1);return HANDLE_BASE+(int32_t)i;
        }
        return -35;
    }
    if(op==0x47){
        if(!drive_arg(be16(a+6)))return PASS;
        if(failed)return -46;
        /* Match the local v6 backend: leading backslash for subdirectories,
         * empty string for the root, and no trailing separator. */
        const char *current=cwd[1]?cwd:"";
        copy(R03_POINTER(be32(a+2)),current,length(current)+1);return 0;
    }
    if(op==0x36){
        if(!drive_arg(be16(a+6)))return PASS;
        result=command(21,4);if(result)return result;
        if(reply_len!=20)return -65;copy(R03_POINTER(be32(a+2)),reply+4,16);return 0;
    }
    if(op==0x4b){
        unsigned mode=be16(a+2);if(mode!=0 && mode!=3)return PASS;
        return virtual_path(R03_POINTER(be32(a+4)))?-36:PASS;
    }
    if(op==0x56){return (virtual_path(R03_POINTER(be32(a+4))) || virtual_path(R03_POINTER(be32(a+8))))?-36:PASS;}
    if(op==0x46){return (handle_index(be16(a+2))>=0 || handle_index(be16(a+4))>=0)?-32:PASS;}
    if(op==0x3e || op==0x3f || op==0x40 || op==0x45 || op==0x42 || op==0x57){
        index=handle_index(be16(a+((op==0x42 || op==0x57)?6:2)));
        if(index<0)return PASS;
        file_handle *f=&files[index];
        if(op==0x3e){clear(f,sizeof(*f));return 0;}
        if(op==0x40)return -36;
        if(op==0x3f && f->mode==1)return -36;
        if(op==0x45)return -32;
        if(op==0x57){if(be16(a+8))return -36;uint8_t *p=R03_POINTER(be32(a+2));put16(p,f->time);put16(p+2,f->date);return 0;}
        if(op==0x42){
            uint16_t mode=be16(a+8);if(mode>2)return -32;
            uint32_t base=mode==0?0:mode==1?f->position:f->size;
            int32_t delta=(int32_t)be32(a+2);uint32_t pos;
            if(delta<0){uint32_t n=0u-(uint32_t)delta;if(n>base)return -64;pos=base-n;}
            else{if((uint32_t)delta>0x7fffffffu-base)return -64;pos=base+(uint32_t)delta;}
            f->position=pos;return (int32_t)pos;
        }
        uint32_t count=be32(a+4),done=0;uint8_t *dest=R03_POINTER(be32(a+8));
        if(count>0x7fffffffu)return -32;
        while(done<count){
            unsigned chunk=count-done>508?508:(unsigned)(count-done);
            put32(request+4,f->position);put16(request+8,(uint16_t)chunk);
            unsigned n=length(f->path)+1;copy(request+10,f->path,n);
            result=command(20,10+n);
            if(result<0)return done?(int32_t)done:result;
            if((uint32_t)result>chunk || reply_len!=4+(unsigned)result){failed=1;return done?(int32_t)done:-65;}
            copy(dest+done,reply+4,(unsigned)result);done+=(unsigned)result;f->position+=(unsigned)result;
            if((unsigned)result<chunk)break;
        }
        return (int32_t)done;
    }
    return PASS;
}
