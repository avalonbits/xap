; ***********************************************************************
;
;   Labels, and the fixups that wait for them.
;
;   A label can be used before it is defined without a second pass. The
;   reference leaves a hole and records what has to go in it; the
;   definition fills every hole that was waiting on it. Nothing is read
;   twice.
;
;   The one thing a single pass cannot recover from is getting an
;   instruction's *length* wrong, because everything after it would move.
;   On this processor the length does depend on the value -- "lda foo" is
;   two bytes if foo is in zero page and three if it is not -- so a
;   forward reference is always assembled as absolute, and zero page is
;   only chosen for a symbol already defined. That wastes a byte on a
;   forward reference into zero page, and is the price of the pass.
;
;   Fixups hang off the symbol they wait for rather than sitting in one
;   list until the end of the file. A label defined on the next line
;   retires its fixups on the next line, so what is held at once follows
;   how far forward references reach and not how long the file is.
;
;   Names are stored upper cased, so FOO and foo are one label. That is
;   what the ROM assembler does -- it upper cases every identifier as it
;   stores it -- and matching it matters more than the alternative.
;
; ***********************************************************************

XAP_SYM_NEXT   = 0          ; next symbol in this hash bucket
XAP_SYM_VALUE  = 2
XAP_SYM_FLAGS  = 4
XAP_SYM_FIXUP  = 5          ; head of the chain waiting on it
XAP_SYM_LEN    = 7
XAP_SYM_NAME   = 8          ; and the name runs on from here

XAP_SYM_DEFINED = $80
XAP_SYM_ADDRESS = $40       ; the value is a code address and moves with it

XAP_FIX_PC     = 0          ; the address the hole occupies
XAP_FIX_KIND   = 2
XAP_FIX_NEXT   = 3
XAP_FIX_WIDE   = 5          ; the opcode to swap in if this one widens
XAP_FIX_SIZE   = 6

XAP_FIX_ABS    = 0          ; two bytes, low then high
XAP_FIX_REL    = 1          ; one signed byte, from the instruction after
XAP_FIX_LOW    = 2          ; one byte, and the value has to fit in it
XAP_FIX_NARROW = 3          ; emitted narrow on the chance that it fits

; -----------------------------------------------------------------------
;   Empties the table: every bucket, and both heaps.
; -----------------------------------------------------------------------

xapSymReset:
        lda     #<XAP_SYMHASH
        sta     xapTmp
        lda     #>XAP_SYMHASH
        sta     xapTmp+1
        ldx     #2                  ; 256 buckets of two bytes
        ldy     #0
        lda     #0
_xsrClear:
        sta     (xapTmp),y
        iny
        bne     _xsrClear
        inc     xapTmp+1
        dex
        bne     _xsrClear

        lda     #<XAP_SYMHEAP
        sta     xapSymTop
        lda     #>XAP_SYMHEAP
        sta     xapSymTop+1
        lda     #<XAP_FIXHEAP
        sta     xapFixTop
        lda     #>XAP_FIXHEAP
        sta     xapFixTop+1
        stz     xapUndefined
        stz     xapUndefined+1
        stz     xapPending
        stz     xapPending+1
        stz     xapDeferred
        rts

; -----------------------------------------------------------------------
;   Hashes the name in XAP_LABEL, length xapLabelLen, into A.
;
;   Pearson: one exclusive or and one indexed load a character. What comes
;   out is the bucket number already, with nothing to mask, which is the
;   whole reason the table has 256 entries.
; -----------------------------------------------------------------------

xapSymHash:
        lda     #0
        ldy     xapLabelLen
_xshLoop:
        dey
        eor     XAP_LABEL,y
        tax
        lda     xapPearson,x
        cpy     #0
        bne     _xshLoop
        rts

; -----------------------------------------------------------------------
;   Finds the label in XAP_LABEL, creating it undefined if it is new.
;
;   Returns the record in xapSym, CC if it was already there and CS if it
;   was just made. On a full heap, CS with an error in A and xapSym zero,
;   which the caller tells apart by checking that.
; -----------------------------------------------------------------------

