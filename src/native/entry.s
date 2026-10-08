; Native cartridge resident GEMDRIVE entry and GEMDOS hook. GPL-3.0.
; Loader supplies d7=cache flush required and relocated/zeroed ST-RAM.
    section text
    xdef _start,_r03_native_drive,_r03_native_dta,_r03_drive_bits,_r03_delay
    xref _r03_dispatch,_r06_diag,_r18_banner,_r20_bus_ptr
_start:
    move.l #'R10A',_r06_diag
    move.l #2,_r06_diag+4
    move.l #128,_r06_diag+8
    move.l #$13579bdf,_r06_diag+112
    move.l #$2468ace0,_r06_diag+116
    move.l #$55aa55aa,_r06_diag+120
    move.l #$aa55aa55,_r06_diag+124
    move.l #_r06_diag,52(a3)
    move.l #'R10D',56(a3)
    move.l #128,60(a3)
    move.w d7,cache_flush
    bsr install
    moveq #0,d0
    move.l $4f2.w,a0
    cmpa.l #0,a0
    beq.s .banner
    move.w 2(a0),d0
.banner:
    move.l d0,-(sp)
    jsr _r18_banner
    addq.l #4,sp
    rts

    xdef _r18_console
_r18_console:
    movem.l d0-d7/a0-a6,-(sp)
    move.l 64(sp),-(sp)
    move.w #9,-(sp)
    trap #1
    addq.l #6,sp
    movem.l (sp)+,d0-d7/a0-a6
    rts

install:
    movem.l d1-d7/a0-a6,-(sp)
    moveq #0,d6
    tst.w $59e.w
    beq.s .cookies
    moveq #2,d6
.cookies:
    move.l $5a0.w,d0
    beq.s .tos
    move.l d0,a0
.cookie:
    move.l (a0)+,d0
    beq.s .tos
    cmp.l #'_CPU',d0
    beq.s .cpu
    addq.l #4,a0
    bra.s .cookie
.cpu:
    tst.l (a0)
    beq.s .prepare
    moveq #2,d6
    bra.s .prepare
.tos:
    move.l $4f2.w,a0
    move.w 2(a0),d0
    and.w #$ff00,d0
    cmp.w #$0400,d0
    bne.s .prepare
    moveq #2,d6
.prepare:
    move.w d6,frame_extra
    ; SD activation is deferred to the native AUTO/ACC search.
    move.w sr,-(sp)
    ori.w #$0700,sr
    move.l $84.w,d0
    move.l d0,old_vector
    move.l d0,chain_target
    tst.w cache_flush
    beq.s .publish
    dc.w $4e7a,$0002
    ori.w #$0808,d0
    dc.w $4e7b,$0002
.publish:
    move.l #handler,$84.w
    ; P: is advertised only after the deferred mount succeeds.
    ;         ; preserve every existing drive bit
    move.w (sp)+,sr
    moveq #0,d0
.done:
    movem.l (sp)+,d1-d7/a0-a6
    rts

    dc.l 'XBRA','SR10'
old_vector: dc.l 0
handler:
    move.w sr,-(sp)
    movem.l d0-d7/a0-a6,-(sp)
    tst.b busy
    bne.s chain
    lea 62(sp),a1
    btst #5,(a1)
    beq.s .user
    lea 6(a1),a0
    adda.w frame_extra,a0
    bra.s .dispatch
.user:
    move.l usp,a0
.dispatch:
    move.b #1,busy
    move.l sp,outer_sp
    lea driver_stack_end,sp
    move.l a0,-(sp)
    jsr _r03_dispatch
    addq.l #4,sp
    move.l outer_sp,sp
    clr.b busy
    cmp.l #$80000000,d0
    beq.s chain
    move.l d0,(sp)              ; replace only saved GEMDOS result d0
    movem.l (sp)+,d0-d7/a0-a6
    move.w (sp)+,sr
    rte                        ; original 68000/68010+ exception frame
chain:
    movem.l (sp)+,d0-d7/a0-a6
    move.w (sp)+,sr
chain_jump:
    jmp $00000000              ; no CCR or exception-frame alteration
chain_target equ chain_jump+2

_r03_native_drive:
    movem.l d1-d7/a0-a6,-(sp)
    move.w #$19,-(sp)
    trap #1
    addq.l #2,sp
    and.l #$ffff,d0
    movem.l (sp)+,d1-d7/a0-a6
    rts
_r03_native_dta:
    movem.l d1-d7/a0-a6,-(sp)
    move.w #$2f,-(sp)
    trap #1
    addq.l #2,sp
    movem.l (sp)+,d1-d7/a0-a6
    rts
_r03_drive_bits:
    move.l $4c2.w,d0
    rts
_r03_delay:
    move.l d2,-(sp)
    move.w #80,d2
.loop:
    dbf d2,.loop
    move.l (sp)+,d2
    rts

    xdef _r05_boot_drive,_r05_publish_drive
_r05_boot_drive:
    moveq #0,d0
    move.w $446.w,d0
    rts
_r05_publish_drive:
    move.w sr,-(sp)
    ori.w #$0700,sr
    ori.l #$8000,$4c2.w
    move.w (sp)+,sr
    rts

    xdef _r12_publish_settings
_r12_publish_settings:
    move.w sr,-(sp)
    ori.w #$0700,sr
    ori.l #$40000,$4c2.w
    move.w (sp)+,sr
    rts

    xdef _r07_tos,_r07_cache,_r07_can_go
_r07_tos:
    move.l 4(sp),a0
    move.l 8(sp),d0
    movem.l d1-d7/a0-a6,-(sp)
    move.l sp,a6
    suba.l d0,sp
    move.l sp,a1
    subq.w #1,d0
.copy:
    move.b (a0)+,(a1)+
    dbf d0,.copy
    trap #1
    move.l a6,sp
    movem.l (sp)+,d1-d7/a0-a6
    rts
_r07_can_go:
    moveq #0,d0
    move.l $4f2.w,a0
    cmpa.l #0,a0
    beq.s .done
    cmp.w #$0104,2(a0)
    bcs.s .done
    moveq #1,d0
.done:
    rts
_r07_cache:
    move.l d0,-(sp)
    tst.w cache_flush
    beq.s .done
    dc.w $4e7a,$0002
    ori.w #$0808,d0
    dc.w $4e7b,$0002
.done:
    move.l (sp)+,d0
    rts
    section data
frame_extra: dc.w 0
cache_flush: dc.w 0
busy: dc.b 0
    even
    section bss
outer_sp: ds.l 1
driver_stack: ds.b 16384
driver_stack_end:

    text
    xdef _r13_publish
_r13_publish:
    move.l 4(sp),d0
    move.w sr,-(sp)
    ori.w #$0700,sr
    or.l d0,$4c2.w
    move.w (sp)+,sr
    rts

    section text
    xdef _r20_publish_jar,_r20_enter
_r20_publish_jar:
    move.w sr,-(sp)
    ori.w #$0700,sr
    move.l 6(sp),$5a0.w
    move.w (sp)+,sr
    rts
_r20_enter:
    move.w sr,-(sp)
    ori.w #$0700,sr
    moveq #0,d0
    move.l _r20_bus_ptr,a0
    tst.w 8(a0)
    bne.s .busy
    move.w #1,8(a0)
    moveq #1,d0
.busy:
    move.w (sp)+,sr
    rts
