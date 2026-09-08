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
        stz     xapFixFree
        stz     xapFixFree+1

        stz     xapLocalCount
        stz     xapLocalUndef
        stz     xapLocal
        lda     #<XAP_LOCALHEAP
        sta     xapLocalTop
        lda     #>XAP_LOCALHEAP
        sta     xapLocalTop+1
        jmp     xapLocalReset

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

        ; Which table. Locals live apart and are thrown away at the next
        ; global label, so a name in one scope cannot be found from
        ; another, and the two can hold the same name at once.
        ;
        ; Both are pairs of parallel byte arrays, so the bucket number is
        ; the index into both and the head of the chain is two absolute
        ; indexed loads. Building a pointer to a bucket instead cost the
        ; better part of thirty cycles a lookup, on a lookup that happens
        ; twice for every name in the file.
        ldx     xapLocal
        bne     _xsfLocalTable

        tax
        stx     xapBucket           ; kept for the insert, if it comes to
        lda     XAP_SYMHASH_LO,x    ; one
        sta     xapSym
        lda     XAP_SYMHASH_HI,x
        sta     xapSym+1
        bra     _xsfWalk

_xsfLocalTable:
        and     #XAP_LOCALMASK
        tax
        stx     xapBucket
        lda     XAP_LOCALHASH_LO,x
        sta     xapSym
        lda     XAP_LOCALHASH_HI,x
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
        ; Room for the fixed part and the name, in whichever heap this
        ; name belongs to.
        ldx     xapLocal
        bne     _xsfLocalRoom

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
        bne     _xsfViaFull
        lda     xapTmp
        cmp     #<XAP_SYMHEAP_END
        bcs     _xsfViaFull

_xsfViaFull:
        jmp     _xsfFull

_xsfRoom:
        lda     xapSymTop
        sta     xapSym
        lda     xapSymTop+1
        sta     xapSym+1
        lda     xapTmp
        sta     xapSymTop
        lda     xapTmp+1
        sta     xapSymTop+1
        bra     _xsfLink

_xsfLocalRoom:
        clc
        lda     xapLocalTop
        adc     #XAP_SYM_NAME
        sta     xapTmp
        lda     xapLocalTop+1
        adc     #0
        sta     xapTmp+1
        clc
        lda     xapTmp
        adc     xapLabelLen
        sta     xapTmp
        lda     xapTmp+1
        adc     #0
        sta     xapTmp+1

        cmp     #>XAP_LOCALHEAP_END
        bcc     _xsfLocalHas
        bne     _xsfViaFull
        lda     xapTmp
        cmp     #<XAP_LOCALHEAP_END
        bcs     _xsfViaFull

_xsfLocalHas:
        lda     xapLocalTop
        sta     xapSym
        lda     xapLocalTop+1
        sta     xapSym+1
        lda     xapTmp
        sta     xapLocalTop
        lda     xapTmp+1
        sta     xapLocalTop+1
        ldx     xapLocalCount       ; note the bucket, so that emptying
        lda     xapBucket           ; the table at the end of the scope
        sta     XAP_LOCALUSED,x     ; touches only what was used
        inc     xapLocalCount       ; so an empty scope costs nothing to
        inc     xapLocalUndef       ; leave, and a full one is checked

_xsfLink:
        ; Onto the head of its bucket. Which table again, because the two
        ; arrays are named rather than pointed at -- a branch on the cold
        ; path, to save the pointer on the hot one.
        ldx     xapBucket
        lda     xapLocal
        bne     _xsfLinkLocal

        ldy     #XAP_SYM_NEXT
        lda     XAP_SYMHASH_LO,x
        sta     (xapSym),y
        iny
        lda     XAP_SYMHASH_HI,x
        sta     (xapSym),y
        lda     xapSym
        sta     XAP_SYMHASH_LO,x
        lda     xapSym+1
        sta     XAP_SYMHASH_HI,x
        bra     _xsfBlank

_xsfLinkLocal:
        ldy     #XAP_SYM_NEXT
        lda     XAP_LOCALHASH_LO,x
        sta     (xapSym),y
        iny
        lda     XAP_LOCALHASH_HI,x
        sta     (xapSym),y
        lda     xapSym
        sta     XAP_LOCALHASH_LO,x
        lda     xapSym+1
        sta     XAP_LOCALHASH_HI,x

_xsfBlank:
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

        lda     xapLocal            ; a local one is counted in its scope
        bne     _xsfCreated

        inc     xapUndefined        ; one more waiting to be defined
        bne     _xsfCreated
        inc     xapUndefined+1
_xsfCreated:
        sec                         ; created
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

