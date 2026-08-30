; SideTNFS virtual floppy interception (Phase 4 MVP)
;
; High-level BIOS/XBIOS sector interception, same proven model the
; original SidecarTridge floppy emulator used (getbpb.vector/rwabs.vector/
; mediach.vector + XBIOS Floprd/Flopwr/Flopfmt/Flopver) -- NOT WD1772/FDC
; register emulation. Drive A: (disk_number 0) only, read-only. Does NOT
; hook hdv_boot (getbpb.vector/rwabs.vector interception alone already
; makes TOS's own native boot-sector read see the virtual image
; transparently -- see Phase 3D/3C's own research; this is exactly how
; the original SidecarTridge driver did it too, per its own floppy.s).
;
; Physical hard-disk bootstrap (dmaboot) suppression is explicitly OUT of
; scope for this phase (see the PHYSICAL_HD_BOOT_SUPPRESSION follow-up
; note in gemdrive.s) -- a boot-sector program that never returns from
; the virtual floppy is unaffected either way; an ordinary GEMDOS floppy
; whose boot sector returns, on a machine with a real physical bootable
; ACSI/SCSI/IDE disk attached, may still see that disk's own driver
; install afterward. Not addressed here.
;
; Installed independently of GEMDRIVE's own GEMDOS-trap/XBIOS install
; (see rom_function's own INSTALL_FLOPPY/INSTALL_GEMDRIVE gating) --
; INSTALL_FLOPPY=YES with INSTALL_GEMDRIVE=NO must work with zero GEMDRIVE
; involvement.

; ROM3 GEMDRVEMUL_FLOPPY_SESSION field offsets (must exactly match
; romemul/include/gemdrvemul.h on the Pico side -- no shared header
; between the two repos, hand-synced like every other GEMDRVEMUL_* offset
; already in this file).
; Base already bakes in ROM3_START_ADDR (matching every other GEMDRVEMUL_*
; equate in this project, e.g. GEMDRVEMUL_TIMEOUT_SEC's own chain from
; ROM_EXCHG_BUFFER_ADDR in gemdrive.s) -- these are absolute addresses,
; not offsets, so every use site below is a plain reference (no ".w"
; suffix, which would be wrong anyway: absolute-short addressing only
; covers -32768..32767, and these addresses are far larger).
GEMDRVEMUL_FLOPPY_SESSION              equ (ROM3_START_ADDR+39168)
GEMDRVEMUL_FLOPPY_SESSION_STATUS       equ (GEMDRVEMUL_FLOPPY_SESSION+0)   ; uint32_t, swapped long
GEMDRVEMUL_FLOPPY_SESSION_ACTIVE_SLOT  equ (GEMDRVEMUL_FLOPPY_SESSION+8)   ; uint32_t, swapped long
GEMDRVEMUL_FLOPPY_SESSION_INSTALL_GEMDRIVE equ (GEMDRVEMUL_FLOPPY_SESSION+12) ; uint16_t, plain word
GEMDRVEMUL_FLOPPY_SESSION_INSTALL_FLOPPY   equ (GEMDRVEMUL_FLOPPY_SESSION+14) ; uint16_t, plain word
GEMDRVEMUL_FLOPPY_SESSION_IMAGE_PATH   equ (GEMDRVEMUL_FLOPPY_SESSION+20)  ; char[512]
GEMDRVEMUL_FLOPPY_SESSION_SIDES        equ (GEMDRVEMUL_FLOPPY_SESSION+532) ; uint16_t, plain word
GEMDRVEMUL_FLOPPY_SESSION_SECTORS_PER_TRACK equ (GEMDRVEMUL_FLOPPY_SESSION+534) ; uint16_t, plain word
GEMDRVEMUL_FLOPPY_SESSION_TRACKS       equ (GEMDRVEMUL_FLOPPY_SESSION+536) ; uint16_t, plain word
GEMDRVEMUL_FLOPPY_SESSION_BYTES_PER_SECTOR equ (GEMDRVEMUL_FLOPPY_SESSION+538) ; uint16_t, plain word
GEMDRVEMUL_FLOPPY_SESSION_SECTOR_LBA   equ (GEMDRVEMUL_FLOPPY_SESSION+544) ; uint32_t, swapped long -- response echo only, see gemdrvemul.h
GEMDRVEMUL_FLOPPY_SESSION_SECTOR_DATA  equ (GEMDRVEMUL_FLOPPY_SESSION+548) ; uint8_t[512]
GEMDRVEMUL_FLOPPY_SESSION_OLD_HDV_BPB     equ (GEMDRVEMUL_FLOPPY_SESSION+1060) ; uint32_t, swapped long
GEMDRVEMUL_FLOPPY_SESSION_OLD_HDV_RW      equ (GEMDRVEMUL_FLOPPY_SESSION+1064) ; uint32_t, swapped long
GEMDRVEMUL_FLOPPY_SESSION_OLD_HDV_MEDIACH equ (GEMDRVEMUL_FLOPPY_SESSION+1068) ; uint32_t, swapped long
GEMDRVEMUL_FLOPPY_SESSION_OLD_XBIOS_VECTOR equ (GEMDRVEMUL_FLOPPY_SESSION+1072) ; uint32_t, swapped long -- floppy's OWN XBIOS chain-through value, separate from GEMDRIVE's own GEMDRVEMUL_OLD_XBIOS slot (no collision: each installer only ever touches its own field)
GEMDRVEMUL_FLOPPY_SESSION_BPB          equ (GEMDRVEMUL_FLOPPY_SESSION+1076) ; uint16_t[9] -- recsize,clsiz,clsizb,rdlen,fsiz,fatrec,datrec,numcl,bflags
GEMDRVEMUL_FLOPPY_SESSION_MEDIA_CHANGED equ (GEMDRVEMUL_FLOPPY_SESSION_BPB+18) ; uint16_t, plain word -- 0=unchanged, nonzero=report "definitely changed" once then ack it (Phase 4A)

; Command IDs (APP_GEMDRVEMUL << 8 | subcommand, matching commands.h)
CMD_FLOPPY_READ_SECTOR       equ ($2A + APP_GEMDRVEMUL)  ; request: LBA, caller PC -- diagnostic-only,
                                                          ; 0 if not tracked for the call path (8-byte payload,
                                                          ; was 4 bytes/LBA-only before hardware bring-up)
CMD_FLOPPY_SAVE_VECTORS      equ ($2C + APP_GEMDRVEMUL)  ; request: old getbpb/rwabs/mediach vectors (12-byte payload -- a plain send_sync call cannot carry a fourth)
CMD_FLOPPY_SAVE_XBIOS_VECTOR equ ($2D + APP_GEMDRVEMUL)  ; request: old XBIOS trap vector (4-byte payload) -- separate call, see commands.h's own comment
CMD_FLOPPY_MEDIA_CHANGE_ACK  equ ($2E + APP_GEMDRVEMUL)  ; zero payload -- clears GEMDRVEMUL_FLOPPY_SESSION_MEDIA_CHANGED back to 0

; Flopver = 19 decimal (0x13), NOT 13 decimal -- 13 decimal is Mfpint.
; Phase 4A correction: the original SidecarTridge driver's own floppy.s
; compares against decimal 13 and labels it Flopver -- an inherited bug,
; not preserved here.
Flopver equ 19

SIDETNFS_FLOPPY_EMUL_OK equ 0   ; must match sidetnfs_floppy_emul_status_t's SIDETNFS_FLOPPY_EMUL_OK on the Pico side

; ---------------------------------------------------------------------
; Disable/restore the Mega STE's 16MHz+cache around every ROM3 touch
; below, mirroring gemdrive.s's own gemdrive_trap_megaste16 entry
; sequence and restore_cpu_cache macro (see gemdrive.s:1157-1168,
; :287-294). ROM3 is bus-snooped by the Pico in real time, not real
; ROM -- ALL of it (this code's own instruction fetches, the
; GEMDRVEMUL_FLOPPY_SESSION_* fields, and the OLD_HDV_*/OLD_XBIOS_VECTOR
; chain-through addresses) is exposed to a stale Mega STE cache line if
; the cache is left enabled, silently desyncing the protocol instead of
; failing loudly. gemdrive.s's GEMDOS trap gets a MegaSTE-specific ENTRY
; POINT chosen once at install time (see save_vectors), so its disable
; needs no runtime hardware check; these hooks are the SAME code
; regardless of machine, so the Mega STE check has to happen here, at
; runtime, on every call -- the same check restore_cpu_cache already
; does.
;
; d4 holds the saved register value for a routine's entire body. Chosen
; because neither floppy_rwabs_emulated/floppy_xbios_rw's own local
; register use (d0-d3/d5-d7/a0), nor floppy_read_one_sector's own
; movem.l d1-d7/a1-a6 save/restore around each send_sync call, ever
; touches d4 -- it survives untouched end to end. Every
; disable_floppy_cache must be paired with exactly one
; restore_floppy_cache on every exit path that follows it, and a
; restore must always come AFTER the last ROM3 touch on that path, never
; before (restoring early re-enables the cache for the very read it was
; meant to protect).
disable_floppy_cache    macro
                    cmp.l #COOKIE_JAR_MEGASTE, (GEMDRVEMUL_SHARED_VARIABLES + SHARED_VARIABLE_HARDWARE_TYPE)
                    bne.s .\@disable_floppy_cache_continue
                    move.b MEGASTE_SPEED_CACHE_REG.w, d4        ; save the old value of cpu speed
                    and.b #%00000001,MEGASTE_SPEED_CACHE_REG.w  ; disable MSTe cache
.\@disable_floppy_cache_continue:
                    endm

restore_floppy_cache    macro
                    cmp.l #COOKIE_JAR_MEGASTE, (GEMDRVEMUL_SHARED_VARIABLES + SHARED_VARIABLE_HARDWARE_TYPE)
                    bne.s .\@restore_floppy_cache_continue
                    move.b d4, MEGASTE_SPEED_CACHE_REG.w
.\@restore_floppy_cache_continue:
                    endm

; ---------------------------------------------------------------------
; Installation -- called from rom_function, gated on
; GEMDRVEMUL_FLOPPY_SESSION_INSTALL_FLOPPY. Independent of, and unrelated
; to, GEMDRIVE's own GEMDOS-trap install below.
; ---------------------------------------------------------------------
install_floppy_hooks:
    ; Save the three vectors we're about to overwrite -- sent to the Pico
    ; once (ROM4 is not Atari-writable, same constraint the GEMDOS-trap
    ; install already works around, see GEMDRVEMUL_FLOPPY_SESSION_OLD_HDV_*'s
    ; own comment in gemdrvemul.h), then read back with a fast local ROM3
    ; load on every "not disk_number 0" fall-through.
    move.l  getbpb.vector.w,d3
    move.l  rwabs.vector.w,d4
    move.l  mediach.vector.w,d5
    send_sync CMD_FLOPPY_SAVE_VECTORS,12

    move.l  #new_getbpb_routine,getbpb.vector.w
    move.l  #new_rwabs_routine,rwabs.vector.w
    move.l  #new_mediach_routine,mediach.vector.w

    bsr     install_floppy_xbios_trap
    rts

; Separate, standalone XBIOS trap install for Floprd/Flopwr/Flopfmt/
; Flopver -- deliberately NOT sharing GEMDRIVE's own conditional
; setup_datetime/save_xbios_vector call (that one only fires when
; GEMDRVEMUL_RTC_Y2K_PATCH is set, and must stay entirely independent of
; INSTALL_FLOPPY). Chains to whatever is at XBIOS_TRAP_ADDR right now --
; correct regardless of whether this runs before or after GEMDRIVE's own
; XBIOS install, since both sides only ever save-old/chain-to-old. The
; old vector goes to the Pico (GEMDRVEMUL_FLOPPY_SAVE_XBIOS_VECTOR) rather
; than a local label -- ROM4 is not Atari-writable (same constraint the
; three hdv_* vectors above already work around).
install_floppy_xbios_trap:
    move.l  XBIOS_TRAP_ADDR.w,d3
    send_sync CMD_FLOPPY_SAVE_XBIOS_VECTOR,4
    move.l  #new_floppy_xbios_trap,XBIOS_TRAP_ADDR.w
    rts

; ---------------------------------------------------------------------
; getbpb.vector (BIOS Getbpb) -- disk_number at 4(sp). Returns d0 =
; pointer to the 9-word BPB record.
; ---------------------------------------------------------------------
new_getbpb_routine:
    disable_floppy_cache                 ; before ANY ROM3 touch below -- even the "not ours"
                                          ; chain-through path reads a ROM3 field
    cmp.w   #0,4(sp)
    bne.s   .not_floppy_a
    tst.w   GEMDRVEMUL_FLOPPY_SESSION_INSTALL_FLOPPY
    beq.s   .not_floppy_a
    tst.l   GEMDRVEMUL_FLOPPY_SESSION_STATUS
    bne.s   .not_floppy_a                ; no validated image ready -- fall through, same as "not our drive"
    move.l  #GEMDRVEMUL_FLOPPY_SESSION_BPB,d0
    restore_floppy_cache
    rts
.not_floppy_a:
    move.l  GEMDRVEMUL_FLOPPY_SESSION_OLD_HDV_BPB,a1
    restore_floppy_cache
    move.l  a1,-(sp)
    rts

; ---------------------------------------------------------------------
; mediach.vector (BIOS Mediach) -- disk_number at 4(sp). Returns d0 =
; 0 (unchanged) / 1 (maybe) / 2 (definitely changed).
;
; Phase 4A: proper state, replacing the earlier "always report 2"
; placeholder. GEMDRVEMUL_FLOPPY_SESSION_MEDIA_CHANGED is a Pico-owned
; ROM3 flag (nonzero = a change happened -- set by SESSION_START on
; mount, and by the future Phase 6 short-SELECT favorite switch). No
; local mutable state needed: reading the flag is a free, ordinary local
; ROM3 load; the one-time transition back to "unchanged" is acknowledged
; by sending CMD_FLOPPY_MEDIA_CHANGE_ACK, which the Pico handles by
; clearing the field -- the SAME field a later switch will set again, so
; this one mechanism already covers both the initial mount and future
; disk switching. The ack round-trip only happens on the actual edge
; (once per real change), never on the steady-state "unchanged" path.
new_mediach_routine:
    disable_floppy_cache                 ; before ANY ROM3 touch below (same rationale as getbpb)
    cmp.w   #0,4(sp)
    bne.s   .mc_not_floppy_a
    tst.w   GEMDRVEMUL_FLOPPY_SESSION_INSTALL_FLOPPY
    beq.s   .mc_not_floppy_a
    tst.w   GEMDRVEMUL_FLOPPY_SESSION_MEDIA_CHANGED
    beq.s   .mc_unchanged
    movem.l d1-d7/a1-a6,-(sp)            ; transparently preserves d4 (our saved cache value) too
    send_sync CMD_FLOPPY_MEDIA_CHANGE_ACK,0
    movem.l (sp)+,d1-d7/a1-a6
    moveq   #2,d0
    restore_floppy_cache
    rts
.mc_unchanged:
    moveq   #0,d0
    restore_floppy_cache
    rts
.mc_not_floppy_a:
    move.l  GEMDRVEMUL_FLOPPY_SESSION_OLD_HDV_MEDIACH,a1
    restore_floppy_cache
    move.l  a1,-(sp)
    rts

; ---------------------------------------------------------------------
; rwabs.vector (BIOS Rwabs) -- rwflag@4(sp).w, buf@6(sp).l, count@10(sp).w,
; recno@12(sp).w, dev@14(sp).w. Returns d0 = 0 (OK) or a negative GEMDOS
; error code.
; ---------------------------------------------------------------------
new_rwabs_routine:
; Diagnostic (hardware bring-up): capture the address hdv_rw was called
; FROM, in a1, threaded through floppy_rwabs_emulated/floppy_read_one_sector
; unchanged (transparently preserved by that routine's own movem.l
; d1-d7/a1-a6) and appended to CMD_FLOPPY_READ_SECTOR's payload -- lets the
; Pico-side trace tell a TOS-ROM-internal caller (e.g. BIOS's own Rwabs()
; trap dispatcher, ~0xE0xxxx) apart from the booted image's own relocated
; loader code (typically a much lower address) calling straight through
; the vector. hdv_rw is always reached via a plain jsr, so (sp) at this
; exact point -- before anything else runs -- is that caller's own return
; address.
    move.l  (sp),a1
    disable_floppy_cache                 ; before ANY ROM3 touch below (same rationale as getbpb) --
                                          ; stays active across the bra into floppy_rwabs_emulated,
                                          ; which restores it on every one of its own exits
    cmp.w   #0,14(sp)
    bne.s   .rw_not_floppy_a
    tst.w   GEMDRVEMUL_FLOPPY_SESSION_INSTALL_FLOPPY
    beq.s   .rw_not_floppy_a
    tst.l   GEMDRVEMUL_FLOPPY_SESSION_STATUS
    bne.s   .rw_not_floppy_a
    bra     floppy_rwabs_emulated
.rw_not_floppy_a:
    move.l  GEMDRVEMUL_FLOPPY_SESSION_OLD_HDV_RW,a1
    restore_floppy_cache
    move.l  a1,-(sp)
    rts

; recno IS the logical sector number for Rwabs (no track/side/sector
; split at the BIOS level -- that translation already happened, if at
; all, on the caller's own side; Getbpb's geometry is what lets TOS
; compute it). read-only MVP: any write request is rejected immediately,
; before ever reaching the wire (req #6).
;
; Phase 4A correction: rwflag is a BIT FIELD, not a 0/1 enum --
; 0=read, 1=write, 2=read/no-media-change-effect, 3=write/same. Testing
; the whole word for zero (the original Phase 4 code) misclassified
; rwflag=2 (a READ variant) as a write. Must test bit 0 only.
floppy_rwabs_emulated:
    move.w  4(sp),d5            ; rwflag bit 0: 0=read, 1=write (bit 1 is a modifier, irrelevant here)
    btst    #0,d5
    beq.s   .rw_read
    moveq   #EWRPRO,d0           ; write-protected -- no wire call at all
    restore_floppy_cache
    rts

.rw_read:
    move.l  6(sp),a0             ; destination buffer
    move.w  10(sp),d1            ; sector count
    move.w  12(sp),d2            ; starting recno (== LBA, one-sector granularity)
    subq.w  #1,d1                ; dbf counts 0..n-1

.rw_read_loop:
    move.l  a0,-(sp)
    move.w  d1,-(sp)
    move.w  d2,-(sp)
    bsr     floppy_read_one_sector
    move.w  (sp)+,d2
    move.w  (sp)+,d1
    move.l  (sp)+,a0
    tst.w   d0
    bne.s   .rw_read_error
    add.l   #NUM_BYTES_PER_SECTOR_ATARI,a0
    addq.w  #1,d2
    dbf     d1,.rw_read_loop
    moveq   #0,d0
    restore_floppy_cache
    rts
.rw_read_error:
    restore_floppy_cache
    rts                          ; d0 already holds the GEMDOS error code from floppy_read_one_sector

NUM_BYTES_PER_SECTOR_ATARI equ 512

; Reads exactly one 512-byte logical sector (d2 = LBA) into (a0). a1 = a
; diagnostic-only caller-PC value (see new_rwabs_routine/floppy_xbios_rw)
; forwarded to the Pico as-is, 0 if not tracked for this call path.
; Output: d0 = 0 (OK) or a negative GEMDOS error code. Note: a0 is
; CONSUMED as the copy-loop's destination pointer and comes back
; advanced past the 512 bytes just written, not preserved -- both callers
; below save/restore their own copy of a0 around the bsr regardless (and
; explicitly re-advance it by exactly one sector themselves), so this is
; safe either way, but do not assume a0 survives a call unchanged. d2 is
; genuinely untouched.
floppy_read_one_sector:
    movem.l d1-d7/a1-a6,-(sp)     ; transparently preserves a1 (caller-PC) too
    move.l  d2,d3                ; payload: LBA (4 bytes)
    move.l  a1,d4                 ; payload: caller PC, diagnostic-only (4 bytes) -- must
                                   ; read a1 here, before it's reused below
    send_sync CMD_FLOPPY_READ_SECTOR,8
    movem.l (sp)+,d1-d7/a1-a6
    tst.w   d0
    bne.s   .read_backend_error
    tst.l   GEMDRVEMUL_FLOPPY_SESSION_STATUS
    bne.s   .read_status_error
    move.l  #GEMDRVEMUL_FLOPPY_SESSION_SECTOR_DATA,a1
    move.w  #(NUM_BYTES_PER_SECTOR_ATARI/4)-1,d7
.copy_loop:
    move.l  (a1)+,(a0)+
    dbf     d7,.copy_loop
    moveq   #0,d0
    rts
.read_backend_error:
    moveq   #EREADF,d0
    rts
.read_status_error:
    moveq   #ESECNF,d0            ; out-of-range LBA / backend error / not-ready -- all surfaced as "sector not found", the closest standard code
    rts

; ---------------------------------------------------------------------
; XBIOS trap extension -- Floprd(8)/Flopwr(9)/Flopfmt(10)/Flopver(19),
; drive A: (Atari XBIOS drive number 0) only. Same reentry-lock discipline
; as GEMDRIVE's own new_XBIOS_trap_routine is not needed here: this trap
; never calls back into GEMDOS/another trap, so there is no reentrancy
; hazard to guard against.
; ---------------------------------------------------------------------
new_floppy_xbios_trap:
    btst    #5,(sp)
    beq.s   .fx_user_mode
.fx_not_user_mode:
    move.l  sp,a0
    bra.s   .fx_check_cpu
.fx_user_mode:
    move.l  usp,a0
    subq.l  #6,a0
.fx_check_cpu:
    tst.w   _longframe
    beq.s   .fx_notlong
    addq.w  #2,a0
.fx_notlong:
    disable_floppy_cache          ; before ANY ROM3 touch below -- every path out of this trap,
                                   ; matched or not, ends up reading a ROM3 field (see .fx_chain)
    cmp.w   #Floprd,6(a0)
    beq.s   .fx_floprd
    cmp.w   #Flopwr,6(a0)
    beq.s   .fx_flopwr
    cmp.w   #Flopfmt,6(a0)
    beq.s   .fx_flopfmt
    cmp.w   #Flopver,6(a0)
    beq     .fx_flopver
    bra     .fx_chain

; Floprd(buf,dummy,rwflag,dev,sect,track,side,count) -- a0 already points
; 6 bytes into the caller's own pushed args (past the trap opcode word +
; return info the same way GEMDRIVE's own XBIOS chain already accounts
; for -- see main new_XBIOS_trap_routine for the identical +6 convention).
.fx_floprd:
    cmp.w   #0,16(a0)             ; dev
    bne     .fx_chain
    tst.w   GEMDRVEMUL_FLOPPY_SESSION_INSTALL_FLOPPY
    beq     .fx_chain
    tst.l   GEMDRVEMUL_FLOPPY_SESSION_STATUS
    bne     .fx_chain
    bra     floppy_xbios_rw

.fx_flopwr:
    cmp.w   #0,16(a0)
    bne     .fx_chain
    tst.w   GEMDRVEMUL_FLOPPY_SESSION_INSTALL_FLOPPY
    beq     .fx_chain
    tst.l   GEMDRVEMUL_FLOPPY_SESSION_STATUS
    bne     .fx_chain
    movem.l d1-d7/a1-a6,-(sp)      ; transparently preserves d4 (our saved cache value) too
    moveq   #EWRPRO,d0            ; read-only MVP: reject immediately, no wire call
    move.l  d0,8(a0)
    movem.l (sp)+,d1-d7/a1-a6
    restore_floppy_cache
    rte

.fx_flopfmt:
    cmp.w   #0,16(a0)
    bne     .fx_chain
    tst.w   GEMDRVEMUL_FLOPPY_SESSION_INSTALL_FLOPPY
    beq     .fx_chain
    movem.l d1-d7/a1-a6,-(sp)
    moveq   #ERR,d0               ; read-only MVP: format always fails, same as the original SidecarTridge driver's own precedent
    move.l  d0,8(a0)
    movem.l (sp)+,d1-d7/a1-a6
    restore_floppy_cache
    rte

.fx_flopver:
    cmp.w   #0,16(a0)
    bne     .fx_chain
    tst.w   GEMDRVEMUL_FLOPPY_SESSION_INSTALL_FLOPPY
    beq     .fx_chain
    movem.l d1-d7/a1-a6,-(sp)
    clr.l   d0                    ; always "verified successfully" -- same as the original SidecarTridge driver's own precedent, no real hardware to verify against
    move.l  d0,8(a0)
    movem.l (sp)+,d1-d7/a1-a6
    restore_floppy_cache
    rte

.fx_chain:
    move.l  GEMDRVEMUL_FLOPPY_SESSION_OLD_XBIOS_VECTOR,a1
    restore_floppy_cache
    move.l  a1,-(sp)
    rts

; Floprd/Flopwr: translate track/side/sector to LBA and dispatch through
; the same floppy_read_one_sector()/write-reject path rwabs.vector uses.
; Register/stack shape and the LBA formula itself are ported directly
; from the original SidecarTridge driver's _floppy_read_emulated_a
; (atarist-sidecart-floppy-emulator/src/floppy.s) -- verified against
; that file's own variable USAGE (secpcyl_A multiplies track, secptrack_A
; multiplies side), not its inline comments, which are swapped/misleading
; there. LBA = track*(sides*sectors_per_track) + side*sectors_per_track +
; (sector-1) -- identical to req #2's own formula.
floppy_xbios_rw:
    movem.l d1-d7/a1-a6,-(sp)
    suba.l  a1,a1                        ; caller-PC diagnostic (see new_rwabs_routine) not wired up
                                          ; for this XBIOS path yet -- 0 is the "not tracked" sentinel
                                          ; floppy_read_one_sector sends through unchanged
    lea     -52(sp),sp
    addq.l  #6,a0
    move.l  2(a0),6(sp)                  ; buffer
    move.w  18(a0),10(sp)                ; sector count
    clr.l   d0
    move.w  12(a0),d0                    ; starting sector (1-based)
    subq.w  #1,d0

    clr.l   d1
    move.w  14(a0),d1                    ; track
    clr.l   d2
    move.w  16(a0),d2                    ; side

    move.w  GEMDRVEMUL_FLOPPY_SESSION_SIDES,d6
    move.w  GEMDRVEMUL_FLOPPY_SESSION_SECTORS_PER_TRACK,d7
    mulu    d7,d6                        ; d6 = sides * sectors_per_track = sectors per cylinder
    mulu    d6,d1                        ; d1 = track * sectors_per_cylinder
    add.w   d1,d0

    mulu    d7,d2                        ; d2 = side * sectors_per_track
    add.w   d2,d0                        ; d0 = final LBA

    move.w  d0,12(sp)                    ; logical sector for the rwabs-style call below
    cmp.w   #Flopwr,(a0)
    seq     d3                           ; d3 = $FF if write, $00 if read (reused as our own "is write" flag below)
    bne.s   .fxrw_read_flag
    move.w  #-1,4(sp)                    ; rwflag: write
    bra.s   .fxrw_dispatch
.fxrw_read_flag:
    clr.w   4(sp)                        ; rwflag: read
.fxrw_dispatch:
    tst.b   d3
    beq.s   .fxrw_do_read
    moveq   #EWRPRO,d0                   ; write: reject immediately, no wire call
    bra.s   .fxrw_done
.fxrw_do_read:
    move.l  6(sp),a0
    move.w  10(sp),d1
    move.w  12(sp),d2
    subq.w  #1,d1
.fxrw_read_loop:
    move.l  a0,-(sp)
    move.w  d1,-(sp)
    move.w  d2,-(sp)
    bsr     floppy_read_one_sector
    move.w  (sp)+,d2
    move.w  (sp)+,d1
    move.l  (sp)+,a0
    tst.w   d0
    bne.s   .fxrw_done
    add.l   #NUM_BYTES_PER_SECTOR_ATARI,a0
    addq.w  #1,d2
    dbf     d1,.fxrw_read_loop
    moveq   #0,d0
.fxrw_done:
    move.l  d0,8(a0)
    lea     52(sp),sp
    movem.l (sp)+,d1-d7/a1-a6
    restore_floppy_cache
    rte

