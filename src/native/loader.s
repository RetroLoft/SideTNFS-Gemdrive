; Included in the cartridge ROM after its trace image. All absolute labels
; here refer to immutable cartridge data; resident code is fully relocated.
r05_load:
    movem.l d0-d7/a0-a6,-(sp)
    move.l #R05_MEMORY,-(sp)
    move.w #$48,-(sp)
    trap #1
    addq.l #6,sp
    tst.l d0
    ble .failed
    move.l d0,a4
    lea r05_image+28,a0
    move.l a4,a1
    move.w #R05_COPY/2-1,d0
.copy:
    move.w (a0)+,(a1)+
    dbf d0,.copy
    move.w #R05_BSS-1,d0
.zero:
    clr.b (a1)+
    dbf d0,.zero
    lea r05_image+R05_RELOC,a0
    move.l (a0)+,d0
    beq.s .relocated
    move.l a4,a1
    adda.l d0,a1
    move.l a4,d1
.patch:
    add.l d1,(a1)
.next:
    moveq #0,d0
    move.b (a0)+,d0
    beq.s .relocated
    cmp.b #1,d0
    bne.s .advance
    adda.w #254,a1
    bra.s .next
.advance:
    adda.l d0,a1
    bra.s .patch
.relocated:
    tst.w d7
    beq.s .enter
    dc.w $4e7a,$0002
    ori.w #$0808,d0
    dc.w $4e7b,$0002
.enter:
    jsr (a4)                   ; ordinary subroutine, not Pexec/TSR startup
    bra.s .done
.failed:
    pea error_message
    move.w #9,-(sp)
    trap #1
    addq.l #6,sp
.done:
    movem.l (sp)+,d0-d7/a0-a6
    rts
    even
r05_image:
    incbin "resident.tos"
    even
