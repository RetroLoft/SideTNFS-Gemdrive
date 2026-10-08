; SIDETNFS recovery gate R10. GPL-3.0, same license as this repository.
; Assemble twice with -DRECOVERY_HOOK=0 (control) / 1 (trace hook).
; No GEMDRIVE protocol, virtual drives, XBIOS hook, bootdev/nflops writes,
; filesystem routing or AUTO execution. TOS/HDDRIVER retain those jobs.
;
; Cartridge enters after GEMDOS initialization, before disk boot (bit 27).
; Resident block is allocated by GEMDOS and never freed by this cartridge.
; All resident references are PC-relative or offsets from its own base.
; The hook retains the first 128 selected calls; overflow increments dropped.

CAPACITY        equ 512
RECORD_SIZE     equ 96
HEADER_SIZE     equ 64
TRACE_BUFFER_BYTES equ CAPACITY*RECORD_SIZE
TRACE_RAM_SIZE equ resident_end-resident_start+TRACE_BUFFER_BYTES
TRACE_HANDLER_OFFSET equ handler-resident_start+TRACE_BUFFER_BYTES
H_COUNT         equ 24
H_DROPPED       equ 28
H_OLD           equ 32
H_HOOK          equ 36
H_PHYSTOP       equ 44
H_FREEZE        equ 48

    org $FA0000
    dc.l $abcdef42,0
    dc.l $08000000+cart_init
    dc.l 0
    dc.w 0,$5d29                  ; fixed 2026-09-09, deterministic header
    dc.l image_end-cart_init
    dc.b "SREC",0
    even
cart_init:
    movem.l d0-d7/a0-a6,-(sp)
    ifeq RECOVERY_HOOK
    pea control_message(pc)
    move.w #9,-(sp)
    trap #1
    addq.l #6,sp
    else
    ; Discover frame size and whether copied code needs a CACR flush.
    ; _CPU is preferable; early TOS 4 initialization may lack cookies.
    moveq #0,d6                   ; frame extension: 0 (68000), 2 (68010+)
    moveq #0,d7                   ; needs instruction/data cache flush
    tst.w $59e.w
    beq.s .cookies
    moveq #2,d6
.cookies:
    move.l $5a0.w,d0
    beq.s .tos_fallback
    move.l d0,a0
.cookie_loop:
    move.l (a0)+,d0
    beq.s .tos_fallback
    cmp.l #'_CPU',d0
    beq.s .cpu
    addq.l #4,a0
    bra.s .cookie_loop
.cpu:
    move.l (a0),d0
    tst.l d0
    beq.s .allocate
    moveq #2,d6
    cmp.l #20,d0
    blt.s .allocate               ; 68010 has a format word but no CACR
    moveq #1,d7
    bra.s .allocate
.tos_fallback:
    move.l $4f2.w,d0
    beq.s .allocate
    move.l d0,a0
    move.w 2(a0),d0               ; OSHEADER.os_version
    and.w #$ff00,d0
    cmp.w #$0400,d0
    bne.s .allocate
    moveq #2,d6                   ; TOS 4 Falcon, even before _CPU exists
    moveq #1,d7
.allocate:
    move.l #TRACE_RAM_SIZE,-(sp)
    move.w #$48,-(sp)             ; Malloc, default ST-RAM on TOS
    trap #1
    addq.l #6,sp
    tst.l d0
    ble .allocation_failed
    move.l d0,a3
    lea resident_start(pc),a0
    move.l a3,a1
    ; Preserve the established dump ABI: header, 512 records, then hook.
    ; Only header + hook are stored in ROM; create empty records in RAM.
    move.w #HEADER_SIZE/2-1,d0
.copy_header:
    move.w (a0)+,(a1)+
    dbf d0,.copy_header
    move.w #TRACE_BUFFER_BYTES/4-1,d0
.zero_records:
    clr.l (a1)+
    dbf d0,.zero_records
    move.w #(resident_end-records)/2-1,d0
.copy_hook:
    move.w (a0)+,(a1)+
    dbf d0,.copy_hook
    move.w d6,22(a3)
    move.l $42e.w,H_PHYSTOP(a3)
    move.l a3,a2
    adda.l #TRACE_HANDLER_OFFSET,a2
    move.l a2,H_HOOK(a3)
    ; Publish only after all state and code exist. Keep the genuine vector
    ; in the XBRA header in RAM; no Pico reconstruction or low-RAM stash.
    move.w sr,-(sp)
    ori.w #$0700,sr
    move.l $84.w,d0
    move.l d0,H_OLD(a3)
    move.l d0,old_handler-handler(a2)
    move.l d0,chain_target-handler(a2)
    tst.w d7
    beq.s .install
    dc.w $4e7a,$0002              ; movec cacr,d0 (68020+ only)
    ori.w #$0808,d0
    dc.w $4e7b,$0002              ; movec d0,cacr
.install:
    move.l a2,$84.w
    move.w (sp)+,sr
    jsr r05_load
    bra.s .boot_done
.allocation_failed:
    pea error_message(pc)
.print:
    move.w #9,-(sp)
    trap #1
    addq.l #6,sp
.boot_done:
    endif
    movem.l (sp)+,d0-d7/a0-a6
    rts

