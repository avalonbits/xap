; ***********************************************************************
;
;   Source and object files, through the KERNAL.
;
;   The source is streamed, not loaded. A refill reads blocks into the
;   buffer and then trims the buffer back to the last newline in it,
;   carrying the partial line after it to the front of the buffer next
;   time. Two things follow, and both matter:
;
;   The window the assembler sees always ends at a line boundary, so a
;   token can never span a refill and the line parser can keep indexing
;   off xapSrc with Y.
;
;   Nothing is read twice and nothing is kept once it has been passed, so
;   the source can be any size at all. What stays in memory is the
;   buffer, and the buffer is a fixed size.
;
;   Blocks come in through MACPTR, which fills memory directly and costs
;   about half a cycle a byte where CHRIN costs a hundred. MACPTR is
;   allowed to refuse -- the KERNAL documents devices without it -- so
;   there is a byte-at-a-time path behind it, and the same for MCIOUT.
;
; ***********************************************************************

SETNAM  = $FFBD
SETLFS  = $FFBA
OPEN    = $FFC0
CLOSE   = $FFC3
CHKIN   = $FFC6
CHKOUT  = $FFC9
CLRCHN  = $FFCC
CHRIN   = $FFCF
CHROUT  = $FFD2
READST  = $FFB7
MACPTR  = $FF44
MCIOUT  = $FEB1

XAP_LFN_SOURCE = 2
XAP_LFN_OBJECT = 3
XAP_DEVICE     = 8

XAP_BLOCK      = 255        ; the most one MACPTR/MCIOUT call is asked for

; -----------------------------------------------------------------------
;   Opens the source file named at xapName/xapNameLen and empties the
;   window. CC on success, CS with an error in A.
; -----------------------------------------------------------------------

xapOpenSource:
        lda     xapNameLen
        ldx     xapName
        ldy     xapName+1
        jsr     SETNAM
        lda     #XAP_LFN_SOURCE
        ldx     #XAP_DEVICE
        ldy     #2                  ; a data channel, not a LOAD
        jsr     SETLFS
        jsr     OPEN
        bcs     _xosFailed
        ldx     #XAP_LFN_SOURCE     ; OPEN can succeed for a name that is
        jsr     CHKIN               ; not there; CHKIN is what refuses
        bcs     _xosFailed
        jsr     CLRCHN

        ; An empty window that is not yet at end of file, so the first
        ; line asks for a refill exactly like every other line does.
        stz     xapEOF
        stz     xapNulSave
        lda     #<XAP_BUFFER
        sta     xapSrc
        sta     xapBufTop
        sta     xapRawTop
        lda     #>XAP_BUFFER
        sta     xapSrc+1
        sta     xapBufTop+1
        sta     xapRawTop+1
        lda     #0
        sta     (xapSrc)
        clc
        rts

_xosFailed:
        lda     #XAP_ENOFILE
        sec
        rts

xapCloseSource:
        jsr     CLRCHN
        lda     #XAP_LFN_SOURCE
        jmp     CLOSE

; -----------------------------------------------------------------------
;   Refills the source window. CC when there is more to assemble, CS at
;   the end of the input or with an error in A.
;
;   This is what xapRefillVec points at when the source is a file.
; -----------------------------------------------------------------------

xapFileRefill:
        jsr     _xfrCarryTail
        jsr     _xfrRead

        ; The window has to end where a line does. At end of file nothing
        ; more is coming, so what is left is the last line whether or not
        ; it was ever terminated.
        lda     xapEOF
        bne     _xfrKeepAll
        jsr     _xfrTrimToNewline
        bcs     _xfrTooLong

_xfrKeepAll:
        ; The parser finds the end of the window as a NUL, which is cheaper
        ; than a bounds test on every character. Where the window was trimmed
        ; back, that NUL lands on the first byte of the partial line still to
        ; come, so the byte is kept and put back before the carry.
        lda     (xapBufTop)
        sta     xapNulSave
        lda     #0
        sta     (xapBufTop)

        lda     xapSrc              ; is there anything in it?
        cmp     xapBufTop
        bne     _xfrMore
        lda     xapSrc+1
        cmp     xapBufTop+1
        beq     _xfrEmpty
_xfrMore:
        clc
        rts

_xfrEmpty:
        lda     #0                  ; the plain end of input, not an error
        sec
        rts

_xfrTooLong:
        lda     #XAP_ELINE
        sec
        rts

; -----------------------------------------------------------------------
;   Moves the unread tail to the front of the buffer, so that the free
;   space after it is one run rather than two. Leaves xapFill at the end
;   of the tail, which is where reading resumes.
; -----------------------------------------------------------------------

