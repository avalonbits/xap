; ***********************************************************************
;
;   Reading mnemonics and numbers.
;
; ***********************************************************************

; -----------------------------------------------------------------------
;   Reads the mnemonic at the cursor and looks it up.
;
;   Sets xapSlot, xapRow, xapMask, xapFlags and xapDigit. Returns CS with
;   an error in A if the word is not an instruction.
;
;   Every mnemonic is three letters, so the key is those three packed five
;   bits each into one word -- A is 1, Z is 26, and zero is not a letter.
;   Comparing two keys is one 16-bit compare where comparing the spellings
;   is a three byte loop with a case fold in it, and the key costs nothing
;   to build because the fold has to happen while the letters are being
;   read anyway. RMB3 and its siblings pack as RMB; the digit is read
;   afterwards and folded into the opcode, not the key.
; -----------------------------------------------------------------------

xapMnemonic:
        stz     xapKey
        stz     xapKey+1
        stz     xapDigit

        ldx     #3
_xmLetter:
        lda     (xapSrc),y
        jsr     xapUpper
        cmp     #'A'
        bcc     _xmNotAWord
        cmp     #'Z'+1
        bcs     _xmNotAWord
        sec
        sbc     #'A'-1              ; A is 1, so a short word cannot look
        pha                         ; like a long one padded with zeros

        asl     xapKey              ; key = key << 5 | letter
        rol     xapKey+1
        asl     xapKey
        rol     xapKey+1
        asl     xapKey
        rol     xapKey+1
        asl     xapKey
        rol     xapKey+1
        asl     xapKey
        rol     xapKey+1
        pla
        ora     xapKey
        sta     xapKey

        iny
        dex
        bne     _xmLetter

        jsr     xapFind
        bcs     _xmNotAWord

        ; The tables for this slot. The opcode row is sixteen bytes, so
        ; its address is the slot shifted left four.
        stx     xapSlot
        lda     xapModeMaskLo,x
        sta     xapMask
        lda     xapModeMaskHi,x
        sta     xapMask+1
        lda     xapMnemonicFlags,x
        sta     xapFlags

        stx     xapRow
        stz     xapRow+1
        asl     xapRow
        rol     xapRow+1
        asl     xapRow
        rol     xapRow+1
        asl     xapRow
        rol     xapRow+1
        asl     xapRow
        rol     xapRow+1
        lda     xapRow
        clc
        adc     #<xapOpcodes
        sta     xapRow
        lda     xapRow+1
        adc     #>xapOpcodes
        sta     xapRow+1

        lda     xapFlags            ; RMBn and friends want their digit
        and     #XAP_FLAG_BITOP
        beq     _xmPlain

        lda     (xapSrc),y
        sec
        sbc     #'0'
        cmp     #8
        bcs     _xmBadBit
        sta     xapDigit
        iny

_xmPlain:
        ; A letter or digit still here means the word was longer than the
        ; mnemonic -- LDAX, or RMB3X -- and is not this instruction.
        lda     (xapSrc),y
        jsr     xapIsIdent
        bcs     _xmNotAWord
        clc
        rts

_xmBadBit:
        lda     #XAP_EBIT
        sec
        rts

_xmNotAWord:
        lda     #XAP_EMNEMONIC
        sec
        rts

; -----------------------------------------------------------------------
;   Finds xapKey in the sorted key table. CC with the slot in X, or CS.
;
;   The bound is exclusive, so neither end can run past the ends of the
;   table: the window only ever shrinks towards a single slot, which is
;   then the one candidate to compare.
; -----------------------------------------------------------------------

xapFind:
        stz     xapRow              ; lo, reused as scratch before the row
        lda     #XAP_MNEMONIC_COUNT
        sta     xapRow+1            ; hi, exclusive

_xfLoop:
        lda     xapRow
        cmp     xapRow+1
        bcs     _xfSettled          ; lo >= hi, the window is empty

        clc                         ; mid = (lo + hi) / 2
        adc     xapRow+1
        lsr     a
        tax

        jsr     xapCompare
        bcc     _xfLower            ; key < table[mid]
        beq     _xfLower            ; key == table[mid], keep it in range
        inx                         ; key > table[mid], lo = mid + 1
        stx     xapRow
        bra     _xfLoop
_xfLower:
        stx     xapRow+1            ; hi = mid
        bra     _xfLoop

_xfSettled:
        ldx     xapRow
        cpx     #XAP_MNEMONIC_COUNT
        bcs     _xfMissing
        jsr     xapCompare
        bne     _xfMissing
        clc
        rts
_xfMissing:
        sec
        rts

; -----------------------------------------------------------------------
;   Compares xapKey against the key in slot X, as a subtraction: C set if
;   the key is greater or equal, Z set if equal.
; -----------------------------------------------------------------------

xapCompare:
        lda     xapKey+1
        cmp     xapKeyHi,x
        bne     _xcDone             ; the high bytes settle it
        lda     xapKey
        cmp     xapKeyLo,x
_xcDone:
        rts

