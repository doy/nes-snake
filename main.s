; configuration {{{
.asciitable
MAP "-" = 1
MAP "|" = 2
MAP ":" = 3
MAP "." = 4
MAP "," = 5
MAP "'" = 6
.enda
.struct point
x db
y db
.endst
; }}}
; memory layout {{{
; rom {{{
.ROMBANKMAP
BANKSTOTAL  2
BANKSIZE    $4000
BANKS       1
BANKSIZE    $2000
BANKS       1
.ENDRO
; }}}
; ram {{{
.MEMORYMAP
DEFAULTSLOT  0
SLOTSIZE     $4000
SLOT 0       $C000
SLOTSIZE     $2000
SLOT 1       $0000 ; location doesn't matter, CHR data isn't in main memory
.ENDME

.ENUM $0000
buttons_pressed DB
sleeping        DB
game_state      DB ; 0: menu, 1: playing, 2: redrawing
head_x          DW
head_y          DW
length          DB
direction       DB ; 0: up, 1: down, 2: left, 3: right
frame_skip      DB
frame_count     DB
rand_state      DB
rand_out        DB
apple           INSTANCEOF point
vram_addr_low   DB
vram_addr_high  DB
body_test_x     DB
body_test_y     DB
.ENDE
; }}}
; }}}
; prg {{{
  .bank 0
  .org $0000
; main codepath {{{
; initialization {{{
; the ppu takes two frames to initialize, so we have some time to do whatever
; initialization of our own that we want to while we wait. we choose here to
; set up cpu flags in the first frame and clear out system ram in the second
; frame (clearing out ram isn't at all necessary, but we can't do anything
; useful at this point anyway, so we may as well in order to make things more
; predictable).
RESET:
  SEI              ; disable IRQs
  CLD              ; disable decimal mode
  LDX #$40
  STX $4017.w      ; disable APU frame IRQ
  LDX #$FF
  TXS              ; Set up stack (grows down from $FF to $00, at $0100-$01FF)
  INX              ; now X = 0
  STX $2000.w      ; disable NMI (we'll enable it later once the ppu is ready)
  STX $2001.w      ; disable rendering (same)
  STX $4010.w      ; disable DMC IRQs

  ; First wait for vblank to make sure PPU is ready
- BIT $2002        ; bit 7 of $2002 is reset once vblank ends
  BPL -            ; and bit 7 is what is checked by BPL

  ; set everything in ram ($0000-$07FF) to $00, except for $0200-$02FF which
  ; is conventionally used to hold sprite attribute data. we set that range
  ; to $FE, since that value as a position moves the sprites offscreen, and
  ; when the sprites are offscreen, it doesn't matter which sprites are
  ; selected or what their attributes are
clrmem:
  LDA #$00
  STA $0000, x
  STA $0100, x
  STA $0500, x
  STA $0600, x
  STA $0700, x
  LDA #$FE
  STA $0200, x
  LDA #$80
  STA $0300, x
  LDA #$7D
  STA $0400, x
  INX
  BNE clrmem

  ; initialize variables in ram
  LDA #$03
  LDX #$01
  STA head_x, x
  LDA #$04
  LDX #$01
  STA head_y, x
  LDA #20
  STA frame_skip

  LDA #$07
  STA $0201
  LDA #$00
  STA $0202

  ; Second wait for vblank, PPU is ready after this
- BIT $2002
  BPL -

  ; now that the ppu is ready, we can start initializing it
LoadPalettes:
  LDA $2002    ; read PPU status to reset the high/low latch
  LDA #$3F
  STA $2006    ; write the high byte of $3F00 address
  LDA #$00
  STA $2006    ; write the low byte of $3F00 address
  LDX #$00
LoadPalettesLoop:
  LDA palette.w, x      ;load palette byte
  STA $2007             ;write to PPU
  INX                   ;set index to next byte
  CPX #$20
  BNE LoadPalettesLoop  ;if x = $20, 32 bytes copied, all done

  LDA #%10000000   ; enable NMI interrupts
  STA $2000

  JSR end_game
; }}}
; main loop {{{
loop:
  INC sleeping
- LDA sleeping
  BNE -

  JSR read_controller1

  LDA game_state
  BNE +
  JSR start_screen_loop
  JMP loop
+ JSR game_loop
  JMP loop
; }}}
; }}}
; nmi interrupt {{{
NMI:
  PHA
  TXA
  PHA
  TYA
  PHA

  LDA game_state
  BEQ do_dma_jmp
  CMP #$01
  BEQ draw_game
  JMP end_nmi
do_dma_jmp:
  JMP do_dma

draw_game:
  LDX #$00
  JSR draw_sprite_at_head
  LDA head_x
  SEC
  SBC length
  STA head_x
  LDA head_y
  SEC
  SBC length
  STA head_y
  LDX #$20
  JSR draw_sprite_at_head
  LDA head_x
  CLC
  ADC length
  STA head_x
  LDA head_y
  CLC
  ADC length
  STA head_y

  LDA #$20
  STA $2006
  LDA #$00
  STA $2006

  JMP do_dma

do_dma:
  LDA #$00
  STA $2003
  LDA #$02
  STA $4014

end_nmi:
  LDA #$00
  STA sleeping

  PLA
  TAY
  PLA
  TAX
  PLA
  RTI
; }}}
; subroutines {{{
start_screen_loop: ; {{{
  LDX rand_state
- INX
  BEQ - ; lfsr prngs have 0 as a fixed point
  STX rand_state

handle_start:
  LDA buttons_pressed
  AND #%00010000
  CMP #$00
  BEQ end_start_screen_loop
  JSR start_game

end_start_screen_loop:
  RTS ; }}}
game_loop: ; {{{
handle_up:
  LDA buttons_pressed
  AND #%00001000
  CMP #$00
  BEQ handle_down
  LDA #$00
  STA direction

handle_down:
  LDA buttons_pressed
  AND #%00000100
  CMP #$00
  BEQ handle_left
  LDA #$01
  STA direction

handle_left:
  LDA buttons_pressed
  AND #%00000010
  CMP #$00
  BEQ handle_right
  LDA #$02
  STA direction

handle_right:
  LDA buttons_pressed
  AND #%00000001
  CMP #$00
  BEQ handle_frame
  LDA #$03
  STA direction

handle_frame:
  LDX frame_count
  INX
  STX frame_count
  CPX frame_skip
  BPL +
  JMP end_game_loop

+ LDA #$00
  STA frame_count

set_offset:
  LDX #$F8             ; i.e., -8
  LDA direction
  AND #%00000001       ; low bit determines negative or positive
  BEQ set_axis
  LDX #$08

set_axis:
  LDY #$00
  LDA direction
  AND #%00000010       ; high bit determines which axis to change
  BNE apply_direction_horiz

apply_direction_vert:
  TXA
  CLC
  ADC (head_y), y
  INC head_y
  STA (head_y), y
  LDA (head_x), y
  INC head_x
  STA (head_x), y
  JMP check_collisions

apply_direction_horiz:
  TXA
  CLC
  ADC (head_x), y
  INC head_x
  STA (head_x), y
  LDA (head_y), y
  INC head_y
  STA (head_y), y

check_collisions
  LDA (head_x), y
  TAX
  LDA (head_y), y
  TAY

  CPX #$40
  BCC collision
  CPX #$C0
  BCS collision

  CPY #$3D
  BCC collision
  CPY #$BD
  BCS collision

  STX body_test_x
  STY body_test_y
  DEC head_x
  DEC head_y
  JSR test_body_collision
  INC head_x
  INC head_y
  LDX body_test_x
  LDY body_test_y
  CMP #$01
  BEQ collision

  CPX apple.x
  BEQ maybe_eat_apple

  JMP end_game_loop

collision:
  JSR end_game

  JMP end_game_loop

maybe_eat_apple:
  CPY apple.y
  BEQ eat_apple

  JMP end_game_loop

eat_apple:
  LDX length
  INX
  TXA
  BEQ collision ; for now - this is the win condition
  STX length
  AND #$07
  BNE +
  LDX length
  LDA speed.w, x
  STA frame_skip
+ JSR new_apple

end_game_loop:
  RTS ; }}}
read_controller1: ; {{{
  ; latch
  LDA #$01
  STA $4016
  LDA #$00
  STA $4016

  ; clock
  LDX #$00
read_controller1_values:
  CPX #$08
  BPL end_read_controller1

  LDA $4016
  AND #%00000001
  ASL buttons_pressed
  ORA buttons_pressed
  STA buttons_pressed
  INX
  JMP read_controller1_values

end_read_controller1:
  RTS ; }}}
start_game: ; {{{
  LDA #$02
  STA game_state

  LDY #$00
  LDA #$80
  STA (head_x), y
  LDA #$7D
  STA (head_y), y

  LDA #$01
  STA length
  LDA #$00
  STA direction

  JSR new_apple

- BIT $2002
  BPL -

  LDA #%00000000
  STA $2001 ; disable rendering (since this will take longer than vblank)

  LDA #$20
  STA $2006
  LDA #$00
  STA $2006

  LDA #$20
  LDY #$07
-- LDX #$00
- STA $2007
  INX
  CPX #$20
  BNE -
  DEY
  BNE --

  LDX #$00
- LDA game_background_top.w, x
  STA $2007
  INX
  CPX #$20
  BNE -

  LDY #$10
-- LDX #$00
- LDA game_background_middle.w, x
  STA $2007
  INX
  CPX #$20
  BNE -
  DEY
  BNE --

  LDX #$00
- LDA game_background_bottom.w, x
  STA $2007
  INX
  CPX #$20
  BNE -

  LDA #$20
  LDX #$00
- STA $2007
  INX
  CPX #$20
  BNE -

  LDA #%00011000
  STA $2001 ; reenable rendering

  LDA #$01
  STA game_state
  RTS ; }}}
end_game: ; {{{
  LDA #$02
  STA game_state

  LDA #$FE
  STA $0200
  STA $0203

- BIT $2002
  BPL -

  LDA #%00000000
  STA $2001 ; disable rendering (since this will take longer than vblank)

  LDA #$20
  STA $2006
  LDA #$00
  STA $2006

  LDA #$20
  LDX #$0F
-- LDY #$00
- STA $2007
  INY
  CPY #$20
  BNE -
  DEX
  BNE --

  LDY #$00
- LDA intro_screen, y
  STA $2007
  INY
  CPY #$20
  BNE -

  LDA #$20
  LDX #$0E
-- LDY #$00
- STA $2007
  INY
  CPY #$20
  BNE -
  DEX
  BNE --

  LDA #%00011000
  STA $2001 ; reenable rendering

  LDA #$00
  STA game_state
  RTS ; }}}
new_apple: ; {{{
  JSR rand4
  LDA rand_out
  ASL
  ASL
  ASL
  CLC
  ADC #$40
  STA apple.x
  JSR rand4
  LDA rand_out
  ASL
  ASL
  ASL
  CLC
  ADC #$3D
  STA apple.y

  LDA apple.x
  STA body_test_x
  LDA apple.y
  STA body_test_y
  JSR test_body_collision
  CMP #$01
  BEQ new_apple

  LDA apple.y
  STA $0200
  LDA apple.x
  STA $0203

  RTS ; }}}
draw_sprite_at_head: ; {{{
  LDA #$20
  STA vram_addr_high
  LDA #$E0
  STA vram_addr_low

  LDY #$00
  LDA (head_y), y
  SEC
  SBC #$35
  LSR
  LSR
  LSR
  TAY
- CLC
  LDA vram_addr_low
  ADC #$20
  STA vram_addr_low
  LDA vram_addr_high
  ADC #$00
  STA vram_addr_high
  DEY
  BNE -

  LDY #$00
  LDA (head_x), y
  SEC
  SBC #$40
  LSR
  LSR
  LSR
  CLC
  ADC #$08
  ADC vram_addr_low
  STA vram_addr_low
  LDA vram_addr_high
  ADC #$00
  STA vram_addr_high

  LDA vram_addr_high
  STA $2006
  LDA vram_addr_low
  STA $2006

  TXA
  STA $2007

  RTS ; }}}
test_body_collision ; {{{
  LDA head_x
  PHA
  LDA head_y
  PHA

  LDA head_x
  SEC
  SBC length
  TAX
  INX
  TXA
  STA head_x

  LDA head_y
  SEC
  SBC length
  TAX
  INX
  TXA
  STA head_y

  LDY length

- DEY
  LDA (head_x), y
  CMP body_test_x
  BEQ maybe_collision_found
  CPY #$00
  BNE -
  JMP collision_not_found

maybe_collision_found:
  LDA (head_y), y
  CMP body_test_y
  BEQ collision_found
  CPY #$00
  BNE -
  JMP collision_not_found

collision_found:
  LDX #$01
  JMP test_body_collision_end
collision_not_found:
  LDX #$00

test_body_collision_end:
  PLA
  STA head_y
  PLA
  STA head_x
  TXA
  RTS ; }}}
rand4: ; {{{
  JSR rand1
  LDX rand_out
  JSR rand1
  TXA
  ASL
  ORA rand_out
  TAX
  JSR rand1
  TXA
  ASL
  ORA rand_out
  TAX
  JSR rand1
  TXA
  ASL
  ORA rand_out
  STA rand_out
  RTS ; }}}
rand1: ; {{{
  ; galois linear feedback shift register with taps at 8, 6, 5, and 4
  LDA rand_state
  AND #$01
  STA rand_out
  LSR rand_state
  LDA rand_out
  BEQ +
  LDA rand_state
  EOR #%10111000
  STA rand_state
+ RTS ; }}}
; }}}
; data {{{
palette: ; {{{
  .db $0F,$31,$32,$33,$0F,$35,$36,$37,$0F,$39,$3A,$3B,$0F,$3D,$3E,$0F
  .db $0F,$1C,$15,$14,$0F,$02,$38,$3C,$0F,$1C,$15,$14,$0F,$02,$38,$3C
; }}}
intro_screen: ; {{{
  .asc "           SNAKE                "
; }}}
game_background_top: ; {{{
  .asc "       ,----------------.       "
; }}}
game_background_middle: ; {{{
  .asc "       |                |       "
; }}}
game_background_bottom: ; {{{
  .asc "       '----------------:       "
; }}}
speed: ; {{{
  .db 20,20,20,19,19,19,19,19,19,19,18,18,18,18,18,18,18,17,17,17,17,17,17,17,
  .db 17,16,16,16,16,16,16,16,16,16,15,15,15,15,15,15,15,15,15,14,14,14,14,14,
  .db 14,14,14,14,13,13,13,13,13,13,13,13,13,13,13,12,12,12,12,12,12,12,12,12,
  .db 12,12,11,11,11,11,11,11,11,11,11,11,11,11,10,10,10,10,10,10,10,10,10,10,
  .db 10,10,10,10,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,
  .db 8,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,
  .db 6,6,6,6,6,6,6,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,4,4,
  .db 4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,3,3,3,3,
  .db 3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3
; }}}
; }}}
  .orga $FFFA    ;first of the three vectors starts here
; interrupt vectors {{{
  .dw NMI        ;when an NMI happens (once per frame if enabled) the 
                   ;processor will jump to the label NMI:
  .dw RESET      ;when the processor first turns on or is reset, it will jump
                   ;to the label RESET:
  .dw 0          ;external interrupt IRQ is not used in this tutorial
; }}}
; }}}
; chr {{{
  .bank 1 slot 1
  .org $0000
  .incbin "sprites.chr"
; }}}