_xfrCarryTail:
        lda     xapNulSave          ; uncover the byte the terminator hid
        sta     (xapBufTop)
        stz     xapNulSave

        ; What is carried runs to the end of what was read, not to the end of
        ; the window: trimming to a line boundary left the partial line after
        ; it, and that line is exactly what the next read has to continue.
        lda     xapRawTop
        sec
        sbc     xapSrc
        sta     xapTmp
        lda     xapRawTop+1
        sbc     xapSrc+1
        sta     xapTmp+1

        lda     #<XAP_BUFFER
        sta     xapFill
        lda     #>XAP_BUFFER
        sta     xapFill+1

_xctCopy:
        lda     xapTmp
        ora     xapTmp+1
        beq     _xctDone

        lda     (xapSrc)
        sta     (xapFill)

        inc     xapSrc
        bne     +
        inc     xapSrc+1
+       inc     xapFill
        bne     +
        inc     xapFill+1
+       lda     xapTmp
        bne     +
        dec     xapTmp+1
+       dec     xapTmp
        bra     _xctCopy

_xctDone:
        lda     #<XAP_BUFFER
        sta     xapSrc
        lda     #>XAP_BUFFER
        sta     xapSrc+1
        rts

; -----------------------------------------------------------------------
;   Fills from xapFill to the end of the buffer, or until the file runs
;   out, and leaves xapBufTop at the end of what is there.
; -----------------------------------------------------------------------

; Both files are open at once, and opening the object file drops whatever
; channel was set for input, so each read claims the source channel again and
; gives it back. Without this the fallback path reads the keyboard, which on a
; machine with nobody at it never returns.
_xfrRead:
        lda     xapEOF
        bne     _xfrSetTop

        ldx     #XAP_LFN_SOURCE
        jsr     CHKIN

_xfrReadLoop:
        lda     #<XAP_BUFFER_END    ; room left
        sec
        sbc     xapFill
        sta     xapTmp
        lda     #>XAP_BUFFER_END
        sbc     xapFill+1
        sta     xapTmp+1

        lda     xapTmp
        ora     xapTmp+1
        beq     _xfrReadDone        ; full

        lda     xapTmp+1            ; ask for at most one block
        bne     _xfrReadBlock
        lda     xapTmp
        cmp     #XAP_BLOCK
        bcc     _xfrReadCall
_xfrReadBlock:
        lda     #XAP_BLOCK

_xfrReadCall:
        pha                         ; MACPTR may refuse, and the fallback
        ldx     xapFill             ; needs to know what was asked for
        ldy     xapFill+1
        clc                         ; advance the destination as it fills
        jsr     MACPTR
        bcs     _xfrByteAtATime

        pla                         ; X,Y is what actually arrived, which
        txa                         ; may be less than was asked for
        clc
        adc     xapFill
        sta     xapFill
        tya
        adc     xapFill+1
        sta     xapFill+1

_xfrReadStatus:
        jsr     READST
        and     #$40                ; end of file
        beq     _xfrReadLoop
        lda     #1
        sta     xapEOF

_xfrReadDone:
        jsr     CLRCHN
_xfrSetTop:
        lda     xapFill
        sta     xapBufTop
        sta     xapRawTop
        lda     xapFill+1
        sta     xapBufTop+1
        sta     xapRawTop+1
        rts

_xfrByteAtATime:
        pla
        tax
_xbaLoop:
        jsr     READST
        and     #$40
        bne     _xbaEOF
        jsr     CHRIN
        sta     (xapFill)
        inc     xapFill
        bne     +
        inc     xapFill+1
+       dex
        bne     _xbaLoop
        bra     _xfrReadStatus

_xbaEOF:
        lda     #1
        sta     xapEOF
        bra     _xfrReadDone

; -----------------------------------------------------------------------
;   Pulls xapBufTop back to just past the last newline in the window, so
;   that it ends where a line does. CS when there is no newline at all,
;   which means one line was longer than the buffer.
; -----------------------------------------------------------------------

_xfrTrimToNewline:
        lda     xapBufTop
        sta     xapFill
        lda     xapBufTop+1
        sta     xapFill+1

_xttBack:
        lda     xapFill             ; back at the front of the buffer?
        cmp     #<XAP_BUFFER
        bne     _xttStep
        lda     xapFill+1
        cmp     #>XAP_BUFFER
        beq     _xttNone

_xttStep:
        lda     xapFill
        bne     +
        dec     xapFill+1