xapSymFind:
        jsr     xapSymHash
        asl     a                   ; two bytes a bucket, and the table is
        tax                         ; page aligned so this cannot carry out
        stx     xapFix              ; keep the bucket for a possible insert

        lda     XAP_SYMHASH,x
        sta     xapSym
        lda     XAP_SYMHASH+1,x
        sta     xapSym+1

_xsfWalk:
        lda     xapSym
        ora     xapSym+1
        beq     _xsfCreate          ; ran off the end of the chain

        ldy     #XAP_SYM_LEN        ; the same length before the same name
        lda     (xapSym),y
        cmp     xapLabelLen
        bne     _xsfNext

        ; Y runs over the record's name, from the last character back to
        ; the first, and the label buffer is indexed through a base
        ; adjusted by the same offset so one register serves both.
        lda     xapLabelLen
        clc
        adc     #XAP_SYM_NAME
        tay
_xsfCompare:
        dey
        lda     (xapSym),y
        cmp     XAP_LABEL-XAP_SYM_NAME,y
        bne     _xsfNext
        cpy     #XAP_SYM_NAME
        bne     _xsfCompare

        clc                         ; found
        rts

_xsfNext:
        ldy     #XAP_SYM_NEXT
        lda     (xapSym),y
        pha
        iny
        lda     (xapSym),y
        sta     xapSym+1
        pla
        sta     xapSym
        bra     _xsfWalk

; -----------------------------------------------------------------------
;   Not there, so build one and push it onto the front of its bucket.
; -----------------------------------------------------------------------

_xsfCreate:
        ; Room for the fixed part and the name.
        clc
        lda     xapSymTop
        adc     #XAP_SYM_NAME
        sta     xapTmp
        lda     xapSymTop+1
        adc     #0
        sta     xapTmp+1
        clc
        lda     xapTmp
        adc     xapLabelLen
        sta     xapTmp
        lda     xapTmp+1
        adc     #0
        sta     xapTmp+1

        cmp     #>XAP_SYMHEAP_END
        bcc     _xsfRoom
        bne     _xsfFull
        lda     xapTmp
        cmp     #<XAP_SYMHEAP_END
        bcs     _xsfFull

_xsfRoom:
        lda     xapSymTop
        sta     xapSym
        lda     xapSymTop+1
        sta     xapSym+1
        lda     xapTmp              ; the heap grows past it
        sta     xapSymTop
        lda     xapTmp+1
        sta     xapSymTop+1

        ldx     xapFix              ; onto the head of its bucket
        lda     XAP_SYMHASH,x
        ldy     #XAP_SYM_NEXT
        sta     (xapSym),y
        lda     XAP_SYMHASH+1,x
        iny
        sta     (xapSym),y
        lda     xapSym
        sta     XAP_SYMHASH,x
        lda     xapSym+1
        sta     XAP_SYMHASH+1,x

        lda     #0                  ; no value, undefined, nothing waiting
        ldy     #XAP_SYM_VALUE
        sta     (xapSym),y
        iny
        sta     (xapSym),y
        iny
        sta     (xapSym),y
        iny
        sta     (xapSym),y
        iny
        sta     (xapSym),y

        ldy     #XAP_SYM_LEN
        lda     xapLabelLen
        sta     (xapSym),y

        clc                         ; the name, counted down as above
        adc     #XAP_SYM_NAME
        tay
_xsfCopy:
        dey
        lda     XAP_LABEL-XAP_SYM_NAME,y
        sta     (xapSym),y
        cpy     #XAP_SYM_NAME
        bne     _xsfCopy

        inc     xapUndefined        ; one more waiting to be defined
        bne     +
        inc     xapUndefined+1
+       sec                          ; created
        rts

_xsfFull:
        stz     xapSym
        stz     xapSym+1
        lda     #XAP_EMEMORY
        sec
        rts

; -----------------------------------------------------------------------
;   Defines the label in XAP_LABEL as the value in xapValue, and fills
;   every hole that was waiting for it. CC on success.
; -----------------------------------------------------------------------

