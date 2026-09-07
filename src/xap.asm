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

; The name of the label being read, upper cased. One byte past the source
; window, which keeps the terminator, and clear of the hash table below.
XAP_LABEL       = XAP_BUFFER_END + 1
XAP_LABEL_MAX   = 31

; One bucket head per byte of hash, so the hash needs no masking.
XAP_SYMHASH     = $3100
XAP_FIXHEAP     = $3300
XAP_FIXHEAP_END = $4000             ; 3.25K, or 665 forward references

; The symbol heap goes below everything else because it is the part that
; wants the most room: eight bytes and a name each. A ROM-resident xap
; would put all of this in banked RAM, where there is as much as anyone
; needs; this flat map is what the tests run against.
XAP_SYMHEAP     = $0800
XAP_SYMHEAP_END = $2000             ; 6K, or about 460 labels

; The object image. Fixups write back into code already emitted, which a
; file that has been flushed cannot do -- so the object is built in
; memory and written out at the end. That is not giving up the streaming
; property: object code for this processor is bounded by the address
; space and source is not, so streaming the thing that can be a megabyte
; and buffering the thing that cannot exceed 64K is the right way round.
XAP_IMAGE       = $4000
XAP_IMAGE_END   = $9E00             ; 23.5K, up to where the KERNAL starts

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
xapSym        = XAP_ZP+49           ; the symbol record in hand
xapSymTop     = XAP_ZP+51           ; next free byte of the symbol heap
xapFixTop     = XAP_ZP+53           ; next free byte of the fixup heap
xapFix        = XAP_ZP+55           ; the fixup record in hand
xapLabelLen   = XAP_ZP+57
xapUndefined  = XAP_ZP+58           ; how many labels are still not defined
xapOrigin     = XAP_ZP+60           ; the program counter the image starts at
xapImage      = XAP_ZP+62           ; where in memory that byte lives
xapForward    = XAP_ZP+64           ; the operand named a label not yet known
xapHole       = XAP_ZP+65           ; the address a fixup has to fill
xapLabelPos   = XAP_ZP+67           ; the cursor, held across a lookup
xapPending    = XAP_ZP+68           ; operands whose size is not settled yet
xapWideOp     = XAP_ZP+70           ; the opcode to swap in if one widens
xapNarrow     = XAP_ZP+71           ; this operand was emitted optimistically
xapWalk       = XAP_ZP+72           ; walks the symbol heap end to end
xapFixFree    = XAP_ZP+75           ; retired fixup records, for reuse
xapDeferred   = XAP_ZP+74           ; a size was guessed, so nothing is filled
                                    ; in until the whole file has been read

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
XAP_EMEMORY   = $0D         ; out of room
XAP_EMNEMONIC = $20         ; not an instruction
XAP_EBIT      = $21         ; bit number missing, or not 0-7
XAP_EVALUE    = $22         ; value does not fit the only mode available
XAP_EUNDEF    = $23         ; a label was used and never defined
XAP_EREDEF    = $24         ; a label was defined twice
XAP_ELABEL    = $25         ; label name missing or too long

; -----------------------------------------------------------------------
;   Z clear when the character in A ends the line: the end of the window,
;   a newline, or a comment. Leaves the character in X, so a caller that
;   wants it back does not read it again.
;
;   A macro because it was four compares behind a call, three times a
;   line, on a character the caller had usually just read.
; -----------------------------------------------------------------------

; -----------------------------------------------------------------------
;   Z clear when the character in A could continue an identifier: a letter
;   or a digit. Leaves it in X as well.
;
;   A macro because it is two loads behind a call, and the call is most of
;   the cost -- it runs once for every mnemonic read and twice for every
;   index register.
; -----------------------------------------------------------------------

isident .macro
        tax
        lda     xapClass,x
        and     #XAP_CLASS_IDENT
        .endm

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
        jsr     xapBegin
        bra     xapRun

; -----------------------------------------------------------------------
;   Common to both entry points: remember where the image starts and what
;   address its first byte has, so a fixup can turn one into the other,
;   and throw away any labels from a previous run.
; -----------------------------------------------------------------------

xapBegin:
        lda     xapOut
        sta     xapImage
        lda     xapOut+1
        sta     xapImage+1
        lda     xapPC
        sta     xapOrigin
        lda     xapPC+1
        sta     xapOrigin+1
        stz     xapForward
        jmp     xapSymReset

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
        lda     #<xapObjOverflow
        sta     xapFlushVec
        lda     #>xapObjOverflow
        sta     xapFlushVec+1

        jsr     xapBegin

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
        lda     xapDeferred         ; holes left open while sizes moved
        beq     _xrFilled
        jsr     xapResolveAll
        bcs     _xrDone
_xrFilled:
        lda     xapUndefined        ; and nothing may still be waiting
        ora     xapUndefined+1
        bne     _xrUndefined
        lda     #XAP_OK
        clc
_xrDone:
        rts
_xrObjError:
        sec
        rts
_xrUndefined:
        lda     #XAP_EUNDEF
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
        ; A label is an unknown mnemonic, or a word ending in a colon.
        ; So try it as an instruction first and read a name if that fails,
        ; which settles the column-one rule without a special case for it.
        phy
        jsr     xapMnemonic
        bcs     _xlNotMnemonic
        pla                         ; it was an instruction after all
        bra     _xlOperand

_xlNotMnemonic:
        ; Only "that is not an instruction" means it might be a label.
        ; RMB8 is an instruction with a bad bit number, and saying so is
        ; more use than calling it a label and tripping over the operand.
        cmp     #XAP_EMNEMONIC
        beq     _xlLabel
        ply
        sec
        rts

_xlLabel:
        ply
        .if XAP_PROFILE >= 2
        ; Defining it is its own phase, because on a file that is mostly
        ; labels it is most of the work, and charging it to the mnemonic
        ; lookup that failed to recognise it says nothing useful.
        jsr     xapLabelHere
        bcs     xapFail
        .skipspace
        .atend                      ; a label on a line of its own
        bne     xapEndLine
        jsr     xapMnemonic
        bcs     xapFail
        .else
        bra     xapEndLine
        .endif
_xlOperand:
        .endif
        .if XAP_PROFILE >= 3
        jsr     xapOperand          ; and what it is applied to
        bcs     xapFail
        .endif
        .if XAP_PROFILE >= 4
        jsr     xapSelect           ; the mode those two agree on
        bcs     xapFail
        .endif
        .if XAP_PROFILE >= 5
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

        .include "symbol.asm"
        .include "lex.asm"
        .include "mode.asm"
        .include "encode.asm"
        .include "file.asm"
        .include "isa.inc"