; -----------------------------------------------------------------------
;   Gives the name in XAP_LABEL the value in xapValue, as an assignment
;   rather than a label: a number that happens to have a name, not a
;   place in the code. So it does not move when a widening shifts the
;   image, which is what XAP_SYM_ADDRESS is for and why _xwMoveLabels
;   has always tested it.
;
;   An assignment that something has already referred to is an error.
;   Everything about how a forward reference is sized rests on a label
;   defined later being at or above the program counter -- that is what
;   lets xapSelect settle "lda fwd" as absolute the moment it reads it,
;   and keeps the guessing and widening machinery out of ordinary
;   programs. A name that turns out to be an assignment could be
;   anything, zero page included, so allowing it would mean guessing on
;   every forward reference in every program.
;
;   The assembler this replaces cannot do it either. It evaluates an
;   undefined symbol to $EEEE on its first pass, so it reserves three
;   bytes; on the second the value is known, a zero page one assembles
;   to two, everything after it shifts and it stops with "value of an
;   identifier has changed". Refusing it outright says so earlier and
;   more clearly.
; -----------------------------------------------------------------------

xapSymAssign:
        lda     #XAP_SYM_DEFINED
        bra     xapSymDefined

; -----------------------------------------------------------------------
;   Defines the name in XAP_LABEL as a label: the address it stands at,
;   which does move when the image shifts.
; -----------------------------------------------------------------------

xapSymDefine:
        lda     #XAP_SYM_DEFINED|XAP_SYM_ADDRESS

; -----------------------------------------------------------------------
;   Both of the above, which differ only in what they set and in whether
;   a reference already waiting is allowed.
;
;   One routine rather than two because 64tass scopes an underscore name
;   between global labels, so anything two entry points share has to be
;   a global itself -- and a handful of globals in the middle of this
;   would also split it across the hotspot profile.
; -----------------------------------------------------------------------

xapSymDefined:
        sta     xapDefFlags
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

        ; An assignment something has already referred to is a use before
        ; the assignment was made. A label is free to have references
        ; waiting on it -- that is the whole point of them.
        bit     xapDefFlags
        bvs     _xsdSet
        ldy     #XAP_SYM_FIXUP
        lda     (xapSym),y
        iny
        ora     (xapSym),y
        bne     _xsdUsed

_xsdSet:
        ldy     #XAP_SYM_VALUE
        lda     xapValue
        sta     (xapSym),y
        iny
        lda     xapValue+1
        sta     (xapSym),y
        ldy     #XAP_SYM_FLAGS
        lda     xapDefFlags
        sta     (xapSym),y

        lda     xapLocal            ; counted in its own scope
        beq     _xsdGlobalCount
        dec     xapLocalUndef
        bra     _xsdCounted
_xsdGlobalCount:
        lda     xapUndefined        ; one fewer outstanding
        bne     +
        dec     xapUndefined+1
+       dec     xapUndefined
_xsdCounted:

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

_xsdUsed:
        lda     #XAP_EFORWARD
        sec
        rts

; -----------------------------------------------------------------------
;   Records that the hole at xapHole needs this symbol, with the kind in
;   A. The symbol is in xapSym and is known to be undefined.
; -----------------------------------------------------------------------

xapSymFixup:
        pha

        ; A record retired by an earlier resolution, if there is one. Without
        ; this the heap grows with every forward reference the file ever
        ; makes rather than with how many are open at once, and a corpus of
        ; a hundred thousand bytes runs it out.
        lda     xapFixFree
        ora     xapFixFree+1
        beq     _xsxBump

        lda     xapFixFree
        sta     xapFix
        lda     xapFixFree+1
        sta     xapFix+1
        ldy     #XAP_FIX_NEXT
        lda     (xapFix),y
        sta     xapFixFree
        iny
        lda     (xapFix),y
        sta     xapFixFree+1
        bra     _xsxHave

_xsxBump:
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

_xsxHave:

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
        bne     _xsrOne
        jmp     _xsrDone
_xsrOne:

        ; Where in the image that address lives, and which bank it is in.
        ldy     #XAP_FIX_PC
        lda     (xapFix),y
        tax
        iny
        lda     (xapFix),y
        tay
        jsr     xapImageAt

        ldy     #XAP_FIX_KIND
        lda     (xapFix),y
        cmp     #XAP_FIX_REL
        beq     _xsrRelative
        cmp     #XAP_FIX_LOW
        beq     _xsrLowByte

        lda     xapValue            ; two bytes, low then high
        sta     (xapTmp)

        ; The two can fall either side of a bank boundary, but only when
        ; the first is the very last byte of a bank -- once in every 8192
        ; -- so that case is asked about rather than paid for.
        lda     xapTmp
        cmp     #<(XAP_WINDOW_END - 1)
        bne     _xsrHighByte
        lda     xapTmp+1
        cmp     #>(XAP_WINDOW_END - 1)
        beq     _xsrHighCrosses
