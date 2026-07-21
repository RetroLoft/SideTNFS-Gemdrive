; SidecarT GEMDRIVE
; (C) 2023 by Diego Parrilla
; License: GPL v3

; Emulate a GEM hard disk drive using the SidecarT in a folder of the SD card

; Bootstrap the code in ASM

    XDEF   rom_function

    ifne _DEBUG
    XREF    nf_has_flag
    XREF    nf_stderr_crlf
    XREF    nf_stderr_id
    XREF    nf_hexnum_buff
    XREF    nf_debugger_id
    endif
    
; CONSTANTS
RANDOM_SEED             equ $1284FBCD  ; Random seed for the random number generator. Should be provided by the pico in the future
DELAY_NOPS              equ 0          ; Number of nops to wait each test of the random number generator
BUFFER_READ_SIZE        equ 16384      ; Number of bytes to read from the Sidecart in each read call
BUFFER_WRITE_SIZE       equ 2048       ; Number of bytes to write to the Sidecart in each write call
BASEPAGE_OFFSET_DTA     equ 32         ; Offset of the DTA in the basepage
FWRITE_RETRIES          equ 3          ; Number of retries to write the data to the Sidecart per each Sidecart call
EMULATED_DRIVE          equ 2          ; Emulated drive number: C = 2, D = 3, E = 4, F = 5, G = 6, H = 7, I = 8, J = 9, K = 10, L = 11, M = 12
                                       ; N = 13, O = 14, P = 15
EMULATED_DRIVE_BITMAP   equ 2          ; Bit number of the emulated drive in the _drvbits variable
PE_LOAD_GO              equ 0          ; Pexec mode to load the program and execute it
PE_LOAD                 equ 3          ; Pexec mode to load the program and return
PE_GO                   equ 4          ; Pexec mode to execute the program
PE_CREATE_BASEPAGE      equ 5          ; Pexec mode to create the basepage
PE_GO_AND_FREE          equ 6          ; Pexec mode to execute the program with the new format
PRG_STRUCT_SIZE         equ 28         ; Size of the GEMDOS structure in the executable header file (PRG)
                                       ; 2 bytes: g_magic
                                       ; 4 bytes: g_tsize
                                       ; 4 bytes: g_dsize
                                       ; 4 bytes: g_bsize
                                       ; 4 bytes: g_ssize
                                       ; 4 bytes: g_junk1
                                       ; 4 bytes: g_hflags
                                       ; 2 bytes: g_absflg
PRG_MAGIC_NUMBER        equ $601A      ; Magic number of the PRG file
STACK_SIZE_HACK_PEXEC   equ 50         ; This is the size of the stack to hack the Pexec() function in <=1.06 TOS versions
                                       ; The size is the same as the size of the movem.l in the save_regs/restore_regs macros plus 4

; Fase 1 (multi-drive, 68k-side only): the Pico must publish a drive table
; using exactly this protocol version, or this ROM refuses to boot (no
; silent single-drive fallback). SIDETNFS_MAX_RUNTIME_DRIVES bounds the
; shared drive_number table below.
GEMDOS_SLOT_PROTOCOL_VERSION equ 1     ; Protocol version this ROM requires from the Pico
SIDETNFS_MAX_ORDINARY_DRIVES equ 8     ; Configurable TNFS/SD drives (informational -- the 68k side is backend-agnostic and never distinguishes these from the CONFIG drive)
SIDETNFS_MAX_RUNTIME_DRIVES  equ 9     ; SIDETNFS_MAX_ORDINARY_DRIVES + 1 CONFIG drive from flash -- number of slots in the shared drive_number table

ROM4_START_ADDR         equ $FA0000 ; ROM4 start address
ROM3_START_ADDR         equ $FB0000 ; ROM3 start address
ROM_EXCHG_BUFFER_ADDR   equ (ROM3_START_ADDR)               ; ROM4 buffer address
RANDOM_TOKEN_ADDR:      equ (ROM_EXCHG_BUFFER_ADDR)
RANDOM_TOKEN_SEED_ADDR: equ (RANDOM_TOKEN_ADDR + 4) ; RANDOM_TOKEN_ADDR + 0 bytes
RANDOM_TOKEN_POST_WAIT: equ $1        ; Wait this cycles after the random number generator is ready

CMD_MAGIC_NUMBER        equ (ROM3_START_ADDR + $ABCD)       ; Magic number to identify a command
APP_GEMDRVEMUL          equ $0400                           ; MSB is the app code. GEMDRIVE is $04
CMD_PING                equ ($0 + APP_GEMDRVEMUL)           ; Command code to ping to the Sidecart
CMD_SAVE_VECTORS        equ ($1 + APP_GEMDRVEMUL)           ; Command code to save the vectors in the Sidecart
CMD_SHOW_VECTOR_CALL    equ ($2 + APP_GEMDRVEMUL)           ; Command code to send to the RP2040 the GEMDOS command executed
CMD_REENTRY_LOCK        equ ($3 + APP_GEMDRVEMUL)           ; Command to enable reentry GEMDOS calls
CMD_REENTRY_UNLOCK      equ ($4 + APP_GEMDRVEMUL)           ; Command to disable reentry GEMDOS calls

CMD_CANCEL              equ ($5 + APP_GEMDRVEMUL)           ; Cancel the current execution

CMD_RTC_START           equ ($6 + APP_GEMDRVEMUL)           ; Start the RTC
CMD_RTC_STOP            equ ($7 + APP_GEMDRVEMUL)           ; Stop the RTC
CMD_NETWORK_START       equ ($8 + APP_GEMDRVEMUL)           ; Start the network stack
CMD_NETWORK_STOP        equ ($9 + APP_GEMDRVEMUL)           ; Stop the network stock

CMD_SAVE_XBIOS_VECTOR   equ ($A + APP_GEMDRVEMUL)           ; Command code to save the XBIOS vector in the Sidecart
CMD_REENTRY_XBIOS_LOCK  equ ($B + APP_GEMDRVEMUL)           ; Command to enable reentry XBIOS calls
CMD_REENTRY_XBIOS_UNLOCK equ ($C + APP_GEMDRVEMUL)          ; Command to disable reentry XBIOS calls

CMD_DGETDRV_CALL        equ ($19 + APP_GEMDRVEMUL)           ; Command code to send to the RP2040 the Dgetdrv() command executed
CMD_FSETDTA_CALL        equ ($1A + APP_GEMDRVEMUL)           ; Command code to send to the RP2040 the Fsetdta() command executed
CMD_FSFIRST_CALL        equ ($4E + APP_GEMDRVEMUL)           ; Command code to send to the RP2040 the Fsfirst() command executed
CMD_FSNEXT_CALL         equ ($4F + APP_GEMDRVEMUL)           ; Command code to send to the RP2040 the Fsnext() command executed

CMD_FCREATE_CALL        equ ($3C + APP_GEMDRVEMUL)           ; Command code to send to the RP2040 the Fcreate() command executed
CMD_FOPEN_CALL          equ ($3D + APP_GEMDRVEMUL)           ; Command code to send to the RP2040 the Fopen() command executed
CMD_FCLOSE_CALL         equ ($3E + APP_GEMDRVEMUL)           ; Command code to send to the RP2040 the Fclose() command executed
CMD_DFREE_CALL          equ ($36 + APP_GEMDRVEMUL)           ; Command code to send to the RP2040 the Dfree() command executed
CMD_DGETPATH_CALL       equ ($47 + APP_GEMDRVEMUL)           ; Command code to send to the RP2040 the Dgetpath() command executed
CMD_DSETPATH_CALL       equ ($3B + APP_GEMDRVEMUL)           ; Command code to send to the RP2040 the Dsetpath() command executed
CMD_DCREATE_CALL        equ ($39 + APP_GEMDRVEMUL)           ; Command code to send to the RP2040 the Dcreate() command executed
CMD_DDELETE_CALL        equ ($3A + APP_GEMDRVEMUL)           ; Command code to send to the RP2040 the Ddelete() command executed
CMD_FDELETE_CALL        equ ($41 + APP_GEMDRVEMUL)           ; Command code to send to the RP2040 the Fdelete() command executed
CMD_FSEEK_CALL          equ ($42 + APP_GEMDRVEMUL)           ; Command code to send to the RP2040 the Fseek() command executed
CMD_FATTRIB_CALL        equ ($43 + APP_GEMDRVEMUL)           ; Command code to send to the RP2040 the Fattrib() command executed

CMD_FRENAME_CALL        equ ($56 + APP_GEMDRVEMUL)           ; Command code to send to the RP2040 the Frename() command executed
CMD_FDATETIME_CALL      equ ($57 + APP_GEMDRVEMUL)           ; Command code to send to the RP2040 the Fdatetime() command executed

CMD_MALLOC_CALL         equ ($48 + APP_GEMDRVEMUL)           ; Command code to send to the RP2040 the malloc() command executed
CMD_PEXEC_CALL          equ ($4B + APP_GEMDRVEMUL)           ; Command code to send to the RP2040 the Pexec() command executed

; This commands are not direct GEMDOS calls, but they are used to send data to the Sidecart
CMD_READ_BUFF_CALL      equ ($81 + APP_GEMDRVEMUL)           ; Command code to send to the RP2040 the read the buffer
CMD_DEBUG               equ ($82 + APP_GEMDRVEMUL)           ; Command code to send to the RP2040 the debug command
CMD_SAVE_BASEPAGE       equ ($83 + APP_GEMDRVEMUL)           ; Command code to send to the RP2040 the save basepage command
CMD_SAVE_EXEC_HEADER    equ ($84 + APP_GEMDRVEMUL)           ; Command code to send to the RP2040 the save exec header command 

CMD_SET_SHARED_VAR      equ ($87 + APP_GEMDRVEMUL)           ; Set a shared variable
CMD_WRITE_BUFF_CALL     equ ($88 + APP_GEMDRVEMUL)           ; Command code to send to the RP2040 the write the buffer
CMD_WRITE_BUFF_CHECK    equ ($89 + APP_GEMDRVEMUL)           ; Write to sdCard the write buffer check call
CMD_DTA_EXIST_CALL      equ ($8A + APP_GEMDRVEMUL)           ; Check if the DTA exists in the rp2040 memory
CMD_DTA_RELEASE_CALL    equ ($8B + APP_GEMDRVEMUL)           ; Release the DTA from the rp2040 memory



; Shared variables indexes
; The first 16 variables are reserved for the shared functions
SHARED_VARIABLE_FIRST_FILE_DESCRIPTOR   equ SHARED_VARIABLE_SHARED_FUNCTIONS_SIZE + 0             ; First file descriptor to use in the Sidecart
; Indexes +1 (drive letter) and +2 (drive number) used to hold the single
; emulated drive as two separate scalars. Retired in favour of the
; multi-drive table below (+5..+15): the drive letter is always derived as
; 'A' + drive_number, never stored separately.
SHARED_VARIABLE_PEXEC_RESTORE           equ SHARED_VARIABLE_SHARED_FUNCTIONS_SIZE + 3             ; Pexec address to restore the program
SHARED_VARIABLE_FAKE_FLOPPY             equ SHARED_VARIABLE_SHARED_FUNCTIONS_SIZE + 4             ; Fake floppy drive to launch AUTO programs

; Fase 1 (multi-drive, 68k-side only): protocol version + active-drive
; table, set by the Pico before this ROM installs its GEMDOS vector. Reuses
; the free +5..+15 range of this same shared-variable block (indexes
; 21..31 / byte offsets +84..+127 of GEMDRVEMUL_SHARED_VARIABLES below) --
; no growth of the 256-byte shared-variable block, no backend-type field,
; no separate drive-letter table. The table has SIDETNFS_MAX_RUNTIME_DRIVES
; (9) entries -- up to SIDETNFS_MAX_ORDINARY_DRIVES (8) configurable TNFS/SD
; drives plus 1 CONFIG drive from flash; the 68k side is backend-agnostic
; and never needs to know which slot is which kind.
SHARED_VARIABLE_PROTOCOL_VERSION        equ SHARED_VARIABLE_SHARED_FUNCTIONS_SIZE + 5             ; Protocol version set by the Pico (must equal GEMDOS_SLOT_PROTOCOL_VERSION)
SHARED_VARIABLE_DRIVE_COUNT             equ SHARED_VARIABLE_SHARED_FUNCTIONS_SIZE + 6             ; Number of active entries in the drive_number table (1..SIDETNFS_MAX_RUNTIME_DRIVES)
SHARED_VARIABLE_DRIVE_NUMBER_TABLE      equ SHARED_VARIABLE_SHARED_FUNCTIONS_SIZE + 7             ; Base index of a SIDETNFS_MAX_RUNTIME_DRIVES-entry table of GEMDOS drive numbers (indexes +7..+15)

