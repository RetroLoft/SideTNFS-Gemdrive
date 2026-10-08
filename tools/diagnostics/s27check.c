/* Read-only F26 guard diagnostic. Requires F26 firmware; no memory writes
 * other than this program's own data and P:\S27CHECK.LOG. */
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <osbind.h>
static long log_handle=-1;
static uint32_t top,os,version,jar,key,run,bp,low,high,drive_byte,stage;
static uint8_t pdbytes[16];
static uint32_t read32(uint32_t a){return *(volatile uint32_t *)(uintptr_t)a;}
static int ram(uint32_t p,unsigned n){return !(p&1) && p>=0x800 && top>=n && p<=top-n;}
/* Supexec does not create a process, so p_run still identifies this tool. */
static long snapshot(void){
 unsigned i;stage=1;top=read32(0x42e);os=read32(0x4f2);
 if(top<0x1000 || top>0xe00000 || (os&1) ||
    !((os>=0xe00000 && os<=0xe7ffd0) || ram(os,48)))return 0;
 stage=2;version=*(volatile uint16_t *)(uintptr_t)(os+2);
 /* Collect the safe pointer evidence even if F26's version gate rejects. */
 if(version<0x0102)return 0;
 jar=read32(0x5a0);stage=3;
 if(jar){uint32_t cursor=jar;
   for(i=0;i<128;i++,cursor+=8){
     if(!ram(cursor,8))return 0;
     key=read32(cursor);if(!key)break;
     if(key==0x4d694e54UL || key==0x4d616758UL)return 0;
   }
   if(i==128)return 0;
 }
 stage=4;run=read32(os+40);if(!ram(run,4))return 0;
 stage=5;bp=read32(run);if(!ram(bp,256))return 0;
 low=read32(bp);high=read32(bp+4);
 for(i=0;i<16;i++)pdbytes[i]=*(volatile uint8_t *)(uintptr_t)(bp+48+i);
 drive_byte=pdbytes[7];stage=6;
 return 0;
}
static void report(const char *name,long value){
 char text[128];int n=sprintf(text,"%s: %ld (0x%08lx)\r\n",name,value,(unsigned long)value);
 (void)Cconws(text);if(log_handle>=0)(void)Fwrite((short)log_handle,n,text);
}
static void dump(void){
 unsigned i;char label[32];
 top=os=version=jar=key=run=bp=low=high=drive_byte=stage=0;memset(pdbytes,0,sizeof(pdbytes));
 (void)Supexec(snapshot);
 report("Snapshot stage",stage);report("ST-RAM top",top);report("OS header",os);
 report("TOS version",version);report("Cookie jar",jar);report("Last cookie key",key);
 report("p_run pointer",run);report("Current basepage",bp);report("p_lowtpa",low);
 report("p_hitpa",high);report("Drive byte at +55",drive_byte);
 if(stage==6)for(i=0;i<16;i++){sprintf(label,"PD byte +%u",48+i);report(label,pdbytes[i]);}
}
int main(void){
 long old,result,h;char data[64];
 (void)Cconws("\r\nS27 F26 selection guard diagnostic\r\n");
 log_handle=Fcreate("P:\\S27CHECK.LOG",0);report("Log handle",log_handle);
 old=Dgetdrv();report("Initial drive",old);dump();
 result=Dsetdrv(18);report("Dsetdrv S result",result);report("Current drive after S",Dgetdrv());dump();
 h=Fopen("S:\\README.TXT",0);report("Explicit S open",h);
 if(h>=0){report("Explicit S read",Fread((short)h,sizeof(data),data));(void)Fclose((short)h);}
 report("Restore result",Dsetdrv((short)old));report("Restored drive",Dgetdrv());
 if(log_handle>=0)(void)Fclose((short)log_handle);
 (void)Cconws("Saved P:\\S27CHECK.LOG. Press a key.\r\n");(void)Cconin();return 0;
}