_xsrHighByte:
        ldy     #1
        lda     xapValue+1
        sta     (xapTmp),y
        bra     _xsrNext

_xsrHighCrosses:
        ldy     #XAP_FIX_PC         ; found the way the first one was
        lda     (xapFix),y
        clc
        adc     #1
        tax
        iny
        lda     (xapFix),y
        adc     #0
        tay
        jsr     xapImageAt
        lda     xapValue+1
        sta     (xapTmp)
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
        ldy     #XAP_FIX_NEXT       ; where the walk goes next
        lda     (xapFix),y
        sta     xapWrote
        iny
        lda     (xapFix),y
        sta     xapWrote+1

        lda     xapFixFree          ; and this record is spare again
        ldy     #XAP_FIX_NEXT
        sta     (xapFix),y
        lda     xapFixFree+1
        iny
        sta     (xapFix),y
        lda     xapFix
        sta     xapFixFree
        lda     xapFix+1
        sta     xapFixFree+1

        lda     xapWrote
        sta     xapFix
        lda     xapWrote+1
        sta     xapFix+1
        jmp     _xsrWalk

_xsrDone:
        jsr     xapOutBankBack      ; the window belongs to the emit path
        clc
        rts

_xsrRange:
        jsr     xapOutBankBack
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

        ; "name = value" names a number rather than a place. Look past
        ; any space for the equals, because "foo = 1" and "foo=1" are the
        ; same thing, and put the cursor back if it is not there.
        sty     xapLabelPos
        .skipspace
        cmp     #'='
        beq     _xlhAssign
        ldy     xapLabelPos

        lda     (xapSrc),y          ; the colon is optional
        cmp     #':'
        bne     +
        iny
+
        lda     xapLocal            ; a global label ends the scope the
        bne     _xlhScope           ; locals before it belonged to
        sty     xapLabelPos
        jsr     xapLocalEnd
        ldy     xapLabelPos
        bcs     _xlhExit

_xlhScope:
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
;   "name = value", where value is a number.
;
;   A name on the right hand side is not read yet. Naming one number
;   after another wants arithmetic to be worth much -- "screen + 40" and
;   the like -- so it waits for expressions, and until then the only
;   thing that can follow the equals is a literal.
;
;   An assignment does not end the local scope the way a label does.
;   64tass has the same rule, and it is the useful one: a table of
;   constants in the middle of a routine should not throw away the
;   routine's local labels.
; -----------------------------------------------------------------------

_xlhAssign:
        iny                         ; past the equals
        .skipspace

        ; A literal, and only a literal. xapNumber would happily read a
        ; name here -- it hands one to xapLabelOperand -- but that reads
        ; it into XAP_LABEL, which is the one buffer, and so over the top
        ; of the name being assigned: "foo = bar" would define bar. There
        ; is nowhere to put the second name and nothing useful to do with
        ; it if there were, since without arithmetic "foo = bar" only
        ; renames bar, and a name whose value is another symbol that has
        ; not been defined yet needs the symbol to wait on a symbol.
        ; Both arrive with expressions.
        tax
        lda     xapLetter,x
        bne     _xlhNotLiteral
        cpx     #'_'
        beq     _xlhNotLiteral
        cpx     #'@'
        bne     _xlhLiteral
_xlhNotLiteral:
        lda     #XAP_EEXPR
        sec
        rts

_xlhLiteral:
        jsr     xapNumber
        bcs     _xlhExit

        ; Nothing may follow it. A label can share its line with an
        ; instruction and an assignment cannot, so this is the place to
        ; say so rather than letting the rest of the line be assembled.
        .skipspace
        .atend                      ; nonzero means it really is the end
        bne     _xlhAssignEnd
        lda     #XAP_ESYNTAX
        sec
        rts

_xlhAssignEnd:
        sty     xapLabelPos
        jsr     xapSymAssign
        ldy     xapLabelPos
        rts

; -----------------------------------------------------------------------
;   Turns the program counter in YX into the window address of that byte
;   of the image, in xapTmp, and shows the bank it lives in. The bank
;   number comes back in A as well, for the caller that has to walk.
;
;   Everything above here treats the image as a flat run of bytes. This
;   is the only place that knows it is really eight banks seen through
;   one 8K window, and it is where the eight comes from: the offset from
;   the origin is a sixteen bit number because the program counter is, so
;   its top three bits are the bank and the rest is the address.
;
;   Leaves the window on that bank. The emit path does not set the bank
;   per byte -- that would cost six cycles on every byte of output to
;   serve a path that runs on a fixup -- so whatever comes here puts the
;   window back with xapOutBankBack before another byte is emitted.
; -----------------------------------------------------------------------