GEMDRVEMUL_TIMEOUT_SEC  equ (ROM_EXCHG_BUFFER_ADDR + $8)     ; ROM_EXCHG_BUFFER_ADDR + 8 bytes
GEMDRVEMUL_PING_STATUS  equ (GEMDRVEMUL_TIMEOUT_SEC + $4)    ; GEMDRVEMUL_TIMEOUT_SEC + 4 bytes
GEMDRVEMUL_RTC_STATUS   equ (GEMDRVEMUL_PING_STATUS + 4)     ; ping status + 4 bytes
GEMDRVEMUL_NETWORK_STATUS   equ (GEMDRVEMUL_RTC_STATUS + 8)  ; rtc status + 8 bytes
GEMDRVEMUL_RTC_ENABLED  equ (GEMDRVEMUL_NETWORK_STATUS + 4) ; network status + 4 bytes
GEMDRVEMUL_REENTRY_TRAP equ (GEMDRVEMUL_RTC_ENABLED + $8)   ; GEMDRVEMUL_RTC_ENABLED + 4 bytes + 4 GAP
GEMDRVEMUL_OLD_XBIOS_TRAP equ (GEMDRVEMUL_REENTRY_TRAP + $4)    ; GEMDRVEMUL_REENTRY_TRAP + 4 bytes
GEMDRVEMUL_RTC_XBIOS_REENTRY_TRAP equ (GEMDRVEMUL_OLD_XBIOS_TRAP + $4) ; GEMDRVEMUL_OLD_XBIOS_TRAP + 4 bytes
GEMDRVEMUL_RTC_DATETIME_BCD equ (GEMDRVEMUL_RTC_XBIOS_REENTRY_TRAP + $4) ; GEMDRVEMUL_RTC_XBIOS_REENTRY_TRAP + 4 bytes
GEMDRVEMUL_RTC_DATETIME_MSDOS equ (GEMDRVEMUL_RTC_DATETIME_BCD + 8) ; GEMDRVEMUL_RTC_DATETIME_BCD + 8 bytes
GEMDRVEMUL_RTC_Y2K_PATCH equ (GEMDRVEMUL_RTC_DATETIME_MSDOS + 8) ; GEMDRVEMUL_RTC_DATETIME_MSDOS + 8 bytes
GEMDRVEMUL_DEFAULT_PATH equ (GEMDRVEMUL_RTC_Y2K_PATCH + $4)  ; GEMDRVEMUL_RTC_Y2K_PATCH + 4 bytes

GEMDRVEMUL_DTA_F_FOUND  equ (GEMDRVEMUL_DEFAULT_PATH + $80)  ; GEMDRVEMUL_DEFAULT_PATH + 128 bytes
GEMDRVEMUL_DTA_TRANSFER equ (GEMDRVEMUL_DTA_F_FOUND + $4)   ; GEMDRVEMUL_DTA_F_FOUND + 4 bytes
GEMDRVEMUL_DTA_EXIST    equ (GEMDRVEMUL_DTA_TRANSFER + 44) ; dta transfer + sizeof(DTA) bytes
GEMDRVEMUL_DTA_RELEASE  equ (GEMDRVEMUL_DTA_EXIST + 4)     ; dta exist + 4 bytes
GEMDRVEMUL_SET_DPATH_STATUS equ (GEMDRVEMUL_DTA_RELEASE + 4)  ; dta release + 4 bytes
GEMDRVEMUL_FOPEN_HANDLE equ (GEMDRVEMUL_SET_DPATH_STATUS + 4)    ; GEMDRVEMUL_SET_DPATH_STATUS + 2 bytes
GEMDRVEMUL_READ_BYTES  equ (GEMDRVEMUL_FOPEN_HANDLE + 4)        ; GEMDRVEMUL_FOPEN_HANDLE + 4 bytes
GEMDRVEMUL_READ_BUFFER  equ (GEMDRVEMUL_READ_BYTES + 4)         ; GEMDRVEMUL_READ_BYTES + 4 bytes
GEMDRVEMUL_WRITE_BYTES equ (GEMDRVEMUL_READ_BUFFER + BUFFER_READ_SIZE) ; GEMDRVEMUL_READ_BUFFER + BUFFER_READ_SIZE bytes
GEMDRVEMUL_WRITE_CHK  equ (GEMDRVEMUL_WRITE_BYTES + 4)         ; GEMDRVEMUL_WRITE_BYTES + 4 bytes
GEMDRVEMUL_WRITE_CONFIRM_STATUS equ (GEMDRVEMUL_WRITE_CHK + 4)     ; GEMDRVEMUL_WRITE_CHK+ 4 bytes
GEMDRVEMUL_FCLOSE_STATUS equ (GEMDRVEMUL_WRITE_CONFIRM_STATUS + 4) ; GEMDRVEMUL_WRITE_CONFIRM_STATUS + 4 bytes
GEMDRVEMUL_DCREATE_STATUS equ (GEMDRVEMUL_FCLOSE_STATUS + 4)     ; GEMDRVEMUL_FCLOSE_STATUS + 2 bytes + 2 bytes padding. Must be aligned to 4 bytes/32 bits
GEMDRVEMUL_DDELETE_STATUS equ (GEMDRVEMUL_DCREATE_STATUS + 4)    ; GEMDRVEMUL_DCREATE_STATUS + 2 bytes + 2 bytes padding. Must be aligned to 4 bytes/32 bits
GEMDRVEMUL_EXEC_HEADER  equ (GEMDRVEMUL_DDELETE_STATUS + 4)   ; GEMDRVEMUL_DDELETE_STATUS + 2 bytes + 2 bytes padding. Must be aligned to 4 bytes/32 bits
GEMDRVEMUL_FCREATE_HANDLE equ (GEMDRVEMUL_EXEC_HEADER + 32)         ; GEMDRVEMUL_EXEC_HEADER + 32 bytes
GEMDRVEMUL_FDELETE_STATUS equ (GEMDRVEMUL_FCREATE_HANDLE + 4)       ; GEMDRVEMUL_FCREATE_HANDLE + 4 bytes
GEMDRVEMUL_FSEEK_STATUS equ (GEMDRVEMUL_FDELETE_STATUS + 4)         ; GEMDRVEMUL_FDELETE_STATUS + 4 bytes
GEMDRVEMUL_FATTRIB_STATUS equ (GEMDRVEMUL_FSEEK_STATUS + 4)             ;  GEMDRVEMUL_FSEEK_STATUS + 4 bytes
GEMDRVEMUL_FRENAME_STATUS equ (GEMDRVEMUL_FATTRIB_STATUS + 4)         ; GEMDRVEMUL_FSEEK_STATUS + 4 bytes
GEMDRVEMUL_FDATETIME_DATE       equ (GEMDRVEMUL_FRENAME_STATUS + 4)      ; GEMDRVEMUL_FRENAME_STATUS + 4 bytes
GEMDRVEMUL_FDATETIME_TIME       equ (GEMDRVEMUL_FDATETIME_DATE + 4)      ; GEMDRVEMUL_FDATETIME_DATE + 4
GEMDRVEMUL_FDATETIME_STATUS     equ (GEMDRVEMUL_FDATETIME_TIME + 4)      ; GEMDRVEMUL_FDATETIME_TIME + 4 bytes
GEMDRVEMUL_DFREE_STATUS         equ (GEMDRVEMUL_FDATETIME_STATUS + 4)    ; GEMDRVEMUL_FRENAME_STATUS + 4 bytes
GEMDRVEMUL_DFREE_STRUCT         equ (GEMDRVEMUL_DFREE_STATUS + 4)        ; GEMDRVEMUL_DFREE_STATUS + 4 bytes

GEMDRVEMUL_PEXEC_MODE       equ (GEMDRVEMUL_DFREE_STRUCT + 32)       ; dfree struct + 32 bytes
GEMDRVEMUL_PEXEC_STACK_ADDR equ (GEMDRVEMUL_PEXEC_MODE + 4)         ; pexec mode status + 4 bytes
GEMDRVEMUL_PEXEC_FNAME      equ (GEMDRVEMUL_PEXEC_STACK_ADDR + 4)   ; pexec mode + 4 bytes
GEMDRVEMUL_PEXEC_CMDLINE    equ (GEMDRVEMUL_PEXEC_FNAME + 4)        ; pexec fname + 4 bytes
GEMDRVEMUL_PEXEC_ENVSTR     equ (GEMDRVEMUL_PEXEC_CMDLINE + 4)      ; pexec cmd line + 4 bytes


GEMDRVEMUL_SHARED_VARIABLES equ (GEMDRVEMUL_PEXEC_ENVSTR + 4)       ; exec PD + 4 bytes

GEMDRVEMUL_EXEC_PD          equ (GEMDRVEMUL_SHARED_VARIABLES + 256) ; shared variables + 256 bytes


_nflops                 equ $4a6                            ; This value indicates the number of floppy drives currently connected to the system
_drvbits                equ $4c2                            ; Each of 32 bits in this longword represents a drive connected to the system. Bit #0 is A, Bit #1 is B and so on.
_dskbufp                equ $4c6                            ; Address of the disk buffer pointer    
_sysbase                equ $4f2                            ; Address of the system base
_longframe              equ $59e                            ; Address of the long frame flag. If this value is 0 then the processor uses short stack frames, otherwise it uses long stack frames.
VEC_GEMDOS              equ $21                             ; Trap #1 GEMDOS vector
XBIOS_TRAP_ADDR         equ $b8                             ; TRAP #14 Handler (XBIOS)
DSKBUFP_TMP_ADDR        equ $100                            ; Address of the temporary registry buffer to store the DSKBUF pointer
DSKBUFP_SWAP_ADDR       equ $200                            ; Address of the temporary swap buffer to store the DSKBUF pointer
MEGASTE_SPEED_CACHE_REG equ $FFFF8E21                       ; Address of the registry to change speed and cache in the MegaSTE
USE_DSKBUF              equ 0                               ; Use the DSKBUF pointer to store the address of the buffer to read the data from the Sidecart. 0 = Stack, 1 = disk buffer

GEMDOS_EINTRN           equ -65 ; GEMDOS Internal error


; Macros

; Restore the registers in the interrupt handler
; Don't forget to update STACK_SIZE_HACK_PEXEC if you change the number of registers
restore_regs        macro
                    movem.l (sp)+, d1-d7/a2-a6
                    endm

; Save the registers in the interrupt handler
; Don't forget to update STACK_SIZE_HACK_PEXEC if you change the number of registers
save_regs           macro
                    movem.l d1-d7/a2-a6,-(sp)
                    endm

; Restore the registries, restore the CPU speed + cache if needed and return from the exception
return_rte          macro
                    restore_regs
                    restore_cpu_cache
                    rte
                    endm

; Return the error code from the Sidecart and restore the registers in the interrupt handler
; /1 : The memory address to return the error code
return_interrupt_w  macro
                    move.w \1, d0                        ; Return the error code from the Sidecart
                    ext.l d0                             ; Extend the sign of the value
                    return_rte
                    endm

return_interrupt_l  macro
                    move.l \1, d0                        ; Return the error code from the Sidecart
                    return_rte
                    endm

; Restore the CPU speed and cache in the MegaSTE
; in d7.b the previous value always
restore_cpu_cache   macro
                    cmp.l #COOKIE_JAR_MEGASTE, (GEMDRVEMUL_SHARED_VARIABLES + SHARED_VARIABLE_HARDWARE_TYPE)    ; Check if the computer is a MegaSTE
                    bne.s .\@restore_cpu_cache_continue
                    move.b d1, MEGASTE_SPEED_CACHE_REG.w
.\@restore_cpu_cache_continue:
                    endm

; Send a synchronous command to the Sidecart setting the reentry flag for the next GEMDOS calls
; inside our trapped GEMDOS calls. Should be always paired with reentry_gem_unlock
reentry_gem_lock	macro
                    move.w #CMD_REENTRY_LOCK,d0          ; Command code to lock the reentry
                    moveq.w #0,d1                        ; Payload size is 0 bytes
                    bsr send_sync_command_to_sidecart
                	endm

; Send a synchronous command to the Sidecart clearing the reentry flag for the next GEMDOS calls
; inside our trapped GEMDOS calls. Should be always paired with reentry_gem_lock
reentry_gem_unlock  macro
                    move.w #CMD_REENTRY_UNLOCK,d0        ; Command code to unlock the reentry
                    moveq.w #0,d1                        ; Payload size is 0 bytes
                    bsr send_sync_command_to_sidecart
                	endm
; Check if the current GEMDOS drive is one of the emulated drives. If not,
; exec_old_handler the code, otherwise continue with the code.
; Output: d0.w = slot index (0..SIDETNFS_MAX_RUNTIME_DRIVES-1) of the matched drive in
; the shared drive_number table -- not yet used by any caller in this phase,
; but every call site now receives it for later phases to consume.
detect_emulated_drive   macro
                        reentry_gem_lock
                        gemdos Dgetdrv, 2                    ; Call Dgetdrv() and get the drive number
                        move.l d0, -(sp)                     ; Save the return value with the drive number
                        reentry_gem_unlock
                        move.l (sp)+, d0                     ; Restore the drive number
                        bsr find_drive_slot_by_number         ; d0 = slot index, or -1 if not one of the emulated drives
                        tst.w d0
                        bmi .exec_old_handler
                        endm