xapSymDefine:
        jsr     xapSymFind
        bcc     _xsdExisting
        lda     xapSym              ; a full heap comes back as a null
        ora     xapSym+1
        bne     _xsdSet
        lda     #XAP_EMEMORY
        sec
        rts

_xsdExisting:
        ldy     #XAP_SYM_FLAGS      ; twice is an error, not a redefinition
        lda     (xapSym),y
        bmi     _xsdTwice

_xsdSet:
        ldy     #XAP_SYM_VALUE
        lda     xapValue
        sta     (xapSym),y
        iny
        lda     xapValue+1
        sta     (xapSym),y
        ldy     #XAP_SYM_FLAGS
        lda     #XAP_SYM_DEFINED|XAP_SYM_ADDRESS
        sta     (xapSym),y

        lda     xapUndefined        ; one fewer outstanding
        bne     +
        dec     xapUndefined+1
+       dec     xapUndefined

        ; Sizes before values: a widening moves code, and moving code
        ; changes addresses that have not been written anywhere yet
        ; because nothing is patched while a size is unsettled.
        jsr     xapSymSettle
        bcs     _xsdFailed
        lda     xapDeferred
        bne     _xsdLater
        jmp     xapSymResolve
_xsdLater:
        clc
_xsdFailed:
        rts

_xsdTwice:
        lda     #XAP_EREDEF
        sec
        rts

; -----------------------------------------------------------------------
;   Records that the hole at xapHole needs this symbol, with the kind in
;   A. The symbol is in xapSym and is known to be undefined.
; -----------------------------------------------------------------------

xapSymFixup:
        pha
        clc                         ; room for one more record
        lda     xapFixTop
        adc     #XAP_FIX_SIZE
        sta     xapTmp
        lda     xapFixTop+1
        adc     #0
        sta     xapTmp+1
        cmp     #>XAP_FIXHEAP_END
        bcc     _xsxRoom
        bne     _xsxFull
        lda     xapTmp
        cmp     #<XAP_FIXHEAP_END
        bcs     _xsxFull

_xsxRoom:
        lda     xapFixTop
        sta     xapFix
        lda     xapFixTop+1
        sta     xapFix+1
        lda     xapTmp
        sta     xapFixTop
        lda     xapTmp+1
        sta     xapFixTop+1

        ldy     #XAP_FIX_PC
        lda     xapHole             ; where the operand sits, which the
        sta     (xapFix),y          ; caller worked out as it emitted it
        iny
        lda     xapHole+1
        sta     (xapFix),y

        pla
        ldy     #XAP_FIX_KIND
        sta     (xapFix),y
        cmp     #XAP_FIX_NARROW     ; one more size not yet settled
        bne     +
        inc     xapPending
        bne     +
        inc     xapPending+1
+       cmp     #XAP_FIX_NARROW
        bne     +
        ; Once one size has been guessed, nothing is filled in until the
        ; file is read. A guess that turns out wrong moves code, and
        ; moving code moves labels -- including ones already written into
        ; holes that were filled while this looked settled. Sticky rather
        ; than "while a size is pending", because a second guess later in
        ; the file would invalidate everything the first one let through.
        lda     #1
        sta     xapDeferred
+
        lda     xapWideOp           ; only a narrow fixup reads this back
        ldy     #XAP_FIX_WIDE
        sta     (xapFix),y

        ldy     #XAP_SYM_FIXUP      ; onto the front of the symbol's chain
        lda     (xapSym),y
        ldx     #XAP_FIX_NEXT
        pha
        iny
        lda     (xapSym),y
        ldy     #XAP_FIX_NEXT+1
        sta     (xapFix),y
        pla
        dey
        sta     (xapFix),y

        ldy     #XAP_SYM_FIXUP
        lda     xapFix
        sta     (xapSym),y
        iny
        lda     xapFix+1
        sta     (xapSym),y
        clc
        rts

_xsxFull:
        pla
        lda     #XAP_EMEMORY
        sec
        rts

; -----------------------------------------------------------------------
;   Fills every hole waiting on the symbol in xapSym, whose value is now
;   in xapValue, and empties its chain. CC on success.
; -----------------------------------------------------------------------