control_message: dc.b 13,10,"SideTNFS multidrive - control build",13,10,0
error_message: dc.b 13,10,"[KO] GEMDRIVE allocation failed; native drives retained",13,10,0
    even

resident_start:
    dc.b "SIDETNFSRECOV001"
    dc.w 1,RECORD_SIZE,CAPACITY,0
    dc.l 0,0,0,0,0,0             ; count, dropped, old, hook, snapshot vector, phystop
    dc.w 0                       ; freeze (set by dump utility)
    dcb.b HEADER_SIZE-50,0
records:
    ; Record storage exists only in the allocated RAM block.
    ; The following XBRA/hook bytes are copied after that zeroed storage.
    dc.l 'XBRA','STR1'
old_handler:
    dc.l 0
handler:
    move.w sr,-(sp)
    movem.l d0-d7/a0-a6,-(sp)     ; 60 bytes + saved live SR = 62
    lea handler(pc),a3
    suba.l #TRACE_HANDLER_OFFSET,a3
    tst.w H_FREEZE(a3)
    bne .chain
    lea 62(sp),a1                ; original exception frame, never rewritten
    btst #5,(a1)                 ; S bit in saved exception SR
    beq.s .user
    lea 6(a1),a0
    adda.w 22(a3),a0             ; format word belongs to SSP only
    bra.s .arguments
.user:
    move.l usp,a0                ; USP already points directly to opcode
.arguments:
    move.w (a0),d0
    cmp.w #$0e,d0                ; Dsetdrv
    beq.s .selected
    cmp.w #$19,d0                ; Dgetdrv
    beq.s .selected
    cmp.w #$1a,d0                ; Fsetdta
    beq.s .selected
    cmp.w #$3b,d0                ; Dsetpath
    beq.s .selected
    cmp.w #$3d,d0                ; Fopen (ACC/NEWDESK.INF, etc.)
    beq.s .selected
    cmp.w #$4b,d0                ; Pexec
    beq.s .selected
    cmp.w #$4e,d0                ; Fsfirst
    beq.s .selected
    cmp.w #$4f,d0                ; Fsnext
    bne .chain
.selected:
    move.l H_COUNT(a3),d1
    cmp.l #CAPACITY,d1
    bcs.s .record
    addq.l #1,H_DROPPED(a3)
    bra .chain
.record:
    ; No nested GEMDOS, callbacks, UART or cart reads in this handler.
    move.l d1,d2
    mulu.w #RECORD_SIZE,d2
    lea records-resident_start(a3),a2
    adda.l d2,a2
    move.l d1,(a2)
    move.l $4ba.w,4(a2)          ; 200 Hz tick
    move.w d0,8(a2)
    move.w (a1),10(a2)
    move.l 2(a1),12(a2)          ; original caller PC
    move.w $446.w,16(a2)         ; bootdev
    move.w $4a6.w,18(a2)         ; nflops
    move.l $4c2.w,20(a2)         ; drvbits
    moveq #0,d2
    moveq #0,d3
    cmp.w #$0e,d0
    bne.s .not_drive
    move.w 2(a0),d3
    bra.s .fields
.not_drive:
    cmp.w #$1a,d0
    bne.s .not_dta
    move.l 2(a0),d2
    bra.s .fields               ; DTA pointer is not a pathname
.not_dta:
    cmp.w #$4b,d0
    bne.s .not_exec
    move.w 2(a0),d3
    tst.w d3
    beq.s .exec_path
    cmp.w #3,d3
    bne.s .fields               ; modes 4/5/6 must not dereference a filename
.exec_path:
    move.l 4(a0),d2
    bra.s .path
.not_exec:
    cmp.w #$3b,d0
    beq.s .simple_path
    cmp.w #$3d,d0
    beq.s .path_with_word
    cmp.w #$4e,d0
    bne.s .fields               ; no arguments for Fsnext/Dgetdrv
.path_with_word:
    move.w 6(a0),d3
.simple_path:
    move.l 2(a0),d2
.path:
    ; Only copy strings wholly inside known ST-RAM. Other pointers remain
    ; visible in the record; never probe MMIO/ROM/TT-RAM for diagnostics.
    cmp.l #$800,d2
    bcs.s .fields
    move.l d2,d4
    add.l #64,d4
    bcs.s .fields
    cmp.l H_PHYSTOP(a3),d4
    bhi.s .fields
    move.l d2,a4
    lea 32(a2),a5
    moveq #62,d4
.copy_path:
    move.b (a4)+,(a5)+
    beq.s .fields
    dbf d4,.copy_path
    ; Last byte stays zero from block initialization.
.fields:
    move.l d2,24(a2)
    move.l d3,28(a2)
    addq.l #1,H_COUNT(a3)        ; commit only after entry is complete
.chain:
    movem.l (sp)+,d0-d7/a0-a6
    move.w (sp)+,sr
    ; JMP does not alter the restored live CCR. A MOVE/PUSH + RTS would.
chain_jump:
    jmp $00000000               ; patched in our RAM copy before installation
chain_target equ chain_jump+2
                                ; original exception frame/USP unchanged
    even
resident_end:
    include "resident.inc"
    include "loader.s"
image_end:
