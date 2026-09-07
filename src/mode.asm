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
;   Reads the operand at the cursor into xapValue, xapTarget and xapMode.
;   CC on success, CS with an error in A.
; -----------------------------------------------------------------------

xapOperand:
        stz     xapValue
        stz     xapValue+1
        stz     xapTarget
        stz     xapTarget+1

        jsr     xapSkipSpace
        jsr     xapAtEnd
        beq     _xoImplied          ; nothing there at all

        lda     (xapSrc),y
        cmp     #'#'
        beq     _xoImmediate
        cmp     #'('
        beq     _xoIndirect

        ; A letter here can only be the accumulator's "A". There are no
        ; symbols yet, so any other word is a syntax error rather than a
        ; name to resolve later.
        jsr     xapUpper
        cmp     #'A'
        bcc     _xoAddress
        cmp     #'Z'+1
        bcs     _xoAddress
        cmp     #'A'
        bne     _xoSyntaxNear
        iny
        lda     (xapSrc),y          ; "AB" is not the accumulator
        jsr     xapIsIdent
        bcs     _xoSyntaxNear

_xoImplied:
        lda     #XAP_MODE_IMPACC
        sta     xapMode
        clc
        rts

; The error itself sits at the end of the routine, out of reach of the
; branches at either end of it. This is the staging post they use.
_xoSyntaxNear:
        jmp     _xoSyntax

; ---- #nn --------------------------------------------------------------

_xoImmediate:
        iny
        jsr     xapSkipSpace
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
        jsr     xapSkipSpace
        jsr     xapNumber
        bcs     _xoExit
        jsr     xapSkipSpace

        lda     (xapSrc),y
        cmp     #','
        beq     _xoIndirectX
        cmp     #')'
        bne     _xoSyntaxNear
        iny
        jsr     xapSkipSpace

        lda     (xapSrc),y          ; (nn) or (nn),y
        cmp     #','
        bne     _xoIndirectPlain
        iny
        jsr     xapSkipSpace
        lda     #'Y'
        jsr     xapRegister
        bcs     _xoSyntaxNear
        lda     #XAP_MODE_IZY
        sta     xapMode
        clc
        rts

_xoIndirectPlain:
        lda     #XAP_MODE_IZP
        sta     xapMode
        clc
        rts

_xoIndirectX:
        iny
        jsr     xapSkipSpace
        lda     #'X'
        jsr     xapRegister
        bcs     _xoSyntax
        jsr     xapSkipSpace
        lda     (xapSrc),y
        cmp     #')'
        bne     _xoSyntax
        iny
        lda     #XAP_MODE_IZX
        sta     xapMode
        clc
        rts

; ---- nn  nn,x  nn,y  nn,target ----------------------------------------

_xoAddress:
        jsr     xapNumber
        bcs     _xoExit
        jsr     xapSkipSpace

        lda     (xapSrc),y
        cmp     #','
        beq     _xoIndexed
        lda     #XAP_MODE_ZP
        sta     xapMode
        clc
        rts

_xoIndexed:
        iny
        jsr     xapSkipSpace

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
        jsr     xapIsIdent
        bcs     _xrBacktrack
        clc
        rts

_xrBacktrack:
        dey                         ; one character, and only on a miss
_xrNo:
        sec
        rts