xapSymResolve:
        ldy     #XAP_SYM_FIXUP
        lda     (xapSym),y
        sta     xapFix
        iny
        lda     (xapSym),y
        sta     xapFix+1

        lda     #0                  ; nothing is waiting any more
        ldy     #XAP_SYM_FIXUP
        sta     (xapSym),y
        iny
        sta     (xapSym),y

_xsrWalk:
        lda     xapFix
        ora     xapFix+1
        beq     _xsrDone

        ; Where in the image that address lives.
        ldy     #XAP_FIX_PC
        lda     (xapFix),y
        sec
        sbc     xapOrigin
        sta     xapTmp
        iny
        lda     (xapFix),y
        sbc     xapOrigin+1
        sta     xapTmp+1
        clc
        lda     xapTmp
        adc     xapImage
        sta     xapTmp
        lda     xapTmp+1
        adc     xapImage+1
        sta     xapTmp+1

        ldy     #XAP_FIX_KIND
        lda     (xapFix),y
        cmp     #XAP_FIX_REL
        beq     _xsrRelative
        cmp     #XAP_FIX_LOW
        beq     _xsrLowByte

        lda     xapValue            ; two bytes, low then high
        sta     (xapTmp)
        ldy     #1
        lda     xapValue+1
        sta     (xapTmp),y
        bra     _xsrNext

_xsrLowByte:
        lda     xapValue+1          ; one byte, so it has to be one byte
        bne     _xsrTooBig
        lda     xapValue
        sta     (xapTmp)
        bra     _xsrNext

_xsrRelative:
        ; Measured from the instruction after, which for every branch on
        ; this processor is the byte after the hole.
        ldy     #XAP_FIX_PC
        lda     (xapFix),y
        clc
        adc     #1
        sta     xapWrote
        iny
        lda     (xapFix),y
        adc     #0
        sta     xapWrote+1

        lda     xapValue
        sec
        sbc     xapWrote
        tax
        lda     xapValue+1
        sbc     xapWrote+1

        beq     _xsrForward         ; in range when the difference sign
        cmp     #$FF                ; extends from the byte
        bne     _xsrRange
        txa
        bmi     _xsrStore
        bra     _xsrRange
_xsrForward:
        txa
        bmi     _xsrRange
_xsrStore:
        sta     (xapTmp)

_xsrNext:
        ldy     #XAP_FIX_NEXT
        lda     (xapFix),y
        pha
        iny
        lda     (xapFix),y
        sta     xapFix+1
        pla
        sta     xapFix
        bra     _xsrWalk

_xsrDone:
        clc
        rts

_xsrRange:
        lda     #XAP_ERANGE
        sec
        rts

_xsrTooBig:
        lda     #XAP_EVALUE
        sec
        rts

; -----------------------------------------------------------------------
;   Defines the label at the cursor as the current program counter, and
;   steps over an optional colon after it.
; -----------------------------------------------------------------------

xapLabelHere:
        jsr     xapReadLabel
        bcs     _xlhExit

        lda     (xapSrc),y          ; the colon is optional
        cmp     #':'
        bne     +
        iny
+
        lda     xapPC               ; a label is where it stands
        sta     xapValue
        lda     xapPC+1
        sta     xapValue+1

        sty     xapLabelPos         ; defining walks records with Y, and
        jsr     xapSymDefine        ; the line still has to be read
        ldy     xapLabelPos
_xlhExit:
        rts

; -----------------------------------------------------------------------
;   Turns the image address of the program counter in YX into xapTmp.
; -----------------------------------------------------------------------

xapImageAt:
        txa
        sec
        sbc     xapOrigin
        sta     xapTmp
        tya
        sbc     xapOrigin+1
        sta     xapTmp+1
        clc
        lda     xapTmp
        adc     xapImage
        sta     xapTmp
        lda     xapTmp+1
        adc     xapImage+1
        sta     xapTmp+1
        rts

