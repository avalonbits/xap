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
;   The source is a window into a buffer rather than the whole text, and
;   the window is refilled through a vector. That is what lets the same
;   assembler read a file of any size through the KERNAL and also run
;   against a block of memory, which is how the host tests drive it
;   without an emulator.
;
; ***********************************************************************

        * = CODEADDR

; -----------------------------------------------------------------------
;   Entry vectors, at the front so a caller needs addresses and not a
;   symbol table.
; -----------------------------------------------------------------------

        jmp     xapAssemble         ; +0  assemble the text at xapSrc
        jmp     xapAssembleFile     ; +3  assemble xapName to xapObjName

; -----------------------------------------------------------------------
;   Buffers.
;
;   Both are page aligned and end on a page boundary, so the tests for
;   "full" are single byte compares. The source buffer has one byte past
;   its end for the terminator that marks the end of the window.
; -----------------------------------------------------------------------

XAP_BUFFER      = $2000
XAP_BUFFER_SIZE = $1000             ; source window, 4K
XAP_BUFFER_END  = XAP_BUFFER + XAP_BUFFER_SIZE

; A page clear of the source buffer's end, which has one byte past it for
; the terminator.
XAP_OBJBUF      = XAP_BUFFER_END + $100
XAP_OBJBUF_SIZE = $400              ; object output, 1K
XAP_OBJBUF_END  = XAP_OBJBUF + XAP_OBJBUF_SIZE

; -----------------------------------------------------------------------
;   Zero page.
;
;   $22 is the first byte the X16 leaves to the user; the KERNAL's r0-r15
;   sit below it and BASIC's area above.
; -----------------------------------------------------------------------

XAP_ZP    = $22

xapSrc        = XAP_ZP+0            ; where the next source byte is
xapOut        = XAP_ZP+2            ; where the next code byte goes
xapPC         = XAP_ZP+4            ; program counter of the instruction
xapValue      = XAP_ZP+6            ; the operand's value
xapTarget     = XAP_ZP+8            ; the branch target of BBRx/BBSx
xapKey        = XAP_ZP+10           ; packed mnemonic, then scratch
xapRow        = XAP_ZP+12           ; the mnemonic's opcode row
xapMask       = XAP_ZP+14           ; the modes it accepts
xapMode       = XAP_ZP+16           ; the mode its operand turned out to be
xapSlot       = XAP_ZP+17           ; its index in the tables
xapDigit      = XAP_ZP+18           ; the n of RMBn, or 0
xapFlags      = XAP_ZP+19           ; XAP_FLAG_BITOP

xapBufTop     = XAP_ZP+20           ; end of the source window
xapFill       = XAP_ZP+22           ; where a refill or flush is working
xapTmp        = XAP_ZP+24           ; byte counts during refill and flush
xapWrote      = XAP_ZP+26           ; how much the last block call moved
xapOutTop     = XAP_ZP+28           ; when the object buffer is full
xapEOF        = XAP_ZP+30           ; the source file has run out
xapObjError   = XAP_ZP+31           ; a write failed, reported at the end
xapName       = XAP_ZP+32           ; source file name
xapNameLen    = XAP_ZP+34
xapObjName    = XAP_ZP+35           ; object file name
xapObjNameLen = XAP_ZP+37
xapRefillVec  = XAP_ZP+38           ; how to get more source
xapFlushVec   = XAP_ZP+40           ; what to do with a full object buffer
xapRunError   = XAP_ZP+42           ; held while the files are closed
xapRawTop     = XAP_ZP+43           ; end of what was read, past the window
xapNulSave    = XAP_ZP+45           ; the byte the window terminator covers
xapNib        = XAP_ZP+46           ; the first three nibbles of a hex number

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
XAP_ENOFILE   = $05         ; source file not found
XAP_ERANGE    = $07         ; relative branch out of range
XAP_EMODE     = $08         ; address mode not supported
XAP_EEXPR     = $09         ; bad expression
XAP_ELINE     = $0A         ; line too long
XAP_EMNEMONIC = $20         ; not an instruction
XAP_EBIT      = $21         ; bit number missing, or not 0-7
XAP_EVALUE    = $22         ; value does not fit the only mode available

; -----------------------------------------------------------------------
;   Z clear when the character in A ends the line: the end of the window,
;   a newline, or a comment. Leaves the character in X, so a caller that
;   wants it back does not read it again.
;
;   A macro because it was four compares behind a call, three times a
;   line, on a character the caller had usually just read.
; -----------------------------------------------------------------------

atend .macro
        tax
        lda     xapClass,x
        and     #XAP_CLASS_EOL
        .endm

; -----------------------------------------------------------------------
;   Steps the cursor over spaces and tabs, leaving the first character
;   that is neither in A.
;
;   Most calls have nothing to skip -- there is one run of indentation a
;   line and the rest of the calls sit between tokens that are usually
;   already touching. So the first character is tested inline and the
;   loop is only entered when there is really a space there.
; -----------------------------------------------------------------------

skipspace .macro
        lda     (xapSrc),y
        cmp     #' '
        beq     _sk\@
        cmp     #9
        bne     _skd\@
_sk\@   jsr     xapSkipSpace
_skd\@
        .endm

; -----------------------------------------------------------------------
;   Assembles the text at xapSrc to xapOut, starting at xapPC.
;
;   The window is whatever is already in memory and there is no more
;   behind it, which is what the host tests want: no KERNAL, no files,
;   and a result they can read straight out of memory.
; -----------------------------------------------------------------------