xapImageAt:
        txa
        sec
        sbc     xapOrigin
        sta     xapTmp
        tya
        sbc     xapOrigin+1

        tax                         ; the high byte of the offset carries
        and     #>(XAP_WINDOW_END - XAP_WINDOW - 1)
        ora     #>XAP_WINDOW        ; both answers: the address below bit
        sta     xapTmp+1            ; 13, and the bank above it

        txa
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        clc
        adc     #XAP_IMAGE_BANK
        sta     XAP_RAMBANK
        rts

; -----------------------------------------------------------------------
;   Steps the image cursor in xapFill down one byte, into the bank below
;   if it has run off the bottom of the window, and leaves the window
;   showing wherever it ended up.
; -----------------------------------------------------------------------

xapImageBack:
        lda     xapFill
        bne     _xibLow
        lda     xapFill+1
        cmp     #>XAP_WINDOW
        bne     _xibHigh

        lda     #>(XAP_WINDOW_END - 1)      ; the top byte of the bank below
        sta     xapFill+1
        lda     #$FF
        sta     xapFill
        dec     xapFillBank
        lda     xapFillBank
        sta     XAP_RAMBANK
        rts

_xibHigh:
        dec     xapFill+1
_xibLow:
        dec     xapFill
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

        ; Room for one more byte. xapOut is always inside the window --
        ; whatever pushed it off the top wrapped it -- so the only way to
        ; be out of image is to be out of banks.
        lda     xapOutBank
        cmp     #XAP_IMAGE_LAST
        bcs     _xwFull

        ; The cursor starts one past the top of the image and walks down.
        ldx     xapPC
        ldy     xapPC+1
        jsr     xapImageAt
        sta     xapFillBank
        lda     xapTmp
        sta     xapFill
        lda     xapTmp+1
        sta     xapFill+1

        ; How many bytes have to move. Counting them rather than walking
        ; to an address means the loop never has to compare a bank as
        ; well, and the program counter says it without any arithmetic on
        ; the image at all: the image offset of the hole is xapHole minus
        ; the origin, and of the top is xapPC minus the origin.
        lda     xapPC
        sec
        sbc     xapHole
        sta     xapTmp
        lda     xapPC+1
        sbc     xapHole+1
        sta     xapTmp+1

        ; Copy the tail up a byte, working down from the top so the two
        ; runs do not tread on each other.
_xwShift:
        lda     xapTmp
        ora     xapTmp+1
        beq     _xwShifted
        lda     xapTmp
        bne     +
        dec     xapTmp+1
+       dec     xapTmp

        jsr     xapImageBack
        lda     xapFill+1           ; the top byte of a bank has to go to
        cmp     #>(XAP_WINDOW_END - 1)   ; the bottom of the next one, and
        bne     _xwPlain            ; both banks cannot be in view at once
        lda     xapFill
        cmp     #$FF
        bne     _xwPlain

        lda     (xapFill)
        ldx     xapFillBank
        inx
        stx     XAP_RAMBANK
        sta     XAP_WINDOW
        lda     xapFillBank         ; back, for the next byte down
        sta     XAP_RAMBANK
        bra     _xwShift

_xwPlain:
        lda     (xapFill)
        ldy     #1
        sta     (xapFill),y
        bra     _xwShift

_xwShifted:
        jsr     xapImageBack        ; the opcode sits just below the hole
        lda     xapWideOp
        sta     (xapFill)

        jsr     xapOutBankBack      ; the window belongs to the emit path

        inc     xapOut              ; and everything after has moved
        bne     +
        inc     xapOut+1
        lda     xapOut+1
        cmp     #>XAP_WINDOW_END
        bne     +
        jsr     xapNextBank
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
        lda     #<XAP_SYMHEAP       ; the globals
        sta     xapFill
        lda     #>XAP_SYMHEAP
        sta     xapFill+1
        lda     xapSymTop
        sta     xapWalkEnd
        lda     xapSymTop+1
        sta     xapWalkEnd+1
        jsr     _xwMoveRange

        lda     #<XAP_LOCALHEAP     ; and the scope in hand, which sits
        sta     xapFill             ; above the shift just as often
        lda     #>XAP_LOCALHEAP
        sta     xapFill+1
        lda     xapLocalTop
        sta     xapWalkEnd
        lda     xapLocalTop+1
        sta     xapWalkEnd+1

