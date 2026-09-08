; ***********************************************************************
;
;   Choosing the opcode and emitting it.
;
; ***********************************************************************

; -----------------------------------------------------------------------
;   Settles xapMode against what the mnemonic actually accepts.
;
;   The parser reports the narrow mode; this either keeps it, widens it,
;   or rejects it. CC on success, CS with an error in A.
; -----------------------------------------------------------------------

xapSelect:
        stz     xapNarrow           ; settled unless proved otherwise
        ; A branch's operand is an address, so it parses as zero page,
        ; but relative is the only mode a branch has. Nothing that has
        ; relative has any other mode, so finding it settles the matter
        ; without looking at the value at all.
        lda     xapMode
        cmp     #XAP_MODE_ZP
        bne     _xslNotBranch
        ldx     #XAP_MODE_REL
        jsr     xapHasMode
        bcc     _xslNotBranch
        stx     xapMode
        clc
        rts

_xslNotBranch:
        lda     xapForward
        bne     _xslUnknown
        lda     xapValue+1          ; a known value picks its own width
        bne     _xslWiden
        ldx     xapMode
        jsr     xapHasMode
        bcs     _xslTake

        ; The value is not known yet. If the mnemonic has only one width
        ; the size is settled anyway -- JMP has no zero page mode, so
        ; "jmp fwd" is three bytes whatever fwd turns out to be. Only when
        ; both widths exist is the size genuinely undecidable, and then
        ; the narrow one is emitted on the chance that it fits and widened
        ; later if it does not.
_xslUnknown:
        ; A label defined later sits at or above where we are now, because
        ; the program counter only moves forward. So once we are past the
        ; zero page a forward reference cannot be a zero page address, and
        ; its size is settled without knowing its value -- which is every
        ; ordinary program, and keeps the guessing machinery out of them.
        ;
        ; This holds while every label is a code address. Assignments will
        ; break it, since "foo = $12" can name a value below the program
        ; counter, and then this has to ask whether the symbol could be an
        ; assignment rather than where the program counter is.
        lda     xapPC+1
        bne     _xslWiden

        ldx     xapMode
        jsr     xapHasMode
        bcc     _xslWiden           ; no narrow form: it is wide, settled

        ldx     xapMode
        lda     xapWiden,x
        cmp     #XAP_MODE_NONE
        beq     _xslTakeNarrow      ; no wide form either: also settled
        tax
        jsr     xapHasMode
        bcc     _xslTakeNarrow

        ; Both, so remember the opcode to swap in if it has to grow. Y is
        ; the source cursor and has to come back untouched.
        phy
        txa
        tay
        lda     (xapRow),y
        sta     xapWideOp
        ply
        inc     xapNarrow
        ldx     xapMode
        bra     _xslTake

_xslWiden:
        ; Either the value does not fit, or the mnemonic has no narrow
        ; form of this shape -- JMP has absolute indirect but no zero page
        ; indirect, so "jmp ($34)" widens even though $34 would fit.
        ldx     xapMode
        lda     xapWiden,x
        cmp     #XAP_MODE_NONE
        beq     _xslNoWider
        tax
        jsr     xapHasMode
        bcs     _xslTake

_xslNoWider:
        ldx     xapMode
        jsr     xapHasMode
        bcs     _xslNarrowOnly
        lda     #XAP_EMODE
        sec
        rts

_xslNarrowOnly:
        ; The narrow mode is the only one there is. That is fine when the
        ; value is not known yet -- the fixup will fill it in and check it
        ; then -- and too big when it is. An immediate, a bit branch and
        ; "(zp),y" all land here, none of which has a wider form.
        lda     xapForward
        bne     _xslTakeNarrow
        lda     #XAP_EVALUE
        sec
        rts

_xslTakeNarrow:
        ldx     xapMode
_xslTake:
        stx     xapMode
        clc
        rts

; -----------------------------------------------------------------------
;   CS when the mnemonic accepts the mode in X. X is preserved, because
;   every caller goes on to store it.
;
;   This used to shift a copy of the mask right once per mode number, so
;   asking about absolute cost eight iterations and asking about the
;   highest mode fourteen -- 140 cycles a call, several times a line, to
;   read one bit. The bit is now tabulated.
; -----------------------------------------------------------------------

xapHasMode:
        lda     xapModeBitLo,x
        and     xapMask
        bne     _xhmYes
        lda     xapModeBitHi,x
        and     xapMask+1
        beq     _xhmNo
_xhmYes:
        sec
        rts
_xhmNo:
        clc
        rts

; -----------------------------------------------------------------------
;   Emits the instruction and advances the program counter past it.
;   CC on success, CS with an error in A.
; -----------------------------------------------------------------------

xapEncode:
        phy                         ; Y is the source cursor

        ldy     xapMode
        lda     (xapRow),y
        ldx     xapDigit
        beq     _xenOpcode
_xenBit:
        clc                         ; RMB3 is RMB0 plus 3*16
        adc     #$10
        dex
        bne     _xenBit
