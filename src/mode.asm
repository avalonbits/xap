; ***********************************************************************
;
;   Working out what the operand is.
;
;   The parser reports the narrow form of whatever it reads -- zero page
;   rather than absolute, and so on. It has to: "lda $34" and "lda $1234"
;   are the same shape, and only the value tells them apart. Choosing
;   between the two is xapSelect's job, once the mnemonic's mode mask is
;   also in hand.
;
; ***********************************************************************

; -----------------------------------------------------------------------
;   Reads the operand at the cursor into xapValue and xapMode. CC on
;   success, CS with an error in A.
;
;   xapTarget is not cleared here, and must not come to depend on being.
;   Only a branch has a target, and both kinds write it from this line's
;   own operand before anything reads it: the bit branch below, and
;   xapEncode for an ordinary one, which copies xapValue into it. So
;   zeroing it every instruction was six cycles spent on a value that is
;   either about to be overwritten or never looked at.
; -----------------------------------------------------------------------

xapOperand:
        stz     xapValue
        stz     xapValue+1

        ; Cleared here as well as in xapNumber, because an instruction
        ; with no operand never reaches xapNumber -- and a NOP after a
        ; forward reference would otherwise inherit the flag and be told
        ; its mode was too narrow for a value it does not have.
        stz     xapForward
        stz     xapPatch

        .skipspace
        .atend
        bne     _xoImplied          ; nothing there at all

        txa                         ; .atend left the character in X
        cmp     #'#'
        beq     _xoImmediate
        cmp     #'('
        beq     _xoIndirect

        ; A letter starts either the accumulator's "A" or a label, and a
        ; lone A is the only thing that is not a label.
        tax
        lda     xapLetter,x
        beq     _xoAddressNear      ; not a letter, so it is a number
        cmp     #1
        bne     _xoAddressNear      ; some other word: a label
        lda     xapFlags            ; and a lone A is only the accumulator
        and     #XAP_FLAG_ACC       ; for the six that have that mode --
        beq     _xoAddressNear      ; "jmp a" is a jump to a label named a
        iny
        lda     (xapSrc),y
        .isident
        beq     _xoImplied          ; a bare A
        dey                         ; "AB..." is a label after all
        bra     _xoAddressNear

_xoImplied:
        lda     #XAP_MODE_IMPACC
        sta     xapMode
        clc
        rts

; The two ends of this routine are out of branch range of each other, so
; these are the staging posts they jump through.
_xoSyntaxNear:
        jmp     _xoSyntax
_xoAddressNear:
        jmp     _xoAddress

; ---- #nn --------------------------------------------------------------

_xoImmediate:
        iny
        .skipspace
        jsr     xapNumber
        bcs     _xoExit
        lda     #XAP_MODE_IMM
        sta     xapMode
        clc
_xoExit:
        rts

; ---- (nn) (nn,x) (nn),y -----------------------------------------------

_xoIndirect:
        iny
        .skipspace
        jsr     xapNumber
        bcs     _xoExit
        .skipspace

        lda     (xapSrc),y
        cmp     #','
        beq     _xoIndirectX
        cmp     #')'
        bne     _xoSyntaxNear
        iny
        .skipspace

        lda     (xapSrc),y          ; (nn) or (nn),y
        cmp     #','
        bne     _xoIndirectPlain
        iny
        .skipspace
        lda     #'Y'
        jsr     xapRegister
        bcs     _xoSyntaxMid
        lda     #XAP_MODE_IZY
        sta     xapMode
        clc
        rts

_xoIndirectPlain:
        lda     #XAP_MODE_IZP
        sta     xapMode
        clc
        rts

; The middle of the routine is out of range of both ends now.
_xoSyntaxMid:
        jmp     _xoSyntax

_xoIndirectX:
        iny
        .skipspace
        lda     #'X'
        jsr     xapRegister
        bcs     _xoSyntaxMid
        .skipspace
        lda     (xapSrc),y
        cmp     #')'
        bne     _xoSyntaxMid
        iny
        lda     #XAP_MODE_IZX
        sta     xapMode
        clc
        rts

; ---- nn  nn,x  nn,y  nn,target ----------------------------------------

_xoAddress:
        jsr     xapNumber
        bcs     _xoAddrExit         ; the shared exit is out of reach here
        .skipspace

        lda     (xapSrc),y
        cmp     #','
        beq     _xoIndexed
        lda     #XAP_MODE_ZP
        sta     xapMode
        clc
_xoAddrExit:
        rts

_xoIndexed:
        iny
        .skipspace

        lda     #'X'
        jsr     xapRegister
        bcc     _xoIndexedX
        lda     #'Y'
        jsr     xapRegister
        bcc     _xoIndexedY

        ; Not an index register, so the only thing it can be is the branch
        ; target of a BBRn or BBSn. Anything else has run out of forms.
        lda     xapFlags
        and     #XAP_FLAG_BITOP
        beq     _xoSyntax

        lda     xapForward          ; the fixup can only wait on one
        bne     _xoSyntaxMid        ; symbol, and the target is the one
                                    ; that needs it
        lda     xapValue+1          ; the bit address, kept while the
        pha                         ; target is read over the top of it
        lda     xapValue
        pha
        jsr     xapNumber
        bcs     _xoDropTwo
        lda     xapValue
        sta     xapTarget
        lda     xapValue+1
        sta     xapTarget+1
        pla
        sta     xapValue
        pla
        sta     xapValue+1

        lda     #XAP_MODE_ZPREL
        sta     xapMode
        clc
        rts

_xoDropTwo:
        plx                         ; keep the error in A
        plx
        sec
        rts

_xoIndexedX:
        lda     #XAP_MODE_ZPX
        sta     xapMode
        clc
        rts

_xoIndexedY:
        lda     #XAP_MODE_ZPY
        sta     xapMode
        clc
        rts

_xoSyntax:
        lda     #XAP_ESYNTAX
        sec
        rts

; -----------------------------------------------------------------------
;   Matches the register named in A at the cursor, stepping over it on a
;   match. CC on a match, CS with the cursor untouched otherwise.
;
;   The letter has to stand alone: "$34,xy" is not "$34,x" with something
;   ignored after it.
; -----------------------------------------------------------------------

xapRegister:
        pha
        lda     (xapSrc),y
        jsr     xapUpper
        sta     xapKey              ; free until the next mnemonic
        pla
        cmp     xapKey
        bne     _xrNo

        iny
        lda     (xapSrc),y
        .isident
        bne     _xrBacktrack
        clc
        rts

_xrBacktrack:
        dey                         ; one character, and only on a miss
_xrNo:
        sec
        rts
