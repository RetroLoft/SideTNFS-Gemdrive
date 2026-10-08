/* Atari console output only; no filesystem or network calls. */
extern void r18_console(const char *text);
void r18_banner(uint32_t tos_version){
    static const char hex[]="0123456789ABCDEF";
    char version[25];
    copy(version,"[..] TOS version: 0.00\r\n",sizeof(version));
    r18_console("\r\nSideTNFS Version 1.1.0 (Falcon F33)\r\n\r\nGEMDRIVE native driver\r\n\r\n");
    if(tos_version){
        version[18]=hex[(tos_version>>8)&15];
        version[20]=hex[(tos_version>>4)&15];version[21]=hex[tos_version&15];
        r18_console(version);
    }else r18_console("[..] TOS version: unavailable\r\n");
    r18_console("[OK] Set GEMDOS vector\r\n[OK] GEMDRIVE hook installed; drives pending activation\r\n");
}
static void r18_drives(void){
    char line[64];unsigned n=23;
    copy(line,"[..] Drives installed: ",n);
    for(unsigned d=2;d<26;d++){
        unsigned ours=(d==15 && activation==1)||(d==18 && settings_active);
        for(unsigned i=2;i<11;i++)if(drive_active[i] && drive_numbers[i]==d)ours=1;
        if(ours){line[n++]=(char)('A'+d);line[n++]=':';line[n++]=' ';}
    }
    line[n++]='\r';line[n++]='\n';line[n]=0;r18_console(line);
    r18_console("[..] Network/NTP initialization continues in background.\r\n");
}
