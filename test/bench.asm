; ***********************************************************************
;
;   The driver the emulator harness runs.
;
;   This is xap plus a stub that hands it two file names and times it.
;   Building them together means the harness never has to be told where
;   anything is: it reads the addresses out of the label file 64tass
;   writes, so moving a buffer or adding a routine cannot leave the two
;   disagreeing about the layout.
;
;   Timing comes from the emulator's cycle counter at $9FB8. Writing to
;   it sets the base; reading it latches the count since. It counts
;   emulated cycles, so the number is what the instruction stream would
;   cost a real 8MHz X16 and does not move when the host is busy or when
;   the emulator is run under -warp.
;
;   The measurement spans the whole job, opens and closes included,
;   because that is what someone waiting for an assembly actually waits
;   for.
;
; ***********************************************************************

        .include "../src/xap.asm"

EMU_CLOCK = $9FB8               ; write: reset the base. read: 4 bytes.

xapBenchEntry:
        lda     #<xapBenchSrcName
        sta     xapName
        lda     #>xapBenchSrcName
        sta     xapName+1
        lda     xapBenchSrcLen
        sta     xapNameLen

        lda     #<xapBenchObjName
        sta     xapObjName
        lda     #>xapBenchObjName
        sta     xapObjName+1
        lda     xapBenchObjLen
        sta     xapObjNameLen

        lda     xapBenchOrigin
        sta     xapPC
        lda     xapBenchOrigin+1
        sta     xapPC+1

        sta     EMU_CLOCK           ; any write starts the count
        jsr     xapAssembleFile
        php                         ; the result, while the clock is read
        pha

        lda     EMU_CLOCK           ; reading byte 0 latches all four
        sta     xapBenchCycles
        lda     EMU_CLOCK+1
        sta     xapBenchCycles+1
        lda     EMU_CLOCK+2
        sta     xapBenchCycles+2
        lda     EMU_CLOCK+3
        sta     xapBenchCycles+3

        pla
        plp
        bcs     _xbeFailed
        stz     xapBenchResult
        rts
_xbeFailed:
        sta     xapBenchResult
        rts

; -----------------------------------------------------------------------
;   What the harness fills in and reads back.
; -----------------------------------------------------------------------

xapBenchSrcName:
        .fill   40
xapBenchSrcLen:
        .fill   1
xapBenchObjName:
        .fill   40
xapBenchObjLen:
        .fill   1
xapBenchOrigin:
        .fill   2
xapBenchResult:
        .fill   1
xapBenchCycles:
        .fill   4

; Where the binary has to be loaded. Emitted so the harness reads it from the
; label file rather than being told twice.
xapBenchLoad = CODEADDR

; And the same ceiling xap.asm checks for itself, applied to xap plus this
; stub, which is what the emulator actually loads.
        .cerror * > $9F00, "the bench image has run into the I/O page at $9F00"