xapAssemble:
        lda     #<xapNoRefill
        sta     xapRefillVec
        lda     #>xapNoRefill
        sta     xapRefillVec+1
        lda     #<xapNoFlush
        sta     xapFlushVec
        lda     #>xapNoFlush
        sta     xapFlushVec+1

        stz     xapOutTop           ; a limit the output cannot reach
        stz     xapOutTop+1
        stz     xapObjError
        bra     xapRun

xapNoRefill:
        sec                         ; there was never any more
        rts
xapNoFlush:
        rts

; -----------------------------------------------------------------------
;   Assembles the file named at xapName into the file named at
;   xapObjName, starting at xapPC. CC on success, CS with an error in A.
; -----------------------------------------------------------------------

xapAssembleFile:
        jsr     xapOpenSource
        bcs     _xafExit

        jsr     xapOpenObject
        bcs     _xafNoObject

        lda     #<xapFileRefill
        sta     xapRefillVec
        lda     #>xapFileRefill
        sta     xapRefillVec+1
        lda     #<xapObjFlush
        sta     xapFlushVec
        lda     #>xapObjFlush
        sta     xapFlushVec+1

        lda     #<XAP_OBJBUF_END
        sta     xapOutTop
        lda     #>XAP_OBJBUF_END
        sta     xapOutTop+1

        ; Both files are closed whatever happens, so the outcome is put
        ; somewhere it will survive the closing rather than juggled on
        ; the stack around two more calls that can fail themselves.
        stz     xapRunError
        jsr     xapRun
        bcc     _xafRan
        sta     xapRunError
_xafRan:
        jsr     xapCloseObject
        bcc     _xafClosed
        ldx     xapRunError         ; a failed write only surfaces if the
        bne     _xafClosed          ; assembly itself was clean
        sta     xapRunError
_xafClosed:
        jsr     xapCloseSource

        lda     xapRunError
        bne     _xafFailed
        clc
        rts
_xafFailed:
        sec
        rts

_xafNoObject:
        pha
        jsr     xapCloseSource
        pla
        sec
_xafExit:
        rts

; -----------------------------------------------------------------------
;   The assembly loop itself, once the vectors are set.
; -----------------------------------------------------------------------

xapRun:
        jsr     xapLine
        bcs     _xrDone             ; stop at the first error

        ldy     #0
        lda     (xapSrc),y          ; more in the window?
        bne     xapRun

        jsr     xapRefill           ; ask for another windowful
        bcc     xapRun
        cmp     #0                  ; CS with a code is a real error
        bne     _xrDone

        lda     xapObjError         ; a write may have failed silently
        bne     _xrObjError
        lda     #XAP_OK
        clc
_xrDone:
        rts
_xrObjError:
        sec
        rts

xapRefill:
        lda     #0                  ; the plain end of input, not an error
        jmp     (xapRefillVec)

; -----------------------------------------------------------------------
;   Assembles one line, leaving xapSrc on the first character of the next.
;
;   Y is the cursor for the whole line and is folded back into xapSrc only
;   at the end, so scanning is an indexed read rather than a pointer
;   increment. A refill only ever happens between lines, so the window
;   cannot move under the cursor.
; -----------------------------------------------------------------------

; XAP_PROFILE stops the line after a given stage, so that building at 0..4
; and taking the differences attributes the cost by phase. Every stage still
; reads the whole file and walks every line, so what changes between two
; builds is one phase and nothing else. It is set by the build; 4 is the
; whole assembler and is what ships.

xapLine:
        ldy     #0
        .skipspace                  ; which leaves the character in A
        .atend                      ; a blank or comment-only line
        bne     xapEndLine

        .if XAP_PROFILE >= 1
        jsr     xapMnemonic         ; which instruction
        bcs     xapFail
        .endif
        .if XAP_PROFILE >= 2
        jsr     xapOperand          ; and what it is applied to
        bcs     xapFail
        .endif
        .if XAP_PROFILE >= 3
        jsr     xapSelect           ; the mode those two agree on
        bcs     xapFail
        .endif
        .if XAP_PROFILE >= 4
        jsr     xapEncode           ; bytes out
        bcs     xapFail

        .skipspace
        .atend                      ; nothing may follow the operand
        bne     xapEndLine
        lda     #XAP_ESYNTAX
        bra     xapFail
        .else
        bra     xapEndLine          ; a partial build stops here
        .endif

xapFail:
        sec
        rts

; -----------------------------------------------------------------------
;   Steps over the rest of the line, including its terminator, and folds
;   the cursor back into xapSrc.
; -----------------------------------------------------------------------

; Nearly a third of real source is comment text, and all of it comes
; through here one character at a time. Everything that ends a line -- the
; NUL, CR and LF -- is below space, and every character a comment is made
; of is not, so one compare passes over the body and the four-way test is
; only paid once at the end of it.
xapEndLine:
        lda     (xapSrc),y
        cmp     #' '
        bcc     _xelControl
        iny                         ; a comment body, or trailing space
        bra     xapEndLine

_xelControl:
        cmp     #0                  ; the compare above settled only that
        beq     _xelFold            ; this is below space
        cmp     #13
        beq     _xelEol
        cmp     #10
        beq     _xelEol
        iny                         ; a tab, or some other control byte
        bra     xapEndLine

_xelEol:
        iny                         ; over the terminator, and over the
        cmp     #13                 ; LF of a CR LF pair
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
        .include "file.asm"
        .include "isa.inc"
