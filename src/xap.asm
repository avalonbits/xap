; ***********************************************************************
;
;   xap -- a 65C02 assembler for the Commander X16, written in 65C02.
;
;   This stage assembles instructions and nothing else. There are no
;   labels, no symbolic constants, no directives and no macros: every
;   operand is a literal whose value is known the moment it is read. What
;   it does do is encode every one of the W65C02S's 212 opcodes.
;
;   Single pass, and each source byte is read exactly once. With no
;   forward references there is nothing yet that could force a second
;   look, but the shape is the point: the reader only ever moves forward,
;   bytes are emitted as soon as the instruction is understood, and
;   nothing is buffered for a later pass to revisit. When labels arrive
;   they add a patch list, not a second read of the source.
;
; ***********************************************************************

        * = CODEADDR

; -----------------------------------------------------------------------
;   Entry vector. First word of the binary, so a caller needs one address
;   and not a symbol table.
; -----------------------------------------------------------------------

        jmp     xapAssemble

; -----------------------------------------------------------------------
;   Zero page.
;
;   $22 is the first byte the X16 leaves to the user; the KERNAL's r0-r15
;   sit below it and BASIC's area above. Twenty bytes, which leaves the
;   rest of the user range for the caller.
; -----------------------------------------------------------------------

XAP_ZP    = $22

xapSrc    = XAP_ZP+0        ; source text, NUL terminated
xapOut    = XAP_ZP+2        ; where the next code byte goes
xapPC     = XAP_ZP+4        ; program counter of the instruction being built
xapValue  = XAP_ZP+6        ; the operand's value
xapTarget = XAP_ZP+8        ; second operand: the branch target of BBRx/BBSx
xapKey    = XAP_ZP+10       ; packed mnemonic, and scratch for the search
xapRow    = XAP_ZP+12       ; the mnemonic's opcode row
xapMask   = XAP_ZP+14       ; the modes it accepts
xapMode   = XAP_ZP+16       ; the mode its operand turned out to be
xapSlot   = XAP_ZP+17       ; its index in the tables
xapDigit  = XAP_ZP+18       ; the n of RMBn, or 0
xapFlags  = XAP_ZP+19       ; XAP_FLAG_BITOP

; -----------------------------------------------------------------------
;   Error codes.
;
;   The ones below $20 are the ROM assembler's, so that a program written
;   against its numbering keeps working. Codes it has no equivalent for
;   start at $20: it has no unknown-mnemonic error because an unknown word
;   is a label to it, and that is a distinction xap cannot make yet.
; -----------------------------------------------------------------------

XAP_OK        = $00
XAP_ESYNTAX   = $01         ; general syntax error
XAP_ERANGE    = $07         ; relative branch out of range
XAP_EMODE     = $08         ; address mode not supported
XAP_EEXPR     = $09         ; bad expression
XAP_EMNEMONIC = $20         ; not an instruction
XAP_EBIT      = $21         ; bit number missing, or not 0-7
XAP_EVALUE    = $22         ; value does not fit the only mode available

; -----------------------------------------------------------------------
;   Assembles the text at xapSrc to xapOut, starting at xapPC.
;
;   Returns the error code in A, CC on success and CS on failure. On
;   failure xapSrc points into the line that failed.
; -----------------------------------------------------------------------

xapAssemble:
        jsr     xapLine
        bcs     _xaDone             ; stop at the first error
        ldy     #0
        lda     (xapSrc),y          ; end of the text?
        bne     xapAssemble

        lda     #XAP_OK
        clc
_xaDone:
        rts

; -----------------------------------------------------------------------
;   Assembles one line, leaving xapSrc on the first character of the next.
;
;   Y is the cursor for the whole line and is folded back into xapSrc
;   only at the end, so scanning is an indexed read rather than a pointer
;   increment. Lines are capped well below 255 characters, so it cannot
;   run off the end of the index.
; -----------------------------------------------------------------------

xapLine:
        ldy     #0
        jsr     xapSkipSpace
        jsr     xapAtEnd            ; a blank or comment-only line
        beq     xapEndLine

        jsr     xapMnemonic         ; which instruction
        bcs     xapFail
        jsr     xapOperand          ; and what it is applied to
        bcs     xapFail
        jsr     xapSelect           ; the mode those two agree on
        bcs     xapFail
        jsr     xapEncode           ; bytes out
        bcs     xapFail

        jsr     xapSkipSpace
        jsr     xapAtEnd            ; nothing may follow the operand
        beq     xapEndLine
        lda     #XAP_ESYNTAX
        ; fall through

; -----------------------------------------------------------------------
;   Fails with the code in A, leaving xapSrc at the start of the line so
;   the caller can report where.
; -----------------------------------------------------------------------

xapFail:
        sec
        rts

; -----------------------------------------------------------------------
;   Steps over the rest of the line, including its terminator, and folds
;   the cursor back into xapSrc.
; -----------------------------------------------------------------------

xapEndLine:
        lda     (xapSrc),y
        beq     _xelFold            ; end of text: stop on the NUL
        cmp     #13
        beq     _xelEol
        cmp     #10
        beq     _xelEol
        iny                         ; comment body
        bra     xapEndLine

_xelEol:
        iny                         ; step over the terminator, and over
        cmp     #13                 ; the LF of a CR LF pair
        bne     _xelFold
        lda     (xapSrc),y
        cmp     #10
        bne     _xelFold
        iny

_xelFold:
        tya
        clc
        adc     xapSrc
        sta     xapSrc
        bcc     _xelExit
        inc     xapSrc+1
_xelExit:
        clc
        rts

; -----------------------------------------------------------------------
;   Z set when the cursor is at something that ends the line: the NUL, a
;   newline, or a comment. Does not move the cursor.
; -----------------------------------------------------------------------

xapAtEnd:
        lda     (xapSrc),y
        beq     _xaeYes
        cmp     #13
        beq     _xaeYes
        cmp     #10
        beq     _xaeYes
        cmp     #';'
        beq     _xaeYes
        rts                         ; Z clear from the compare
_xaeYes:
        lda     #0                  ; Z set
        rts

; -----------------------------------------------------------------------
;   Steps the cursor over spaces and tabs.
; -----------------------------------------------------------------------

xapSkipSpace:
        lda     (xapSrc),y
        cmp     #' '
        beq     _xssNext
        cmp     #9
        bne     _xssDone
_xssNext:
        iny
        bra     xapSkipSpace
_xssDone:
        rts

        .include "lex.asm"
        .include "mode.asm"
        .include "encode.asm"
        .include "isa.inc"
