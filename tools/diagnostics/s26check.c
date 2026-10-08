/* Diskless S: current-drive diagnostic. Does not write settings or firmware. */
#include <stdio.h>
#include <string.h>
#include <osbind.h>
static long log_handle=-1;
static void report(const char *name,long value){
 char text[120];int n=sprintf(text,"%s: %ld\r\n",name,value);
 (void)Cconws(text);if(log_handle>=0)(void)Fwrite((short)log_handle,n,text);
}
int main(void){
 char path[128],data[64];long result,handle,old;
 (void)Cconws("\r\nSideTNFS S26 drive selection check\r\n");
 log_handle=Fcreate("P:\\S26CHECK.LOG",0);
 report("Log handle (P:\\S26CHECK.LOG)",log_handle);
 old=Dgetdrv();report("Initial Dgetdrv",old);
 report("Dsetdrv S returned bitmap",Dsetdrv(18));
 result=Dgetdrv();report("Dgetdrv after selecting S (expected 18)",result);
 memset(path,0,sizeof(path));report("Dgetpath explicit S",Dgetpath(path,19));
 report("Dsetpath explicit S root",Dsetpath("S:\\"));
 if(result==18)report("Dsetpath relative root on S",Dsetpath("\\"));
 else (void)Cconws("Skipped relative root: S was not selected.\r\n");
 handle=Fopen("S:\\README.TXT",0);report("Fopen S README read-only",handle);
 if(handle>=0){report("Fread S README",Fread((short)handle,sizeof(data),data));report("Fclose S README",Fclose((short)handle));}
 report("Restore original drive bitmap",Dsetdrv((short)old));
 report("Restored Dgetdrv",Dgetdrv());
 if(log_handle>=0)(void)Fclose((short)log_handle);
 (void)Cconws("Saved P:\\S26CHECK.LOG if writable.\r\nPress a key to exit.\r\n");(void)Cconin();return 0;
}
