/* R14 native mutations and metadata. SD and TNFS backends enforce their
 * own capabilities; uncertain writes retain the existing fail-closed policy. */
static int r08_scope(const char *p){
    return selected!=1 && p[0]=='\\';
}
static int r08_busy(const char *p,int writers_only){
    for(unsigned i=0;i<HANDLES;i++)if(files[i].used && (!writers_only || files[i].mode)){
        unsigned j=0;while(p[j] && p[j]==files[i].path[j])j++;
        if(!p[j] && !files[i].path[j])return 1;
    }return 0;
}
static int32_t r08_mutate(unsigned op,unsigned n){
    int32_t r=command((uint8_t)op,n);
    if(reply_len!=4 && !failed){failed=1;return -65;}
    if(r==-65)failed=1;
    return r;
}
static int32_t r08_dispatch(const uint8_t *a){
    unsigned op=be16(a);int32_t result;const char *name;
    if(op==0x3c || op==0x3d || op==0x39 || op==0x3a || op==0x41){
        name=R03_POINTER(be32(a+2));if(!virtual_path(name))return PASS;
        if(normalize(name,path))return -34;
        if(op==0x3d && be16(a+6)==0)return r08_busy(path,1)?-36:PASS;
        if(!r08_scope(path))return -36;
        if(failed)return -46;
        if(r08_busy(path,0))return -36;
        unsigned n=length(path)+1;
        if(op==0x39 || op==0x3a || op==0x41){
            if(op==0x39){copy(request+4,path,n);return r08_mutate(24,4+n);}
            put16(request+4,op==0x3a?1:0);copy(request+6,path,n);
            /* Root and ancestors of cwd stay protected. An empty cwd may
             * be removed; only on success move our per-drive cwd to parent. */
            unsigned same=0;
            if(op==0x3a){unsigned j=0;while(path[j] && path[j]==cwd[j])j++;
                if(!path[1] || (!path[j] && cwd[j]=='\\'))return -36;
                same=!path[j] && !cwd[j];}
            result=r08_mutate(25,6+n);
            if(!result && same){unsigned j=length(cwd);while(j>1 && cwd[j-1]!='\\')j--;cwd[j>1?j-1:1]=0;}
            return result;
        }
        unsigned mode=op==0x3c?2:be16(a+6);
        if(mode>2)return -32;
        if(op==0x3c && be16(a+6)!=0)return -36; /* ordinary files only */
        int slot=-1;for(unsigned i=0;i<HANDLES;i++)if(!files[i].used){slot=(int)i;break;}
        if(slot<0)return -35; /* no truncation until a handle is available */
        uint32_t size=0;uint16_t time=0,date=0;
        if(op==0x3c){copy(request+4,path,n);result=r08_mutate(22,4+n);if(result)return result;}
        else{result=stat_path();if(result)return result;
            if(be16(reply+4)&(16|1) || be32(reply+12)>0x7fffffffu)return -36;
            size=be32(reply+12);time=be16(reply+6);date=be16(reply+8);}
        file_handle *f=&files[slot];clear(f,sizeof(*f));f->used=1;f->mode=(uint8_t)mode;
        f->size=size;f->time=time;f->date=date;copy(f->path,path,n);return HANDLE_BASE+slot;
    }
    if(op==0x43 && be16(a+6)){
        name=R03_POINTER(be32(a+2));if(!virtual_path(name))return PASS;
        if(normalize(name,path))return -34;
        unsigned attr=be16(a+8);if(attr&~0x27u)return -36;
        if(failed)return -46;
        put16(request+4,attr);copy(request+6,path,length(path)+1);
        return r08_mutate(27,7+length(path));
    }
    if(op==0x57 && be16(a+8)){
        int i=handle_index(be16(a+6));if(i<0)return PASS;
        if(failed)return -46;
        const uint8_t *dt=R03_POINTER(be32(a+2));file_handle *h=&files[i];
        put16(request+4,be16(dt));put16(request+6,be16(dt+2));
        copy(request+8,h->path,length(h->path)+1);
        result=r08_mutate(28,9+length(h->path));
        if(!result){h->time=be16(dt);h->date=be16(dt+2);}return result;
    }
    if(op==0x56){
        const char *old=R03_POINTER(be32(a+4)),*newname=R03_POINTER(be32(a+8));
        int ov=virtual_path(old),nv=virtual_path(newname);if(!ov && !nv)return PASS;
        if(!ov || !nv)return -48;
        if(be16(a+2))return -32;
        if(normalize(old,path))return -34;
        if(!r08_scope(path) || r08_busy(path,0))return -36;
        unsigned n=length(path)+1;copy(request+6,path,n);
        if(normalize(newname,path))return -34;
        if(!r08_scope(path) || r08_busy(path,0))return -36;
        unsigned m=length(path)+1;if(6+n+m>sizeof(request))return -34;
        put16(request+4,(uint16_t)n);copy(request+6+n,path,m);return r08_mutate(26,6+n+m);
    }
    if(op==0x40){
        int i=handle_index(be16(a+2));if(i<0)return PASS;
        file_handle *f=&files[i];if(!f->mode)return -36;
        if(failed)return -46;
        uint32_t count=be32(a+4),done=0;
        if(count>0x7fffffffu-f->position)return -64;
        if(f->position>f->size)return -64; /* no uninitialised holes */
        const uint8_t *src=R03_POINTER(be32(a+8));
        unsigned n=length(f->path)+1,limit=256-12-n;
        while(done<count){unsigned chunk=count-done>limit?limit:(unsigned)(count-done);
            put32(request+4,f->position);put16(request+8,(uint16_t)n);put16(request+10,(uint16_t)chunk);
            copy(request+12,f->path,n);copy(request+12+n,src+done,chunk);
            result=r08_mutate(23,12+n+chunk);
            if(result<0)return done?(int32_t)done:result;
            if((unsigned)result>chunk){failed=1;return done?(int32_t)done:-65;}
            done+=(unsigned)result;f->position+=(unsigned)result;
            if(f->size<f->position)f->size=f->position;
            if((unsigned)result<chunk)break;
        }return (int32_t)done;
    }
    if(op==0x3e){int i=handle_index(be16(a+2));
        if(i>=0 && files[i].mode && failed){clear(&files[i],sizeof(files[i]));return -65;}}
    return PASS;
}