; Check if the first letter of the path is one of the emulated drives. If
; not, exec_old_handler the code. Pass the address of the file specification
; string in a4.
; Output: d0.w = slot index (0..SIDETNFS_MAX_RUNTIME_DRIVES-1) of the matched drive.
detect_emulated_drive_letter   macro
                        cmp.b #':', 1(a4)                    ; Check if the second character of the file specification string is the colon
                        bne.s .\@detect_emulated_drive_continue; If not, exec_old_handler the code. Otherwise continue with the code
                        move.b (a4), d0                      ; Get the first letter of the file specification string
                        bsr find_drive_slot_by_letter         ; d0 = slot index, or -1 if not one of the emulated drives
                        tst.w d0
                        bmi .exec_old_handler                ; If not, exec_old_handler the code. Otherwise continue with the code
                        bra.s .\@detect_emulated_drive_ignore; The drive is one of the emulated ones, slot index already in d0
.\@detect_emulated_drive_continue:
                        detect_emulated_drive                ; Check if the drive is one of the emulated ones.
.\@detect_emulated_drive_ignore:
                        endm

; Check if the file handler is of the SidecarT or not.
detect_emulated_file_handler   macro
                        and.l #$FFFF, d3                     ; Mask the upper word of the file handle
                        cmp.l (GEMDRVEMUL_SHARED_VARIABLES + (SHARED_VARIABLE_FIRST_FILE_DESCRIPTOR * 4)), d3 ; Check if the file handle in the range
                        blt .exec_old_handler                ; If less than, exec_old_handler the code. Otherwise continue with the code
                        endm

; Macros should be included before any function code
    include inc/tos.s
    include inc/debug.s
    include inc/sidecart_macros.s

    ifne _RELEASE
        org $FA0040
    endif
rom_function:
    print gemdrive_emulator_msg          ; Prints "...GEMDRIVE - v" and stops there (see note above)

; Print the ROM version digits at runtime (VERSION_MAJOR/MINOR/PATCH are
; numeric -D defines, single decimal digits 0-9; convert to ASCII here
; rather than embedding them as static bytes -- see the note above
; gemdrive_emulator_msg for why that silently truncated the boot banner).
    moveq #VERSION_MAJOR, d0
    add.b #'0', d0
    pchar_reg
    pchar '.'
    moveq #VERSION_MINOR, d0
    add.b #'0', d0
    pchar_reg
    pchar '.'
    moveq #VERSION_PATCH, d0
    add.b #'0', d0
    pchar_reg
    print spacing

; Setup the RTC
    tst.l GEMDRVEMUL_RTC_ENABLED
    beq.s .rtc_conf_bypass
    bsr wait_rtc

.rtc_conf_bypass:
    tst.l (GEMDRVEMUL_SHARED_VARIABLES + (SHARED_VARIABLE_BUFFER_TYPE * 4))
    bne.s .show_stack_buffer_msg

    print dskbuf_buffer_msg
    bra.s .get_tos_version
.show_stack_buffer_msg:
    print stack_buffer_msg

.get_tos_version:
    print ok_msg

; Figure out the TOS version to display
    bsr get_tos_version
    bsr print_tos_version
    
; Wait for the folder in the sd card of the Sidecart to be mounted
    print query_ping_msg
    bsr test_ping
    tst.w d0
    bne _exit_timemout

; Ping was successful
_ping_ready:
    print ok_msg
    print ready_gemdrive_msg

; Clean GEM reentry lock on start
; This is necessary in case there was a crash during a reentry call
    bsr clean_gem_reentry_lock
    print ok_msg

; Validate the multi-drive table set by the Pico (protocol version, drive
; count, drive numbers). Hard failure here means the Pico firmware does not
; speak the protocol version this ROM requires -- no silent single-drive
; fallback.
    print validate_drive_table_msg
    bsr validate_drive_table
    tst.w d0
    bne _exit_invalid_table
    print ok_msg

; Show the disk drive to emulate
    print emulated_drive_msg
    move.w (GEMDRVEMUL_SHARED_VARIABLES + 2 + (SHARED_VARIABLE_DRIVE_NUMBER_TABLE * 4)), d0   ; Get the drive number of slot 0 (the primary/default drive)
    add.w #'A', d0                                                                             ; Convert to its drive letter
    pchar_reg
    pchar ':'
    pchar '\'
    pchar ' '
    pchar ' '
    pchar ' '
    print ok_msg

; Set the virtual hard disk
    tst.l (GEMDRVEMUL_SHARED_VARIABLES + (SHARED_VARIABLE_FAKE_FLOPPY * 4)) ; Do we want to simulate a floppy drive to launch AUTO programs?
    beq.s .create_virtual_hard_disk                                         ; If not, continue with the code
    tst.w _nflops.w                                                         ; if there is no floppy drive, let's simulate that there is a floppy drive
    bne.s .create_virtual_hard_disk                                         ; There are floppy drives, continue with the code
    move.l #1,_drvbits.w                                                    ; Create the drive A bit
    move.w #1,_nflops.w                                                     ; Simulate that floppy A is attached
.create_virtual_hard_disk:
    bsr create_virtual_hard_disk


; Save the old GEMDRVEMUL_OLD_GEM_VEC and set our own vector
    print set_vectors_msg

; Get the hardware version 
    bsr detect_hw
    bsr save_vectors
    tst.w d0
    bne _exit_timemout
    print ok_msg

; This is where the clock is set.
    tst.l GEMDRVEMUL_RTC_ENABLED
    beq.s .exit_graciouslly
    bsr setup_datetime

.exit_graciouslly:
    rts

_exit_timemout:
    asksil error_sidecart_comm_msg
    rts

_exit_invalid_table:
    asksil error_invalid_table_msg
    rts

; Print the obtained TOS version
print_tos_version:
    print set_version_msg   ; Print the TOS version message

    move.l (GEMDRVEMUL_SHARED_VARIABLES + (SHARED_VARIABLE_SVERSION * 4)), d0   ; Get the TOS version from the shared variables
    swap d0
    and.l #$FFFF,d0
    move.w d0, d1
    lsr.w #8, d1    ; Major version

    move.w d0, d2
    and.w #$FF, d2  ; Minor version

    add.w #48, d1
    move.w d1, d0
    pchar_reg

    pchar '.'

;    move.w d2, d0
;    print_num
    move.w d2, d0
    swap d0
    lsl.l #8, d0
    moveq #1, d1    ; Number of digits to print minus 1 
    print_hex

    pchar '.'
    pchar '.'
    pchar '.'

    print ok_msg
    rts

; Wait for the RPP2040 to have a mounted folder in the SD card
test_ping:
    move.l GEMDRVEMUL_TIMEOUT_SEC, d7           ; Wait for a while until ping responds
_retest_ping:
    move.w d7, -(sp)                 

    send_sync CMD_PING, 0                ; Send the command to the Sidecart. 0 bytes of payload

    move.w (sp)+, d7
    tst.w d0                            ; 0 if no error
    bne.s _test_ping_timeout            ; The RP2040 is not responding, timeout now

    tst.w GEMDRVEMUL_PING_STATUS
    beq.s _ping_not_yet                ; The NTP has a valid date, exit
_exit_test_ping:
    moveq #0, d0
    rts


_ping_not_yet:

    move.w d7,d0                        ; Pass the number of seconds to print
    print_num                           ; Print the decimal number

    print backwards_msg

    move.w #50, d6                      ; Loop to wait a second (aprox 50 VBlanks)
_ping_not_yet_loop:
    move.w 	#37,-(sp)                   ; Wait for the VBlank. Add a delay
    trap 	#14
    addq.l 	#2,sp
    dbf d6, _ping_not_yet_loop

    dbf d7, _retest_ping                 ; The ping command does not have a valid path, wait a bit more

_test_ping_timeout:
    moveq #-1, d0
    rts

; wait for the RTC to be ready
wait_rtc:
    tst.l GEMDRVEMUL_RTC_STATUS     ; Test if the RTC is already started
    beq.s _wait_rtc_start           ; If the RTC is not started, continue with the code
    print rtc_already_started_msg
    print ok_msg
    rts                             ; We wait for the RTC to be ready, but we set the RTC at the end init

; Start the RTC because it was not initalized yet
_wait_rtc_start:
    print query_network_msg
     
; Loop to wait for the Network to be ready
    move.l GEMDRVEMUL_TIMEOUT_SEC, d7   ; Wait for a while until ping responds
_wait_for_network_stack:
    move.w d7,d0                    ; Pass the number of seconds to print
    print_num                       ; Print the decimal number
    print backwards_msg
    wait_sec
    tst.l GEMDRVEMUL_NETWORK_STATUS ; Test if the network stack is ready
    bne.s _wait_for_rtc             ; The network is ok. Wait for the RTC to be ready now

    wait_sec_or_key_press
    cmp.b #27,d0                    ; Check if ESC is pressed and continue
    beq _test_rtc_canceled          ; The user canceled the operation

    dbf d7, _wait_for_network_stack ; The network is not ready yet, wait a bit more
    bra _test_rtc_timeout         ; The network stack is not ready yet, timeout now

; Network is ready, but the RTC is not ready yet
_wait_for_rtc:
    print ok_msg
    print query_ntp_msg

    move.l GEMDRVEMUL_TIMEOUT_SEC, d7       ; Wait for a while until the RTC is ready
_wait_for_rtc_loop:
    move.w d7,d0                    ; Pass the number of seconds to print
    print_num                       ; Print the decimal number
    print backwards_msg
    wait_sec
    tst.l GEMDRVEMUL_RTC_STATUS     ; Test if the RTC is ready
    bne.s _rtc_ready                ; The RTC is ready to start now
    dbf d7, _wait_for_rtc_loop      ; The RTC is not ready yet, wait a bit more
    bra _test_rtc_timeout         ; The RTC is not ready yet, timeout now
_rtc_ready:
    print ok_msg
    rts





; Configure the date and time when the RTC clock in the RP2040 is ready
setup_datetime:
    tst.l GEMDRVEMUL_RTC_Y2K_PATCH
    beq.s _set_xbios_vector_ignore

; We don't need to fix Y2K problem in EmuTOS
; Save the old XBIOS vector in GEMDRVEMUL_RTC_OLD_XBIOS and set our own vector
    print set_xbios_vector_msg
    bsr save_xbios_vector
    tst.w d0
    bne _test_rtc_timeout
    print ok_msg

_set_xbios_vector_ignore:
    pea GEMDRVEMUL_RTC_DATETIME_BCD     ; Buffer should have a valid IKBD date and time format
    move.w #6, -(sp)                    ; Six bytes plus the header = 7 bytes
    move.w #25, -(sp)                   ; 
    trap #14
    addq.l #8, sp

    print set_datetime_msg

    move.l GEMDRVEMUL_RTC_DATETIME_MSDOS, d0
    bsr set_datetime
    tst.w d0
    bne _exit_timemout

	move.w #23,-(sp)                    ; gettime from XBIOS
	trap #14
	addq.l #2,sp

    tst.l GEMDRVEMUL_RTC_Y2K_PATCH
    beq.s _ignore_y2k
    add.l #$3c000000,d0                 ; +30 years to guarantee the Y2K problem works in all TOS versions
_ignore_y2k:

    move.l d0, -(sp)                    ; Save the date and time in MSDOS format
    move.w #22,-(sp)                    ; settime with XBIOS
    trap #14
    addq.l #6, sp

    print ok_msg
    moveq #0, d0
    rts

_test_rtc_timeout:
    print timeout_msg
    moveq #-1, d0
    rts

_test_rtc_canceled:
    print canceled_msg
    send_sync CMD_CANCEL, 0         ; Force cancel command
    moveq #-1, d0
    rts


; Send a synchronous command to the Sidecart setting the reentry flag for the next XBIOS calls
; inside our trapped XBIOS calls. Should be always paired with reentry_xbios_unlock
reentry_xbios_lock	macro
                    movem.l d0-d7/a0-a6,-(sp)            ; Save all registers
                    send_sync CMD_REENTRY_XBIOS_LOCK,0   ; Command code to lock the reentry
                    movem.l (sp)+,d0-d7/a0-a6            ; Restore all registers
                	endm

; Send a synchronous command to the Sidecart clearing the reentry flag for the next XBIOS calls
; inside our trapped XBIOS calls. Should be always paired with reentry_xbios_lock
reentry_xbios_unlock  macro
                    movem.l d0-d7/a0-a6,-(sp)            ; Save all registers
                    send_sync CMD_REENTRY_XBIOS_UNLOCK,0 ; Command code to unlock the reentry
                    movem.l (sp)+,d0-d7/a0-a6            ; Restore all registers
                	endm

