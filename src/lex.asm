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
;   bits each into one word -- A is 1, Z is 26, and zero is not a letter,
;   so a short word cannot look like a long one padded out. RMB3 and its
;   siblings pack as RMB; the digit is read afterwards and folded into the
;   opcode, not the key.
;
;   The key is built by lookup rather than by shifting. It is
;   c1<<10 | c2<<5 | c3, and of those the first letter lands wholly in the
;   high byte as c1<<2 and the third wholly in the low byte; only the
;   second straddles the two, and its halves are tabulated. Reading a
;   letter is one indexed load that folds the case and rejects a
;   non-letter at the same time. Between them these replace fifteen
;   asl/rol pairs on a zero page word and three calls to fold the case --
;   about 250 cycles a line, for the sake of a 256-byte table.
; -----------------------------------------------------------------------

xapMnemonic:
        stz     xapDigit

        lda     (xapSrc),y
        tax
        lda     xapLetter,x
        beq     _xmNotAWord
        asl     a                   ; c1<<2 in the high byte is c1<<10
        asl     a
        sta     xapKey+1
        iny

        lda     (xapSrc),y
        tax
        lda     xapLetter,x
        beq     _xmNotAWord
        tax
        lda     xapLetter2Hi,x      ; the halves of c2<<5
        ora     xapKey+1
        sta     xapKey+1
        lda     xapLetter2Lo,x
        sta     xapKey
        iny

        lda     (xapSrc),y
        tax
        lda     xapLetter,x
        beq     _xmNotAWord
        ora     xapKey              ; c2<<5 leaves the low five bits clear,
        sta     xapKey              ; so the third letter just drops in
        iny

        jsr     xapFind
        bcs     _xmNotAWord

        ; Everything about this mnemonic, indexed by its slot. The address
        ; of the opcode row is tabulated too, rather than shifting the slot
        ; left four and adding the base every time.
        lda     xapModeMaskLo,x
        sta     xapMask
        lda     xapModeMaskHi,x
        sta     xapMask+1
        lda     xapMnemonicFlags,x
        sta     xapFlags
        lda     xapRowLo,x
        sta     xapRow
        lda     xapRowHi,x
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
;   Finds xapKey. CC with the slot in X, CS if there is no such mnemonic.
;
;   A hashed lookup with linear probing, which replaced a binary search
;   that cost seven iterations and a subroutine call in each. Seventy
;   entries in 256 slots is a load factor of 0.27 and about 1.3 probes for
;   a hit, so this is a shade over one compare where the search was seven.
;
;   Not a perfect hash: seventy keys placed collision-free in 256 slots is
;   a one in ten thousand shot, and finding one would cost more complexity
;   than the quarter of a probe it saves.
;
;   The slot number is passed back through xapSlot because Y is the source
;   cursor and has to be given back untouched.
; -----------------------------------------------------------------------

xapFind:
        phy

        lda     xapKey+1
        .if XAP_HASH_SHIFT >= 1
        asl     a
        .endif
        .if XAP_HASH_SHIFT >= 2
        asl     a
        .endif
        .if XAP_HASH_SHIFT >= 3
        asl     a
        .endif
        eor     xapKey
        tax

_xfProbe:
        ldy     xapHashTable,x      ; slots are 0..69, so an empty one is
        bmi     _xfMissing          ; the only value with bit 7 set
        lda     xapKey
        cmp     xapKeyLo,y
        bne     _xfNext
        lda     xapKey+1
        cmp     xapKeyHi,y
        beq     _xfFound
_xfNext:
        inx                         ; the table always keeps an empty slot,
        bra     _xfProbe            ; so a miss cannot circle forever

_xfFound:
        sty     xapSlot
        ply
        ldx     xapSlot
        clc
        rts

_xfMissing:
        ply
        sec
        rts

; -----------------------------------------------------------------------
;   Reads a number into xapValue. CC on success, CS with an error in A.
;
;   $ is hex, % is binary, ' is a character, anything else is decimal.
;   Values are 16 bit and wrap silently, as they do in the ROM assembler.
;
;   Recognising a digit is one indexed load. It used to be a call to a
;   routine that itself called another, for the sake of two compares --
;   about forty cycles a digit where this is sixteen, on the hottest loop
;   in the assembler. One table serves all three bases: a hex digit worth
;   less than ten is a decimal digit, less than two is a binary one, and
;   $FF is not a digit at all.
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

        tax
        lda     xapHexDigit,x
        cmp     #10
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
        tax
        lda     xapHexDigit,x
        cmp     #10
        bcc     _xnDecimal
        clc
        rts

; ---- hex --------------------------------------------------------------

_xnHex:
        iny
        lda     (xapSrc),y
        tax
        lda     xapHexDigit,x
        cmp     #XAP_NOT_DIGIT
        beq     _xnBad
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
        tax
        lda     xapHexDigit,x
        cmp     #XAP_NOT_DIGIT
        bne     _xnHexLoop
        clc
        rts

; ---- binary -----------------------------------------------------------

_xnBinary:
        iny
        lda     (xapSrc),y
        tax
        lda     xapHexDigit,x
        cmp     #2
        bcs     _xnBad
_xnBinLoop:
        asl     xapValue
        rol     xapValue+1
        ora     xapValue
        sta     xapValue
        iny
        lda     (xapSrc),y
        tax
        lda     xapHexDigit,x
        cmp     #2
        bcc     _xnBinLoop
        clc
        rts

; ---- character --------------------------------------------------------
;
;   The closing quote is required, so a stray one is an error rather than
;   the start of something that swallows the rest of the line.

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
;   xapValue = xapValue * 10, leaving A alone for the caller's digit.
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
;
;   Two nested calls became one indexed load.
; -----------------------------------------------------------------------

xapIsIdent:
        tax
        lda     xapClass,x
        and     #XAP_CLASS_IDENT
        beq     _xiiNo
        sec
        rts
_xiiNo:
        clc
        rts