; -----------------------------------------------------------------------
;   Widens the instruction whose operand hole is at xapHole, swapping in
;   the opcode in A. Everything above the hole moves up one byte.
;
;   The shift is what makes this the expensive case, so only genuinely
;   ambiguous operands ever get here: a mnemonic with one width has its
;   size settled whatever the value turns out to be.
; -----------------------------------------------------------------------

xapWidenHole:
        sta     xapWideOp

        lda     xapOut              ; room for one more byte
        cmp     #<XAP_IMAGE_END
        lda     xapOut+1
        sbc     #>XAP_IMAGE_END
        bcs     _xwFull

        ldx     xapHole
        ldy     xapHole+1
        jsr     xapImageAt          ; xapTmp is where the hole lives

        ; Copy the tail up a byte, working down from the top so the two
        ; runs do not tread on each other.
        lda     xapOut
        sta     xapFill
        lda     xapOut+1
        sta     xapFill+1
_xwShift:
        lda     xapFill
        cmp     xapTmp
        bne     _xwByte
        lda     xapFill+1
        cmp     xapTmp+1
        beq     _xwShifted
_xwByte:
        lda     xapFill
        bne     +
        dec     xapFill+1
+       dec     xapFill
        lda     (xapFill)
        ldy     #1
        sta     (xapFill),y
        bra     _xwShift

_xwShifted:
        lda     xapTmp              ; the opcode sits just below the hole
        bne     +
        dec     xapTmp+1
+       dec     xapTmp
        lda     xapWideOp
        sta     (xapTmp)

        inc     xapOut              ; and everything after has moved
        bne     +
        inc     xapOut+1
+       inc     xapPC
        bne     +
        inc     xapPC+1
+
        jsr     _xwMoveLabels
        jsr     _xwMoveFixups
        clc
        rts

_xwFull:
        lda     #XAP_EMEMORY
        sec
        rts

; -----------------------------------------------------------------------
;   Every code label above the hole is a byte further on than it was.
;   A label that is not an address -- an assignment, when those exist --
;   does not move, which is what the flag is for.
; -----------------------------------------------------------------------

_xwMoveLabels:
        lda     #<XAP_SYMHEAP
        sta     xapFill
        lda     #>XAP_SYMHEAP
        sta     xapFill+1

_xwmLoop:
        lda     xapFill             ; reached the top of the heap?
        cmp     xapSymTop
        lda     xapFill+1
        sbc     xapSymTop+1
        bcs     _xwmDone

        ldy     #XAP_SYM_FLAGS
        lda     (xapFill),y
        and     #XAP_SYM_ADDRESS
        beq     _xwmNext

        ldy     #XAP_SYM_VALUE
        lda     (xapFill),y
        sta     xapWrote
        iny
        lda     (xapFill),y
        sta     xapWrote+1

        lda     xapHole             ; only what is above the hole moves
        cmp     xapWrote
        lda     xapHole+1
        sbc     xapWrote+1
        bcs     _xwmNext

        inc     xapWrote
        bne     +
        inc     xapWrote+1
+       ldy     #XAP_SYM_VALUE
        lda     xapWrote
        sta     (xapFill),y
        iny
        lda     xapWrote+1
        sta     (xapFill),y

_xwmNext:
        ldy     #XAP_SYM_LEN        ; records are eight bytes and a name
        lda     (xapFill),y
        clc
        adc     #XAP_SYM_NAME
        adc     xapFill
        sta     xapFill
        bcc     _xwmLoop
        inc     xapFill+1
        bra     _xwmLoop

_xwmDone:
        rts

; -----------------------------------------------------------------------
;   And so is every hole still waiting above it.
; -----------------------------------------------------------------------

_xwMoveFixups:
        lda     #<XAP_FIXHEAP
        sta     xapFill
        lda     #>XAP_FIXHEAP
        sta     xapFill+1

_xwfLoop:
        lda     xapFill
        cmp     xapFixTop
        lda     xapFill+1
        sbc     xapFixTop+1
        bcs     _xwfDone

        ldy     #XAP_FIX_PC
        lda     (xapFill),y
        sta     xapWrote
        iny
        lda     (xapFill),y
        sta     xapWrote+1

        lda     xapHole
        cmp     xapWrote
        lda     xapHole+1
        sbc     xapWrote+1
        bcs     _xwfNext

        inc     xapWrote
        bne     +
        inc     xapWrote+1