+       dec     xapFill

        lda     (xapFill)
        cmp     #10
        beq     _xttFound
        cmp     #13
        bne     _xttBack

_xttFound:
        inc     xapFill             ; the terminator stays in the window
        bne     +
        inc     xapFill+1
+       lda     xapFill
        sta     xapBufTop
        lda     xapFill+1
        sta     xapBufTop+1
        clc
        rts

_xttNone:
        sec
        rts

; -----------------------------------------------------------------------
;   Opens the object file named at xapObjName/xapObjNameLen and points
;   the emitter at the object buffer. CC on success.
; -----------------------------------------------------------------------

xapOpenObject:
        stz     xapObjError
        lda     xapObjNameLen
        ldx     xapObjName
        ldy     xapObjName+1
        jsr     SETNAM
        lda     #XAP_LFN_OBJECT
        ldx     #XAP_DEVICE
        ldy     #3
        jsr     SETLFS
        jsr     OPEN
        bcs     _xooFailed

        lda     #<XAP_OBJBUF
        sta     xapOut
        lda     #>XAP_OBJBUF
        sta     xapOut+1
        clc
        rts

_xooFailed:
        lda     #XAP_ENOFILE
        sec
        rts

; -----------------------------------------------------------------------
;   Writes the object buffer out and empties it.
;
;   Called from inside xapPut, which is called from the middle of
;   encoding an instruction, so it preserves X and Y and cannot return an
;   error up the chain. A failure is recorded in xapObjError instead, and
;   the top level reports it once the line is finished.
; -----------------------------------------------------------------------

xapObjFlush:
        phx
        phy

        lda     xapOut              ; how much is waiting
        sec
        sbc     #<XAP_OBJBUF
        sta     xapTmp
        lda     xapOut+1
        sbc     #>XAP_OBJBUF
        sta     xapTmp+1
        lda     xapTmp
        ora     xapTmp+1
        beq     _xofEmpty

        ldx     #XAP_LFN_OBJECT
        jsr     CHKOUT
        bcs     _xofFailed

        lda     #<XAP_OBJBUF
        sta     xapFill
        lda     #>XAP_OBJBUF
        sta     xapFill+1

_xofLoop:
        lda     xapTmp
        ora     xapTmp+1
        beq     _xofEnd

        lda     xapTmp+1            ; at most one block a call
        bne     _xofBlock
        lda     xapTmp
        cmp     #XAP_BLOCK
        bcc     _xofSend
_xofBlock:
        lda     #XAP_BLOCK

_xofSend:
        pha                         ; the fallback needs the request
        ldx     xapFill
        ldy     xapFill+1
        clc
        jsr     MCIOUT
        bcs     _xofByteAtATime

        pla                         ; X,Y is what actually went
        stx     xapWrote
        sty     xapWrote+1
        bra     _xofAccount

_xofByteAtATime:
        pla
        sta     xapWrote
        stz     xapWrote+1
        tax
_xobLoop:
        lda     (xapFill)
        phx
        jsr     CHROUT
        plx
        inc     xapFill
        bne     +
        inc     xapFill+1
+       dex
        bne     _xobLoop

        lda     xapFill             ; the loop moved xapFill itself, so
        sec                         ; put it back for the common step
        sbc     xapWrote
        sta     xapFill
        bcs     +
        dec     xapFill+1
+
_xofAccount:
        lda     xapFill             ; xapFill += written
        clc
        adc     xapWrote
        sta     xapFill
        lda     xapFill+1
        adc     xapWrote+1
        sta     xapFill+1

        lda     xapTmp              ; xapTmp -= written
        sec
        sbc     xapWrote
        sta     xapTmp
        lda     xapTmp+1
        sbc     xapWrote+1
        sta     xapTmp+1
        bra     _xofLoop

_xofFailed:
        lda     #XAP_ENOFILE
        sta     xapObjError
_xofEnd:
        jsr     CLRCHN
_xofEmpty:
        lda     #<XAP_OBJBUF        ; empty again either way
        sta     xapOut
        lda     #>XAP_OBJBUF
        sta     xapOut+1
        ply
        plx
        rts

; -----------------------------------------------------------------------
;   Flushes what is left and closes the object file. CC on success, CS
;   with an error in A if any write along the way failed.
; -----------------------------------------------------------------------

xapCloseObject:
        jsr     xapObjFlush
        jsr     CLRCHN
        lda     #XAP_LFN_OBJECT
        jsr     CLOSE
        lda     xapObjError
        beq     _xcoOkay
        sec
        rts
_xcoOkay:
        clc
        rts