save_xbios_vector:
    move.l XBIOS_TRAP_ADDR.w,d3         ; Address of the old XBIOS vector
    send_sync CMD_SAVE_XBIOS_VECTOR,4   ; Send the command to the Sidecart
    tst.w d0                            ; 0 if no error
    bne.s _save_xbios_vector_timeout    ; The RP2040 is not responding, timeout now

    ; Now we have the XBIOS vector in GEMDRVEMUL_RTC_OLD_XBIOS
    ; Now we can safely change it to our own vector
    move.l #custom_xbios,XBIOS_TRAP_ADDR.w    ; Set our own vector
    moveq #0, d0
    rts
_save_xbios_vector_timeout:
    moveq #-1, d0
    rts

custom_xbios:
    btst #0, GEMDRVEMUL_RTC_XBIOS_REENTRY_TRAP      ; Check if the reentry is locked
    beq.s _custom_bios_trapped         ; If the bit is active, we are in a reentry call. We need to exec_old_handler the code

    move.l GEMDRVEMUL_OLD_XBIOS_TRAP, -(sp) ; if not, continue with XBIOS call
    rts 

_custom_bios_trapped:
    btst #5, (sp)                    ; Check if called from user mode
    beq.s _xbios_user_mode                 ; if so, do correct stack pointer
_xbios_not_user_mode:
    move.l sp,a0                     ; Move stack pointer to a0
    bra.s _xbios_check_cpu
_xbios_user_mode:
    move.l usp,a0                    ; if user mode, correct stack pointer
    subq.l #6,a0
;
; This code checks if the CPU is a 68000 or not
;
_xbios_check_cpu:
    tst.w _longframe                ; Check if the CPU is a 68000 or not
    beq.s _xbios_notlong
_xbios_long:
    addq.w #2, a0                   ; Correct the stack pointer parameters for long frames 
_xbios_notlong:
    cmp.w #23,6(a0)                 ; is it XBIOS call 23 / getdatetime?
    beq.s _getdatetime              ; if yes, go to our own routine
    cmp.w #22,6(a0)                 ; is it XBIOS call 22 / setdatetime?
    beq.s _setdatetime              ; if yes, go to our own routine

_continue_xbios:
    move.l GEMDRVEMUL_OLD_XBIOS_TRAP, -(sp) ; if not, continue with XBIOS call
    rts 

; Adjust the time when reading to compensate for the Y2K problem
; We should not tap this call for EmuTOS
_getdatetime:
    reentry_xbios_lock
	move.w #23,-(sp)
	trap #14
	addq.l #2,sp
	add.l #$3c000000,d0 ; +30 years for all TOS except EmuTOS
    reentry_xbios_unlock
	rte

; Adjust the time when setting to compensate for the Y2K problem
; We should not tap this call for TOS 2.06 and EmuTOS
_setdatetime:
	sub.l #$3c000000,8(a0)
    bra.s _continue_xbios

; Get the date and time from the RP2040 and set the IKBD information
; d0.l : Date and time in MSDOS format
set_datetime:
    move.l d0, d7

    bsr print_hour
    pchar ':'
    move.l d7, d0
    bsr print_minute
    pchar ':'
    move.l d7, d0
    bsr print_seconds

    pchar ' '

    swap d7
    move.l d7, d0
    bsr print_day
    pchar '/'
    move.l d7, d0
    bsr print_month
    pchar '/'
    move.l d7, d0
    bsr print_year

    swap d7

	move.w d7,-(sp)
	move.w #$2d,-(sp)                   ; settime with GEMDOS
	trap #1
	addq.l #4,sp
    tst.w d0
    bne.s _exit_set_time

	swap d7

	move.w d7,-(sp)
	move.w #$2b,-(sp)                   ; settime with GEMDOS  
	trap #1
	addq.l #4,sp
    tst.w d0
    bne.s _exit_set_time

    ; And we are done!
    moveq #0, d0
    rts
_exit_set_time:
    moveq #-1, d0
    rts

print_seconds:
    and.l #%11111,d0
    print_num
    rts

print_minute:
    lsr.l #5, d0
    and.l #%111111,d0
    print_num
    rts

print_hour:
    lsr.l #8, d0
    lsr.l #3, d0
    and.l #%11111,d0
    print_num
    rts

print_day:
    and.l #%11111,d0
    print_num
    rts

print_month:
    lsr.l #5, d0
    and.l #%1111,d0
    print_num
    rts

print_year:
    lsr.l #8, d0
    lsr.l #1, d0
    and.l #%1111111,d0
    sub.l #20, d0 ; Year - 1980
    print_num
    rts

;
; Clean the gem reentry lock flag on start
;
clean_gem_reentry_lock:
    move.w #CMD_REENTRY_UNLOCK,d0          ; Command code to unlock the reentry
    moveq.w #0,d1                        ; Payload size is 0 bytes
    bra send_sync_command_to_sidecart

; Set one _drvbits bit for every entry in the active-drive table, then make
; slot 0 the current/default drive via Dsetdrv(). With
; SHARED_VARIABLE_DRIVE_COUNT effectively pinned to 1 in this phase, this is
; byte-for-byte equivalent to the previous single-drive behaviour.
create_virtual_hard_disk:
    movem.l d1-d3/a5,-(sp)
    move.l (GEMDRVEMUL_SHARED_VARIABLES + (SHARED_VARIABLE_DRIVE_COUNT * 4)), d2       ; d2 = number of active drives
    lea (GEMDRVEMUL_SHARED_VARIABLES + (SHARED_VARIABLE_DRIVE_NUMBER_TABLE * 4)), a5   ; a5 -> drive_number[0]
    move.l _drvbits.w, d3
.create_virtual_hard_disk_loop:
    tst.l d2
    beq.s .create_virtual_hard_disk_done
    move.w 2(a5), d0                     ; d0 = drive_number[slot]
    moveq.l #1, d1
    lsl.l d0, d1                         ; Calculate the bit number of the drive
    or.l d1, d3                          ; Set the drive bit
    addq.l #4, a5                        ; Next slot
    subq.l #1, d2
    bra.s .create_virtual_hard_disk_loop
.create_virtual_hard_disk_done:
    move.l d3, _drvbits.w

    move.w (GEMDRVEMUL_SHARED_VARIABLES + 2 + (SHARED_VARIABLE_DRIVE_NUMBER_TABLE * 4)), -(sp)  ; Slot 0 becomes the current/default drive
    gemdos Dsetdrv, 4                    ; Call Dsetdrv() and set the emulated drive
    movem.l (sp)+, d1-d3/a5
    rts

; Read and validate the multi-drive table set by the Pico after PING:
; protocol version must match exactly, drive count must be in
; 1..SIDETNFS_MAX_RUNTIME_DRIVES, every drive number must be in 0..25 (A..Z), and no
; drive number may appear twice.
; Output: d0.w = 0 if valid, -1 if not (protocol version mismatch or
; malformed table)
; Modifies: d0 only (all other registers preserved)
validate_drive_table:
    movem.l d1-d4/a4-a5,-(sp)

    move.l (GEMDRVEMUL_SHARED_VARIABLES + (SHARED_VARIABLE_PROTOCOL_VERSION * 4)), d0
    cmp.l #GEMDOS_SLOT_PROTOCOL_VERSION, d0
    bne.s .validate_drive_table_fail

    move.l (GEMDRVEMUL_SHARED_VARIABLES + (SHARED_VARIABLE_DRIVE_COUNT * 4)), d1   ; d1 = drive count
    cmp.l #1, d1
    blt.s .validate_drive_table_fail
    cmp.l #SIDETNFS_MAX_RUNTIME_DRIVES, d1
    bgt.s .validate_drive_table_fail

    ; d1 = validated drive count (1..SIDETNFS_MAX_RUNTIME_DRIVES). Check that
    ; every entry is a plausible GEMDOS drive number (0..25 = A..Z) and that
    ; no entry appears twice (O(n^2); n is at most SIDETNFS_MAX_RUNTIME_DRIVES = 9).
    lea (GEMDRVEMUL_SHARED_VARIABLES + (SHARED_VARIABLE_DRIVE_NUMBER_TABLE * 4)), a5 ; a5 -> drive_number[0]
    move.l d1, d4                          ; d4 = outer loop counter (entries left)
.validate_drive_table_outer:
    tst.l d4
    beq.s .validate_drive_table_ok
    move.w 2(a5), d2                       ; d2 = drive_number[i]
    cmp.w #0, d2
    blt.s .validate_drive_table_fail
    cmp.w #25, d2
    bgt.s .validate_drive_table_fail

    ; Compare against every later entry for a duplicate
    lea 4(a5), a4                          ; a4 -> drive_number[i+1]
    move.l d4, d3
    subq.l #1, d3                          ; d3 = number of later entries to check
.validate_drive_table_inner:
    tst.l d3
    beq.s .validate_drive_table_next
    cmp.w 2(a4), d2
    beq.s .validate_drive_table_fail       ; duplicate drive number
    addq.l #4, a4
    subq.l #1, d3
    bra.s .validate_drive_table_inner
.validate_drive_table_next:
    addq.l #4, a5
    subq.l #1, d4
    bra.s .validate_drive_table_outer

.validate_drive_table_ok:
    moveq #0, d0
    bra.s .validate_drive_table_exit
.validate_drive_table_fail:
    moveq #-1, d0
.validate_drive_table_exit:
    movem.l (sp)+, d1-d4/a4-a5
    rts

; Search the active-drive table for a given GEMDOS drive number (0-based:
; A=0, B=1, ...). Used by detect_emulated_drive.
; Input:  d0.w = GEMDOS drive number to look for
; Output: d0.w = slot index (0..SIDETNFS_MAX_RUNTIME_DRIVES-1) if found, -1 if not
; Modifies: d0 only (all other registers preserved)
find_drive_slot_by_number:
    movem.l d1-d2/a5,-(sp)
    move.w d0, d2                        ; d2 = target drive number
    move.l (GEMDRVEMUL_SHARED_VARIABLES + (SHARED_VARIABLE_DRIVE_COUNT * 4)), d1  ; d1 = number of active drives
    lea (GEMDRVEMUL_SHARED_VARIABLES + (SHARED_VARIABLE_DRIVE_NUMBER_TABLE * 4)), a5 ; a5 -> drive_number[0]
    moveq #0, d0                         ; d0 = slot index being tested
.find_drive_slot_by_number_loop:
    tst.l d1
    beq.s .find_drive_slot_by_number_notfound
    cmp.w 2(a5), d2                      ; compare with low word of drive_number[slot]
    beq.s .find_drive_slot_by_number_exit
    addq.l #4, a5                        ; next slot (4 bytes per shared variable)
    addq.w #1, d0
    subq.l #1, d1
    bra.s .find_drive_slot_by_number_loop
.find_drive_slot_by_number_notfound:
    moveq #-1, d0
.find_drive_slot_by_number_exit:
    movem.l (sp)+, d1-d2/a5
    rts

; Search the active-drive table for a given drive letter (uppercase ASCII),
; derived from each slot's drive number as 'A' + drive_number[slot]. Used by
; detect_emulated_drive_letter.
; Input:  d0.b = drive letter to look for
; Output: d0.w = slot index (0..SIDETNFS_MAX_RUNTIME_DRIVES-1) if found, -1 if not
; Modifies: d0 only (all other registers preserved)
find_drive_slot_by_letter:
    movem.l d1-d3/a5,-(sp)
    and.l #$FF, d0
    move.w d0, d2                        ; d2 = target drive letter
    move.l (GEMDRVEMUL_SHARED_VARIABLES + (SHARED_VARIABLE_DRIVE_COUNT * 4)), d1
    lea (GEMDRVEMUL_SHARED_VARIABLES + (SHARED_VARIABLE_DRIVE_NUMBER_TABLE * 4)), a5
    moveq #0, d0
.find_drive_slot_by_letter_loop:
    tst.l d1
    beq.s .find_drive_slot_by_letter_notfound
    move.w 2(a5), d3                     ; d3 = drive_number[slot]
    add.w #'A', d3                       ; d3 = corresponding drive letter
    cmp.w d3, d2
    beq.s .find_drive_slot_by_letter_exit
    addq.l #4, a5
    addq.w #1, d0
    subq.l #1, d1
    bra.s .find_drive_slot_by_letter_loop
.find_drive_slot_by_letter_notfound:
    moveq #-1, d0
.find_drive_slot_by_letter_exit:
    movem.l (sp)+, d1-d3/a5
    rts

; Get the cookie jar from d0.l as parameter
save_vectors:
    cmp.l #COOKIE_JAR_MEGASTE, d0    ; Check if the computer is a MegaSTE
    beq.s .save_vectors_megaste      ; If it is a MegaSTE, use the trap with speed and cache change
    move.l #gemdrive_trap,-(sp)      ; Otherwise, use the standard entry point
    bra.s .save_vectors_continue