_xwMoveRange:
_xwmLoop:
        lda     xapFill             ; reached the top of the heap?
        cmp     xapWalkEnd
        lda     xapFill+1
        sbc     xapWalkEnd+1
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
        lda     xapSymTop
        sta     xapWalkEnd
        lda     xapSymTop+1
        sta     xapWalkEnd+1
        jsr     _xraRange
        bcs     _xraExit

        ; The local heap as well. Nothing is filled in while a size is in
        ; doubt, so a scope that has been left still holds records with
        ; holes hanging off them -- which is why leaving one does not give
        ; the records back while anything is deferred.
        lda     #<XAP_LOCALHEAP
        sta     xapWalk
        lda     #>XAP_LOCALHEAP
        sta     xapWalk+1
        lda     xapLocalTop
        sta     xapWalkEnd
        lda     xapLocalTop+1
        sta     xapWalkEnd+1

_xraRange:
_xraLoop:
        lda     xapWalk              ; reached the top of the heap?
        cmp     xapWalkEnd
        lda     xapWalk+1
        sbc     xapWalkEnd+1
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
_xraExit:
        rts

; -----------------------------------------------------------------------
;   Empties the local bucket table.
; -----------------------------------------------------------------------

; -----------------------------------------------------------------------
;   Empties the whole bucket table, for a run that is only starting.
;
;   xapLocalClear below walks the list of buckets this scope wrote to,
;   which says nothing at all about the ones it did not -- and at the
;   start of a run that is every one of them. So the first clear cannot
;   go through the list; there is nothing in it, and what is in the table
;   is whatever the machine powered on with.
; -----------------------------------------------------------------------

xapLocalReset:
        lda     #0
        ldx     #XAP_LOCALMASK
_xlrLoop:
        sta     XAP_LOCALHASH_LO,x
        sta     XAP_LOCALHASH_HI,x
        dex
        bpl     _xlrLoop
        stz     xapLocalCount
        rts

; -----------------------------------------------------------------------
;   Empties it at a scope boundary, which is the hot one.
; -----------------------------------------------------------------------

xapLocalClear:
        ; Only the buckets this scope wrote to. A scope with two locals in
        ; it left two entries behind, and walking those beats walking
        ; thirty-two buckets that are almost all still empty.
        ;
        ; The count and the list agree by construction: every record made
        ; in the local heap appends one entry and bumps the count, and
        ; nothing else moves either.
        ldy     xapLocalCount
        beq     _xlcDone
_xlcLoop:
        dey
        ldx     XAP_LOCALUSED,y
        stz     XAP_LOCALHASH_LO,x
        stz     XAP_LOCALHASH_HI,x
        cpy     #0
        bne     _xlcLoop
_xlcDone:
        stz     xapLocalCount
        rts

; The list is indexed by the count, so it has to hold as many entries as
; the heap can make records -- which is the heap over the shortest record
; a one-character name can make.
XAP_LOCAL_MAXREC = (XAP_LOCALHEAP_END - XAP_LOCALHEAP) / (XAP_SYM_NAME + 1)
        .cerror XAP_LOCAL_MAXREC > XAP_LOCALUSED_END - XAP_LOCALUSED, "the local bucket list is too small for a full heap"

; -----------------------------------------------------------------------
;   Ends the current local scope, which a global label definition does.
;
;   Anything still waiting to be defined was never going to be, so this is
;   where an undefined local is caught -- at the end of the scope it
;   belonged to rather than at the end of the file.
;
;   The end of file catches it too, since the count is never cleared, so
;   this changes where the error is reported and not whether there is one.
;   That is worth nothing until errors carry a position, and five cycles a
;   global label until then.
;
;   The records go back only when nothing is deferred. While a size is
;   still in doubt no hole has been filled yet, and a widening later on
;   could move a label in a scope already left; the record has to survive
;   to be resolved at the end. Lookups cannot reach it either way, because
;   the buckets are cleared regardless.
; -----------------------------------------------------------------------

xapLocalEnd:
        lda     xapLocalUndef
        bne     _xleUndefined

        lda     xapLocalCount       ; an empty scope costs nothing to leave
        beq     _xleEmpty
        jsr     xapLocalClear

        lda     xapDeferred
        bne     _xleEmpty
        lda     #<XAP_LOCALHEAP
        sta     xapLocalTop
        lda     #>XAP_LOCALHEAP
        sta     xapLocalTop+1

_xleEmpty:
        clc
        rts

_xleUndefined:
        lda     #XAP_EUNDEF
        sec
        rts