; -----------------------------------------------------------------------
;   Reads a number into xapValue. CC on success, CS with an error in A.
;
;   $ is hex, % is binary, ' is a character, anything else is decimal.
;   Values are 16 bit and wrap silently, as they do in the ROM assembler.
; -----------------------------------------------------------------------

xapNumber:
        stz     xapValue
        stz     xapValue+1

        lda     (xapSrc),y
        cmp     #'$'
        beq     _xnHex
        cmp     #'%'
        beq     _xnBinary
        cmp     #''''
        beq     _xnChar

; ---- decimal ----------------------------------------------------------

        jsr     xapDigitValue
        bcs     _xnBad              ; a number has to start with a digit
_xnDecimal:
        jsr     xapMul10
        clc
        adc     xapValue
        sta     xapValue
        bcc     +
        inc     xapValue+1
+       iny
        lda     (xapSrc),y
        jsr     xapDigitValue
        bcc     _xnDecimal
        clc
        rts

; ---- hex --------------------------------------------------------------

_xnHex:
        iny
        lda     (xapSrc),y
        jsr     xapHexValue
        bcs     _xnBad
_xnHexLoop:
        asl     xapValue            ; a nibble at a time
        rol     xapValue+1
        asl     xapValue
        rol     xapValue+1
        asl     xapValue
        rol     xapValue+1
        asl     xapValue
        rol     xapValue+1
        ora     xapValue
        sta     xapValue
        iny
        lda     (xapSrc),y
        jsr     xapHexValue
        bcc     _xnHexLoop
        clc
        rts

; ---- binary -----------------------------------------------------------

_xnBinary:
        iny
        lda     (xapSrc),y
        jsr     xapBitValue
        bcs     _xnBad
_xnBinLoop:
        asl     xapValue
        rol     xapValue+1
        ora     xapValue
        sta     xapValue
        iny
        lda     (xapSrc),y
        jsr     xapBitValue
        bcc     _xnBinLoop
        clc
        rts

; ---- character --------------------------------------------------------
;
;   'a' is the code of the character between the quotes. The closing quote
;   is required, so a stray quote is an error rather than the start of
;   something that swallows the rest of the line.

_xnChar:
        iny
        lda     (xapSrc),y
        beq     _xnBad              ; end of text inside the quotes
        sta     xapValue
        iny
        lda     (xapSrc),y
        cmp     #''''
        bne     _xnBad
        iny
        clc
        rts

_xnBad:
        lda     #XAP_EEXPR
        sec
        rts

; -----------------------------------------------------------------------
;   xapValue = xapValue * 10, leaving the running total in A's caller.
;
;   Ten is eight plus two, so it is two shifted copies added, which is
;   cheaper than a multiply routine and is the only multiply xap needs
;   until expressions arrive.
; -----------------------------------------------------------------------

xapMul10:
        pha
        asl     xapValue            ; x2
        rol     xapValue+1
        lda     xapValue
        pha
        lda     xapValue+1
        pha
        asl     xapValue            ; x4
        rol     xapValue+1
        asl     xapValue            ; x8
        rol     xapValue+1
        pla                         ; + the x2 copy
        clc
        adc     xapValue+1
        sta     xapValue+1
        pla
        clc
        adc     xapValue
        sta     xapValue
        bcc     +
        inc     xapValue+1
+       pla
        rts

; -----------------------------------------------------------------------
;   Character classes. Each returns CC with the value in A, or CS.
; -----------------------------------------------------------------------

xapDigitValue:
        cmp     #'0'
        bcc     _xdvNo
        cmp     #'9'+1
        bcs     _xdvNo
        sec
        sbc     #'0'
        clc
        rts
_xdvNo:
        sec
        rts

xapBitValue:
        cmp     #'0'
        bcc     _xbvNo
        cmp     #'2'
        bcs     _xbvNo
        sec
        sbc     #'0'
        clc
        rts
_xbvNo:
        sec
        rts

xapHexValue:
        jsr     xapDigitValue
        bcc     _xhvDone
        jsr     xapUpper
        cmp     #'A'
        bcc     _xhvNo
        cmp     #'F'+1
        bcs     _xhvNo
        sec
        sbc     #'A'-10
        clc
_xhvDone:
        rts
_xhvNo:
        sec
        rts

; -----------------------------------------------------------------------
;   Folds a letter to upper case, leaving anything else alone.
;
;   Clearing bit 5 would turn punctuation into control codes, so the fold
;   only applies to the range it is meant for.
; -----------------------------------------------------------------------

xapUpper:
        cmp     #'a'
        bcc     _xuDone
        cmp     #'z'+1
        bcs     _xuDone
        and     #$DF
_xuDone:
        rts

; -----------------------------------------------------------------------
;   CS when A could continue an identifier: a letter or a digit.
; -----------------------------------------------------------------------

xapIsIdent:
        jsr     xapDigitValue
        bcc     _xiiYes
        jsr     xapUpper
        cmp     #'A'
        bcc     _xiiNo
        cmp     #'Z'+1
        bcs     _xiiNo
_xiiYes:
        sec
        rts
_xiiNo:
        clc
        rts