.save_vectors_megaste:
    move.l #gemdrive_trap_megaste16,-(sp)
.save_vectors_continue:
    move.w #VEC_GEMDOS,-(sp)
    move.w #5,-(sp)                     ; Setexc() modify GEMDOS vector and add our trap
    trap #13
    addq.l #8,sp

    move.l d0, d3                       ; Address of the old GEMDOS vector
    move.l #old_handler, d4             ; Address of the old handler
    send_sync CMD_SAVE_VECTORS, 8       ; Send the command to the Sidecart. 8 bytes of payload
    tst.w d0                            ; 0 if no error
    bne.s _read_timeout                 ; The RP2040 is not responding, timeout now
    rts

_read_timeout:
    moveq #-1, d0
    rts


    dc.l 'XBRA'                             ; XBRA structure
    dc.l 'SDGD'                             ; Put your cookie here
old_handler:
    dc.l 0                                  ; We can't modify this address because it's in ROM, but we can modify it in the RP2040 memory

    even

gemdrive_trap_megaste16:
; Disable the CPU 16Mhz and Cache 

    move.b MEGASTE_SPEED_CACHE_REG.w, d1           ; Save the old value of cpu speed
    and.b #%00000001,MEGASTE_SPEED_CACHE_REG.w     ; disable MSTe cache
; 
; Shortcut in case of reentry (Code repeated for performance reasons)
;
    btst #0, GEMDRVEMUL_REENTRY_TRAP    ; Check if the reentry is locked
    beq.s exec_trapped_handler         ; If the bit is active, we are in a reentry call. We need to exec_old_handler the code

    restore_cpu_cache
    move.l old_handler,-(sp)            ; Fake a return
    rts                                 ; to old code.

gemdrive_trap:
; 
; Shortcut in case of reentry
;
    btst #0, GEMDRVEMUL_REENTRY_TRAP    ; Check if the reentry is locked
    beq.s exec_trapped_handler         ; If the bit is active, we are in a reentry call. We need to exec_old_handler the code

    move.l old_handler,-(sp)            ; Fake a return
    rts                                 ; to old code.

;
; No reentry, we can exec the trapped handler
; But first, check user or supervisor mode and the CPU type
;
exec_trapped_handler:
    btst #5, (sp)                         ; Check if called from user mode
    beq.s _user_mode                      ; if so, do correct stack pointer
_not_user_mode:
    move.l sp,a0                          ; Move stack pointer to a0
    bra.s _check_cpu
_user_mode:
    move.l usp,a0                          ; if user mode, correct stack pointer
    subq.l #6,a0
;
; This code checks if the CPU is a 68000 or not
;
_check_cpu:
    tst.w _longframe                          ; Check if the CPU is a 68000 or not
    beq.s _notlong
_long:
    addq.w #2, a0                             ; Correct the stack pointer parameters for long frames 
_notlong:

;
; Trap #1 handler goes here
;
    save_regs

    move.w 6(a0),d3                      ; get GEMDOS opcode number
;    cmp.w #$0e, d3                       ; Check if it's a Dsetdrv() call
;    beq.s .Dsetdrv
;    cmp.w #$19, d3                       ; Check if it's a Dgetdrv() call
;    beq.s .Dgetdrv
;    cmp.w #$1a, d3                       ; Check if it's a Fsetdta() call
;    beq .Fsetdta
    cmp.w #Dfree, d3                     ; Check if it's a Dfree() call
    beq .Dfree
    cmp.w #$39, d3                       ; Check if it's a Dcreate() call
    beq .Dcreate
    cmp.w #$3a, d3                       ; Check if it's a Ddelete() call
    beq .Ddelete
    cmp.w #$3b, d3                       ; Check if it's a Dsetpath() call
    beq .Dsetpath
    cmp.w #$3c, d3                       ; Check if it's a Fcreate() call
    beq .Fcreate
    cmp.w #$47, d3                       ; Check if it's a Dgetpath() call
    beq .Dgetpath
    cmp.w #$3d, d3                       ; Check if it's a Fopen() call
    beq .Fopen
    cmp.w #$3e, d3                       ; Check if it's a Fclose() call
    beq .Fclose
    cmp.w #Frename, d3                   ; Check if it's a Frename() call
    beq .Frename
    cmp.w #Fdatime, d3                 ; Check if it's a Fdatetime() call
    beq .Fdatime
    cmp.w #$3f, d3                       ; Check if it's a Fread() call
    beq .Fread
    cmp.w #$40, d3                       ; Check if it's a Fwrite() call
    beq .Fwrite
    cmp.w #Fattrib, d3                   ; Check if it's a Fattrib() call
    beq .Fattrib
    cmp.w #$4e, d3                       ; Check if it's a Fsfirst() call
    beq .Fsfirst
    cmp.w #$4f, d3                       ; Check if it's a Fsnext() call
    beq .Fsnext
    cmp.w #Pexec, d3                     ; Check if it's a Pexec() call
    beq .Pexec
    cmp.w #$41, d3                       ; Check if it's a Fdelete() call
    beq .Fdelete
    cmp.w #Fseek, d3                     ; Check if it's a Fseek() call
    beq .Fseek

.show_vector_calls:
    ; Trace the not implemented GEMDOS call
;    send_sync CMD_SHOW_VECTOR_CALL, 2    ; Send the command to the Sidecart. 2 bytes of payload

.exec_old_handler:
    restore_regs
    restore_cpu_cache
    move.l old_handler,-(sp)            ; Fake a return
    rts                                 ; to old code.

; Start of the GEMDOS calls
.Fsetdta:
    move.l 8(a0),d3                      ; get address of DTA and save in the payload
    send_sync CMD_FSETDTA_CALL, 4        ; Send the command to the Sidecart. 4 bytes of payload
    bra .exec_old_handler

; Get the storage space available on the disk
.Dfree:
    move.w 8(a0),d3                      ; get the drive number
    subq.w #1, d3                        ; Remove 1 to the drive number. I don't want to use the default drive
    move.w d3, d0                        ; d0 = drive number to search for
    bsr find_drive_slot_by_number        ; d0 = slot index, or -1 if not one of the emulated drives
    tst.w d0
    bmi .exec_old_handler                ; If not, exec_old_handler the code
    move.l 10(a0),a4                     ; get the address of the structure to store the information
    send_sync CMD_DFREE_CALL, 2          ; Send the command to the Sidecart. 2 bytes of payload

    move.l GEMDRVEMUL_DFREE_STATUS, d0   ; Copy here the result status of the Dfree call
    tst.l d0                             ; Check if the call was successful
    bne.s .Dfree_exit                    ; If not, exit with the error code
    ; Copy here to the DISKINFO structure pointed by a4
    move.l GEMDRVEMUL_DFREE_STRUCT, a5   ; Address of the structure where the result is stored
    move.l (a5)+, (a4)+                  ; Copy the total number of free clusters
    move.l (a5)+, (a4)+                  ; Copy the number of clusters per drive
    move.l (a5)+, (a4)+                  ; Copy the number of bytes per sector
    move.l (a5)+, (a4)+                  ; Copy the number of sectors per cluster
    ; We are done, exit with the success code
.Dfree_exit:
    return_rte

.Dcreate:
    move.l 8(a0),a4                      ; get the fpath address

    detect_emulated_drive_letter         ; If not, exec_old_handler the code. Otherwise continue with the code

    send_write_sync CMD_DCREATE_CALL, 256 ; Send the command to the Sidecart. 256 bytes of buffer to send

    return_interrupt_w GEMDRVEMUL_DCREATE_STATUS    ; Return the error code from the Sidecart

.Ddelete:
    move.l 8(a0),a4                      ; get the fpath address

    detect_emulated_drive_letter         ; If not, exec_old_handler the code. Otherwise continue with the code

    send_write_sync CMD_DDELETE_CALL, 256 ; Send the command to the Sidecart. 256 bytes of buffer to send

    return_interrupt_w GEMDRVEMUL_DDELETE_STATUS    ; Return the error code from the Sidecart


.Dsetpath:
    move.l 8(a0),a4                      ; Address to the new GEMDOS path

    detect_emulated_drive_letter         ; If not, exec_old_handler the code. Otherwise continue with the code.
                                         ; d0.w = slot index of the matched drive: the explicit "X:" prefix in the
                                         ; path if present, otherwise the current GEMDOS drive (via Dgetdrv())

    ; This is the emulated drive, it's our moment!
    move.w d0, d3                        ; d3.w = slot index, sent as the first word of the CMD_DSETPATH_CALL payload
    send_write_sync CMD_DSETPATH_CALL, 256

    return_interrupt_w GEMDRVEMUL_SET_DPATH_STATUS ; Return the error code from the Sidecart

.Dgetpath:
    move.l 8(a0),a4                      ; Address to the  new GEMDOS path
    move.w 12(a0),d3                     ; get the drive number
    tst.w d3                             ; Check if the drive number is 0 (current drive)
    beq.s .Dgetpath_current_drive        ; If it's the current drive, continue with the code
    subq.w #1, d3                        ; Remove 1 to the drive number. A is 0, B is 1, C is 2, etc.
    move.w d3, d0                        ; d0 = drive number to search for
    bsr find_drive_slot_by_number        ; d0 = slot index, or -1 if not one of the emulated drives
    tst.w d0
    bmi .exec_old_handler                ; If not, exec_old_handler the code

.Dgetpath_current_drive:
;    detect_emulated_drive                ; Check if the drive is the emulated one. If not, exec_old_handler the code.
    ; This is the emulated drive, it's our moment!
    send_sync CMD_DGETPATH_CALL, 2       ; Two bytes of payload

    move.w #$7F, d0                      ; Maximum length of the path
    lea GEMDRVEMUL_DEFAULT_PATH, a5      ; Address of the default path
.Dgetpath_copy:
    tst.b (a5)
    beq.s .Dgetpath_copy_done
    move.b (a5)+, (a4)+                  ; Copy the path
    dbf d0, .Dgetpath_copy

.Dgetpath_copy_done:
    move.b #0, (a4)                      ; Add the null terminator
    move.w #0, d0                        ; Error code. -33 is the error code for the file not found
    ext.l d0                             ; Extend the sign of the value
    return_rte

.Fopen:
    move.l 8(a0),a4                      ; get the fpname address
    move.w 12(a0),d3                     ; get mode attribute

    detect_emulated_drive_letter         ; If not, exec_old_handler the code. Otherwise continue with the code

    ; This is an emulated drive, it's our moment!
    send_write_sync CMD_FOPEN_CALL, 256
    
    return_interrupt_l GEMDRVEMUL_FOPEN_HANDLE    ; Return the error code from the Sidecart

.Fclose:
    move.w 8(a0),d3                      ; get the file handle
    and.l #$FFFF, d3                     ; Mask the upper word of the file handle

    detect_emulated_file_handler         ; If not emulated, exec_old_handler the code. Otherwise continue with the code

    send_sync CMD_FCLOSE_CALL, 2         ; Send the command to the Sidecart.

    return_interrupt_w GEMDRVEMUL_FCLOSE_STATUS    ; Return the error code from the Sidecart

.Fcreate:
    move.l 8(a0),a4                      ; get the fpname address
    move.w 12(a0),d3                     ; get mode attribute

    detect_emulated_drive_letter         ; If not, exec_old_handler the code. Otherwise continue with the code

    ; This is an emulated drive, it's our moment!
    send_write_sync CMD_FCREATE_CALL, 256

    return_interrupt_w GEMDRVEMUL_FCREATE_HANDLE    ; Return the error code from the Sidecart

.Fdelete:
    move.l 8(a0),a4                      ; get the fpname address

    detect_emulated_drive_letter         ; If not, exec_old_handler the code. Otherwise continue with the code

    ; This is an emulated drive, it's our moment!
    send_write_sync CMD_FDELETE_CALL, 256

    return_interrupt_w GEMDRVEMUL_FDELETE_STATUS    ; Return the error code from the Sidecart

.Frename:
    move.l 10(a0),a5                     ; get the fpname address
    move.l 14(a0),a6                    ; get the new fpname address

    detect_emulated_drive_letter         ; If not, exec_old_handler the code. Otherwise continue with the code

    lea -256(sp), sp
    move.l sp, a4

    move.w #127, d3
.frename_copy_src:
    move.b (a5)+, (a4)+
    dbf d3, .frename_copy_src

    move.w #127, d3
.frename_copy_dst:
    move.b (a6)+, (a4)+
    dbf d3, .frename_copy_dst

    move.l sp, a4
    ; This is an emulated drive, it's our moment!
    send_write_sync CMD_FRENAME_CALL, 256
    lea 256(sp), sp

    return_interrupt_l GEMDRVEMUL_FRENAME_STATUS    ; Return the error code from the Sidecart