+       ldy     #XAP_FIX_PC
        lda     xapWrote
        sta     (xapFill),y
        iny
        lda     xapWrote+1
        sta     (xapFill),y

_xwfNext:
        clc
        lda     xapFill
        adc     #XAP_FIX_SIZE
        sta     xapFill
        bcc     _xwfLoop
        inc     xapFill+1
        bra     _xwfLoop

_xwfDone:
        rts

; -----------------------------------------------------------------------
;   Settles the size of every operand waiting on the symbol in xapSym,
;   whose value is now in xapValue. CC on success.
;
;   A narrow hole that turns out to hold more than a byte grows, taking
;   the rest of the image up with it. One that fits becomes an ordinary
;   one-byte hole and is filled later with everything else.
; -----------------------------------------------------------------------

xapSymSettle:
        ldy     #XAP_SYM_FIXUP
        lda     (xapSym),y
        sta     xapFix
        iny
        lda     (xapSym),y
        sta     xapFix+1

_xssWalk:
        lda     xapFix
        ora     xapFix+1
        beq     _xssDone

        ldy     #XAP_FIX_KIND
        lda     (xapFix),y
        cmp     #XAP_FIX_NARROW
        bne     _xssNext

        lda     xapPending          ; settled, whichever way it goes
        bne     +
        dec     xapPending+1
+       dec     xapPending

        lda     xapValue+1
        bne     _xssGrow

        lda     #XAP_FIX_LOW        ; it fits, so it stays as it is
        ldy     #XAP_FIX_KIND
        sta     (xapFix),y
        bra     _xssNext

_xssGrow:
        ldy     #XAP_FIX_PC
        lda     (xapFix),y
        sta     xapHole
        iny
        lda     (xapFix),y
        sta     xapHole+1

        ldy     #XAP_FIX_WIDE
        lda     (xapFix),y
        jsr     xapWidenHole
        bcs     _xssFailed

        lda     #XAP_FIX_ABS        ; two bytes now, not one
        ldy     #XAP_FIX_KIND
        sta     (xapFix),y

_xssNext:
        ldy     #XAP_FIX_NEXT
        lda     (xapFix),y
        pha
        iny
        lda     (xapFix),y
        sta     xapFix+1
        pla
        sta     xapFix
        bra     _xssWalk

_xssDone:
        clc
_xssFailed:
        rts

; -----------------------------------------------------------------------
;   Fills every hole in the whole table. Run once the last unsettled size
;   settles, because until then any of them could still move.
; -----------------------------------------------------------------------

xapResolveAll:
        lda     #<XAP_SYMHEAP
        sta     xapWalk
        lda     #>XAP_SYMHEAP
        sta     xapWalk+1

_xraLoop:
        lda     xapWalk              ; reached the top of the heap?
        cmp     xapSymTop
        lda     xapWalk+1
        sbc     xapSymTop+1
        bcs     _xraDone

        lda     xapWalk
        sta     xapSym
        lda     xapWalk+1
        sta     xapSym+1

        ldy     #XAP_SYM_FLAGS      ; only a symbol with a value can fill
        lda     (xapSym),y          ; anything
        bpl     _xraNext

        ldy     #XAP_SYM_FIXUP
        lda     (xapSym),y
        ldy     #XAP_SYM_FIXUP+1
        ora     (xapSym),y
        beq     _xraNext

        ldy     #XAP_SYM_VALUE
        lda     (xapSym),y
        sta     xapValue
        iny
        lda     (xapSym),y
        sta     xapValue+1
        jsr     xapSymResolve
        bcs     _xraFailed

_xraNext:
        ldy     #XAP_SYM_LEN
        lda     (xapWalk),y
        clc
        adc     #XAP_SYM_NAME
        adc     xapWalk
        sta     xapWalk
        bcc     _xraLoop
        inc     xapWalk+1
        bra     _xraLoop

_xraDone:
        clc
_xraFailed:
        rts