_xenOpcode:
        .put

        ldx     xapMode
        cpx     #XAP_MODE_REL
        beq     _xenRelative
        cpx     #XAP_MODE_ZPREL
        beq     _xenBitBranch

        lda     xapModeLength,x
        cmp     #1
        beq     _xenViaAdvance
        lda     xapValue
        .put
        lda     xapModeLength,x
        cmp     #3
        bne     _xenViaAdvance
        lda     xapValue+1
        .put
        bra     _xenViaAdvance

; The relative and bit-branch paths sit between here and the tail of the
; routine now, so the ordinary path cannot branch over them.
_xenViaAdvance:
        jmp     _xenAdvance
_xenViaFail:
        jmp     _xenFail

_xenRelative:
        lda     xapForward          ; a target nobody has defined yet is
        ora     xapPatch            ; a hole, and so is one that may still
        bne     _xenRelHole         ; move
        lda     xapValue            ; for a branch the operand is the
        sta     xapTarget           ; target
        lda     xapValue+1
        sta     xapTarget+1
        lda     #2
        jsr     xapOffset
        bcs     _xenViaFail
        .put
        bra     _xenAdvance
_xenRelHole:
        lda     #0
        .put
        bra     _xenAdvance

_xenBitBranch:
        lda     xapValue            ; the zero page byte, then the branch,
        .put                        ; which is measured from after all
        lda     xapForward          ; three bytes
        ora     xapPatch
        bne     _xenBitHole
        lda     #3
        jsr     xapOffset
        bcs     _xenViaFail
        .put
        bra     _xenAdvance
_xenBitHole:
        lda     #0
        .put

_xenAdvance:
        lda     xapForward          ; an operand that named a label nobody
        ora     xapPatch            ; has defined yet leaves a hole here,
        beq     _xenNoFixup         ; and so does one that may still move

        lda     xapPC               ; the hole is the byte after the
        clc                         ; opcode, except for a bit branch,
        adc     #1                  ; where it is the byte after that
        sta     xapHole
        lda     xapPC+1
        adc     #0
        sta     xapHole+1

        ldx     xapMode
        cpx     #XAP_MODE_ZPREL
        bne     +
        inc     xapHole
        bne     +
        inc     xapHole+1
+
        cpx     #XAP_MODE_REL       ; a displacement, not an address
        beq     _xenFixRel
        cpx     #XAP_MODE_ZPREL
        beq     _xenFixRel
        lda     xapNarrow           ; emitted narrow on the chance it fits
        bne     _xenFixNarrow
        lda     xapModeLength,x     ; otherwise the width says which
        cmp     #3
        beq     _xenFixAbs
        lda     #XAP_FIX_LOW
        bra     _xenFixKind
_xenFixNarrow:
        lda     #XAP_FIX_NARROW
        bra     _xenFixKind
_xenFixAbs:
        lda     #XAP_FIX_ABS
        bra     _xenFixKind
_xenFixRel:
        lda     #XAP_FIX_REL
_xenFixKind:
        jsr     xapSymFixup
        bcs     _xenFail

_xenNoFixup:
        ldx     xapMode
        lda     xapModeLength,x
        clc
        adc     xapPC
        sta     xapPC
        bcc     _xenDone
        inc     xapPC+1
_xenDone:
        ply
        clc
        rts

_xenFail:
        ply                         ; PLY leaves the error code in A alone
        sec
        rts

; -----------------------------------------------------------------------
;   The branch displacement from xapPC to xapTarget, for an instruction
;   A bytes long. Returns it in A with CC, or CS on a target out of reach.
;
;   A branch is measured from the instruction after it, so the length is
;   part of the sum rather than a fixed two: BBRn is three bytes long.
; -----------------------------------------------------------------------

xapOffset:
        clc
        adc     xapPC
        sta     xapKey
        lda     xapPC+1
        adc     #0
        sta     xapKey+1

        lda     xapTarget
        sec
        sbc     xapKey
        tax
        lda     xapTarget+1
        sbc     xapKey+1

        ; In range exactly when the 16-bit difference sign extends from
        ; the byte: $0000-$007F forward, $FF80-$FFFF back.
        beq     _xofForward
        cmp     #$FF
        bne     _xofRange
        txa
        bmi     _xofOkay
        bra     _xofRange
_xofForward:
        txa
        bmi     _xofRange
_xofOkay:
        clc
        rts
_xofRange:
        lda     #XAP_ERANGE
        sec
        rts

; -----------------------------------------------------------------------
;   Writes one byte of object code. Preserves X and Y.
;
;   The buffer can only become full on a page boundary, because it ends
;   on one, so the check costs a taken branch on 255 bytes out of 256 and
;   a compare on the other. Assembling to memory points the vector at an
;   RTS and sets a limit the output never reaches.
;
;   Inlined at its callers, where the call and return were two thirds of
;   the cost. The subroutine stays for anything cold enough not to care.
; -----------------------------------------------------------------------

put .macro
        sta     (xapOut)
        inc     xapOut
        bne     _put\@
        inc     xapOut+1
        lda     xapOut+1
        cmp     xapOutTop+1
        bne     _put\@
        jsr     xapPutFlush
_put\@
        .endm

xapPut:
        .put
        rts

xapPutFlush:
        jmp     (xapFlushVec)