.Fseek:
    move.l 8(a0),d4                      ; get the offset
    move.w 12(a0),d3                     ; get the handle
    move.w 14(a0),d5                     ; get the mode

    detect_emulated_file_handler         ; If not emulated, exec_old_handler the code. Otherwise continue with the code

    send_sync CMD_FSEEK_CALL, 12         ; Send the command to the Sidecart. 12 bytes of payload

    return_interrupt_l GEMDRVEMUL_FSEEK_STATUS    ; Return the error code from the Sidecart or the absolute position

.Fattrib:
    move.l 8(a0),a4                      ; get the fpname address
    move.w 12(a0),d3                     ; get the mode attribute
    move.w 14(a0),d4                     ; get the attribute

    detect_emulated_drive_letter         ; If not, exec_old_handler the code. Otherwise continue with the code

    ; This is an emulated drive, it's our moment!
    send_write_sync CMD_FATTRIB_CALL, 128

    return_interrupt_l GEMDRVEMUL_FATTRIB_STATUS    ; Return the error code from the Sidecart

.Fdatime:
    move.l 8(a0),a4                      ; get the datetime struct address
    move.w 12(a0),d4                     ; get the handle
    move.w 14(a0),d3                     ; get the flag
    move.l 0(a4), d5                     ; get the datetime information (DOSTIME)
    move.l 4(a4), d6                     ; get the datetime information (DOSDATE)
    and.l #$FFFF, d3                     ; Mask the upper word of the flag
    and.l #$FFFF, d4                     ; Mask the upper word of the handle


    detect_emulated_drive_letter         ; If not, exec_old_handler the code. Otherwise continue with the code

    move.l a4, -(sp)
    ; This is an emulated drive, it's our moment!
    send_sync CMD_FDATETIME_CALL, 16
    move.l (sp)+, a4
    
    lea GEMDRVEMUL_FDATETIME_TIME, a6
    move.b 2(a6), 0(a4)
    move.b 3(a6), 1(a4)
    lea GEMDRVEMUL_FDATETIME_DATE, a6
    move.b 2(a6), 2(a4)
    move.b 3(a6), 3(a4)

    return_interrupt_l GEMDRVEMUL_FDATETIME_STATUS    ; Return the error code from the Sidecart

.Fread:
    move.w 8(a0),d3                      ; get the file handle
    move.l 10(a0),d4                     ; get number of bytes to read
    move.l 14(a0),a4                     ; get address of buffer to read into

    detect_emulated_file_handler         ; If not emulated, exec_old_handler the code. Otherwise continue with the code

    bsr.s .Fread_core                    ; Read the data from the Sidecart

;    movem.l d0-d7/a0-a6, -(sp)
;    move.l d0, d3
;    send_sync CMD_DEBUG, 4
;    movem.l (sp)+,d0-d7/a0-a6

    return_rte

.Fread_core:
    move.l d4, d5                        ; Save the number of bytes to read in d5
    clr.l  d6                            ; d6 is the bytes read counter
.fread_loop:
    tst.l (GEMDRVEMUL_SHARED_VARIABLES + (SHARED_VARIABLE_BUFFER_TYPE * 4))
    bne.s .fread_loop_use_stack_buffer
    move.l _dskbufp, a5               ; Address of the buffer to read the data from the Sidecart
    movem.l d3-d7, DSKBUFP_TMP_ADDR(a5) ; Save the registers
    send_sync CMD_READ_BUFF_CALL, 12     ; Send the command to the Sidecart. handle.w, padding.w, bytes_to_read.l, pending_bytes_to_read.l
    move.l _dskbufp, a5               ; Address of the buffer to read the data from the Sidecart
    movem.l DSKBUFP_TMP_ADDR(a5), d3-d7 ; Restore the registers
    bra.s .fread_loop_continue
.fread_loop_use_stack_buffer:
    movem.l d3-d7, -(sp)                 ; Save the registers
    send_sync CMD_READ_BUFF_CALL, 12     ; Send the command to the Sidecart. handle.w, padding.w, bytes_to_read.l, pending_bytes_to_read.l
    movem.l (sp)+,d3-d7                 ; Restore the registers

.fread_loop_continue
    tst.w d0                             ; Check if there is an error
    beq.s .fread_command_ok              ; If not, we can continue
    moveq.l #GEMDOS_EINTRN, d0           ; Error code. GEMDOS_EINTRN is the error code for the internal error
    bra .fread_exit                      ; Exit the loop

.fread_command_ok:
    move.l GEMDRVEMUL_READ_BYTES, d0     ; The number of bytes actually read from the Sidecart or the error code
    ext.l d0                             ; Extend the sign of the value
    ; If d0 is negative, there is an error
    bmi .fread_exit                      ; Exit the loop
    tst.l d0                             ; Check if the number of bytes read is 0
    beq .fread_exit_ok                   ; If 0, we are done
    lea GEMDRVEMUL_READ_BUFFER, a5       ; Address of the buffer to copy the data from the Sidecart
    move.l a4, d7                        ; Test if the dest address is odd or even
    btst #0, d7                          ; Check if the address is odd
    beq.s .fread_loop_copy_even          ; If even go to copy longword 
.fread_copy_odd:
    move.l d0, d7                        ; Number of bytes to copy to the buffer
    subq.l #1, d7                        ; We need to copy one byte less because dbf counts 0
.fread_loop_copy:
    move.b (a5)+, (a4)+                  ; Copy the byte
    dbf d7, .fread_loop_copy             ; Loop until we copy all the bytes
    bra .fread_copy_exit               ; No copy anymore

.fread_loop_copy_even:
    move.l d0, d7                        ; Number of bytes to copy to the buffer
    lsr.l #1, d7                         ; Divide the number of bytes by 2
    btst #1, d7                          ; Check if can copy longwords
    beq.s .fread_loop_copy_lword_even    ; If so, copy longwords
    subq.l #1, d7                        ; We need to copy one byte less because dbf counts 0
.fread_loop_copy_word:
    move.w (a5)+, (a4)+                  ; Copy word
    dbf d7, .fread_loop_copy_word        ; Loop until we copy all the bytes
    btst #0, d0                          ; Check if the number of bytes to copy is odd
    beq.s .fread_copy_exit               ; If not, we are done
    move.b (a5)+, (a4)+                  ; Copy the last byte
    bra.s .fread_copy_exit               ; No copy anymore

.fread_loop_copy_lword_even:
    move.l d0, d7                        ; Number of bytes to copy to the buffer
    lsr.l #2, d7                         ; Divide the number of words by 4
    tst.l d7                             ; Check if we have to copy the last bytes
    beq.s .fread_loop_copy_tail_bytes    ; if zero, only copy the last bytes
    subq.l #1, d7                        ; We need to copy one byte less because dbf counts 0

    cmp.l #8, d7
    blt.s .fread_loop_copy_lword
    
    move.l d1, -(sp)                     ; Save the register D1
    move.l d7, d1                        ; Use D1 as loop counter for the unrolled amount
    lsr.l #3, d1                         ; Divide the number of words by 8
    and.l #$7, d7                        ; remaining amount of words in d7
    subq.l #1, d1                        ; We need to copy one byte less because dbf counts 0
.fread_loop_copy_lword_unroll_by8:      ; 8x unrolled loop
    move.l (a5)+, (a4)+                  ; Copy longword
    move.l (a5)+, (a4)+                  ; Copy longword
    move.l (a5)+, (a4)+                  ; Copy longword
    move.l (a5)+, (a4)+                  ; Copy longword
    move.l (a5)+, (a4)+                  ; Copy longword
    move.l (a5)+, (a4)+                  ; Copy longword
    move.l (a5)+, (a4)+                  ; Copy longword
    move.l (a5)+, (a4)+                  ; Copy longword
    dbf d1, .fread_loop_copy_lword_unroll_by8
    move.l (sp)+,d1                      ; Restore the register D1
    
    cmp.l #4, d7
    blt.s .fread_loop_copy_lword
.fread_loop_copy_lword_unroll_by4:       ; unrolled by 4
    move.l (a5)+, (a4)+                  ; Copy longword
    move.l (a5)+, (a4)+                  ; Copy longword
    move.l (a5)+, (a4)+                  ; Copy longword
    move.l (a5)+, (a4)+                  ; Copy longword
    subq.l #4,d7
  
.fread_loop_copy_lword:
    move.l (a5)+, (a4)+                  ; Copy longword
    dbf d7, .fread_loop_copy_lword       ; Loop until we copy all the bytes

    move.l d0, d7                        ; Number of bytes to copy to the buffer
    and.l #%11, d7                       ; Check if we have to copy the last bytes        
    beq.s .fread_copy_exit               ; If not, we are done
    subq.l #1, d7                        ; We need to copy one byte less because dbf counts 0
.fread_loop_copy_tail_bytes:
    move.b (a5)+, (a4)+                  ; Copy the last byte
    dbf d7, .fread_loop_copy_tail_bytes  ; No copy anymore


.fread_copy_exit:
    add.l d0, d6                         ; Add the number of bytes read to the counter
    cmp.l #BUFFER_READ_SIZE, d0          ; Check if the number of bytes read is not equal than the buffer size
    bne.s .fread_exit_ok                 ; if not equal, it's smaller than the buffer size. We are done

    sub.l d0, d5                         ; Subtract the number of bytes read from the total number of bytes to read
    bpl .fread_loop                    ; If there are more bytes to read, continue

.fread_exit_ok:
    move.l d6, d0                        ; Return the number of bytes read

.fread_exit:
    rts


.Fwrite:
    move.w 8(a0),d3                      ; get the file handle
    move.l 10(a0),d4                     ; get number of bytes to write
    move.l 14(a0),a4                     ; get address of buffer to the data to write

    detect_emulated_file_handler         ; If not emulated, exec_old_handler the code. Otherwise continue with the code

    bsr.s .Fwrite_core                    ; Read the data from the Sidecart

    return_rte

.Fwrite_core:
    move.l d4, d5                        ; Save the number of bytes to write in d5
    clr.l  d6                            ; d6 is the bytes write counter
.fwrite_loop:
    move.w #FWRITE_RETRIES, d7           ; Number of retries to write the data to the Sidecart    
.fwrite_loop_retry:
    tst.w d7                             ; Check if the number of retries is 0
    bne.s .fwrite_loop_retry_start       ; If not 0, simply retry to send the data
    moveq.l #GEMDOS_EINTRN, d0           ; Error code. GEMDOS_EINTRN is the error code for the internal error
    bra .fwrite_exit                   ; Exit the loop
.fwrite_loop_retry_start:                ; Start the loop to retry to send the data
    tst.l (GEMDRVEMUL_SHARED_VARIABLES + (SHARED_VARIABLE_BUFFER_TYPE * 4))
    bne.s .fwrite_loop_use_stack_buffer
    move.l _dskbufp, a5                    ; Address of the buffer to read the data from the Sidecart
    movem.l d3-d7/a4, DSKBUFP_TMP_ADDR(a5) ; Save the registers
    send_write_sync CMD_WRITE_BUFF_CALL, BUFFER_WRITE_SIZE       ; Send the command to the Sidecart. handle.w, padding.w, bytes_to_read.l, pending_bytes_to_read.l
    move.l d7, d1                          ; CHECKSUM value
    move.l _dskbufp, a5                    ; Address of the buffer to read the data from the Sidecart
    movem.l DSKBUFP_TMP_ADDR(a5), d3-d7/a4 ; Restore the registers
    bra.s .fwrite_loop_continue
.fwrite_loop_use_stack_buffer:
    movem.l d3-d7/a4, -(sp)                ; Save the registers
    send_write_sync CMD_WRITE_BUFF_CALL, BUFFER_WRITE_SIZE       ; Send the command to the Sidecart. handle.w, padding.w, bytes_to_read.l, pending_bytes_to_read.l
    move.l d7, d1                          ; CHECKSUM value
    movem.l (sp)+,d3-d7/a4                 ; Restore the registers

.fwrite_loop_continue
    tst.w d0                             ; Check if there is an error
    beq.s .fwrite_command_ok             ; If not, we can continue
    moveq.l #GEMDOS_EINTRN, d0           ; Error code. GEMDOS_EINTRN is the error code for the internal error
    bra .fwrite_exit                     ; Exit the loop

; Calculate the CHK value of the buffer to write
.fwrite_command_ok:
    subq.w #1, d7                        ; Subtract 1 to the number of retries
    move.l GEMDRVEMUL_WRITE_BYTES, d2    ; The number of bytes to check the CHK
    tst.l d2                             ; Check if the number of bytes to check the CHK is 0
    beq.s .fwrite_check_crc_exit         ; If 0, bypass the test

    cmp.l GEMDRVEMUL_WRITE_CHK, d1       ; Check if the CHK value is the same
    bne.s .fwrite_loop_retry             ; If not, retry to send the data until the number of retries is 0

.fwrite_check_crc_exit:
    add.l d2, a4
    tst.l (GEMDRVEMUL_SHARED_VARIABLES + (SHARED_VARIABLE_BUFFER_TYPE * 4))
    bne.s .fwrite_check_use_stack_buffer
    move.l _dskbufp, a5                    ; Address of the buffer to read the data from the Sidecart
    movem.l d3-d7/a4, DSKBUFP_TMP_ADDR(a5) ; Save the registers

    ; Send the command to the Sidecart. Bytes to move forward the offset in d4.l. handle.w in d3.w
    move.l GEMDRVEMUL_WRITE_BYTES, d4    ; The number of bytes to move forward the offset
    send_sync CMD_WRITE_BUFF_CHECK, 8
    move.l _dskbufp, a5                    ; Address of the buffer to read the data from the Sidecart
    movem.l DSKBUFP_TMP_ADDR(a5), d3-d7/a4 ; Restore the registers
    bra.s .fwrite_check_continue
.fwrite_check_use_stack_buffer:
    movem.l d3-d7/a4, -(sp)                ; Save the registers

    ; Send the command to the Sidecart. Bytes to move forward the offset in d4.l. handle.w in d3.w
    move.l GEMDRVEMUL_WRITE_BYTES, d4    ; The number of bytes to move forward the offset
    send_sync CMD_WRITE_BUFF_CHECK, 8
    movem.l (sp)+,d3-d7/a4                 ; Restore the registers

.fwrite_check_continue
    move.l GEMDRVEMUL_WRITE_BYTES, d0    ; The number of bytes actually write to the Sidecart or the error code
    ext.l d0                             ; Extend the sign of the value
    ; If d0 is negative, there is an error
    bmi.s .fwrite_exit                   ; Exit the loop
    tst.l d0                             ; Check if the number of bytes written is 0
    beq.s .fwrite_exit_ok                ; If 0, we are done

    add.l d0, d6                         ; Add the number of bytes written to the counter
    cmp.w #BUFFER_WRITE_SIZE, d0         ; Check if the number of bytes written is not equal than the buffer size
    bne.s .fwrite_exit_ok                ; if not equal, it's smaller than the buffer size. We are done

    sub.l d0, d5                         ; Subtract the number of bytes written from the total number of bytes to write
    bpl .fwrite_loop                     ; If there are more bytes to write, continue

.fwrite_exit_ok:
    move.l d6, d0                        ; Return the number of bytes written

.fwrite_exit:
    rts


.Fsfirst:
    move.l 8(a0), a4                     ; Get the address of the file specification string
    move.w 12(a0),d4                     ; get attribs

    cmp.b #':', 1(a4)                    ; Check if the second character of the file specification string is the colon
    bne .fs_first_check_drive            ; If not, go and check if the drive is the emulated one or not
    move.b (a4), d0                      ; Get the first character of the file specification string
.fs_first_check_drive_others:

    bsr find_drive_slot_by_letter        ; d0 = slot index, or -1 if not one of the emulated drives
    tst.w d0
    bpl.s .fs_first_emulated             ; If found, execute specific fsfirst emulated code
    bra .exec_old_handler              ; Now it's safe to execute the old handler
; We need to clean the DTA to avoid issues with previous DTAs used in the emulated code
;    reentry_gem_lock
;    gemdos Fgetdta, 2                    ; Call Fgetdta() and get the address of the DTA
;    move.l d0, -(sp)                     ; Save the return value with the address of the DTA
;    reentry_gem_unlock
;    move.l (sp)+, d3                     ; Restore the DTA value

;    move.l _sysbase, a6
;    move.l 40(a6), a6
;    move.l 0(a6), d3                     ; Pointer to the BASEPAGE structure of the process
;    add.l #BASEPAGE_OFFSET_DTA, d3       ; Address of the DTA in the BASEPAGE structure

;    send_sync CMD_DTA_RELEASE_CALL, 4    ; Send the command to the Sidecart. 4 bytes of payload

.fs_first_check_drive:
    detect_emulated_drive                ; If not, exec_old_handler the code. Otherwise continue with the code

;    bra .exec_old_handler                ; Now it's safe to execute the old handler

.fs_first_emulated:
    reentry_gem_lock

    gemdos Fgetdta, 2                    ; Call Fgetdta() and get the address of the DTA
    move.l d0, -(sp)                     ; Save the return value with the address of the DTA

    reentry_gem_unlock

    move.l (sp), d3                            ; Restore the DTA value
    move.l a4, d5                              ; Save the address of the file specification string
    send_write_sync CMD_FSFIRST_CALL, 192      ; Send the command to the Sidecart. 256 bytes of buffer to send

.populate_fsdta_struct:
    move.l (sp)+, a5                            ; Restore the DTA value into a5

    ; Test if there is a file found
    move.w GEMDRVEMUL_DTA_F_FOUND, d0           ; Get the value of the file found
    ext.l d0                                    ; Extend the sign of the value
    ; A file found, restore the DTA from the Sidecart
    lea GEMDRVEMUL_DTA_TRANSFER, a4             ; Address of the buffer to receive the DTA
    move.l #43, d2                              ; Number of bytes to read
.populate_fsdta_struct_loop:
    move.b (a4)+, (a5)+                         ; Copy the DTA
    dbf d2, .populate_fsdta_struct_loop         ; Loop until we copy all the bytes
;    tst.w d0                                    ; If the value is 0, there is a file found (E_OK)
;    bne.s .empty_fsdta_struct                   ; If not, exit with the error code
    return_rte

;.empty_fsdta_struct:
;    move.l d0, -(sp)                            ; Save the return value of the operation with the DTA
;    send_sync CMD_DTA_RELEASE_CALL, 4           ; Send the command to the Sidecart. 4 bytes of payload
;    move.l (sp)+, d0                            ; Restore the return value with the address of the DTA
;    move.l #$ffffffd1, d0                       ; Error code. -47 is the error code for the no more files found
;    return_rte

.Fsnext:
    reentry_gem_lock
    gemdos Fgetdta, 2                     ; Call Fgetdta() and get the address of the DTA
    move.l d0, -(sp)                      ; Save the return value with the address of the DTA
    reentry_gem_unlock

    move.l (sp), d3                       ; Check if the DTA exists in the rp2040 memory
    send_sync CMD_DTA_EXIST_CALL, 4       ; Send the command to the Sidecart. 4 bytes of payload
    move.l GEMDRVEMUL_DTA_EXIST, d0       ; Restore the DTA value
    tst.l d0                              ; Check if the DTA exists
    beq.s .Fsnext_bypass                  ; If not, exec_old_handler the code

    move.l d0, d3                         ; Restore the DTA value
    send_sync CMD_FSNEXT_CALL, 4          ; Send the command to the Sidecart.

    bra .populate_fsdta_struct

.Fsnext_bypass:
    ; Force the exec_old_handler
    move.l (sp)+, d0                      ; Restore the DTA value into a scratch register
    bra .exec_old_handler

.Pexec:
    move.l a0, d4                         ; Otherwise continue with the code
    move.w 8(a0), d3                      ; get the Pexec mode
    move.l 10(a0), a4                     ; get the address of the file name string
    move.l a4, d5
    move.l 14(a0), d6                     ; get the address of the command line string
    move.l 18(a0), d7                     ; get the address of the environment string

    detect_emulated_drive_letter          ; If not, exec_old_handler the code. Otherwise continue with the code

    send_sync CMD_PEXEC_CALL, 20          ; Send the command to the Sidecart. 16 bytes of buffer to send    

    cmp.w #PE_LOAD_GO, GEMDRVEMUL_PEXEC_MODE    ; Check if the mode is PE_LOAD_GO
    beq.s .pexec_load_go                        ; If yes, continue with the code
    cmp.w #PE_LOAD, GEMDRVEMUL_PEXEC_MODE       ; Check if the mode is PE_LOAD
    bne .exec_old_handler                       ; if not, exec_old_handler the code

.pexec_load_go:
    clr.w d3                              ; open mode read only 
    send_write_sync CMD_FOPEN_CALL, 256
    move.l GEMDRVEMUL_FOPEN_HANDLE, d0    ; Error code obtained from the Sidecart
    ; If d0 is negative, there is an error
    bmi .pexec_exit                     ; If there is an error, exit

.pexec_load_header:

    move.w d0,d3                            ; get the file handle
    move.l #PRG_STRUCT_SIZE,d4           ; get number of bytes to read

;    ifeq USE_DSKBUF
;        move.l _dskbufp, a4                  ; Address of the buffer to read the data from the Sidecart
;        lea DSKBUFP_SWAP_ADDR(a4), a4        ; This is the swap area
;        bsr .Fread_core                      ; Read the data from the Sidecart
;        move.l _dskbufp, a4                  ; Address of the buffer to read the data from the Sidecart
;        lea DSKBUFP_SWAP_ADDR(a4), a4        ; This is the swap area
;    else    
;        sub.l #PRG_STRUCT_SIZE,sp            ; reserve space for the header of the file
;        move.l sp,a4                         ; get address of buffer to read into
;        move.l a4, -(sp)                     ; Save the address of the buffer to read
;        bsr .Fread_core                      ; Read the data from the Sidecart
;        move.l (sp)+, a4                     ; Restore the address of the buffer to read
;    endif

    tst.l (GEMDRVEMUL_SHARED_VARIABLES + (SHARED_VARIABLE_BUFFER_TYPE * 4))
    bne.s .pexec_load_header_use_stack_buffer
    move.l _dskbufp, a4                  ; Address of the buffer to read the data from the Sidecart
    lea DSKBUFP_SWAP_ADDR(a4), a4        ; This is the swap area
    bsr .Fread_core                      ; Read the data from the Sidecart
    move.l _dskbufp, a4                  ; Address of the buffer to read the data from the Sidecart
    lea DSKBUFP_SWAP_ADDR(a4), a4        ; This is the swap area    
    bra.s .pexec_load_header_continue
.pexec_load_header_use_stack_buffer:
    sub.l #PRG_STRUCT_SIZE,sp            ; reserve space for the header of the file
    move.l sp,a4                         ; get address of buffer to read into
    move.l a4, -(sp)                     ; Save the address of the buffer to read
    bsr .Fread_core                      ; Read the data from the Sidecart
    move.l (sp)+, a4                     ; Restore the address of the buffer to read

.pexec_load_header_continue:
    cmp.l #PRG_STRUCT_SIZE,d0            ; Check if the number of bytes read is not equal than the buffer size
    bne   .pexec_close_exit_fix_hdr_buf  ; if not equal, it's smaller than the buffer size. We are done
    cmp.w #PRG_MAGIC_NUMBER, 0(a4)       ; Check if the magic number is correct
    bne   .pexec_close_exit_fix_hdr_buf  ; if not equal, it's not a valid PRG file. We are done

; Send all the structure read from the header of the file
    send_write_sync CMD_SAVE_EXEC_HEADER, $1c   ; Send the command to the Sidecart

;    ifeq USE_DSKBUF
;        nop
;    else    
;        add.l #PRG_STRUCT_SIZE,sp            ; restore the stack pointer
;    endif

    tst.l (GEMDRVEMUL_SHARED_VARIABLES + (SHARED_VARIABLE_BUFFER_TYPE * 4))
    beq.s .pexec_load_header_not_restore_stack
    add.l #PRG_STRUCT_SIZE,sp            ; restore the stack pointer

.pexec_load_header_not_restore_stack:
; Save in the SidecarT the basepage of the current process for later use
; Get the values from _sysbase
;    move.l _sysbase, a4
;    move.l 40(a4), a4
;    move.l 0(a4), a4
;    send_write_sync CMD_SAVE_BASEPAGE, 256 ; Send the command to the Sidecart. 256 bytes of buffer to send

; Shrink the memory of the current process, if necessary
; Get the values from _sysbase
;    reentry_gem_lock
;    move.l _sysbase, a4
;    move.l 40(a4), a4
;    clr.l -(sp)                          ; NULL address of the environment string
;    move.l 0(a4), -(sp)                  ; Pointer to the BASEPAGE structure of the process
;    clr.w -(sp)                          ; NULL address of the command line string
;    gemdos Mshrink, 12                   ; Call Mshrink() and create the basepage    
;    reentry_gem_unlock    
;    ext.l d0                             ; Extend the sign of the value
    ; If d0 is negative, there is an error
;    bmi .pexec_exit                    ; If there is an error, exit

; Reserve memory for the process
;    reentry_gem_lock
;    lea GEMDRVEMUL_EXEC_HEADER, a5        ; Address of the buffer to receive the header
;    move.l 2(a5), -(sp)                   ; Get the text size.
;    gemdos Malloc, 6                      ; Call Mshrink() and create the basepage    
;    reentry_gem_unlock    
;    ext.l d0                             ; Extend the sign of the value
;    ; If d0 is negative, there is an error
;    bmi .pexec_exit                    ; If there is an error, exit

; Now we have to do a reentry call to the GEMDOS Pexec in mode PE_CREATE_BASEPAGE
; to create the basepage of the new process
    reentry_gem_lock
    move.l GEMDRVEMUL_PEXEC_STACK_ADDR, a0
    pea 18(a0)                            ; get the address of the environment string
    pea 14(a0)                            ; get the address of the command line string
    clr.l -(sp)                           ; unused
    move.w #PE_CREATE_BASEPAGE, -(sp)     ; create basepage mode
    gemdos Pexec, 16                      ; Call Pexec() and create the basepage
    move.l d0, a4
    reentry_gem_unlock

; We need to populate the basepage with the values from the header of the PRG file
    lea GEMDRVEMUL_EXEC_HEADER, a5        ; Address of the buffer to receive the header
    move.l 2(a5), d3                      ; Get the text size.
    move.l 6(a5), d4                      ; Get the data size.
    move.l 10(a5), d5                     ; Get the bss size.
    move.l 14(a5), d6                     ; Get the symbol size.

    move.l a4, d7                         ; Get the address of the basepage
    add.l #$100, d7                       ; Add 256 bytes to the basepage address to point to the start of the text segment

    move.l d7, 8(a4)                      ; Save the address of the start of the text segment
    move.l d3, 12(a4)                     ; Save the size of the text segment

    add.l d3, d7                          ; Add the text size to the basepage address to point to the start of the data segment
    move.l d7, 16(a4)                     ; Save the address of the start of the data segment
    move.l d4, 20(a4)                     ; Save the size of the data segment

    add.l d4, d7                          ; Add the data size to the basepage address to point to the start of the bss segment
    move.l d7, 24(a4)                     ; Save the address of the start of the bss segment
    move.l d5, 28(a4)                     ; Save the size of the bss segment

    send_write_sync CMD_SAVE_BASEPAGE, 256 ; Send the command to the Sidecart. 256 bytes of buffer to send

; Now we need to load the file in the area where the memory is
.pexec_read_rest_of_file:
    lea GEMDRVEMUL_EXEC_HEADER, a5        ; Address of the buffer to receive the header
    lea GEMDRVEMUL_EXEC_PD, a4            ; load the rest of the file
    move.l 8(a4), a4                     ; Start of the text segment
    move.l 2(a5), d4                     ; Get the TEXT size.
    add.l  6(a5), d4                     ; Add the DATA size.
    add.l 14(a5), d4                     ; Add the SYMBOL size.
    add.l #$FFFF, d4

    move.l GEMDRVEMUL_FOPEN_HANDLE, d3   ; Pass the file handle to close
    bsr .Fread_core                      ; Read the data from the Sidecart

; Close the file
.pexec_close_exit:
    move.l GEMDRVEMUL_FOPEN_HANDLE, d3   ; Pass the file handle to close
    send_sync CMD_FCLOSE_CALL, 2         ; Send the command to the Sidecart.
    move.w GEMDRVEMUL_FCLOSE_STATUS, d0  ; Error code obtained from the Sidecart
    ext.l d0                             ; Extend the sign of the value
    bmi .pexec_exit                      ; If there is an error, exit

; Relocating if needed
    lea GEMDRVEMUL_EXEC_PD, a5            
    move.l 8(a5), a5                      ; Start of the text segment
    move.l a5, d1                         ; Pass the address of the TEXT segment to the relocation code to d1
    move.l a5, a6                         ; Pass the address of the TEXT segment to the relocation code to a6

    lea GEMDRVEMUL_EXEC_HEADER, a4        ; Address of the buffer to receive the header
    add.l 2(a4), a5                       ; Add the TEXT segment size to the TEXT segment address
    add.l 6(a4), a5                       ; Add the DATA segment size to the TEXT segment address + TEXT segment size
    add.l 14(a4), a5                      ; Add the SYMBOL segment size to the TEXT segment address + TEXT segment size + DATA segment size
    tst.l (a5)                            ; If long word stored at the address is 0, we don't need to relocate
    beq.s .zeroing_bss_no_reloc
    moveq #0, d0                          ; Clear the d0 register
    add.l (a5)+, a6                       ; a6 -> first fixup
.fixup_get_next_reloc_byte:
    add.l d1, (a6)                       ; longword += TEXT base
.get_next_reloc_byte:
    move.b (a5)+, d0                     ; get the next fixup byte
    beq.s .zeroing_bss                   ; If 0, we are done
    cmp.b #1, d0                         ; If 1, a6 += 0xfe
    bne.s .bypass_bump_location_ptr
    add.w #$fe, a6                       ; bump location pointer
    bra.s .get_next_reloc_byte           ; get next reloc byte
.bypass_bump_location_ptr:
    add.w d0, a6                         ; a6 += byte
    bra.s .fixup_get_next_reloc_byte     ; fixup and get next reloc byte

; Do not reloc here
.zeroing_bss_no_reloc:
; Zeroing the BSS segment
.zeroing_bss:
    move.l GEMDRVEMUL_EXEC_PD, a4        ; load the pointer to the basepage of the new process of the file
    move.l 24(a4), a5                    ; Get the address of the start of the bss segment
    move.l 28(a4), d5                    ; Get the size of the bss segment
    bsr .fill_zero                     ; Zero the memory

.pexec_pexec_go:
; New we continue to the Pexec() call modifying the parameters to PE_GO and the address of the basepage
; By pass if not GO mode
    cmp.w #PE_LOAD, GEMDRVEMUL_PEXEC_MODE; Check if the mode is PE_LOAD
    beq .pexec_exit_load               ; If so, don't continue with the code GO mode and exit

; Before continuing, we need to figure out if PE_GO_AND_FREE is implemented or not
; if so, do not trap the exit of the PE_GO call
    move.l GEMDRVEMUL_PEXEC_STACK_ADDR, a0
    move.w #PE_GO_AND_FREE, 8(a0)        ; overwrite the mode with PE_GO_AND_FREE
    move.l (GEMDRVEMUL_SHARED_VARIABLES + (SHARED_VARIABLE_SVERSION * 4)), d0
    and.l #$FFFF, d0                     ; Mask the version number
    cmp.w #$1500, d0    ; If the version is equal or higher than 0x1500 (TOS 1.04 or TOS 1.06), PE_GO_AND_FREE exists
    bhs.s .pexec_go_and_free_exists

; Hack for TOS 1.00 and 1.02
; Trap the exit of the classic PE_GO call
    move.l #SHARED_VARIABLE_PEXEC_RESTORE, d3
    ; See the definition of STACK_SIZE_HACK_PEXEC to understand its size
    move.l STACK_SIZE_HACK_PEXEC(sp),d4  ; Store the return address in the shared variable PEXEC_RESTORE
    send_sync CMD_SET_SHARED_VAR, 8      ; Send the command to the Sidecart. 8 bytes of payload
    move.l #.pexec_mshrink_exit, STACK_SIZE_HACK_PEXEC(sp)  ; Trap the exit of the PE_GO before exiting to release memory

    move.l GEMDRVEMUL_PEXEC_STACK_ADDR, a0  ; We need to set again the a0 register
    move.w #PE_GO, 8(a0)                    ; overwrite the mode with PE_GO

.pexec_go_and_free_exists:
; Try to execute the new process
; The GO_AND_FREE also releases the memory of the current process
; The GO does not release the memory and must be manually released
    clr.l 10(a0)                         ; NULL address of the environment string
    move.l GEMDRVEMUL_EXEC_PD, 14(a0)    ; overwrite the address of the pointer to the fname with the address of the basepage
    clr.l 18(a0)                         ; NULL address of the command line string
    bra .exec_old_handler

; The code here is executed when the PE_GO is finished. It must release the memory of the current process
; and restore the basepage of the current process
.pexec_mshrink_exit:
; Release the memory of the current process, if necessary
; Get the values from _sysbase
    movem.l d1-d7/a0-a6, -(sp)           ; Save registers
    reentry_gem_lock
    move.l GEMDRVEMUL_EXEC_PD, -(sp)     ; Pointer to the BASEPAGE structure of the process
    gemdos Mfree, 6                      ; Call Mfree() and release the memory of the current process
    reentry_gem_unlock    
    ext.l d0                             ; Extend the sign of the value
    movem.l (sp)+,d1-d7/a0-a6            ; Restore registers

    move.l (GEMDRVEMUL_SHARED_VARIABLES + (SHARED_VARIABLE_PEXEC_RESTORE * 4)), -(sp)
    rts

.pexec_exit_load:
    move.l GEMDRVEMUL_EXEC_PD, d0        ; Return in D0 the address of the basepage of the new process
.pexec_exit:
    return_rte

.pexec_close_exit_fix_hdr_buf:
;    ifeq USE_DSKBUF
;        nop
;    else    
;        add.l #PRG_STRUCT_SIZE,sp            ; restore the stack pointer
;    endif

    tst.l (GEMDRVEMUL_SHARED_VARIABLES + (SHARED_VARIABLE_BUFFER_TYPE * 4))
    beq.s .pexec_close_exit_fix_hdr_buf_not_restore_stack
    add.l #PRG_STRUCT_SIZE,sp            ; restore the stack pointer

.pexec_close_exit_fix_hdr_buf_not_restore_stack:
    move.l GEMDRVEMUL_FOPEN_HANDLE, d3   ; Pass the file handle to close
    send_sync CMD_FCLOSE_CALL, 2         ; Send the command to the Sidecart.
    move.w GEMDRVEMUL_FCLOSE_STATUS, d0  ; Error code obtained from the Sidecart
    ext.l d0                             ; Extend the sign of the value
    bra.s .pexec_exit                    ; If there is an error, exit

; Zero the memory given the address and the size
; Input registers:
; a5: address of the memory to zero
; d5.l: size of the memory to zero
; Output registers:
; a5: modified
; d5: modified
.fill_zero:
    tst.l d5                            ; Check if the size is 0
    beq.s .fill_zero_exit               ; If 0, we are done
.fill_zero_loop:
    clr.b (a5)+                         ; Zero the memory
    subq.l #1, d5                       ; Decrement the counter
    bne.s .fill_zero_loop               ; Loop until the counter is 0
.fill_zero_exit:
    rts

; Shared functions included at the end of the file
; Don't forget to include the macros for the shared functions at the top of file
    include "inc/sidecart_functions.s"





        even
; NOTE: VERSION_MAJOR/MINOR/PATCH are numeric -D defines (single decimal
; digits, e.g. 1/0/1), not string literals -- vasm's -D only defines a
; numeric symbol, so "dc.b VERSION_MAJOR" would emit the raw byte value
; (e.g. 0x01, and 0x00 for a "0" component), not the printable ASCII digit.
; A literal 0x00 byte terminates Cconws early, silently swallowing the rest
; of this string (including its trailing blank-line CRLFs) and everything
; printed after this point lands on the same screen line. The version
; digits are therefore printed at runtime instead (see rom_function below);
; this string stops right after "v" on purpose.
gemdrive_emulator_msg:
        dc.b	"SidecarTridge multidevice"
        dc.b    $d,$a,$a
        dc.b    "GEMDRIVE - v",0

spacing:
        dc.b    $d,$a,$d,$a,0

set_version_msg:
        dc.b	"[..] TOS version: ",0

set_vectors_msg:
        dc.b	"[..] Set GEMDOS vector...",0

set_xbios_vector_msg:
        dc.b	"[..] Set XBIOS vector...",0

stack_buffer_msg:
        dc.b	"[..] Using stack as temp buffer...",0

dskbuf_buffer_msg:
        dc.b	"[..] Using _dskbuf as temp buffer...",0

query_ping_msg:
        dc.b	"[..] Mounting microSD card...",0

query_network_msg:
        dc.b	"[..] Network conf. [ESC] to cancel...",0

query_ntp_msg:
        dc.b	"[..] NTP synchronization...",0

rtc_already_started_msg:
        dc.b	"[..] RTC already started.",0

set_datetime_msg:
        dc.b	"[..] Date and time: ",0

validate_drive_table_msg:
        dc.b	"[..] Checking drive table...",0

emulated_drive_msg:
        dc.b	"[..] Emulating drive ",0

ready_gemdrive_msg:
        dc.b	"[..] GEMDRIVE driver loaded...",0

error_sidecart_comm_msg:
        dc.b	$d,$a,"Error communication. Power cycle the computer.",$d,$a,0

error_invalid_table_msg:
        dc.b	$d,$a,"Error: invalid drive table or protocol version. Update the Sidecart firmware.",$d,$a,0

backwards_msg:
        dc.b    $8, $8,0

ok_msg:
        dc.b	$d, "[OK]",$d,$a,0

timeout_msg:
        dc.b	$d, 27, "K[KO] Timeout!",$d,$a,0 

canceled_msg:
        dc.b	$d, 27, "K[KO] Canceled!",$d,$a,0 

        even

null_pointer:
        dc.l    0

        even
rom_function_end:
