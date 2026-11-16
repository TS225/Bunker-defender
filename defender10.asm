; ============================================================
;  BUNKER DEFENDER  -  air defense gun game for the C64
;  Commodore 64 / MOS 6510 - ACME assembler
;  Only documented 6502/6510 opcodes are used.
;
;  Assemble:  acme -f cbm -o defender.prg defender.asm
;  Run:       LOAD"DEFENDER.PRG",8,1  then  RUN
;
;  Controls (choose J = joystick port 2 or K = keyboard on the start menu):
;        keyboard: I J K L or CURSOR KEYS aim, S fires
;        joystick: stick aims, button fires (S also fires)
;        A = copyright notice
;  Graphics: 320x200 hires bitmap (VIC bank 1), single-pixel artwork,
;  text is drawn with the ROM character shapes copied to RAM.
;  You sit in a bunker and look out through the slit window.
;  Targets approach from the horizon and grow bigger (pseudo 3D).
;  The reticle has an UPPER line (aim for near targets) and a LOWER
;  line (aim for far targets): bullets drop with distance, so far
;  targets must be aimed higher (put the lower line on them).
;  Each target needs 3 hits. Every 3 destroyed targets the next
;  target flies 2x faster. The bunker survives 3 hits.
;  From level 3 up there is one more enemy aircraft in the air at
;  every level (up to 5). Level 3 also upgrades the gun: it fires two
;  rounds at once and the tube cools twice as fast.
;  Title screen: M = mission objectives, T = music on/off,
;  J / K = joystick or keyboard.
;  60 rounds at start, +5 rounds per hit. Out of ammo = game over.
;  Hit bonus score = 2 x level (on top of 10 points per hit).
;  Every level up repairs the bunker: +3 armor, +1 armor from level 4 on.
;  Music (SID, interrupt driven): filtered growling bass, quiet vibrato
;  lead and a kick drum. Toggle with T on the start screen.
;  The gun tube heats up with every shot (20..500 C) and cools down
;  slowly. At 500 C it is overheated: shots land a tenth of the
;  screen away from the aim point (32 px x, 20 px y) until it has
;  cooled below 450 C.
; ============================================================
!cpu 6510

; ---- zero page ---------------------------------------------
sp      = $fb           ; screen pointer
cp      = $fd           ; colour pointer
tp      = $f7           ; text pointer
gp      = $f9           ; glyph / source pointer

GETIN   = $ffe4
CHROUT  = $ffd2
BITMAP  = $6000         ; hires bitmap (VIC bank 1)
SCRRAM  = $5c00         ; colour attributes (fg<<4 | bg)
FONT    = $5400         ; character shapes copied from the ROM
BGBMP   = $3000         ; pristine background bitmap
BGCOL   = $5000         ; pristine background colours
SPTR    = $5ff8         ; sprite pointers (screen RAM + $3f8)
SPRBLK  = $60           ; sprite data lives at $5800 (= block $60)
NSTEP   = 24            ; path length of a target (steps)
OFFX    = 52            ; game x = sprite x (centre) - 52
AXMIN   = 14            ; aim limits (reticle centre, game x)
AXMAX   = 248
AYMIN   = 88
AYMAX   = 150
AIMSP   = 3             ; aim speed (pixels per frame)
AMMO0   = 60            ; starting ammo
AMMOBON = 5             ; ammo bonus per hit
BUNKHP  = 3             ; hits the bunker can take
LVLARMOR = 3            ; armor gained at level up (levels 2 and 3)
LVLARMOR2 = 1           ; armor gained at level up from level 4 on
SCATX   = 32            ; overheat: shot error, a tenth of the screen width
SCATY   = 20            ; overheat: shot error, a tenth of the screen height
SPEEDF  = 6             ; music: frames per 16th note (125 bpm)
HITSCORE = $12          ; start value of score per hit (BCD): 10 + 2*level
HEATSHOT = 25           ; tube heating per shot (C)
FIRECD  = 6             ; gun cooldown in frames
ST_IDLE = 0
ST_FLY  = 1
ST_EXP  = 2
ST_OVER = 3
NTMAX   = 5             ; maximum aircraft in the air

; ---- BASIC stub: 10 SYS 2061 --------------------------------
* = $0801
        !byte $0b,$08,$0a,$00,$9e,$32,$30,$36,$31,$00,$00,$00

; ============================================================
;  MAIN
; ============================================================
start:
        jsr initall
        jsr showtitle
newgame:
        jsr initgame
        lda #<redrawgame
        sta redrawv
        lda #>redrawgame
        sta redrawv+1
        jsr redrawgame
mainloop:
        jsr waitframe
        jsr scanaim
        jsr readkey
        jsr update
        jsr placereticle
        lda gover
        beq @c
        jmp gameover
@c      lda dirty
        beq @t
        lda #0
        sta dirty
        jsr drawhud
@t      lda tdirty
        beq @n
        lda #0
        sta tdirty
        jsr drawtemp
@n      jmp mainloop

waitframe:                      ; sync to raster line 250
@a      lda $d012
        cmp #250
        bcc @a
@b      lda $d012
        cmp #250
        bcs @b
        rts

readkey:
        jsr GETIN
        cmp #0
        beq @r
        cmp #$53                ; S
        bne @a
        jmp fire
@a      cmp #$41                ; A
        bne @m
        jmp copyright
@m      cmp #$4d                ; M
        bne @r
        jmp togglemusic
@r      rts

; ============================================================
;  GAME STATE
; ============================================================
initgame:
        lda #0
        sta score0
        sta score1
        sta score2
        sta kills
        sta k3
        sta cooldown
        sta flash
        sta msgt
        sta bph
        sta hits
        sta hitcnt
        sta goreason
        sta hot
        sta coolc
        sta temphi
        sta $d017
        sta $d01d
        lda #1
        sta level
        sta smult
        sta dirty
        lda #12                 ; speed = 12 (steps/256 per frame)
        sta spdlo
        lda #0
        sta spdhi
        lda #$50                ; kill bonus (BCD) = 50 * level
        sta bonlo
        lda #0
        sta bonhi
        lda #AMMO0
        sta ammo
        lda #20                 ; gun tube starts at 20 C
        sta templo
        lda #HITSCORE
        sta hitscore
        lda #1
        sta tdirty
        lda #BUNKHP
        sta bunkhp
        lda #132                ; reticle start position (window centre)
        sta ax
        lda #120
        sta ay
        lda #0
        sta gover
        sta shf
        jsr setntarg
        ldx #4
@ia     lda #ST_IDLE
        sta tstate,x
        lda tinit,x
        sta ttimer,x
        lda #0
        sta thits,x
        sta tprl,x
        sta tprh,x
        sta tstepv,x
        sta ttcx,x
        sta ttcy,x
        dex
        bpl @ia
        lda #4                  ; only the reticle sprite is on
        sta $d015
        lda #ST_IDLE
        sta state
        lda #60
        sta timer
        rts

update:
        lda cooldown
        beq @c1
        dec cooldown
@c1     lda flash
        beq @c2
        dec flash
        bne @c2
        jsr clrflash
@c2     lda msgt
        beq @c3
        dec msgt
        bne @c3
        jsr clrmsg
@c3     jsr movebullet
        jsr shakeupdate
        jsr shellupdate
        jsr heatcool
        lda #0
        sta ti
@t      jsr loadt
        jsr tgtupdate
        jsr savet
        inc ti
        lda ti
        cmp ntarg
        bcc @t
        rts

tgtupdate:                      ; one aircraft (loaded into the work variables)
        lda state
        cmp #ST_FLY
        beq @fly
        cmp #ST_EXP
        beq @exp
        lda timer
        beq @sp
        dec timer
        rts
@sp     jmp spawn
@fly    jmp flyupdate
@exp    jmp expupdate

loadt:                          ; aircraft ti -> work variables
        ldx ti
        lda tstate,x
        sta state
        lda ttimer,x
        sta timer
        lda thits,x
        sta hits
        lda tprl,x
        sta prog
        lda tprh,x
        sta prog+1
        lda tstepv,x
        sta step
        lda ttcx,x
        sta tcx
        lda ttcy,x
        sta tcy
        lda tsn2,x
        sta sn2
        lda tbit,x
        sta sbit
        lda tsn,x
        sta snum
        lda pbtab,x
        sta pbase
        rts

savet:                          ; work variables -> aircraft ti
        ldx ti
        lda state
        sta tstate,x
        lda timer
        sta ttimer,x
        lda hits
        sta thits,x
        lda prog
        sta tprl,x
        lda prog+1
        sta tprh,x
        lda step
        sta tstepv,x
        lda tcx
        sta ttcx,x
        lda tcy
        sta ttcy,x
        rts

setntarg:                       ; aircraft in the air = level-1 (1..5)
        lda level
        sec
        sbc #1
        bne @a
        lda #1
@a      cmp #(NTMAX+1)
        bcc @b
        lda #NTMAX
@b      sta ntarg
        rts

spawn:                          ; new target: build its flight path
        lda $dc04
        eor $d012
        and #7
        sta pidx
        tax
        lda startx,x
        sta xh
        lda #$80
        sta xl
        lda pbase
        sta pz
        lda #0
        sta pcnt
@l      ldy pz
        lda xh
        sta tpath,y
        ldx pidx
        lda xl
        clc
        adc dlo,x
        sta xl
        lda xh
        adc dhi,x
        sta xh
        inc pz
        inc pcnt
        lda pcnt
        cmp #NSTEP
        bne @l
        lda #3
        sta hits
        lda #0
        sta prog
        sta prog+1
        sta step
        lda #ST_FLY
        sta state
        jsr placesprite
        lda $d015
        ora sbit
        sta $d015
        lda #1
        sta dirty
        rts

flyupdate:
        lda prog
        clc
        adc spdlo
        sta prog
        lda prog+1
        adc spdhi
        sta prog+1
        cmp #NSTEP
        bcc @ok
        dec bunkhp              ; target reached the bunker
        lda #ST_EXP
        sta state
        lda #28
        sta timer
        ldx snum
        lda #7
        sta $d027,x
        jsr sndbig
        lda #2
        jsr setflash
        lda #24
        sta shkc
        lda #8
        sta flash
        lda #1
        sta dirty
        lda #<sBunk
        ldx #>sBunk
        jsr smsg
        lda bunkhp
        jmp pr2
@ok     sta step
        jmp placesprite

expupdate:
        lda timer
        beq @done
        dec timer
        lsr
        lsr
        and #1
        clc
        adc #(SPRBLK+4)
        ldx snum
        sta SPTR,x
        lda sbit                ; explosion shapes are single colour
        eor #$ff
        sta tmp2
        lda $d01c
        and tmp2
        sta $d01c
        rts
@done   lda sbit
        eor #$ff
        sta tmp2
        lda $d015
        and tmp2
        sta $d015
        lda bunkhp
        bne @alive
        lda #1                  ; bunker destroyed
        sta gover
@alive  lda #ST_IDLE
        sta state
        lda #45
        sta timer
        rts

placesprite:                    ; pseudo 3D: size/position from step
        lda step
        lsr
        lsr
        tax                     ; size stage 0..5
        lda stgfrm,x
        clc
        adc #SPRBLK
        ldy snum
        sta SPTR,y
        lda sbit
        eor #$ff
        sta tmp2
        lda stgexp,x
        beq @nex
        lda $d017
        ora sbit
        sta $d017
        lda $d01d
        ora sbit
        sta $d01d
        jmp @ex
@nex    lda $d017
        and tmp2
        sta $d017
        lda $d01d
        and tmp2
        sta $d01d
@ex     lda stghx,x
        sta hx
        lda stghy,x
        sta hy
        lda step                ; centre y = 160 - step*5/2
        asl
        asl
        clc
        adc step
        lsr
        sta tmp
        lda #160
        sec
        sbc tmp
        sta tcy
        sec
        sbc hy
        ldx sn2
        sta $d001,x
        lda step
        clc
        adc pbase
        tay
        lda tpath,y
        sta tcx
        sta spgx
        lda hx
        sta sphw
        lda snum
        sta spn
        jsr setsprx
        ldx hits
        lda hitcol,x
        ldy snum
        sta $d027,y
        lda $d01c               ; aircraft are multicolour sprites
        ora sbit
        sta $d01c
        rts

setsprx:                        ; game x (spgx) -> sprite x register + bit 8
        lda spgx
        clc
        adc #OFFX
        sta spt
        lda #0
        adc #0
        sta sph
        lda spt
        sec
        sbc sphw
        sta spt
        lda sph
        sbc #0
        sta sph
        lda spn
        asl
        tax
        lda spt
        sta $d000,x
        ldx spn
        lda bittab,x
        ldy sph
        beq @c
        ora $d010
        sta $d010
        rts
@c      eor #$ff
        and $d010
        sta $d010
        rts

; ---------------- aiming & firing ---------------------
scanaim:                        ; keyboard matrix or joystick port 2
        lda ctl
        beq @kb
        jmp joyscan
@kb     sei
        lda #$fe
        sta $dc00
        lda $dc01
        sta kb0
        lda #$fd
        sta $dc00
        lda $dc01
        sta kb1
        lda #$ef
        sta $dc00
        lda $dc01
        sta kb4
        lda #$df
        sta $dc00
        lda $dc01
        sta kb5
        lda #$bf
        sta $dc00
        lda $dc01
        sta kb6
        lda #$ff
        sta $dc00
        cli
        lda kb5                 ; L = right
        and #$04
        bne @n1
        jsr aimright
@n1     lda kb4                 ; J = left
        and #$04
        bne @n2
        jsr aimleft
@n2     lda kb4                 ; I = up
        and #$02
        bne @n3
        jsr aimup
@n3     lda kb4                 ; K = down
        and #$20
        bne @n4
        jsr aimdown
@n4     lda kb0                 ; cursor left/right
        and #$04
        bne @n5
        lda kb1
        and #$80
        beq @sl
        lda kb6
        and #$10
        beq @sl
        jsr aimright
        jmp @n5
@sl     jsr aimleft
@n5     lda kb0                 ; cursor up/down
        and #$80
        bne @n6
        lda kb1
        and #$80
        beq @su
        lda kb6
        and #$10
        beq @su
        jsr aimdown
        jmp @n6
@su     jsr aimup
@n6     rts

joyscan:                        ; joystick in port 2 (bits are 0 = pressed)
        sei
        lda #$ff
        sta $dc00
        lda $dc00
        sta kb0
        cli
        lda kb0
        and #$04
        bne @j1
        jsr aimleft
@j1     lda kb0
        and #$08
        bne @j2
        jsr aimright
@j2     lda kb0
        and #$01
        bne @j3
        jsr aimup
@j3     lda kb0
        and #$02
        bne @j4
        jsr aimdown
@j4     lda kb0
        and #$10
        bne @j5
        jsr fire
@j5     rts

aimright:
        lda ax
        clc
        adc #AIMSP
        cmp #(AXMAX+1)
        bcc @ok
        lda #AXMAX
@ok     sta ax
        rts

aimleft:
        lda ax
        sec
        sbc #AIMSP
        cmp #AXMIN
        bcs @ok
        lda #AXMIN
@ok     sta ax
        rts

aimup:
        lda ay
        sec
        sbc #AIMSP
        cmp #AYMIN
        bcs @ok
        lda #AYMIN
@ok     sta ay
        rts

aimdown:
        lda ay
        clc
        adc #AIMSP
        cmp #(AYMAX+1)
        bcc @ok
        lda #AYMAX
@ok     sta ay
        rts

placereticle:
        lda ax
        sta spgx
        lda #12
        sta sphw
        lda #2
        sta spn
        jsr setsprx
        lda ay
        sec
        sbc #3
        sta $d005
        rts

fire:
        lda cooldown
        beq @go
        rts
@go     lda ammo
        bne @have
        rts
@have   dec ammo
        lda #FIRECD
        sta cooldown
        jsr sndshot
        lda #1                  ; muzzle flash
        jsr setflash
        lda #2
        sta flash
        lda #1
        sta dirty
        lda #0                  ; overheated tube: shots go a tenth of
        sta sdx                 ; the screen away (32 px x, 20 px y)
        sta sdy
        lda hot
        beq @nh
        lda ax
        cmp #132
        bcs @lx
        lda #SCATX
        bne @sx
@lx     lda #(256-SCATX)
@sx     sta sdx
        lda ay
        cmp #119
        bcs @ly
        lda #SCATY
        bne @sy
@ly     lda #(256-SCATY)
@sy     sta sdy
@nh     lda #1                  ; level 3 upgrade: two rounds at once
        sta nrnd
        lda level
        cmp #3
        bcc @r1
        lda #2
        sta nrnd
@r1     lda #0
        sta rr
@rl     jsr oneround
        inc rr
        lda rr
        cmp nrnd
        bcc @rl
        lda #1
        sta bph
        lda #(SPRBLK+6)         ; one tracer, or the twin tracer
        ldx nrnd
        cpx #2
        bcc @sb
        lda #(SPRBLK+8)
@sb     sta SPTR+1
        lda $d015
        ora #2
        sta $d015
        jsr shellstart
        jsr addheat
        lda ammo
        bne @r
        lda #1                  ; out of ammo
        sta goreason
        sta gover
@r      rts

oneround:                       ; one bullet: aim, hit test, tracer
        lda nrnd
        cmp #1
        bne @tw
        lda #0
        beq @ss
@tw     ldx rr
        lda sprd,x
@ss     sta spread
        lda ax
        clc
        adc sdx
        clc
        adc spread
        sta ix
        lda #0
        sta refset
        sta refdrop
        sta hfound
        sta ti
@tl     jsr loadt
        jsr testtgt
        bcc @tn
        lda #1
        sta hfound
        lda iy
        sta hity
        jsr hit
        jsr savet
@tn     inc ti
        lda ti
        cmp ntarg
        bcc @tl
        lda hfound
        bne @hv
        lda ay
        clc
        adc sdy
        clc
        adc refdrop
        sta hity
@hv     lda hity
        sta iy
        lda #0
        ldx rr
        beq @bb
        lda #6
@bb     sta bbase
        jmp calcbullet

testtgt:                        ; carry set = this bullet hits the loaded aircraft
        lda state
        cmp #ST_FLY
        bne @no
        lda #(NSTEP-1)          ; bullet drop = (23-step)*5/8
        sec
        sbc step
        sta tmp
        asl
        asl
        clc
        adc tmp
        lsr
        lsr
        lsr
        sta drop
        lda refset
        bne @nr
        lda drop
        sta refdrop
        lda #1
        sta refset
@nr     lda hfound
        bne @no
        lda ay
        clc
        adc sdy
        clc
        adc drop
        sta iy
        lda step
        lsr
        lsr
        tax
        lda ix
        sec
        sbc tcx
        bcs @p1
        eor #$ff
        clc
        adc #1
@p1     cmp tolx,x
        beq @ok1
        bcs @no
@ok1    lda iy
        sec
        sbc tcy
        bcs @p2
        eor #$ff
        clc
        adc #1
@p2     cmp toly,x
        beq @ok2
        bcs @no
@ok2    sec
        rts
@no     clc
        rts

shellstart:                     ; eject a spent shell to the right
        lda #190
        sta shx
        lda #188
        sta shy
        lda #$fd
        sta shvy
        lda #1
        sta shf
        lda #(SPRBLK+9)
        sta SPTR+7
        lda shx
        sta $d00e
        lda shy
        sta $d00f
        lda $d015
        ora #$80
        sta $d015
        rts

shellupdate:                    ; spinning casing flies right and falls
        lda shf
        beq @r
        cmp #14
        bcs @off
        lsr
        and #3
        clc
        adc #(SPRBLK+9)
        sta SPTR+7
        lda shx
        clc
        adc #4
        sta shx
        sta $d00e
        lda shy
        clc
        adc shvy
        sta shy
        sta $d00f
        inc shvy
        inc shf
        rts
@off    lda #0
        sta shf
        lda $d015
        and #$7f
        sta $d015
@r      rts

shiftr:                            ; arithmetic shift right of A
        cmp #$80
        ror
        rts

calc1:                          ; 3-step tracer path, X = 0 (x) or 3 (y)
        lda cbt
        sec
        sbc cbs
        sta tmp
        jsr shiftr
        sta tmp2
        jsr shiftr
        sta tmp3
        lda tmp
        sec
        sbc tmp3
        sta tmp3
        lda tmp2
        clc
        adc cbs
        sec
        sbc cbo
        sta bp,x
        lda tmp3
        clc
        adc cbs
        sec
        sbc cbo
        sta bp+1,x
        lda cbt
        sec
        sbc cbo
        sta bp+2,x
        rts

calcbullet:                     ; from the muzzle (game x 132, y 176) to (ix,iy)
        lda ix
        sta cbt
        lda #132
        sta cbs
        lda #0
        sta cbo
        ldx bbase
        jsr calc1
        lda iy
        sta cbt
        lda #176
        sta cbs
        lda #4
        sta cbo
        lda bbase
        clc
        adc #3
        tax
        jmp calc1

movebullet:
        lda bph
        beq @r
        cmp #4
        bcs @off
        tax
        dex
        lda bp+3,x
        sta $d003
        lda bp,x
        sta spgx
        lda #12
        sta sphw
        lda #1
        sta spn
        jsr setsprx
        inc bph
        rts
@off    lda #0
        sta bph
        lda $d015
        and #$fd                ; bullet sprite off
        sta $d015
@r      rts

hit:
        dec hits
        lda ammo                ; bonus ammo per hit
        clc
        adc #AMMOBON
        bcc @a
        lda #255
@a      sta ammo
        lda hitcnt              ; hit counter
        cmp #255
        beq @h
        inc hitcnt
@h      lda hitscore            ; 10 points + 2 x level bonus points
        sta addlo
        lda #0
        sta addhi
        jsr addscore
        jsr sndhit
        lda #1
        sta dirty
        lda hits
        beq @kill
        lda #<sHit
        ldx #>sHit
        jmp smsg
@kill   lda bonlo               ; kill bonus
        sta addlo
        lda bonhi
        sta addhi
        jsr addscore
        inc kills
        inc k3
        lda #ST_EXP
        sta state
        lda #28
        sta timer
        ldx snum
        lda #7
        sta $d027,x
        jsr sndboom
        lda #<sKill
        ldx #>sKill
        jsr smsg
        lda k3
        cmp #3
        bne @r
        lda #0
        sta k3
        jmp levelup
@r      rts

levelup:                        ; 3 kills -> next level, speed doubles
        inc level
        lda level               ; +3 armor, +5 from level 4 on
        cmp #4
        lda #LVLARMOR
        bcc @a3
        lda #LVLARMOR2
@a3     clc
        adc bunkhp
        cmp #100
        bcc @ab
        lda #99
@ab     sta bunkhp
        lda smult
        cmp #128
        bcs @ns
        asl
        sta smult
        asl spdlo
        rol spdhi
@ns     sei
        sed
        clc
        lda bonlo
        adc #$50
        sta bonlo
        lda bonhi
        adc #0
        sta bonhi
        lda hitscore            ; hit bonus grows by 2 per level
        cmp #$98
        bcs @nh
        clc
        adc #$02
        sta hitscore
@nh     cld
        cli
        jsr setntarg
        lda #<sLvl
        ldx #>sLvl
        ldy level
        cpy #3
        bcc @m
        bne @m2
        lda #<sUpg
        ldx #>sUpg
        bne @m
@m2     lda #<sLvl2
        ldx #>sLvl2
@m      jsr smsg
        jmp sndlevel

addscore:                       ; score += addhi:addlo (BCD)
        sei
        sed
        clc
        lda score0
        adc addlo
        sta score0
        lda score1
        adc addhi
        sta score1
        lda score2
        adc #0
        sta score2
        cld
        cli
        rts

smsg:                           ; A/X = text, shown on row 22 for a while
        sta mlo
        stx mhi
        ldy #22
        jsr clrrow
        lda #7
        sta col
        ldx #3
        ldy #22
        jsr gotoxy
        lda mlo
        ldx mhi
        jsr prts
        lda #45
        sta msgt
        rts

clrmsg:
        ldy #22
        jmp clrrow

; ============================================================
;  GAME OVER
; ============================================================
gameover:
        lda #0                  ; the target blows up the bunker
        sta $d015
        sta $d01c
        sta $d010
        lda #148
        sta $d000
        lda #108
        sta $d001
        lda #1
        sta $d017
        sta $d01d
        lda #7
        sta $d027
        lda $d015
        ora #1
        sta $d015
        jsr sndbig
        lda #60
        sta timer
        lda #24
        sta shkc
@l      jsr waitframe
        lda shkc
        bne @sk
        lda #24
        sta shkc
@sk     jsr shakeupdate
        lda timer
        lsr
        lsr
        and #1
        clc
        adc #(SPRBLK+4)
        sta SPTR
        lda timer
        and #2
        beq @b0
        lda #2
        jmp @sb
@b0     lda #0
@sb     jsr setflash
        dec timer
        bne @l
        jsr clrflash
        lda #0
        sta shkc
        sta $d015
        sta $d017
        sta $d01d
        lda score2              ; new high score?
        cmp hi2
        bcc @no
        bne @new
        lda score1
        cmp hi1
        bcc @no
        bne @new
        lda score0
        cmp hi0
        bcc @no
@new    lda score0
        sta hi0
        lda score1
        sta hi1
        lda score2
        sta hi2
@no     lda #<drawgo
        sta redrawv
        lda #>drawgo
        sta redrawv+1
        jsr drawgo
        jsr flush
@k      jsr getkey
        cmp #$20                ; space
        bne @q
        jmp newgame
@q      cmp #$51                ; Q
        bne @k
        jmp quit

drawgo:
        jsr cls
        lda #10
        sta col
        ldx #11
        ldy #4
        jsr gotoxy
        lda #<sGO
        ldx #>sGO
        jsr prts
        lda #7
        sta col
        ldx #5
        ldy #7
        jsr gotoxy
        lda goreason
        bne @r1
        lda #<sGO2
        ldx #>sGO2
        jmp @r2
@r1     lda #<sGO3
        ldx #>sGO3
@r2     jsr prts
        lda #7
        sta col
        ldx #8
        ldy #10
        jsr gotoxy
        lda #<sFinal
        ldx #>sFinal
        jsr prts
        lda #1
        sta col
        lda score2
        jsr prbcd
        lda score1
        jsr prbcd
        lda score0
        jsr prbcd
        lda #7
        sta col
        ldx #8
        ldy #12
        jsr gotoxy
        lda #<sHigh
        ldx #>sHigh
        jsr prts
        lda #1
        sta col
        lda hi2
        jsr prbcd
        lda hi1
        jsr prbcd
        lda hi0
        jsr prbcd
        lda #7
        sta col
        ldx #8
        ldy #14
        jsr gotoxy
        lda #<sLvlR
        ldx #>sLvlR
        jsr prts
        lda #1
        sta col
        lda level
        jsr prnum
        lda #7
        sta col
        ldx #8
        ldy #15
        jsr gotoxy
        lda #<sKills
        ldx #>sKills
        jsr prts
        lda #1
        sta col
        lda kills
        jsr prnum
        lda #7
        sta col
        ldx #8
        ldy #16
        jsr gotoxy
        lda #<sTotH
        ldx #>sTotH
        jsr prts
        lda #1
        sta col
        lda hitcnt
        jsr prnum
        lda #5
        sta col
        ldx #7
        ldy #19
        jsr gotoxy
        lda #<sAgain
        ldx #>sAgain
        jsr prts
        ldx #7
        ldy #20
        jsr gotoxy
        lda #<sQuit
        ldx #>sQuit
        jsr prts
        jmp drawhint

quit:
        sei
        lda #0                  ; raster interrupts off, system timer back on
        sta $d01a
        lda #$ff
        sta $d019
        lda #$81
        sta $dc0d
        lda #$c8
        sta $d016
        lda #$31                ; restore the system interrupt
        sta $0314
        lda #$ea
        sta $0315
        cli
        lda #0
        sta $0291
        sta $d015
        lda #14
        sta $d020
        lda #6
        sta $d021
        lda #0
        ldx #$18
@c      sta $d400,x
        dex
        bpl @c
        lda $d011               ; back to text mode, VIC bank 0
        and #$df
        sta $d011
        lda $dd00
        ora #$03
        sta $dd00
        lda #$15
        sta $d018
        lda #147
        jsr CHROUT
        rts

; ============================================================
;  INITIALISATION
; ============================================================
initall:
        jsr inittab
        jsr initsid
        jsr initspr
        jsr copyfont
        jsr cls
        lda #0
        sta $d020
        sta $d021
        lda $dd00
        and #$fc
        ora #$02
        sta $dd00               ; VIC bank 1 = $4000-$7fff
        lda #$78
        sta $d018               ; screen $5c00, bitmap $6000
        lda $d011
        ora #$20
        sta $d011               ; bitmap mode
        lda $d016
        and #$ef
        sta $d016               ; hires
        lda #$80
        sta $0291               ; lock charset switching
        sei                     ; music runs from the system interrupt
        lda #<irqmusic
        sta $0314
        lda #>irqmusic
        sta $0315
        cli
        jmp musicinit

copyfont:                       ; character ROM (first 128 shapes) -> RAM
        sei
        lda $01
        pha
        and #$fb
        sta $01
        lda #$00
        sta sp
        sta cp
        lda #$d0
        sta sp+1
        lda #>FONT
        sta cp+1
        ldx #4
        ldy #0
@l      lda (sp),y
        sta (cp),y
        iny
        bne @l
        inc sp+1
        inc cp+1
        dex
        bne @l
        pla
        sta $01
        cli
        rts

inittab:                        ; bitmap row / attribute row address tables
        lda #<BITMAP
        sta sp
        lda #>BITMAP
        sta sp+1
        lda #<SCRRAM
        sta cp
        lda #>SCRRAM
        sta cp+1
        ldy #0
@l      lda sp
        sta rowlo,y
        lda sp+1
        sta rowhi,y
        lda cp
        sta arlo,y
        lda cp+1
        sta arhi,y
        lda sp
        clc
        adc #<320
        sta sp
        lda sp+1
        adc #>320
        sta sp+1
        lda cp
        clc
        adc #40
        sta cp
        bcc @n
        inc cp+1
@n      iny
        cpy #25
        bne @l
        rts

initspr:
        lda #SPRBLK
        sta SPTR
        lda #(SPRBLK+6)
        sta SPTR+1
        lda #(SPRBLK+7)
        sta SPTR+2
        lda #SPRBLK
        sta SPTR+3
        sta SPTR+4
        sta SPTR+5
        sta SPTR+6
        lda #(SPRBLK+9)
        sta SPTR+7
        lda #15
        sta $d02a
        sta $d02b
        sta $d02c
        sta $d02d
        lda #7
        sta $d02e
        lda #11                 ; shared multicolour: dark grey / yellow
        sta $d025
        lda #7
        sta $d026
        lda #1
        sta $d029               ; reticle colour
        lda #0
        sta $d015
        sta $d010
        sta $d017
        sta $d01d
        sta $d01c
        sta $d01b
        lda #7
        sta $d028
        lda #15
        sta $d027
        rts

initsid:
        lda #0
        ldx #$18
@c      sta $d400,x
        dex
        bpl @c
        lda #$08                ; voice 2 = bass
        sta $d40c
        lda #$78
        sta $d40d
        lda #$44                ; voice 3 = lead
        sta $d413
        lda #$66
        sta $d414
        lda #$a2                ; filter: resonance 10, voice 2 filtered
        sta $d417
        lda #$1f                ; low-pass + volume 15
        sta $d418
        rts

; ============================================================
;  SOUND
; ============================================================
delay:                          ; A = time units (~1.3 ms each)
        sta dly
@o      ldy #$ff
@i      dey
        bne @i
        dec dly
        bne @o
        rts

sfxon:                          ; effects own voice 1 (the drums step aside)
        lda #9
        sta sfxt
        lda #0
        sta kact
        rts

sndshot:
        jsr sfxon
        lda #$04
        sta $d405
        lda #$00
        sta $d406
        sta $d400
        lda #$1c
        sta $d401
        lda #$80
        sta $d404
        ldx #12
@w      dex
        bne @w
        lda #$81
        sta $d404
        rts

sndhit:
        jsr sfxon
        lda #$05
        sta $d405
        lda #$00
        sta $d406
        sta $d400
        sta $d402
        lda #$08
        sta $d403
        lda #$40
        sta $d401
        lda #$40
        sta $d404
        ldx #12
@w      dex
        bne @w
        lda #$41
        sta $d404
        rts

sndboom:
        jsr sfxon
        lda #45
        sta sfxt
        lda #$09
        sta $d405
        sta $d406
        lda #$00
        sta $d400
        lda #$0a
        sta $d401
        lda #$80
        sta $d404
        ldx #12
@w      dex
        bne @w
        lda #$81
        sta $d404
        rts

sndbig:
        jsr sfxon
        lda #120
        sta sfxt
        lda #$09
        sta $d405
        lda #$0a
        sta $d406
        lda #$00
        sta $d400
        lda #$04
        sta $d401
        lda #$80
        sta $d404
        ldx #12
@w      dex
        bne @w
        lda #$81
        sta $d404
        rts

sndlevel:
        jsr sfxon
        lda #40
        sta sfxt
        lda #$20
        jsr n3
        lda #$2c
        jsr n3
        lda #$3a
n3:     sta $d401
        lda #$00
        sta $d400
        lda #$05
        sta $d405
        lda #$00
        sta $d406
        lda #$10
        sta $d404
        ldx #10
@w      dex
        bne @w
        lda #$11
        sta $d404
        lda #40
        jsr delay
        lda #$10
        sta $d404
        rts

; ---------------- music engine (3 voices, 4 slots per frame, raster driven) ----------------
; voices: 0 = bass (SID voice 2), 1 = drums (SID voice 1, steps aside for
; sound effects), 2 = lead / arps / pads (SID voice 3).
; tricks from the synth-pop tune: hard restart, test-bit oscillator reset,
; 200 Hz PWM with bounce, resonant low-pass sweeps with a bass "pump"
; envelope, volume-register kick duck, software FM, delayed vibrato,
; wave-table instruments (arps, noise drums, pitch drops), tempo/key changes
; and a master volume fade.
FENV_START = $70
mptr    = $10
mzp     = $12

RL0     = 1             ; raster lines of the six interrupts per frame
RL1     = 65
RL2     = 81
RL3     = 139
RL4     = 177
RL5     = 217

irqmusic:                       ; VIC raster interrupts (chained from the KERNAL entry)
        cld
        lda $d019
        sta $d019
        and #$01
        bne @mine
        jmp $ea81
@mine   lda rirq
        asl
        tax
        lda rtab+1,x
        pha
        lda rtab,x
        pha
        rts

rtab:   !byte <(r0-1),>(r0-1),<(r1-1),>(r1-1),<(r2-1),>(r2-1)
        !byte <(r3-1),>(r3-1),<(r4-1),>(r4-1),<(r5-1),>(r5-1)
rlines: !byte RL1,RL2,RL3,RL4,RL5,RL0

rdone:                          ; arm the next interrupt, leave through the KERNAL
        ldx rirq
        lda rlines,x
        sta $d012
        inx
        cpx #6
        bcc @s
        ldx #0
@s      stx rirq
        jmp $ea81

r0:     lda #0                  ; line 1: top border, sprite colours, music slot 0
        jsr setborder
        lda #11
        sta $d025
        lda #7
        sta $d026
        jsr musicplay
        jmp rdone
r1:     lda xsh                 ; line 65: the top wall starts to shake
        sta $d016
        jmp rdone
r2:     lda #$08                ; line 81: the window stays still
        sta $d016
        lda #1
        jsr setborder
        jsr musicplay
        jmp rdone
r3:     lda #14                 ; line 139: hazy sprite colours near the horizon
        sta $d025
        lda #8
        sta $d026
        jsr musicplay
        jsr $ff9f               ; keyboard scan (the system timer is off)
        jmp rdone
r4:     lda xsh                 ; line 177: gun and parapet shake
        sta $d016
        lda #2
        jsr setborder
        jmp rdone
r5:     lda #$08                ; line 217: text rows stay still
        sta $d016
        lda #3
        jsr setborder
        jsr musicplay
        jmp rdone

setborder:                      ; A = band 0..3: border colour (flash / overheat override)
        tax
        lda bflash
        beq @n
        lda bfcol
        sta $d020
        rts
@n      lda hot
        beq @c
        cpx #1
        beq @h
        cpx #2
        bne @c
@h      lda #10
        sta $d020
        rts
@c      lda bcol,x
        sta $d020
        rts

setflash:                       ; A = border flash colour
        sta bfcol
        lda #1
        sta bflash
        rts

clrflash:
        lda #0
        sta bflash
        rts

shakeupdate:                    ; bunker hit: shake table -> scroll value for the bands
        lda shkc
        beq @n
        tax
        lda shktab-1,x
        sta xsh
        dec shkc
        rts
@n      lda #$08
        sta xsh
        rts

rasterinit:
        sei
        lda #$7f                ; CIA interrupts off: raster drives everything
        sta $dc0d
        sta $dd0d
        lda $dc0d
        lda $dd0d
        lda $d011
        and #$7f
        sta $d011
        lda #RL0
        sta $d012
        lda #0
        sta rirq
        lda #$ff
        sta $d019
        lda #$01
        sta $d01a
        cli
        rts

musicinit:
        ldx #2
@l      lda mstl,x
        sta mseql,x
        lda msth,x
        sta mseqh,x
        lda #1
        sta mdur,x
        lda #0
        sta mins,x
        sta mwpos,x
        sta mctrl,x
        sta mtbit,x
        sta mpwsp,x
        sta mage,x
        sta mcut,x
        sta mfmd,x
        sta mvibd,x
        sta mbfl,x
        sta mbfh,x
        lda #$ff
        sta mgmask,x
        dex
        bpl @l
        lda #0
        sta mslot
        sta mframe
        sta mtrans
        sta mdigi
        sta fenv
        sta mfdiv
        lda #SPEEDF
        sta mspd
        sec
        sbc #1
        sta mhrfr
        lda #15
        sta mvol
        sta mtgt
        sta mvolo
        lda #1
        sta mrate
        lda #1
        jsr setfilter
        jmp rasterinit

musicplay:
        lda musicon
        bne @on
        lda #$40                ; music off: silence bass and lead
        sta $d40b
        lda #$10
        sta $d412
        lda sfxt
        beq @z
        dec sfxt
        rts
@z      lda #$00
        sta $d404
        rts
@on     lda mslot
        bne @nz
        jsr frame_logic
        jmp @fx
@nz     cmp #1
        bne @fx
        lda #0
        sta mtbit
        sta mtbit+1
        sta mtbit+2
@fx     jsr fast_fx
        jsr filter_step
        lda mslot
        clc
        adc #1
        and #3
        sta mslot
@r      rts

frame_logic:                    ; 50 Hz
        lda sfxt
        beq @a
        dec sfxt
@a      jsr vol_fade
        inc mframe
        lda mframe
        cmp mspd
        bcc @nt
        lda #0
        sta mframe
        jsr seq_step
@nt     lda mframe
        cmp mhrfr
        bne @nh
        jsr hard_restart
@nh     ldx #2
@v      jsr voice_frame
        dex
        bpl @v
        rts

seq_step:
        lda #2
        sta msqi
@e      ldy msqi
        ldx mordtab,y
        dec mdur,x
        bne @n
        jsr read_event
@n      dec msqi
        bpl @e
        rts

read_event:
        lda mseql,x
        sta mptr
        lda mseqh,x
        sta mptr+1
        ldy #0
@fetch  lda (mptr),y
        bmi @cmd
        iny
        clc
        adc mtrans
        sta mnote,x
        lda (mptr),y
        iny
        sta mdur,x
        tya
        pha
        jsr note_on
        pla
        tay
        jmp @done
@cmd    iny
        cmp #$80
        beq @rest
        cmp #$81
        beq @setins
        cmp #$82
        beq @setflt
        cmp #$84
        beq @trans
        cmp #$85
        beq @spd
        cmp #$87
        beq @fade
        cmp #$fe
        beq @loop
        jmp @done
@rest   lda (mptr),y
        iny
        sta mdur,x
        lda #$fe
        sta mgmask,x
        jmp @done
@setins lda (mptr),y
        iny
        sta mins,x
        jmp @fetch
@setflt lda (mptr),y
        iny
        jsr setfilter
        jmp @fetch
@trans  lda (mptr),y
        iny
        sta mtrans
        jmp @fetch
@spd    lda (mptr),y
        iny
        sta mspd
        sec
        sbc #1
        sta mhrfr
        jmp @fetch
@fade   lda (mptr),y
        iny
        sta mvol
        lda (mptr),y
        iny
        sta mtgt
        lda (mptr),y
        iny
        sta mrate
        lda #0
        sta mcnt
        jmp @fetch
@loop   lda mstl,x
        sta mptr
        lda msth,x
        sta mptr+1
        ldy #0
        jmp @fetch
@done   tya
        clc
        adc mptr
        sta mseql,x
        lda mptr+1
        adc #0
        sta mseqh,x
        rts

note_on:
        lda mins,x
        asl
        asl
        asl
        sta mzp
        lda #0
        sta mzp+1
        clc
        lda mzp
        adc #<instab
        sta mzp
        lda mzp+1
        adc #>instab
        sta mzp+1
        ldy #0
        lda (mzp),y
        sta mt0
        iny
        lda (mzp),y
        sta mt1
        iny
        lda (mzp),y
        sta mwpos,x
        iny
        lda (mzp),y
        sta mpwh,x
        iny
        lda (mzp),y
        sta mpwsp,x
        iny
        lda (mzp),y
        sta mcut,x
        iny
        lda (mzp),y
        sta mfmd,x
        iny
        lda (mzp),y
        sta mt2
        sta mvfl,x
        lda #0
        sta mpwl,x
        sta mfmp,x
        sta mage,x
        sta mtbit,x
        sta mvibp,x
        sta mvibd,x
        lda mt2
        and #$10
        beq @nov
        lda mfmd,x              ; vibrato spec = delay<<4 | depth
        and #$0f
        sta mvibd,x
        lda mfmd,x
        lsr
        lsr
        lsr
        lsr
        asl
        sta mvibdel,x
        lda #0
        sta mfmd,x
@nov    lda #$ff
        sta mgmask,x
        cpx #1                  ; drums: sound effects own the voice
        bne @w
        lda sfxt
        bne @sk
@w      ldy mvoff,x
        lda mt0
        sta $d405,y
        lda mt1
        sta $d406,y
@sk     lda mt2
        and #1
        beq @nt
        lda #8
        sta mtbit,x
@nt     lda mt2
        and #2
        beq @nd
        lda #12
        sta mdigi
@nd     lda mt2
        and #$20
        beq @nf
        lda #FENV_START
        sta fenv
@nf     rts

hard_restart:
        ldx #2
@l      lda mdur,x
        cmp #1
        bne @n
        lda #$fe
        sta mgmask,x
        cpx #1
        bne @w
        lda sfxt
        bne @n
@w      ldy mvoff,x
        lda #0
        sta $d405,y
        sta $d406,y
@n      dex
        bpl @l
        rts

voice_frame:                    ; wave-table rows, ageing (50 Hz)
        lda mage,x
        cmp #$ff
        beq @aged
        inc mage,x
@aged   lda mcut,x
        beq @nocut
        cmp mage,x
        bne @nocut
        lda #$fe
        sta mgmask,x
@nocut  ldy mwpos,x
@row    lda wavetab,y
        cmp #$ff
        bne @norm
        lda wavetab+1,y
        tay
        jmp @row
@norm   sta mctrl,x
        lda wavetab+1,y
        sta mtmp
        iny
        iny
        tya
        sta mwpos,x
        lda mtmp
        bmi @abs
        and #$40
        bne @sub
        lda mtmp
        clc
        adc mnote,x
        jmp @look
@sub    lda mtmp
        and #$3f
        sta mtmp
        lda mnote,x
        sec
        sbc mtmp
        jmp @look
@abs    and #$7f
@look   tay
        lda ntlo,y
        sta mbfl,x
        lda nthi,y
        sta mbfh,x
        rts

fast_fx:                        ; 200 Hz: FM, vibrato, PWM, register writes
        ldx #0
@l      jsr fx_voice
        inx
        cpx #3
        bne @l
        rts

fx_voice:
        lda #0
        sta mtmp2
        sta mtmp3
        lda mfmd,x
        beq @nofm
        jsr fm_calc
@nofm   lda mvibd,x
        beq @novib
        jsr vib_calc
@novib  clc
        lda mbfl,x
        adc mtmp2
        sta moutl
        lda mbfh,x
        adc mtmp3
        sta mouth
        lda mpwsp,x
        beq @nopwm
        jsr pwm_step
@nopwm  cpx #1
        bne @write
        lda sfxt
        beq @write
        rts
@write  ldy mvoff,x
        lda moutl
        sta $d400,y
        lda mouth
        sta $d401,y
        lda mpwl,x
        sta $d402,y
        lda mpwh,x
        sta $d403,y
        lda mctrl,x
        and mgmask,x
        ora mtbit,x
        sta $d404,y
        rts

fm_calc:
        lda mfmd,x
        lsr
        lsr
        lsr
        lsr
        clc
        adc mfmp,x
        sta mfmp,x
        and #$0f
        tay
        lda fmtab,y
        sta mtmp2
        bmi @neg
        lda #0
        beq @ext
@neg    lda #$ff
@ext    sta mtmp3
        lda mfmd,x
        and #$0f
        tay
        beq @ret
@sh     asl mtmp2
        rol mtmp3
        dey
        bne @sh
@ret    rts

vib_calc:                       ; delayed, pitch-scaled vibrato
        lda mage,x
        sec
        sbc mvibdel,x
        bcc @ret
        inc mvibp,x
        lda mvibp,x
        and #$1f
        tay
        lda vibtab,y
        sta mtmp
        bpl @abs
        eor #$ff
        clc
        adc #1
@abs    tay
        beq @ret
        lda #0
        sta mt0
        sta mt1
@mul    lda mt0
        clc
        adc mbfh,x
        sta mt0
        bcc @nc
        inc mt1
@nc     dey
        bne @mul
        ldy mvibd,x
        dey
        beq @sd
@shr    lsr mt1
        ror mt0
        dey
        bne @shr
@sd     lda mtmp
        bmi @sub
        clc
        lda mtmp2
        adc mt0
        sta mtmp2
        lda mtmp3
        adc mt1
        sta mtmp3
@ret    rts
@sub    sec
        lda mtmp2
        sbc mt0
        sta mtmp2
        lda mtmp3
        sbc mt1
        sta mtmp3
        rts

pwm_step:
        lda mpwsp,x
        bpl @pos
        lda #$ff
        bne @ext
@pos    lda #0
@ext    sta mtmp
        clc
        lda mpwl,x
        adc mpwsp,x
        sta mpwl,x
        lda mpwh,x
        adc mtmp
        sta mpwh,x
        bmi @low
        cmp #$0d
        bcs @high
        cmp #$03
        bcs @ok
@low    lda #$03
        sta mpwh,x
        bne @flip
@high   lda #$0c
        sta mpwh,x
@flip   lda mpwsp,x
        eor #$ff
        clc
        adc #1
        sta mpwsp,x
@ok     rts

vol_fade:                       ; 50 Hz: master volume towards the target
        lda mvol
        cmp mtgt
        beq @d
        inc mcnt
        lda mcnt
        cmp mrate
        bcc @d
        lda #0
        sta mcnt
        lda mvol
        cmp mtgt
        bcc @up
        dec mvol
        rts
@up     inc mvol
@d      rts

filter_step:                    ; one SID filter + volume register
        inc mfdiv
        ldx mdigi
        beq @nov
        lda digitab-1,x
        dec mdigi
        cmp mvol
        bcc @hv
@nov    lda mvol
@hv     sta mvolo
        lda mfdiv
        and #3
        bne @nosw
        lda mfdir
        beq @nosw
        bmi @down
        clc
        adc mfcut
        bcs @top
        cmp mfmax
        bcc @store
@top    lda mfmax
        jsr flipdir
        jmp @store
@down   clc
        adc mfcut
        bcc @bot
        cmp mfmin
        bcs @store
@bot    lda mfmin
        jsr flipdir
@store  sta mfcut
@nosw   lda mfcut
        clc
        adc fenv
        bcc @nc
        lda #$ff
@nc     sta $d416
        lda fenv
        beq @fe
        lsr
        lsr
        lsr
        lsr
        bne @fd
        lda #1
@fd     sta mtmp
        lda fenv
        sec
        sbc mtmp
        sta fenv
@fe     lda #0
        sta $d415
        lda mfroute
        sta $d417
        lda mvolo
        ora mfmode
        sta $d418
        rts

flipdir:
        pha
        lda mfdir
        eor #$ff
        clc
        adc #1
        sta mfdir
        pla
        rts

setfilter:                      ; A = preset, keeps X and Y
        stx msx
        sty msy
        sta mtmp
        asl
        clc
        adc mtmp
        asl
        tay
        lda fpresets,y
        sta mfroute
        lda fpresets+1,y
        sta mfmode
        lda fpresets+2,y
        sta mfcut
        lda fpresets+3,y
        sta mfdir
        lda fpresets+4,y
        sta mfmin
        lda fpresets+5,y
        sta mfmax
        ldx msx
        ldy msy
        rts

; ---- raster / shake variables ----
rirq:     !byte 0
xsh:      !byte $08
shkc:     !byte 0
bflash:   !byte 0
bfcol:    !byte 0
bcol:     !byte 11,6,5,11
shktab:   !byte 3,3,3,3,3,3,4,3,3,4,3,4,3,4,2,5,2,5,1,6,1,6,0,7
; ---- music variables ----
micr:     !byte 0
mslot:    !byte 0
mframe:   !byte 0
mspd:     !byte 6
mhrfr:    !byte 5
mtrans:   !byte 0
mdigi:    !byte 0
mvol:     !byte 15
mtgt:     !byte 15
mvolo:    !byte 15
mrate:    !byte 1
mcnt:     !byte 0
mfdiv:    !byte 0
mfroute:  !byte 0
mfmode:   !byte 0
mfcut:    !byte 0
mfdir:    !byte 0
mfmin:    !byte 0
mfmax:    !byte 0
msqi:     !byte 0
msx:      !byte 0
msy:      !byte 0
mt0:      !byte 0
mt1:      !byte 0
mt2:      !byte 0
mtmp:     !byte 0
mtmp2:    !byte 0
mtmp3:    !byte 0
moutl:    !byte 0
mouth:    !byte 0
mseql:    !fill 3,0
mseqh:    !fill 3,0
mdur:     !fill 3,0
mins:     !fill 3,0
mnote:    !fill 3,0
mwpos:    !fill 3,0
mctrl:    !fill 3,0
mgmask:   !fill 3,0
mtbit:    !fill 3,0
mbfl:     !fill 3,0
mbfh:     !fill 3,0
mpwl:     !fill 3,0
mpwh:     !fill 3,0
mpwsp:    !fill 3,0
mage:     !fill 3,0
mcut:     !fill 3,0
mfmd:     !fill 3,0
mfmp:     !fill 3,0
mvibd:    !fill 3,0
mvibp:    !fill 3,0
mvibdel:  !fill 3,0
mvfl:     !fill 3,0

; ============================================================
;  KEYBOARD
; ============================================================
getkey:                         ; 'A' anywhere shows the copyright notice
        jsr GETIN
        cmp #0
        beq getkey
        cmp #$41
        bne @r
        jsr copyright
        jmp getkey
@r      rts

flush:
        jsr GETIN
        cmp #0
        bne flush
        rts

copyright:
        lda $d015               ; pause: hide sprites
        sta sprsave
        lda #0
        sta $d015
        jsr cls
        lda #7
        sta col
        ldx #12
        ldy #3
        jsr gotoxy
        lda #<sCopyH
        ldx #>sCopyH
        jsr prts
        lda #1
        sta col
        lda #0
        sta cri
@l      ldx cri
        lda crlo,x
        sta mlo
        lda crhi,x
        sta mhi
        lda cri
        asl
        clc
        adc #6
        tay
        ldx #2
        jsr gotoxy
        lda mlo
        ldx mhi
        jsr prts
        inc cri
        lda cri
        cmp #7
        bne @l
        lda #14
        sta col
        ldx #8
        ldy #22
        jsr gotoxy
        lda #<sBack
        ldx #>sBack
        jsr prts
        jsr flush
@w      jsr GETIN
        cmp #0
        beq @w
        jsr callred
        lda sprsave
        sta $d015
        jmp flush

callred:                        ; redraw the screen we came from
        jmp (redrawv)

; ============================================================
;  SCREEN PRIMITIVES
; ============================================================
cls:                            ; clear bitmap and attributes
        lda #<BITMAP
        sta sp
        lda #>BITMAP
        sta sp+1
        lda #0
        ldx #31
        ldy #0
@p      sta (sp),y
        iny
        bne @p
        inc sp+1
        dex
        bne @p
        ldy #63
@q      sta (sp),y
        dey
        bpl @q
        lda #<SCRRAM
        sta sp
        lda #>SCRRAM
        sta sp+1
        lda #0
        ldx #3
        ldy #0
@r      sta (sp),y
        iny
        bne @r
        inc sp+1
        dex
        bne @r
        ldy #231
@s      sta (sp),y
        dey
        cpy #$ff
        bne @s
        rts

gotoxy:                         ; X = column, Y = row
        txa
        clc
        adc arlo,y
        sta cp
        lda arhi,y
        adc #0
        sta cp+1
        stx t8lo
        lda #0
        sta t8hi
        asl t8lo
        rol t8hi
        asl t8lo
        rol t8hi
        asl t8lo
        rol t8hi
        lda rowlo,y
        clc
        adc t8lo
        sta sp
        lda rowhi,y
        adc t8hi
        sta sp+1
        rts

putch:                          ; A = screen code (+$80 = inverse), colour = col
        stx pcx
        sta pcode
        and #$7f
        sta gp
        lda #0
        sta gp+1
        asl gp
        rol gp+1
        asl gp
        rol gp+1
        asl gp
        rol gp+1
        lda gp
        clc
        adc #<FONT
        sta gp
        lda gp+1
        adc #>FONT
        sta gp+1
        lda pcode
        and #$80
        sta pinv
        ldy #7
@l      lda (gp),y
        ldx pinv
        beq @n
        eor #$ff
@n      sta (sp),y
        dey
        bpl @l
        lda col
        asl
        asl
        asl
        asl
        ldy #0
        sta (cp),y
        lda sp
        clc
        adc #8
        sta sp
        bcc @a
        inc sp+1
@a      inc cp
        bne @b
        inc cp+1
@b      ldx pcx
        rts

prts:                           ; A/X = lo/hi of 0-terminated ASCII text
        sta tp
        stx tp+1
@l      ldy #0
        lda (tp),y
        beq @d
        inc tp
        bne @c
        inc tp+1
@c      cmp #$40
        bcc @o
        and #$3f                ; ASCII letter -> screen code
@o      jsr putch
        jmp @l
@d      rts

clrrow:                         ; Y = row
        ldx #0
        jsr gotoxy
        lda #0
        ldy #0
@a      sta (sp),y
        iny
        bne @a
        inc sp+1
        ldy #63
@b      sta (sp),y
        dey
        bpl @b
        ldy #39
@c      sta (cp),y
        dey
        bpl @c
        rts

prnum:                          ; A = 0..255 printed as 3 chars
        ldx #0
@h      cmp #100
        bcc @hd
        sbc #100
        inx
        bne @h
@hd     stx hdig
        ldx #0
@t      cmp #10
        bcc @td
        sbc #10
        inx
        bne @t
@td     stx tdig
        sta odig
        lda hdig
        beq @sh
        ora #$30
        bne @ph
@sh     lda #$20
@ph     jsr putch
        lda hdig
        ora tdig
        beq @st
        lda tdig
        ora #$30
        bne @pt
@st     lda #$20
@pt     jsr putch
        lda odig
        ora #$30
        jmp putch

prbcd:                          ; A = two BCD digits
        pha
        lsr
        lsr
        lsr
        lsr
        ora #$30
        jsr putch
        pla
        and #$0f
        ora #$30
        jmp putch

drawhint:
        lda #15
        sta col
        ldx #5
        ldy #24
        jsr gotoxy
        lda #<sHint
        ldx #>sHint
        jmp prts

; ============================================================
;  SCENES
; ============================================================
showtitle:
        lda #<drawtitle
        sta redrawv
        lda #>drawtitle
        sta redrawv+1
        jsr drawtitle
        jsr flush
@k      jsr getkey
        cmp #$54                ; T toggles the music
        bne @mm
        jsr togglemusic
        jsr drawmusic
        jmp @k
@mm     cmp #$4d                ; M = mission objectives
        bne @j
        jsr showmission
        jmp @k
@j      cmp #$4a                ; J = joystick
        bne @kk
        lda #1
        sta ctl
        jsr drawctl
        jmp @k
@kk     cmp #$4b                ; K = keyboard
        bne @go
        lda #0
        sta ctl
        jsr drawctl
        jmp @k
@go     rts

showmission:
        lda #<drawmission
        sta redrawv
        lda #>drawmission
        sta redrawv+1
        jsr drawmission
        jsr flush
        jsr getkey
        lda #<drawtitle
        sta redrawv
        lda #>drawtitle
        sta redrawv+1
        jmp drawtitle

drawmission:
        jsr cls
        ldx #0
@l      lda mtab,x
        cmp #$ff
        beq @d
        sta srow
        lda mtab+1,x
        sta scnt
        lda mtab+2,x
        sta col
        lda mtab+3,x
        sta mlo
        lda mtab+4,x
        sta mhi
        stx sidx
        ldx srow
        ldy scnt
        jsr gotoxy
        lda mlo
        ldx mhi
        jsr prts
        lda sidx
        clc
        adc #5
        tax
        jmp @l
@d      lda #14
        sta col
        ldx #8
        ldy #22
        jsr gotoxy
        lda #<sBack
        ldx #>sBack
        jsr prts
        jmp drawhint

drawtitle:
        jsr cls
        ldx #0
@l      lda ttab,x
        cmp #$ff
        beq @d
        sta srow                ; (column)
        lda ttab+1,x
        sta scnt                ; (row)
        lda ttab+2,x
        sta col
        lda ttab+3,x
        sta mlo
        lda ttab+4,x
        sta mhi
        stx sidx
        ldx srow
        ldy scnt
        jsr gotoxy
        lda mlo
        ldx mhi
        jsr prts
        lda sidx
        clc
        adc #5
        tax
        jmp @l
@d      jsr drawhint
        jsr drawmusic
        jmp drawctl

drawctl:                        ; control selection: green = selected, red = not
        lda #7
        sta col
        ldx #2
        ldy #21
        jsr gotoxy
        lda #<sCtl
        ldx #>sCtl
        jsr prts
        lda #10
        ldx ctl
        beq @j
        lda #5
@j      sta col
        lda #$0a                ; 'J'
        jsr putch
        lda #15
        sta col
        lda #<sJoy
        ldx #>sJoy
        jsr prts
        lda #5
        ldx ctl
        beq @k
        lda #10
@k      sta col
        lda #$0b                ; 'K'
        jsr putch
        lda #15
        sta col
        lda #<sKey
        ldx #>sKey
        jmp prts

togglemusic:
        lda musicon
        eor #1
        sta musicon
        rts

drawmusic:
        lda #7
        sta col
        ldx #4
        ldy #22
        jsr gotoxy
        lda #<sMus
        ldx #>sMus
        jsr prts
        lda musicon
        beq @off
        lda #5
        sta col
        lda #<sOn
        ldx #>sOn
        jsr prts
        jmp @t
@off    lda #10
        sta col
        lda #<sOff
        ldx #>sOff
        jsr prts
@t      lda #15
        sta col
        lda #<sMusT
        ldx #>sMusT
        jmp prts

drawbg:                         ; pristine artwork -> bitmap + attributes
        lda #<BGBMP
        sta gp
        lda #>BGBMP
        sta gp+1
        lda #<BITMAP
        sta sp
        lda #>BITMAP
        sta sp+1
        ldx #31
        lda #64
        jsr copyblk
        lda #<BGCOL
        sta gp
        lda #>BGCOL
        sta gp+1
        lda #<SCRRAM
        sta sp
        lda #>SCRRAM
        sta sp+1
        ldx #3
        lda #232
        jmp copyblk

copyblk:                        ; gp -> sp, X full pages + A extra bytes
        sta ctail
        ldy #0
        cpx #0
        beq @t
@p      lda (gp),y
        sta (sp),y
        iny
        bne @p
        inc gp+1
        inc sp+1
        dex
        bne @p
@t      ldy #0
        cpy ctail
        beq @d
@q      lda (gp),y
        sta (sp),y
        iny
        cpy ctail
        bne @q
@d      rts

drawscene:                      ; the bunker window
        jsr drawbg
        lda #15
        sta col
        ldx #4
        ldy #23
        jsr gotoxy
        lda #<sFireH
        ldx #>sFireH
        jsr prts
        jmp drawhint

redrawgame:
        jsr drawscene
        jsr drawhud
        jmp drawtemp

drawhud:
        lda #7
        sta col
        ldx #1
        ldy #0
        jsr gotoxy
        lda #<sScore
        ldx #>sScore
        jsr prts
        lda #1
        sta col
        lda score2
        jsr prbcd
        lda score1
        jsr prbcd
        lda score0
        jsr prbcd
        lda #7
        sta col
        ldx #15
        ldy #0
        jsr gotoxy
        lda #<sHi
        ldx #>sHi
        jsr prts
        lda #1
        sta col
        lda hi2
        jsr prbcd
        lda hi1
        jsr prbcd
        lda hi0
        jsr prbcd
        lda #7
        sta col
        ldx #26
        ldy #0
        jsr gotoxy
        lda #<sLevel
        ldx #>sLevel
        jsr prts
        lda #1
        sta col
        lda level
        jsr prnum
        lda #7                  ; row 1: ammo, hit counter, bunker, target
        sta col
        ldx #1
        ldy #1
        jsr gotoxy
        lda #<sAmmo
        ldx #>sAmmo
        jsr prts
        lda #1
        sta col
        lda ammo
        cmp #11
        bcs @a1
        lda #10                 ; low ammo warning colour
        sta col
@a1     lda ammo
        jsr prnum
        lda #7
        sta col
        ldx #11
        ldy #1
        jsr gotoxy
        lda #<sHitsC
        ldx #>sHitsC
        jsr prts
        lda #1
        sta col
        lda hitcnt
        jsr prnum
        lda #7
        sta col
        ldx #21
        ldy #1
        jsr gotoxy
        lda #<sBunkH
        ldx #>sBunkH
        jsr prts
        lda #1
        sta col
        lda bunkhp
        jsr pr2
        lda #7
        sta col
        ldx #31
        ldy #1
        jsr gotoxy
        lda #<sTgt
        ldx #>sTgt
        jsr prts
        lda #1
        sta col
        lda ntarg
        ora #$30
        jmp putch

; ---------------- gun tube temperature -----------------
heatcool:                       ; cools 1 C every 2 frames (every frame from level 3)
        lda level
        cmp #3
        bcs @fast
        inc coolc
        lda coolc
        and #1
        bne @r
@fast
        lda temphi
        bne @dec
        lda templo
        cmp #21
        bcc @r
@dec    lda templo
        bne @nb
        dec temphi
@nb     dec templo
        lda hot                 ; overheat ends below 450 C ($01C2)
        beq @upd
        lda temphi
        beq @clr
        cmp #1
        bne @upd
        lda templo
        cmp #$c2
        bcs @upd
@clr    lda #0
        sta hot
@upd    lda #1
        sta tdirty
@r      rts

addheat:                        ; every shot heats the tube
        lda templo
        clc
        adc #HEATSHOT
        sta templo
        lda temphi
        adc #0
        sta temphi
        cmp #2
        bcs @cap
        cmp #1
        bne @ok
        lda templo
        cmp #$f4
        bcc @ok
@cap    lda #$f4                ; max 500 C = $01F4
        sta templo
        lda #1
        sta temphi
        lda hot
        bne @ok
        lda #1
        sta hot
        lda #<sHotMsg
        ldx #>sHotMsg
        jsr smsg
@ok     lda #1
        sta tdirty
        rts

pr2:                            ; A = 0..99 printed as two digits
        ldx #0
@t      cmp #10
        bcc @d
        sbc #10
        inx
        bne @t
@d      sta odig
        txa
        ora #$30
        jsr putch
        lda odig
        ora #$30
        jmp putch

prtemp:                         ; prints the temperature (3 digits)
        lda templo
        sta t16lo
        lda temphi
        sta t16hi
        ldx #0
@h      lda t16hi
        bne @sub
        lda t16lo
        cmp #100
        bcc @done
@sub    lda t16lo
        sec
        sbc #100
        sta t16lo
        lda t16hi
        sbc #0
        sta t16hi
        inx
        bne @h
@done   stx thun
        lda t16lo
        sta trem
        lda thun
        beq @sp
        ora #$30
        bne @p
@sp     lda #$20
@p      jsr putch
        lda trem
        jmp pr2

drawtemp:                       ; gauge on row 21: text + 10 cell bar
        lda #7
        ldx hot
        beq @c
        lda #2
@c      sta col
        ldx #1
        ldy #21
        jsr gotoxy
        lda #<sGun
        ldx #>sGun
        jsr prts
        jsr prtemp
        lda #$03                ; 'C'
        jsr putch
        lda thun                ; lit cells = temperature / 50
        asl
        sta ncell
        lda trem
        cmp #50
        bcc @n1
        inc ncell
@n1     ldx #28
        ldy #21
        jsr gotoxy
        lda #1
        sta cidx
@b      lda cidx
        cmp #6
        bcc @g
        cmp #9
        bcc @y
        lda #2
        bne @cc
@g      lda #5
        bne @cc
@y      lda #7
@cc     ldx cidx
        cpx ncell
        beq @fill
        bcc @fill
        lda #11
@fill   sta col
        lda #$a0
        jsr putch
        inc cidx
        lda cidx
        cmp #11
        bne @b
        rts

; ============================================================
;  DATA
; ============================================================
stgfrm: !byte 0,1,2,3,2,3
stgexp: !byte 0,0,0,0,1,1
stghx:  !byte 12,12,12,12,24,24
stghy:  !byte 10,10,10,10,21,21
hitcol: !byte 15,2,8,15
; hit tolerance (pixels) per size stage: horizontal / vertical
tolx:   !byte 7,9,12,15,22,28

; ---- music tables (generated) ----
ntlo:
        !byte $16,$27,$39,$4b,$5f,$74,$8a,$a1,$ba,$d4,$f0,$0e
        !byte $2d,$4e,$71,$96,$be,$e7,$14,$42,$74,$a9,$e0,$1b
        !byte $5a,$9c,$e2,$2d,$7b,$cf,$27,$85,$e8,$51,$c1,$37
        !byte $b4,$38,$c4,$59,$f7,$9d,$4e,$0a,$d0,$a2,$81,$6d
        !byte $67,$70,$89,$b2,$ed,$3b,$9c,$13,$a0,$45,$02,$da
        !byte $ce,$e0,$11,$64,$da,$76,$39,$26,$40,$89,$04,$b4
        !byte $9c,$c0,$23,$c8,$b4,$eb,$72,$4c,$80,$12,$08,$68
        !byte $39,$80,$45,$90,$68,$d6,$e3,$99,$00,$24,$10,$ff
nthi:
        !byte $01,$01,$01,$01,$01,$01,$01,$01,$01,$01,$01,$02
        !byte $02,$02,$02,$02,$02,$02,$03,$03,$03,$03,$03,$04
        !byte $04,$04,$04,$05,$05,$05,$06,$06,$06,$07,$07,$08
        !byte $08,$09,$09,$0a,$0a,$0b,$0c,$0d,$0d,$0e,$0f,$10
        !byte $11,$12,$13,$14,$15,$17,$18,$1a,$1b,$1d,$1f,$20
        !byte $22,$24,$27,$29,$2b,$2e,$31,$34,$37,$3a,$3e,$41
        !byte $45,$49,$4e,$52,$57,$5c,$62,$68,$6e,$75,$7c,$83
        !byte $8b,$93,$9c,$a5,$af,$b9,$c4,$d0,$dd,$ea,$f8,$ff
fmtab:  !byte 0,2,4,6,8,6,4,2,0,-2,-4,-6,-8,-6,-4,-2
digitab: !byte 15,15,15,15,15,15,14,13,11,9,8,10
vibtab: !byte 0,2,3,4,6,7,7,8,8,8,7,7,6,4,3,2
        !byte 0,-2,-3,-4,-6,-7,-7,-8,-8,-8,-7,-7,-6,-4,-3,-2
; filter presets: route|res, mode, start cutoff, step, min, max
fpresets:
        !byte $00,$00,$80,$00,$00,$ff   ; 0 off
        !byte $62,$10,$28,$00,$00,$ff   ; 1 LP bass only, envelope pluck
        !byte $66,$10,$50,$02,$50,$f0   ; 2 LP bass+lead, bright sweep
        !byte $66,$10,$3c,$00,$00,$ff   ; 3 LP bass+lead, bass pumps the cutoff
        !byte $76,$10,$30,$01,$30,$b0   ; 4 resonant LP sweep (build)
        !byte $66,$10,$50,$01,$50,$f0   ; 5 slow breathing LP sweep
        !byte $66,$20,$58,$01,$40,$a0   ; 6 band-pass sweep (bridge)
; instruments: AD, SR, wave start, PW hi, PWM speed, staccato cut, FM/vibrato spec, flags
instab:
        !byte $00,$00, w_bsub-wavetab, $08,$00,$00,$00,$00   ; 0 SIL
        !byte $35,$98, w_lead-wavetab, $06,$28,$00,$32,$11   ; 1 LEAD
        !byte $48,$a9, w_brass-wavetab, $08,$00,$00,$42,$10   ; 2 LEAD2
        !byte $99,$ca, w_lead-wavetab, $08,$0c,$00,$42,$11   ; 3 PAD
        !byte $08,$c6, w_arpmin-wavetab, $06,$28,$00,$12,$01   ; 4 ARPMIN
        !byte $08,$c6, w_arpmaj-wavetab, $06,$28,$00,$12,$01   ; 5 ARPMAJ
        !byte $05,$c5, w_power-wavetab, $06,$38,$05,$11,$01   ; 6 STAB
        !byte $06,$46, w_lead-wavetab, $05,$0a,$00,$31,$01   ; 7 EP
        !byte $16,$c5, w_bkick-wavetab, $08,$00,$00,$21,$23   ; 8 BKICK
        !byte $16,$c5, w_bplain-wavetab, $08,$00,$00,$21,$20   ; 9 BPLAIN
        !byte $19,$e7, w_bplain-wavetab, $08,$00,$00,$21,$20   ; 10 BLONG
        !byte $16,$b5, w_lead-wavetab, $04,$00,$00,$00,$21   ; 11 BPULSE
        !byte $06,$c6, w_bsub-wavetab, $08,$00,$00,$00,$00   ; 12 BSUB
        !byte $07,$64, w_lead-wavetab, $06,$12,$00,$00,$01   ; 13 PLUCK
        !byte $05,$c4, w_stac-wavetab, $06,$50,$05,$12,$01   ; 14 RUN
        !byte $06,$a4, w_bkick-wavetab, $08,$00,$07,$00,$03   ; 15 KICK
        !byte $03,$00, w_hat-wavetab, $08,$00,$02,$00,$00   ; 16 HAT
        !byte $05,$00, w_ohat-wavetab, $08,$00,$08,$00,$00   ; 17 OHAT
        !byte $08,$a0, w_snare-wavetab, $08,$00,$0a,$00,$00   ; 18 SNARE
        !byte $01,$90, w_clap-wavetab, $08,$00,$08,$00,$00   ; 19 CLAP
        !byte $08,$00, w_tom-wavetab, $08,$00,$0a,$00,$00   ; 20 TOM
        !byte $08,$00, w_tomh-wavetab, $08,$00,$08,$00,$00   ; 21 TOMH
        !byte $09,$00, w_toml-wavetab, $08,$00,$0c,$00,$00   ; 22 TOML
        !byte $09,$00, w_crash-wavetab, $08,$00,$1c,$00,$00   ; 23 CRASH
        !byte $a8,$f0, w_riser-wavetab, $08,$00,$00,$00,$00   ; 24 RISER
wavetab:
w_lead:    !byte $41,0
           !byte $ff,w_lead-wavetab
w_brass:   !byte $21,$40|1
w_brass_l: !byte $21,0
           !byte $ff,w_brass_l-wavetab
w_bsub:    !byte $11,0
           !byte $ff,w_bsub-wavetab
w_bkick:   !byte $81,36
           !byte $11,24
           !byte $11,12
w_bkick_l: !byte $11,0
           !byte $ff,w_bkick_l-wavetab
w_bplain:  !byte $11,12
w_bplain_l:!byte $11,0
           !byte $ff,w_bplain_l-wavetab
w_power:   !byte $41,0
           !byte $41,7
           !byte $41,0
           !byte $41,12
           !byte $ff,w_power-wavetab
w_arpmin:  !byte $41,0
           !byte $41,3
           !byte $41,7
           !byte $41,12
           !byte $ff,w_arpmin-wavetab
w_arpmaj:  !byte $41,0
           !byte $41,4
           !byte $41,7
           !byte $41,12
           !byte $ff,w_arpmaj-wavetab
w_stac:    !byte $41,12
           !byte $41,0
w_stac_l:  !byte $41,0
           !byte $ff,w_stac_l-wavetab
w_hat:     !byte $81,$80|82
           !byte $81,$80|80
w_hat_l:   !byte $80,$80|80
           !byte $ff,w_hat_l-wavetab
w_ohat:    !byte $81,$80|82
           !byte $81,$80|81
           !byte $81,$80|80
w_ohat_l:  !byte $81,$80|79
           !byte $ff,w_ohat_l-wavetab
w_snare:   !byte $81,$80|76
           !byte $81,$80|72
           !byte $41,$80|54
w_snare_l: !byte $81,$80|68
           !byte $ff,w_snare_l-wavetab
w_tom:     !byte $11,$80|52
           !byte $11,$80|49
           !byte $11,$80|46
           !byte $11,$80|43
w_tom_l:   !byte $11,$80|40
           !byte $ff,w_tom_l-wavetab
w_tomh:    !byte $11,$80|58
           !byte $11,$80|55
           !byte $11,$80|52
w_tomh_l:  !byte $11,$80|49
           !byte $ff,w_tomh_l-wavetab
w_toml:    !byte $11,$80|46
           !byte $11,$80|43
           !byte $11,$80|40
w_toml_l:  !byte $11,$80|37
           !byte $ff,w_toml_l-wavetab
w_crash:   !byte $81,$80|86
           !byte $81,$80|84
w_crash_l: !byte $81,$80|82
           !byte $ff,w_crash_l-wavetab
w_clap:    !byte $81,$80|70
           !byte $80,$80|70
           !byte $81,$80|68
           !byte $80,$80|68
w_clap_l:  !byte $81,$80|66
           !byte $ff,w_clap_l-wavetab
w_riser:   !byte $81,$80|36
           !byte $81,$80|40
           !byte $81,$80|44
           !byte $81,$80|48
           !byte $81,$80|52
           !byte $81,$80|56
           !byte $81,$80|60
           !byte $81,$80|64
           !byte $81,$80|68
           !byte $81,$80|72
           !byte $81,$80|76
w_riser_l: !byte $81,$80|80
           !byte $ff,w_riser_l-wavetab
mstl:    !byte <s_bass,<s_drum,<s_lead
msth:    !byte >s_bass,>s_drum,>s_lead
mvoff:   !byte 7,0,14
mordtab: !byte 2,0,1


toly:   !byte 5,7,9,12,17,22

; flight paths (game x = sprite centre - 52): start x, per-step delta (8.8 fixed)
startx: !byte 16,48,82,116,150,184,218,248
dlo:    !byte $88,$8e,$86,$7d,$74,$6b,$62,$78
dhi:    !byte $03,$02,$01,$00,$ff,$fe,$fd,$fc



sHint:    !text "PRESS "
          !byte $22
          !text "A"
          !byte $22
          !text " FOR COPYRIGHT NOTICE"
          !byte 0
sFireH:   !text "AIM: KEYS/JOYSTICK   FIRE: S/BUTTON"
          !byte 0
sCopyH:   !text "COPYRIGHT NOTICE"
          !byte 0
sBack:    !text "PRESS ANY KEY TO RETURN"
          !byte 0
cr1:      !text "THIS IS AI SLOP COMPUTING,"
          !byte 0
cr2:      !text "PRESENTING ANOTHER RELEASE."
          !byte 0
cr3:      !text "AI SLOP COMPUTING DOES NOT TAKE ANY"
          !byte 0
cr4:      !text "RESPONSIBILITY ABOUT USERS MENTAL"
          !byte 0
cr5:      !text "HEALTH AFTER USING THIS SOFTWARE."
          !byte 0
cr6:      !text "REMEMBER: COPY RIGHT ."
          !byte 0
cr7:      !text "(LICENSE IS FREEWARE)"
          !byte 0
crlo:     !byte <cr1,<cr2,<cr3,<cr4,<cr5,<cr6,<cr7
crhi:     !byte >cr1,>cr2,>cr3,>cr4,>cr5,>cr6,>cr7

sScore:   !text "SCORE:"
          !byte 0
sHi:      !text "HI:"
          !byte 0
sLevel:   !text "LEVEL:"
          !byte 0
sMiss:    !text "MISS - FAR TARGETS NEED AIM HIGH"
          !byte 0
sBunk:    !text "BUNKER HIT! ARMOR LEFT: "
          !byte 0
sAmmo:    !text "AMMO:"
          !byte 0
sHitsC:   !text "HITS:"
          !byte 0
sBunkH:   !text "BUNKER:"
          !byte 0
sTgt:     !text "AIR:"
          !byte 0
sGun:     !text "GUN "
          !byte 0
sCtl:     !text "CONTROL: "
          !byte 0
sJoy:     !text "=JOYSTICK  "
          !byte 0
sKey:     !text "=KEYBOARD"
          !byte 0
sMus:     !text "MUSIC: "
          !byte 0
sOn:      !text "ON "
          !byte 0
sOff:     !text "OFF"
          !byte 0
sMusT:    !text "   (PRESS T TO TOGGLE)"
          !byte 0
sHotMsg:  !text "GUN TUBE OVERHEATED!"
          !byte 0
sWild:    !text "OVERHEATED GUN - SHOT WENT WILD"
          !byte 0
sGO3:     !text "YOU RAN OUT OF AMMO!"
          !byte 0
sTotH:    !text "TOTAL HITS:    "
          !byte 0
sHit:     !text "DIRECT HIT! +5 AMMO"
          !byte 0
sKill:    !text "TARGET DESTROYED!"
          !byte 0
sLvl:     !text "LEVEL UP! SPEED X2   +3 ARMOR"
          !byte 0
sLvl2:    !text "LEVEL UP! +1 AIRCRAFT +1 ARMOR"
          !byte 0
sUpg:     !text "UPGRADE! TWIN SHOTS, 2X COOLING"
          !byte 0
sGO:      !text "G A M E   O V E R"
          !byte 0
sGO2:     !text "THE BUNKER WAS DESTROYED!"
          !byte 0
sFinal:   !text "FINAL SCORE:  "
          !byte 0
sHigh:    !text "HIGH SCORE:   "
          !byte 0
sLvlR:    !text "LEVEL REACHED: "
          !byte 0
sKills:   !text "TARGETS DOWN:  "
          !byte 0
sAgain:   !text "PRESS SPACE TO PLAY AGAIN"
          !byte 0
sQuit:    !text "PRESS Q TO QUIT"
          !byte 0

; title screen table: column,row,colour,text lo,text hi
ttab:     !byte 12,2,7,<t0,>t0
          !byte 1,4,1,<t1,>t1
          !byte 3,5,15,<t2,>t2
          !byte 5,7,5,<t3,>t3
          !byte 6,8,5,<t3b,>t3b
          !byte 4,10,15,<t4,>t4
          !byte 4,11,15,<t5,>t5
          !byte 1,12,10,<t6,>t6
          !byte 1,14,15,<t7,>t7
          !byte 4,15,15,<t8,>t8
          !byte 4,16,15,<t9,>t9
          !byte 1,17,10,<t11,>t11
          !byte 4,18,5,<t12,>t12
          !byte 6,19,7,<t10,>t10
          !byte 5,20,3,<t13,>t13
          !byte $ff
t0:       !text "BUNKER DEFENDER"
          !byte 0
t1:       !text "YOU ARE INSIDE AN AIR DEFENSE BUNKER."
          !byte 0
t2:       !text "TARGETS APPROACH FROM THE HORIZON."
          !byte 0
t3:       !text "AIM: IJKL, CURSORS OR JOYSTICK"
          !byte 0
t3b:      !text "FIRE: S OR JOYSTICK BUTTON"
          !byte 0
t4:       !text "UPPER LINE = AIM AT NEAR TARGETS"
          !byte 0
t5:       !text "LOWER LINE = AIM AT FAR TARGETS"
          !byte 0
t6:       !text "BULLETS DROP - AIM HIGH AT FAR TARGETS"
          !byte 0
t7:       !text "60 AMMO, +5 PER HIT, BONUS 2 X LEVEL"
          !byte 0
t8:       !text "EACH TARGET NEEDS 3 HITS"
          !byte 0
t9:       !text "3 KILLS = TARGETS FLY 2X FASTER"
          !byte 0
t11:      !text "GUN OVERHEATS AT 500C: SHOTS GO WILD"
          !byte 0
t12:      !text "BUNKER ARMOR 3, +3/+1 PER LEVEL UP"
          !byte 0
t13:      !text "PRESS M FOR MISSION OBJECTIVES"
          !byte 0
t10:      !text "PRESS ANY OTHER KEY TO START"
          !byte 0

; mission objectives screen: column,row,colour,text lo,text hi
mtab:     !byte 10,3,7,<m0,>m0
          !byte 2,6,1,<m1,>m1
          !byte 2,7,1,<m2,>m2
          !byte 2,9,1,<m3,>m3
          !byte 2,10,1,<m4,>m4
          !byte 2,11,1,<m5,>m5
          !byte 2,13,1,<m6,>m6
          !byte 2,14,1,<m7,>m7
          !byte $ff
m0:       !text "MISSION OBJECTIVES."
          !byte 0
m1:       !text "YOUR MISSION IS TO INTERCEPT HOSTILE"
          !byte 0
m2:       !text "AIRCRAFTS."
          !byte 0
m3:       !text "IF ACTION IS SUCCESFUL, YOU ARE"
          !byte 0
m4:       !text "AWARDED BY EQUIPMENT UPGRADES AND"
          !byte 0
m5:       !text "BONUS POINTS."
          !byte 0
m6:       !text "KEEP TUBE TEMPERATURE IN CONTROL,"
          !byte 0
m7:       !text "OR ACCURACY WILL SUFFER."
          !byte 0

; ---- variables ---------------------------------------------
col:      !byte 1
dirty:    !byte 0
state:    !byte 0
timer:    !byte 0
hits:     !byte 0
prog:     !byte 0,0
step:     !byte 0
spdlo:    !byte 0
spdhi:    !byte 0
smult:    !byte 1
level:    !byte 1
kills:    !byte 0
k3:       !byte 0
cooldown: !byte 0
flash:    !byte 0
msgt:     !byte 0
bph:      !byte 0
ax:       !byte 172
ay:       !byte 120
iy:       !byte 0
drop:     !byte 0
ammo:     !byte 60
ix:       !byte 0
musicon:  !byte 1
mtick:    !byte 1
mpos:     !byte 0
mfr:      !byte 0
fenv:     !byte 0
kact:     !byte 0
kf:       !byte 0
sfxt:     !byte 0
ledlo:    !byte 0
ledhi:    !byte 0
vd:       !byte 0
vdh:      !byte 0
templo:   !byte 20
temphi:   !byte 0
hot:      !byte 0
coolc:    !byte 0
tdirty:   !byte 0
hitscore: !byte $12
t16lo:    !byte 0
t16hi:    !byte 0
thun:     !byte 0
trem:     !byte 0
ncell:    !byte 0
cidx:     !byte 0
hitcnt:   !byte 0
bunkhp:   !byte 3
goreason: !byte 0
cbt:      !byte 0
cbs:      !byte 0
cbo:      !byte 0
tmp2:     !byte 0
tmp3:     !byte 0
kb0:      !byte 0
kb1:      !byte 0
kb4:      !byte 0
kb5:      !byte 0
kb6:      !byte 0
bp:       !fill 12, 0
tcx:      !byte 0
tcy:      !byte 0
hx:       !byte 0
hy:       !byte 0
tmp:      !byte 0
score0:   !byte 0
score1:   !byte 0
score2:   !byte 0
hi0:      !byte 0
hi1:      !byte 0
hi2:      !byte 0
addlo:    !byte 0
addhi:    !byte 0
bonlo:    !byte $50
bonhi:    !byte 0
xl:       !byte 0
xh:       !byte 0
pidx:     !byte 0
srow:     !byte 0
scol:     !byte 0
scnt:     !byte 0
scc:      !byte 0
sidx:     !byte 0
rr:       !byte 0
mlo:      !byte 0
mhi:      !byte 0
hdig:     !byte 0
tdig:     !byte 0
odig:     !byte 0
dly:      !byte 0
cri:      !byte 0
sprsave:  !byte 0
tpath:    !fill 120, 0
tstate:   !fill 5, 0
ttimer:   !fill 5, 0
thits:    !fill 5, 0
tprl:     !fill 5, 0
tprh:     !fill 5, 0
tstepv:   !fill 5, 0
ttcx:     !fill 5, 0
ttcy:     !fill 5, 0
tsn:      !byte 0,3,4,5,6
tsn2:     !byte 0,6,8,10,12
tbit:     !byte $01,$08,$10,$20,$40
pbtab:    !byte 0,24,48,72,96
tinit:    !byte 60,100,140,180,220
sprd:     !byte $fc,$04
ti:       !byte 0
sn2:      !byte 0
sbit:     !byte 1
snum:     !byte 0
pbase:    !byte 0
pz:       !byte 0
pcnt:     !byte 0
ntarg:    !byte 1
gover:    !byte 0
sdx:      !byte 0
sdy:      !byte 0
nrnd:     !byte 1
spread:   !byte 0
refdrop:  !byte 0
refset:   !byte 0
hfound:   !byte 0
hity:     !byte 0
bbase:    !byte 0
shf:      !byte 0
spgx:     !byte 0
sphw:     !byte 0
spn:      !byte 0
sph:      !byte 0
spt:      !byte 0
bittab:   !byte 1,2,4,8,16,32,64,128
shx:      !byte 0
shy:      !byte 0
shvy:     !byte 0
rowlo:    !fill 25, 0
rowhi:    !fill 25, 0
arlo:     !fill 25, 0
arhi:     !fill 25, 0
ctl:      !byte 0
redrawv:  !byte 0,0
pcx:      !byte 0
pcode:    !byte 0
pinv:     !byte 0
t8lo:     !byte 0
t8hi:     !byte 0
ctail:    !byte 0

; ---- pixel artwork and sprite shapes ------------------------
* = $3000
bgbmp:
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 90,244,173,185,191,86,239,220,4,121,0,1,34,163,4,0
        !byte 110,222,186,253,221,189,22,31,7,136,252,42,35,44,235,33
        !byte 1,68,26,20,184,2,1,98,68,67,32,194,17,19,210,0
        !byte 61,238,173,201,241,215,238,255,8,64,33,14,66,154,17,64
        !byte 103,226,59,213,223,219,54,223,32,194,14,33,129,64,182,8
        !byte 54,115,59,250,213,190,247,215,10,129,132,2,2,35,44,82
        !byte 96,144,13,134,34,66,49,35,1,97,226,51,32,54,224,2
        !byte 23,93,95,245,183,127,107,236,41,39,78,2,72,64,32,85
        !byte 6,75,155,64,162,36,115,210,93,103,114,149,233,125,112,159
        !byte 32,20,194,44,52,36,245,22,13,180,128,100,164,2,234,200
        !byte 33,42,76,40,68,26,49,130,1,36,0,85,160,144,0,229
        !byte 120,16,1,6,70,6,3,192,73,4,200,32,32,60,217,120
        !byte 60,93,81,1,160,194,0,242,10,48,32,8,17,82,128,136
        !byte 96,128,1,171,34,160,4,24,16,157,1,2,66,26,137,35
        !byte 121,113,54,223,223,221,50,119,62,8,166,37,52,25,100,246
        !byte 42,128,45,82,1,32,226,1,64,48,16,113,64,35,108,196
        !byte 20,14,13,10,26,202,161,87,83,32,220,32,42,36,230,96
        !byte 97,191,222,255,167,126,50,239,100,16,83,236,204,1,192,122
        !byte 71,215,251,243,255,95,79,255,44,223,75,199,199,246,223,219
        !byte 2,136,27,17,36,242,161,19,104,32,12,84,4,109,85,8
        !byte 0,170,68,170,85,251,221,255,0,170,68,170,85,251,221,255
        !byte 0,170,68,170,85,251,221,255,0,170,68,170,85,251,221,255
        !byte 0,170,68,170,85,251,221,255,0,170,68,170,85,251,221,255
        !byte 0,170,68,170,85,251,221,255,0,170,68,170,85,251,221,255
        !byte 0,170,68,170,85,251,221,255,0,170,68,170,85,251,221,255
        !byte 0,170,68,170,85,251,221,255,0,170,68,170,85,251,221,255
        !byte 0,170,68,170,85,251,221,255,0,170,68,170,85,251,221,255
        !byte 0,170,68,170,85,251,221,255,0,170,68,170,85,251,221,255
        !byte 0,170,68,170,85,251,221,255,0,170,68,170,85,251,221,255
        !byte 0,170,68,170,85,251,221,255,0,170,68,170,85,251,221,255
        !byte 0,170,68,170,85,251,221,255,0,170,68,170,85,251,221,255
        !byte 0,170,68,170,85,251,221,255,0,170,68,170,85,251,221,255
        !byte 0,170,68,170,85,251,221,255,0,170,68,170,85,251,221,255
        !byte 0,170,68,170,85,251,221,255,0,170,68,170,85,251,221,255
        !byte 0,170,68,170,85,251,221,255,0,170,68,170,85,251,221,255
        !byte 0,170,68,170,85,251,221,255,0,170,68,170,85,251,221,255
        !byte 0,170,68,170,85,251,221,255,0,170,68,170,85,251,221,255
        !byte 0,170,68,170,85,251,221,255,0,170,68,170,85,251,221,255
        !byte 0,170,68,170,85,251,221,255,0,170,68,170,85,251,221,255
        !byte 0,170,68,170,85,251,221,255,0,170,68,170,85,251,221,255
        !byte 123,191,219,175,239,118,157,0,112,56,148,49,88,112,22,255
        !byte 47,5,43,21,47,5,43,21,85,187,85,255,85,255,93,255
        !byte 127,255,255,255,127,255,255,255,0,0,0,0,136,0,34,0
        !byte 0,0,0,0,136,0,34,0,0,0,0,0,136,0,34,0
        !byte 0,0,0,0,136,0,34,0,0,0,0,0,136,0,34,0
        !byte 0,0,0,0,136,0,34,0,0,0,0,0,136,0,34,0
        !byte 0,0,0,0,136,0,34,0,0,0,0,0,136,0,34,0
        !byte 0,0,0,0,136,0,34,0,0,0,0,0,136,0,34,0
        !byte 0,0,0,0,136,0,34,0,0,0,0,0,136,0,34,0
        !byte 0,0,0,0,136,0,34,0,0,0,0,0,136,0,34,0
        !byte 0,0,0,0,136,0,34,0,0,0,0,0,136,0,34,0
        !byte 0,0,0,0,136,0,34,0,0,0,0,0,136,0,34,0
        !byte 0,0,0,0,136,0,34,0,0,0,0,0,136,0,34,0
        !byte 0,0,0,0,0,0,31,127,0,0,0,0,0,0,192,224
        !byte 0,0,0,0,136,0,34,0,0,0,0,0,136,0,34,0
        !byte 0,0,0,0,136,0,34,0,0,0,0,0,136,0,34,0
        !byte 0,0,0,0,136,0,34,0,0,0,0,0,136,0,34,0
        !byte 0,0,0,0,136,0,34,0,0,0,0,0,136,0,34,0
        !byte 85,251,213,255,85,251,221,255,47,5,43,21,47,5,43,21
        !byte 17,4,24,175,144,52,32,255,75,79,203,226,239,232,205,0
        !byte 96,145,31,2,10,162,89,9,45,3,38,205,203,207,45,233
        !byte 47,5,43,21,47,5,43,21,34,64,170,16,170,69,170,21
        !byte 85,191,85,239,85,186,85,234,85,191,85,239,85,186,85,234
        !byte 85,191,85,239,85,186,85,234,85,191,85,239,85,186,85,234
        !byte 0,0,0,3,63,127,255,255,0,0,32,252,254,255,255,255
        !byte 85,191,85,239,85,186,85,106,85,191,85,239,85,186,85,234
        !byte 85,191,85,239,85,186,85,234,85,191,85,239,85,186,85,234
        !byte 85,191,85,239,85,186,85,234,85,191,85,239,85,186,85,234
        !byte 85,191,85,239,85,186,85,234,85,191,85,239,85,186,85,234
        !byte 85,191,85,239,85,186,85,234,85,191,85,239,85,186,85,234
        !byte 85,191,85,239,85,186,85,234,85,191,85,239,85,186,85,234
        !byte 85,191,85,239,85,186,85,234,85,191,85,239,85,186,85,234
        !byte 0,0,0,0,0,7,15,15,0,1,31,63,127,255,255,255
        !byte 0,0,0,15,15,3,62,63,31,3,1,224,192,128,0,252
        !byte 0,0,0,0,0,240,248,248,85,191,85,239,85,186,85,234
        !byte 85,191,85,239,85,186,85,234,85,191,85,239,85,186,85,226
        !byte 0,0,0,162,21,151,47,127,0,0,0,160,16,120,148,240
        !byte 85,191,85,239,85,186,85,106,85,191,85,239,85,186,85,234
        !byte 93,191,85,239,85,186,85,234,47,5,43,21,47,5,43,21
        !byte 53,247,248,103,71,247,168,223,89,16,17,145,148,154,56,26
        !byte 10,7,157,127,246,217,182,0,8,53,228,73,136,164,144,255
        !byte 47,5,43,21,47,5,43,21,85,170,85,170,17,170,68,170
        !byte 85,170,85,170,17,170,68,170,85,170,85,170,17,170,68,170
        !byte 0,0,0,1,19,255,255,255,11,127,255,255,255,255,255,255
        !byte 0,0,7,7,3,1,0,15,0,0,255,255,254,252,32,192
        !byte 15,7,3,1,1,0,0,0,0,0,0,0,64,248,252,252
        !byte 85,170,85,170,17,170,68,170,85,170,85,170,17,170,68,170
        !byte 85,170,85,170,17,170,68,170,85,170,85,170,17,170,68,170
        !byte 85,170,85,170,17,170,68,170,85,170,85,170,17,170,68,170
        !byte 85,170,85,170,17,170,68,170,85,170,85,170,17,170,68,170
        !byte 85,170,85,170,17,170,68,170,85,170,85,170,17,170,68,170
        !byte 85,170,85,170,17,170,68,170,85,170,85,170,17,170,68,170
        !byte 80,160,80,170,17,170,68,170,0,0,0,170,17,170,68,170
        !byte 0,0,65,170,17,170,68,170,0,0,68,170,17,170,68,170
        !byte 7,255,255,255,255,255,255,255,85,170,85,170,17,170,68,170
        !byte 85,170,85,170,17,170,68,170,1,9,3,43,19,43,7,15
        !byte 0,0,0,2,15,15,31,15,7,4,0,3,1,0,1,1
        !byte 85,170,21,170,17,138,68,10,85,170,85,170,17,170,68,170
        !byte 85,170,85,170,17,170,68,170,47,5,43,21,47,5,43,21
        !byte 8,16,248,85,30,72,128,255,31,208,8,10,17,48,45,255
        !byte 36,4,224,112,10,11,24,171,125,123,107,127,156,255,223,110
        !byte 47,5,43,21,47,5,43,21,0,42,0,138,0,32,0,128
        !byte 0,42,0,138,0,32,0,128,1,3,1,0,0,0,0,0
        !byte 0,0,0,255,255,255,255,255,0,127,255,255,255,255,255,255
        !byte 0,0,0,0,64,253,255,255,0,0,0,0,24,255,255,255
        !byte 7,15,7,0,0,0,0,0,3,1,3,255,255,255,255,255
        !byte 0,42,0,138,0,32,0,128,0,42,0,138,0,32,0,128
        !byte 0,42,0,138,0,32,0,128,0,42,0,138,0,32,0,128
        !byte 0,42,0,138,0,32,0,128,0,42,0,138,0,32,0,128
        !byte 0,42,0,138,0,32,0,128,0,42,0,138,0,32,0,128
        !byte 0,42,0,138,0,32,0,128,0,42,0,138,0,32,0,128
        !byte 0,42,0,138,0,32,0,128,0,42,0,138,0,32,0,128
        !byte 0,42,0,138,0,32,0,128,0,42,0,138,0,32,0,128
        !byte 0,42,0,138,0,32,0,128,0,42,0,138,0,32,0,128
        !byte 0,42,0,138,0,32,0,128,0,42,0,138,0,32,0,128
        !byte 0,42,0,138,0,32,0,128,23,47,5,7,5,3,1,2
        !byte 0,0,0,0,0,64,176,203,0,3,2,3,6,7,75,29
        !byte 0,160,64,128,0,128,0,0,0,42,0,138,0,32,0,128
        !byte 0,42,0,138,0,32,0,128,47,5,43,21,47,5,43,21
        !byte 43,39,223,58,255,89,223,86,63,222,177,247,207,86,49,118
        !byte 32,70,235,20,2,0,1,255,45,102,108,227,205,111,239,0
        !byte 47,5,43,21,47,5,43,21,0,0,0,0,136,0,34,0
        !byte 0,0,0,0,136,0,34,0,0,0,0,0,0,0,3,15
        !byte 0,0,0,0,0,0,0,128,0,0,0,0,136,0,34,0
        !byte 0,0,0,0,136,0,34,0,0,0,0,0,136,0,34,0
        !byte 0,0,0,0,136,0,34,0,0,0,0,0,136,0,34,0
        !byte 0,0,0,0,136,0,34,0,0,0,0,0,136,0,34,0
        !byte 0,0,0,0,136,0,34,0,0,0,0,0,136,0,34,0
        !byte 0,0,0,0,136,0,34,0,0,0,0,0,136,0,34,0
        !byte 0,0,0,0,0,7,31,127,0,0,0,0,0,248,252,252
        !byte 0,0,0,0,136,0,34,0,0,0,0,0,136,0,34,0
        !byte 0,0,0,0,136,0,34,0,0,0,0,0,136,0,34,0
        !byte 0,0,0,0,136,0,34,0,0,0,0,0,136,0,34,0
        !byte 0,0,0,0,136,0,34,0,0,0,0,0,136,0,34,0
        !byte 0,0,0,0,136,0,34,0,0,0,0,0,136,0,34,0
        !byte 0,0,0,0,136,0,34,0,0,0,0,0,136,0,34,0
        !byte 21,2,0,0,0,0,0,0,0,0,0,0,0,0,1,3
        !byte 0,0,0,0,48,252,238,86,0,0,0,0,136,0,34,0
        !byte 0,0,0,0,136,0,34,0,47,5,43,21,47,5,43,21
        !byte 3,146,39,48,36,10,8,255,56,81,178,144,22,16,18,255
        !byte 126,251,146,249,221,121,186,143,82,176,216,48,56,57,240,84
        !byte 47,5,43,21,47,5,43,21,0,0,0,0,128,192,192,96
        !byte 85,191,85,239,85,186,85,234,30,21,42,116,96,192,160,64
        !byte 63,159,79,167,215,235,241,248,85,191,85,239,85,186,85,234
        !byte 85,191,85,239,85,186,85,234,85,191,85,239,85,186,85,234
        !byte 85,191,85,239,85,186,85,234,85,191,85,239,85,186,85,234
        !byte 85,191,85,239,85,186,85,234,85,191,85,239,85,186,85,234
        !byte 85,191,85,239,85,186,85,234,85,191,85,239,85,186,85,234
        !byte 0,0,0,0,0,7,15,31,0,7,31,63,127,255,255,255
        !byte 128,0,0,7,3,1,15,15,1,0,0,252,248,240,128,128
        !byte 0,192,224,224,240,255,255,255,85,191,85,239,85,186,85,42
        !byte 85,191,85,239,85,186,85,234,85,191,85,239,85,186,85,234
        !byte 85,191,85,239,85,186,85,234,85,191,85,239,85,186,85,234
        !byte 85,191,85,239,85,186,85,234,85,191,85,239,85,186,85,234
        !byte 85,191,85,239,85,186,85,234,85,191,85,239,85,186,85,234
        !byte 85,191,85,239,85,186,85,234,0,0,1,3,2,5,6,12
        !byte 135,0,80,170,85,250,255,255,14,253,250,84,168,80,0,0
        !byte 84,186,253,254,255,255,255,255,0,0,128,128,192,64,128,96
        !byte 85,191,85,239,85,186,85,234,47,5,43,21,47,5,43,21
        !byte 79,255,160,231,183,231,248,214,35,207,199,79,96,72,169,175
        !byte 4,65,101,26,25,225,0,255,68,160,90,6,0,3,2,255
        !byte 47,5,43,21,47,5,43,21,79,175,215,227,243,249,244,250
        !byte 1,3,2,5,14,28,248,244,0,33,0,1,0,1,2,5
        !byte 3,5,2,1,0,0,0,0,127,0,0,170,85,170,255,255
        !byte 0,128,224,112,176,88,40,20,85,170,85,170,17,170,68,170
        !byte 85,170,85,170,17,170,68,170,85,170,85,170,17,170,68,170
        !byte 85,170,85,170,17,170,68,170,85,170,85,170,17,170,68,170
        !byte 85,170,85,170,17,170,68,138,85,170,85,170,17,170,68,170
        !byte 31,31,0,0,0,0,0,0,31,31,255,255,255,255,255,255
        !byte 0,0,0,16,238,85,187,85,254,252,249,250,245,227,231,207
        !byte 0,0,79,167,87,235,243,249,21,42,85,170,17,170,68,170
        !byte 85,170,85,170,17,170,68,170,85,170,85,170,17,170,68,170
        !byte 85,170,85,170,17,170,68,170,85,170,85,170,17,170,68,170
        !byte 85,170,85,170,17,170,68,170,85,170,85,170,17,170,68,170
        !byte 85,170,85,170,17,170,68,170,85,170,85,170,17,170,68,170
        !byte 85,170,85,170,17,170,68,170,8,4,24,16,0,48,32,0
        !byte 10,5,10,5,10,5,27,37,0,0,2,128,0,0,9,3
        !byte 10,5,10,53,74,151,46,77,32,16,48,16,8,24,12,4
        !byte 85,170,85,170,17,170,68,170,47,5,43,21,47,5,43,21
        !byte 0,130,119,164,48,70,107,255,8,160,148,95,12,17,76,255
        !byte 40,184,0,36,36,5,16,162,0,157,37,141,65,58,51,49
        !byte 47,5,43,21,47,5,43,21,87,171,85,170,21,42,85,168
        !byte 87,175,95,255,255,255,255,255,41,27,38,73,146,37,105,147
        !byte 85,170,69,138,21,32,17,162,95,183,95,191,95,61,95,191
        !byte 12,6,2,5,3,1,0,1,0,42,0,138,0,32,128,159
        !byte 0,42,0,138,0,32,0,128,0,42,0,138,0,32,0,128
        !byte 0,42,0,138,0,32,0,128,0,1,1,3,2,1,2,0
        !byte 7,35,81,169,117,251,253,255,0,42,0,138,0,32,128,192
        !byte 0,42,0,138,0,32,0,129,0,42,0,138,28,127,255,255
        !byte 0,42,0,138,1,35,255,255,215,175,31,63,127,191,127,255
        !byte 2,4,3,1,0,1,0,0,0,42,0,138,128,160,128,192
        !byte 0,42,0,138,0,32,0,128,0,42,0,138,0,32,0,128
        !byte 0,42,0,138,0,32,0,128,0,42,0,138,0,32,0,128
        !byte 0,42,0,138,0,32,0,128,0,42,0,138,0,32,0,128
        !byte 0,42,0,138,0,32,0,128,0,42,0,138,0,36,31,191
        !byte 0,42,0,138,0,33,1,129,159,191,255,63,127,255,127,255
        !byte 75,151,46,77,154,53,75,159,36,73,146,44,109,146,36,73
        !byte 69,218,180,104,209,178,37,210,10,6,3,1,2,1,0,0
        !byte 0,0,1,131,130,1,130,0,47,5,43,21,47,5,43,21
        !byte 32,132,11,4,128,192,70,34,64,64,65,78,0,196,75,18
        !byte 10,11,199,0,72,120,136,255,16,60,52,48,180,157,84,255
        !byte 47,5,43,21,47,5,43,21,5,138,21,42,65,162,69,10
        !byte 126,189,123,246,109,217,54,109,44,89,146,37,73,147,36,73
        !byte 69,138,20,40,81,162,69,139,22,45,90,182,73,155,22,173
        !byte 85,170,69,138,21,43,81,163,130,65,130,1,2,1,2,1
        !byte 128,224,255,255,255,255,255,255,0,0,192,240,248,255,255,255
        !byte 255,254,222,224,64,193,255,255,159,63,63,127,255,255,255,255
        !byte 10,85,10,21,14,21,42,93,0,0,0,12,6,6,0,0
        !byte 3,3,7,15,31,63,127,255,2,5,2,5,66,13,2,5
        !byte 160,79,175,95,191,127,191,127,1,255,255,255,255,255,255,255
        !byte 10,5,10,5,10,5,10,5,127,191,95,143,95,47,23,43
        !byte 0,0,32,0,138,0,170,0,0,0,32,0,138,0,170,0
        !byte 0,0,32,0,138,0,170,0,0,0,32,0,138,0,168,0
        !byte 0,0,0,0,224,248,252,254,0,0,32,0,138,0,168,0
        !byte 0,0,1,3,31,255,255,255,2,1,2,1,2,1,2,1
        !byte 127,63,63,31,31,7,9,7,9,18,4,9,18,36,9,18
        !byte 47,77,154,37,75,151,46,77,105,219,180,109,219,178,108,219
        !byte 75,151,46,93,218,37,75,151,85,42,69,138,21,42,81,162
        !byte 31,191,95,190,31,143,93,191,47,5,43,21,47,5,43,21
        !byte 49,106,147,90,3,2,5,255,107,235,235,199,143,102,193,0
        !byte 36,163,35,66,198,30,183,68,21,16,208,52,52,49,212,144
        !byte 47,5,43,21,47,5,43,21,20,40,65,162,69,138,20,40
        !byte 27,178,109,219,55,111,87,167,105,218,166,108,255,255,255,255
        !byte 23,47,95,255,255,255,255,255,91,166,85,171,84,170,87,175
        !byte 71,15,23,47,95,255,255,255,2,1,2,1,2,1,11,19
        !byte 87,175,87,175,87,175,87,175,42,21,42,21,42,21,42,21
        !byte 93,175,95,175,31,175,87,175,0,5,2,4,1,42,4,8
        !byte 101,202,181,104,209,226,213,232,85,171,85,171,87,191,255,255
        !byte 0,0,128,225,240,248,253,255,2,69,2,20,38,76,144,40
        !byte 127,255,255,255,255,255,255,255,0,0,0,0,0,0,0,1
        !byte 10,5,10,5,10,5,26,37,85,170,85,170,84,170,85,170
        !byte 85,187,213,255,255,255,255,255,85,187,85,238,253,254,255,255
        !byte 85,187,85,174,87,175,255,255,87,191,95,175,255,255,255,255
        !byte 46,21,42,21,42,21,42,21,87,191,223,255,255,255,255,255
        !byte 0,0,0,0,0,0,0,0,2,1,2,1,6,9,18,32
        !byte 87,171,85,170,85,170,85,170,37,79,151,47,255,255,255,255
        !byte 10,21,11,21,10,21,10,21,73,150,39,207,255,255,255,255
        !byte 209,178,229,250,252,248,253,254,69,10,20,40,81,34,69,138
        !byte 93,191,95,190,77,155,23,46,47,5,43,21,47,5,43,21
        !byte 4,92,47,8,200,168,23,1,20,54,17,177,242,149,48,84
        !byte 127,27,79,178,222,223,218,0,127,175,20,175,235,156,254,0
        !byte 47,5,43,21,47,5,43,21,0,0,0,224,240,248,252,252
        !byte 144,32,192,128,128,0,0,255,0,0,15,62,127,254,255,0
        !byte 0,0,0,191,95,191,95,0,31,127,255,255,255,255,127,0
        !byte 95,171,85,170,85,170,85,255,0,0,0,1,127,191,127,0
        !byte 0,0,0,240,252,255,223,0,42,149,42,93,186,53,106,255
        !byte 0,1,7,15,63,127,255,0,0,192,208,235,215,235,215,0
        !byte 7,31,127,255,255,255,255,0,40,20,42,21,42,21,42,0
        !byte 42,85,42,21,10,2,2,255,0,0,0,12,253,254,253,0
        !byte 4,9,18,4,9,18,4,255,109,219,183,111,223,191,127,0
        !byte 0,4,10,5,10,5,10,0,1,7,255,255,255,255,255,0
        !byte 2,5,2,5,2,5,2,0,0,0,128,64,168,84,138,0
        !byte 0,0,0,0,15,127,255,0,40,84,42,85,42,5,2,255
        !byte 42,53,43,87,187,255,238,255,2,1,2,1,2,1,2,0
        !byte 0,64,160,80,160,80,160,0,63,255,255,255,255,255,253,0
        !byte 127,191,95,175,87,170,85,255,127,255,127,255,127,255,255,0
        !byte 10,21,10,21,2,1,0,255,127,191,127,191,127,191,127,0
        !byte 7,31,63,127,255,255,255,0,75,175,85,171,85,171,85,255
        !byte 15,63,255,255,255,255,255,127,47,5,43,21,47,5,43,21
        !byte 38,255,223,127,248,93,207,0,0,20,38,0,132,137,65,255
        !byte 102,247,250,175,255,239,222,254,10,156,224,33,45,160,144,2
        !byte 47,5,43,21,47,5,43,21,2,2,34,0,170,68,170,21
        !byte 0,0,34,0,170,68,170,21,0,0,34,0,170,68,169,16
        !byte 0,0,34,0,2,0,95,14,128,128,34,0,170,68,170,31
        !byte 0,0,34,0,170,68,1,224,0,0,0,95,142,255,254,63
        !byte 32,32,2,124,186,255,127,252,0,0,34,0,129,129,240,63
        !byte 0,0,34,0,240,248,31,192,8,8,34,30,124,31,192,63
        !byte 0,0,33,30,31,129,254,1,0,0,199,31,7,248,3,61
        !byte 2,25,14,15,193,30,232,5,1,204,56,15,240,5,46,117
        !byte 109,230,241,14,248,192,162,21,45,50,198,8,186,100,170,255
        !byte 130,37,49,8,46,70,42,255,0,164,204,56,143,68,162,20
        !byte 0,176,102,113,135,192,186,23,32,0,51,199,135,124,11,16
        !byte 0,0,128,142,131,15,224,31,0,0,31,63,207,131,63,1
        !byte 8,73,192,255,255,255,11,126,0,224,226,64,192,248,240,3
        !byte 0,0,34,0,0,62,63,248,2,2,34,0,170,0,3,0
        !byte 0,0,34,0,170,4,176,0,0,0,34,0,170,68,0,63
        !byte 0,0,34,0,170,64,40,143,128,128,2,0,0,254,127,255
        !byte 0,0,34,0,10,4,250,245,0,0,34,0,170,68,170,21
        !byte 0,0,34,0,170,68,170,21,47,5,43,21,47,5,43,21
        !byte 41,2,4,16,49,32,0,135,118,255,77,244,243,221,210,211
        !byte 21,64,38,12,0,4,72,255,50,17,20,155,188,20,24,255
        !byte 47,5,43,21,47,5,43,21,17,191,0,255,0,47,240,0
        !byte 17,224,63,192,7,250,0,0,28,255,7,255,3,255,254,1
        !byte 31,241,254,225,255,220,3,255,0,255,0,127,252,1,255,255
        !byte 127,0,191,208,7,223,255,252,127,128,15,250,0,34,31,224
        !byte 63,208,11,255,252,129,127,255,31,233,7,168,240,32,0,0
        !byte 47,244,0,147,31,143,255,240,31,250,240,26,1,14,0,0
        !byte 47,253,184,65,31,221,255,252,19,190,196,168,0,2,0,0
        !byte 111,93,251,213,255,220,243,207,17,174,92,170,192,34,0,0
        !byte 110,85,187,85,255,221,255,255,47,21,9,21,47,1,43,21
        !byte 23,47,221,175,23,251,21,175,17,170,68,170,0,34,0,0
        !byte 46,69,179,85,254,221,255,255,17,162,64,170,128,98,24,6
        !byte 15,65,186,245,255,223,255,255,1,160,228,190,3,34,0,0
        !byte 7,208,251,87,63,193,252,255,1,232,127,42,0,32,128,120
        !byte 3,244,191,5,248,253,255,255,127,15,15,128,224,48,0,0
        !byte 3,123,127,252,255,253,3,252,3,255,0,250,15,2,0,224
        !byte 7,255,129,255,31,192,255,255,0,62,192,191,0,226,31,0
        !byte 15,128,15,224,31,0,192,63,46,192,3,254,15,208,255,127
        !byte 17,254,1,255,0,250,7,0,47,5,43,21,47,5,43,21
        !byte 6,38,197,25,38,36,10,255,80,147,146,24,24,48,57,255
        !byte 59,255,82,243,205,254,187,242,24,208,115,24,209,176,16,176
        !byte 47,5,43,21,47,5,43,21,87,255,93,255,85,187,85,255
        !byte 0,255,255,255,255,248,7,255,0,0,0,0,63,192,0,0
        !byte 0,0,7,248,0,0,0,0,0,31,254,62,127,62,62,8
        !byte 3,255,255,255,255,255,255,255,0,0,0,0,0,3,60,192
        !byte 0,0,0,7,56,192,0,0,0,7,120,128,0,0,0,0
        !byte 47,255,255,255,255,255,255,255,0,0,0,0,0,0,0,0
        !byte 3,0,0,0,0,1,6,8,0,1,6,24,96,128,0,0
        !byte 63,255,255,255,255,255,255,255,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,47,21,43,21,0,5,43,21
        !byte 23,47,21,175,255,43,21,175,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,1,0,0,0,0,0,0,0
        !byte 127,191,207,243,252,255,255,255,4,31,31,63,31,223,52,8
        !byte 0,0,0,128,0,0,0,0,7,0,0,0,0,0,0,0
        !byte 127,143,240,255,255,255,255,255,0,0,0,240,14,1,0,0
        !byte 0,0,0,0,0,224,30,1,31,0,0,0,0,0,0,128
        !byte 127,131,252,255,255,255,255,255,0,0,240,15,0,0,0,0
        !byte 0,0,0,128,126,1,0,0,127,0,0,0,0,240,15,0
        !byte 117,255,213,255,85,251,213,255,47,5,43,21,47,5,43,21
        !byte 8,198,16,8,0,12,156,30,7,231,111,207,236,230,227,239
        !byte 0,127,127,0,0,0,0,0,0,222,189,123,247,239,222,0
        !byte 0,7,7,0,0,0,0,0,255,7,7,255,255,255,255,255
        !byte 252,254,254,254,254,254,254,252,0,127,127,0,0,0,0,0
        !byte 0,222,189,123,247,239,222,0,0,7,7,0,0,0,0,0
        !byte 255,7,7,255,255,255,255,255,252,254,254,254,254,254,254,252
        !byte 0,127,127,0,0,0,0,0,0,222,189,123,247,239,222,0
        !byte 0,7,7,0,0,0,0,0,255,7,7,255,255,255,255,255
        !byte 252,254,254,254,254,254,254,252,0,127,127,0,0,0,0,0
        !byte 0,222,189,123,247,239,222,0,0,7,7,0,0,0,0,0
        !byte 255,7,7,255,255,255,255,255,47,21,43,21,0,5,43,21
        !byte 23,47,21,175,255,43,21,175,0,222,189,123,247,239,222,0
        !byte 0,7,7,0,0,0,0,0,255,7,7,255,255,255,255,255
        !byte 252,254,254,254,254,254,254,252,0,127,127,0,0,0,0,0
        !byte 0,222,189,123,247,239,222,0,0,7,7,0,0,0,0,0
        !byte 255,7,7,255,255,255,255,255,252,254,254,254,254,254,254,252
        !byte 0,127,127,0,0,0,0,0,0,222,189,123,247,239,222,0
        !byte 0,7,7,0,0,0,0,0,255,7,7,255,255,255,255,255
        !byte 252,254,254,254,254,254,254,252,0,127,127,0,0,0,0,0
        !byte 0,222,189,123,247,239,222,0,0,7,7,0,0,0,0,0
        !byte 255,7,7,255,255,255,255,255,252,254,254,254,254,254,254,252
        !byte 0,222,189,123,247,239,222,0,0,31,31,0,0,0,0,0
        !byte 255,31,31,255,255,255,255,255,241,251,251,251,251,251,251,241
        !byte 255,1,1,255,255,255,255,255,0,222,189,123,247,239,222,0
        !byte 0,31,31,0,0,0,0,0,255,31,31,255,255,255,255,255
        !byte 241,251,251,251,251,251,251,241,255,1,1,255,255,255,255,255
        !byte 0,222,189,123,247,239,222,0,0,31,31,0,0,0,0,0
        !byte 255,31,31,255,255,255,255,255,241,251,251,251,251,251,251,241
        !byte 255,1,1,255,255,255,255,255,0,222,189,123,247,239,222,0
        !byte 0,31,31,0,0,0,0,0,255,31,31,255,255,255,255,255
        !byte 241,251,251,251,251,251,251,241,47,21,43,21,0,5,43,21
        !byte 23,47,21,175,255,43,21,175,0,31,31,0,0,0,0,0
        !byte 255,31,31,255,255,255,255,255,241,251,251,251,251,251,251,241
        !byte 255,1,1,255,255,255,255,255,0,222,189,123,247,239,222,0
        !byte 0,31,31,0,0,0,0,0,255,31,31,255,255,255,255,255
        !byte 241,251,251,251,251,251,251,241,255,1,1,255,255,255,255,255
        !byte 0,222,189,123,247,239,222,0,0,31,31,0,0,0,0,0
        !byte 255,31,31,255,255,255,255,255,241,251,251,251,251,251,251,241
        !byte 255,1,1,255,255,255,255,255,0,222,189,123,247,239,222,0
        !byte 0,31,31,0,0,0,0,0,255,31,31,255,255,255,255,255
        !byte 241,251,251,251,251,251,251,241,255,1,1,255,255,255,255,255
        !byte 0,44,61,121,111,244,214,109,0,239,99,221,93,28,99,162
        !byte 0,198,243,116,119,150,190,253,0,251,255,89,255,246,107,203
        !byte 0,206,167,47,173,111,239,109,0,159,45,247,255,239,255,79
        !byte 0,222,67,93,156,157,226,95,0,142,207,111,173,231,202,232
        !byte 0,45,191,187,247,158,255,203,0,157,255,93,100,213,60,95
        !byte 0,175,42,198,142,227,74,235,0,110,163,93,93,93,99,119
        !byte 0,223,23,93,171,251,158,119,0,35,226,230,108,197,73,237
        !byte 0,177,243,127,127,103,244,253,0,206,255,127,251,3,31,175
        !byte 0,79,162,207,175,79,138,111,10,0,34,0,10,0,2,0
        !byte 81,170,84,234,81,170,84,234,0,160,0,168,0,160,64,168
        !byte 0,2,0,10,0,34,0,138,21,171,85,175,21,171,85,174
        !byte 87,191,95,255,87,255,95,255,0,172,254,223,111,158,127,81
        !byte 0,143,191,251,253,251,126,233,0,234,64,239,70,103,205,238
        !byte 0,250,46,117,105,103,106,221,0,61,234,239,105,109,172,235
        !byte 0,239,194,28,220,93,97,239,0,189,119,183,251,215,248,235
        !byte 0,251,223,243,175,122,190,238,0,71,107,109,206,238,198,111
        !byte 0,239,173,212,217,185,200,237,0,155,224,221,220,93,227,255
        !byte 0,143,111,174,235,197,239,173,0,249,218,62,222,238,247,255
        !byte 0,183,171,239,110,186,232,57,0,196,237,71,171,234,236,175
        !byte 0,61,163,28,93,221,195,114,0,119,251,255,117,93,156,185
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,60,99,162,34,93,146,36
        !byte 0,0,0,240,240,240,0,0,0,0,0,240,240,240,0,0
        !byte 0,0,0,240,240,240,0,0,0,0,0,240,240,240,0,0
        !byte 0,0,0,240,240,240,0,0,0,0,0,240,240,240,0,0
        !byte 0,0,0,240,240,240,0,0,0,0,0,240,240,240,0,0
        !byte 0,60,69,198,68,121,146,36,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0

* = $5000
bgcol:
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 203,188,203,188,188,188,203,188,203,188,203,188,188,188,203,188
        !byte 188,203,188,188,188,188,188,188,188,188,188,188,203,188,188,188
        !byte 188,188,203,188,203,203,188,188,207,207,207,207,207,207,207,207
        !byte 207,207,207,207,207,207,207,207,207,207,207,207,207,207,207,207
        !byte 207,207,207,207,207,207,207,207,207,207,207,207,207,207,207,207
        !byte 203,188,252,96,96,230,230,230,230,230,230,230,230,230,230,230
        !byte 230,230,230,230,230,230,230,230,230,230,22,22,230,230,230,230
        !byte 230,230,230,230,96,188,188,203,188,203,252,230,110,110,110,110
        !byte 22,22,110,110,110,110,110,110,110,110,110,110,110,110,110,110
        !byte 22,22,241,225,22,110,110,110,118,118,110,110,110,188,203,188
        !byte 203,188,252,110,110,110,30,22,241,241,225,30,110,110,110,110
        !byte 110,110,110,110,110,110,110,110,110,111,110,110,225,110,110,126
        !byte 23,231,110,110,110,188,188,188,188,203,252,110,110,30,241,241
        !byte 239,239,31,225,110,110,110,110,110,110,110,110,110,110,110,110
        !byte 110,110,110,110,110,110,110,126,231,231,126,110,110,188,203,203
        !byte 188,203,252,62,62,30,30,62,62,62,62,62,62,62,62,62
        !byte 62,62,30,30,62,62,62,62,62,62,62,62,62,62,62,62
        !byte 126,30,30,62,62,188,188,188,203,188,252,30,227,30,225,227
        !byte 227,227,227,227,227,227,227,227,30,30,241,241,30,227,227,227
        !byte 227,227,227,227,227,227,227,30,225,30,225,30,227,188,203,203
        !byte 188,188,252,225,30,110,22,225,30,227,227,227,227,227,227,227
        !byte 19,241,63,225,225,227,227,227,227,227,227,227,227,227,227,30
        !byte 110,110,110,30,227,188,188,188,188,188,252,230,225,110,230,230
        !byte 30,227,227,227,227,19,225,227,227,227,227,225,30,227,227,227
        !byte 227,227,227,227,227,195,227,225,110,110,230,30,30,188,188,188
        !byte 188,188,252,230,230,110,230,230,230,188,195,195,225,225,110,30
        !byte 227,110,206,206,188,54,19,19,19,19,227,19,195,188,235,110
        !byte 110,230,110,230,230,188,188,203,188,188,252,230,230,198,198,203
        !byte 198,188,203,188,230,110,230,198,206,110,198,188,188,203,193,193
        !byte 49,225,110,193,204,188,203,206,188,206,198,230,230,188,188,188
        !byte 203,203,252,86,188,92,92,91,93,92,91,188,92,92,91,213
        !byte 188,92,188,203,213,91,213,219,92,188,190,213,213,91,189,203
        !byte 188,203,91,93,86,188,203,188,203,188,252,93,93,93,93,93
        !byte 93,93,93,93,93,93,93,93,93,93,93,93,93,93,93,93
        !byte 93,93,93,93,93,93,93,93,93,93,93,93,93,188,188,203
        !byte 188,188,252,213,213,93,93,93,93,213,93,213,93,213,93,213
        !byte 93,213,93,203,188,213,93,213,93,213,93,213,93,213,93,213
        !byte 93,213,213,93,213,188,188,188,203,188,252,80,93,213,213,197
        !byte 93,213,213,213,93,85,213,213,93,85,85,252,207,85,85,213
        !byte 93,197,197,213,93,213,213,213,93,213,213,213,80,188,188,203
        !byte 121,137,121,135,128,121,137,121,135,128,121,137,121,135,128,121
        !byte 137,121,135,252,207,137,121,135,128,121,137,121,135,128,121,137
        !byte 121,135,128,121,137,121,135,128,137,121,135,128,135,137,121,135
        !byte 128,135,137,121,135,128,135,137,121,135,128,252,207,121,135,128
        !byte 135,137,121,135,128,135,137,121,135,128,135,137,121,135,128,135
        !byte 203,203,203,203,203,203,203,203,203,203,203,203,203,203,203,203
        !byte 203,203,188,188,188,188,188,203,203,203,203,203,203,203,203,203
        !byte 203,203,203,203,203,203,203,203,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,188,12,12,12,12,12,12,12,12
        !byte 188,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0

* = $5800                ; sprite blocks $60..$67
spr0:
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00010100,%00000000
        !byte %00000000,%00101000,%00000000
        !byte %00000000,%00101000,%00000000
        !byte %00000000,%10101010,%00000000
        !byte %00000000,%10101010,%00000000
        !byte %00000000,%00101000,%00000000
        !byte %00000000,%00010100,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte 0
spr1:
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00010100,%00000000
        !byte %00000000,%00101000,%00000000
        !byte %00000000,%01101001,%00000000
        !byte %00000000,%01101001,%00000000
        !byte %00000000,%01101001,%00000000
        !byte %00000010,%10101010,%10000000
        !byte %00000010,%10101010,%10000000
        !byte %00000000,%10101010,%00000000
        !byte %00000000,%01101001,%00000000
        !byte %00000000,%01101001,%00000000
        !byte %00000000,%00111100,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte 0
spr2:
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%01100100,%00000000
        !byte %00000000,%10101000,%00000000
        !byte %00000000,%10101000,%00000000
        !byte %00000001,%10111001,%00000000
        !byte %00000001,%10101001,%00000000
        !byte %00000001,%10101001,%00000000
        !byte %00000101,%10101001,%01000000
        !byte %00011010,%10101010,%10010000
        !byte %00101010,%10101010,%10100000
        !byte %00101010,%10101010,%10100000
        !byte %00000110,%10101010,%01000000
        !byte %00000001,%10101001,%00000000
        !byte %00000001,%10101001,%00000000
        !byte %00000001,%10101001,%00000000
        !byte %00000001,%10101001,%00000000
        !byte %00000000,%11111100,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte 0
spr3:
        !byte %00000000,%00010100,%00000000
        !byte %00000000,%01101001,%00000000
        !byte %00000000,%01101001,%00000000
        !byte %00000001,%10111110,%01000000
        !byte %00000001,%10111110,%01000000
        !byte %00000001,%10101010,%01000000
        !byte %00000001,%10101010,%01000000
        !byte %00000001,%10101010,%01000000
        !byte %00000101,%10101010,%01010000
        !byte %00011010,%10101010,%10100100
        !byte %01101010,%10101010,%10101001
        !byte %11101010,%10101010,%10101011
        !byte %01101010,%10101010,%10101001
        !byte %00011010,%10101010,%10100100
        !byte %00000110,%10010110,%10010000
        !byte %00000001,%10101010,%01000000
        !byte %00000110,%10101010,%10010000
        !byte %00000111,%10000010,%11010000
        !byte %00000001,%10101010,%01000000
        !byte %00000001,%01111101,%01000000
        !byte %00000000,%00111100,%00000000
        !byte 0
spre0:
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%01011010,%00000000
        !byte %00000000,%11111111,%00000000
        !byte %00000011,%11111111,%11000000
        !byte %00000001,%11111111,%10000000
        !byte %00000000,%11111111,%00000000
        !byte %00000001,%11111111,%10000000
        !byte %00000011,%11111111,%01000000
        !byte %00000000,%11111111,%00000000
        !byte %00000000,%10011001,%00000000
        !byte %00000000,%00011000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte 0
spre1:
        !byte %00000000,%01000000,%00000000
        !byte %00000000,%10000111,%00000000
        !byte %00000000,%01111111,%00000000
        !byte %00001100,%01111110,%01010000
        !byte %00001111,%01111110,%11100000
        !byte %00000111,%11111111,%11100000
        !byte %00000011,%11111111,%11000000
        !byte %00100111,%10000111,%11101110
        !byte %00110111,%10001001,%11111000
        !byte %00011111,%00011100,%11111000
        !byte %00000111,%00000110,%11100000
        !byte %00011111,%11101101,%11111000
        !byte %00111111,%10011001,%11101100
        !byte %01110111,%10111101,%11111110
        !byte %00000011,%11111111,%11000000
        !byte %00000011,%11111111,%11100000
        !byte %00001101,%01111110,%11110000
        !byte %00001110,%11111111,%01110000
        !byte %00000000,%01101111,%00000000
        !byte %00000000,%11000101,%00000000
        !byte %00000000,%01000000,%00000000
        !byte 0
sprb:
        !byte %00000000,%00011000,%00000000
        !byte %00000000,%00011000,%00000000
        !byte %00000000,%00011000,%00000000
        !byte %00000000,%00011000,%00000000
        !byte %00000000,%00011000,%00000000
        !byte %00000000,%00011000,%00000000
        !byte %00000000,%00011000,%00000000
        !byte %00000000,%00011000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte 0
sprr:
        !byte %00000000,%00000000,%00000000
        !byte %10000000,%00000000,%00000001
        !byte %10000000,%00000000,%00000001
        !byte %11111111,%11011011,%11111111
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00011000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00011000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00011000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00011000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00011000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00011000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000111,%11011011,%11100000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte 0
sprb2:
        !byte %00000001,%10000001,%10000000
        !byte %00000001,%10000001,%10000000
        !byte %00000001,%10000001,%10000000
        !byte %00000001,%10000001,%10000000
        !byte %00000001,%10000001,%10000000
        !byte %00000001,%10000001,%10000000
        !byte %00000001,%10000001,%10000000
        !byte %00000001,%10000001,%10000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte 0
sprc0:
        !byte %01111110,%00000000,%00000000
        !byte %11111111,%00000000,%00000000
        !byte %01111110,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte 0
sprc1:
        !byte %11100000,%00000000,%00000000
        !byte %11110000,%00000000,%00000000
        !byte %01110000,%00000000,%00000000
        !byte %00111000,%00000000,%00000000
        !byte %00011100,%00000000,%00000000
        !byte %00001100,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte 0
sprc2:
        !byte %11100000,%00000000,%00000000
        !byte %01100000,%00000000,%00000000
        !byte %01100000,%00000000,%00000000
        !byte %01100000,%00000000,%00000000
        !byte %01100000,%00000000,%00000000
        !byte %01100000,%00000000,%00000000
        !byte %01100000,%00000000,%00000000
        !byte %01100000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte 0
sprc3:
        !byte %00001100,%00000000,%00000000
        !byte %00011100,%00000000,%00000000
        !byte %00111000,%00000000,%00000000
        !byte %01110000,%00000000,%00000000
        !byte %11110000,%00000000,%00000000
        !byte %11100000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte %00000000,%00000000,%00000000
        !byte 0

* = $8000                ; music song data
; ---- song streams (generated): 64 bars ----
s_bass:
        !byte 129,12,21,16,129,12,29,16,129,12,24,16,129,12,31,16
        !byte 129,11,21,2,33,2,21,2,33,2,21,2,33,2,21,2
        !byte 33,2,129,11,29,2,41,2,29,2,41,2,29,2,41,2
        !byte 29,2,41,2,129,11,24,2,36,2,24,2,36,2,24,2
        !byte 36,2,24,2,36,2,129,11,31,2,43,2,31,2,43,2
        !byte 31,2,43,2,31,2,43,2,129,11,21,2,33,2,21,2
        !byte 33,2,21,2,33,2,21,2,33,2,129,11,29,2,41,2
        !byte 29,2,41,2,29,2,41,2,29,2,41,2,129,11,31,2
        !byte 43,2,31,2,43,2,31,2,43,2,31,2,43,2,129,11
        !byte 28,2,40,2,28,2,40,2,28,2,40,2,28,2,40,2
        !byte 129,8,21,2,129,11,33,2,129,8,21,2,129,11,33,2
        !byte 129,8,21,2,129,11,33,2,129,8,21,2,129,11,33,2
        !byte 129,8,129,8,29,2,129,11,41,2,129,8,29,2,129,11
        !byte 41,2,129,8,29,2,129,11,41,2,129,8,29,2,129,11
        !byte 41,2,129,8,129,8,24,2,129,11,36,2,129,8,24,2
        !byte 129,11,36,2,129,8,24,2,129,11,36,2,129,8,24,2
        !byte 129,11,36,2,129,8,129,8,31,2,129,11,43,2,129,8
        !byte 31,2,129,11,43,2,129,8,31,2,129,11,43,2,129,8
        !byte 31,2,129,11,43,2,129,8,129,8,21,2,129,11,33,2
        !byte 129,8,21,2,129,11,33,2,129,8,21,2,129,11,33,2
        !byte 129,8,21,2,129,11,33,2,129,8,129,8,29,2,129,11
        !byte 41,2,129,8,29,2,129,11,41,2,129,8,29,2,129,11
        !byte 41,2,129,8,29,2,129,11,41,2,129,8,129,8,31,2
        !byte 129,11,43,2,129,8,31,2,129,11,43,2,129,8,31,2
        !byte 129,11,43,2,129,8,31,2,129,11,43,2,129,8,129,11
        !byte 28,2,40,2,28,2,40,2,28,2,40,2,28,2,40,2
        !byte 129,9,26,3,38,1,26,2,33,2,26,3,38,1,26,2
        !byte 36,2,129,9,21,3,33,1,21,2,28,2,21,3,33,1
        !byte 21,2,31,2,129,9,29,3,41,1,29,2,36,2,29,3
        !byte 41,1,29,2,39,2,129,9,28,3,40,1,28,2,35,2
        !byte 28,3,40,1,28,2,38,2,129,9,26,3,38,1,26,2
        !byte 33,2,26,3,38,1,26,2,36,2,129,9,21,3,33,1
        !byte 21,2,28,2,21,3,33,1,21,2,31,2,129,9,28,3
        !byte 40,1,28,2,35,2,28,3,40,1,28,2,38,2,129,9
        !byte 21,3,33,1,21,2,28,2,21,3,33,1,21,2,31,2
        !byte 129,8,21,4,21,4,21,4,21,4,129,8,29,4,29,4
        !byte 29,4,29,4,129,8,24,4,24,4,24,4,24,4,129,8
        !byte 31,4,31,4,31,4,31,4,129,8,21,4,21,4,21,4
        !byte 21,4,129,8,29,4,29,4,29,4,29,4,129,8,31,4
        !byte 31,4,31,4,31,4,129,11,28,2,40,2,28,2,40,2
        !byte 28,2,40,2,28,2,40,2,129,12,21,8,28,8,129,12
        !byte 31,8,31,8,129,12,29,8,29,8,129,12,28,8,35,8
        !byte 129,12,21,8,28,8,129,12,31,8,31,8,129,12,29,8
        !byte 29,8,129,12,28,8,35,8,129,8,26,2,129,11,38,2
        !byte 129,8,26,2,129,11,38,2,129,8,26,2,129,11,38,2
        !byte 129,8,26,2,129,11,38,2,129,8,129,8,21,2,129,11
        !byte 33,2,129,8,21,2,129,11,33,2,129,8,21,2,129,11
        !byte 33,2,129,8,21,2,129,11,33,2,129,8,129,8,29,2
        !byte 129,11,41,2,129,8,29,2,129,11,41,2,129,8,29,2
        !byte 129,11,41,2,129,8,29,2,129,11,41,2,129,8,129,8
        !byte 28,2,129,11,40,2,129,8,28,2,129,11,40,2,129,8
        !byte 28,2,129,11,40,2,129,8,28,2,129,11,40,2,129,8
        !byte 129,8,26,2,129,11,38,2,129,8,26,2,129,11,38,2
        !byte 129,8,26,2,129,11,38,2,129,8,26,2,129,11,38,2
        !byte 129,8,129,8,21,2,129,11,33,2,129,8,21,2,129,11
        !byte 33,2,129,8,21,2,129,11,33,2,129,8,21,2,129,11
        !byte 33,2,129,8,129,8,28,2,129,11,40,2,129,8,28,2
        !byte 129,11,40,2,129,8,28,2,129,11,40,2,129,8,28,2
        !byte 129,11,40,2,129,8,129,11,21,2,33,2,21,2,33,2
        !byte 21,2,33,2,21,2,33,2,129,8,21,2,129,11,33,2
        !byte 129,8,21,2,129,11,33,2,129,8,21,2,129,11,33,2
        !byte 129,8,21,2,129,11,33,2,129,8,129,8,29,2,129,11
        !byte 41,2,129,8,29,2,129,11,41,2,129,8,29,2,129,11
        !byte 41,2,129,8,29,2,129,11,41,2,129,8,129,8,24,2
        !byte 129,11,36,2,129,8,24,2,129,11,36,2,129,8,24,2
        !byte 129,11,36,2,129,8,24,2,129,11,36,2,129,8,129,8
        !byte 31,2,129,11,43,2,129,8,31,2,129,11,43,2,129,8
        !byte 31,2,129,11,43,2,129,8,31,2,129,11,43,2,129,8
        !byte 129,8,21,2,129,11,33,2,129,8,21,2,129,11,33,2
        !byte 129,8,21,2,129,11,33,2,129,8,21,2,129,11,33,2
        !byte 129,8,129,8,29,2,129,11,41,2,129,8,29,2,129,11
        !byte 41,2,129,8,29,2,129,11,41,2,129,8,29,2,129,11
        !byte 41,2,129,8,129,8,31,2,129,11,43,2,129,8,31,2
        !byte 129,11,43,2,129,8,31,2,129,11,43,2,129,8,31,2
        !byte 129,11,43,2,129,8,129,8,28,4,28,4,28,4,28,4
        !byte 129,11,26,2,38,2,26,2,38,2,26,2,38,2,26,2
        !byte 38,2,129,11,28,2,40,2,28,2,40,2,28,2,40,2
        !byte 28,2,40,2,129,11,26,2,38,2,26,2,38,2,26,2
        !byte 38,2,26,2,38,2,129,11,28,2,40,2,28,2,40,2
        !byte 28,2,40,2,28,2,40,2,254
s_drum:
        !byte 133,6,130,5,132,0,129,16,0,1,128,1,129,16,0,1
        !byte 128,1,129,16,0,1,128,1,129,16,0,1,128,1,129,16
        !byte 0,1,128,1,129,16,0,1,128,1,129,16,0,1,128,1
        !byte 129,16,0,1,128,1,129,16,0,1,128,1,129,16,0,1
        !byte 128,1,129,16,0,1,128,1,129,16,0,1,128,1,129,16
        !byte 0,1,128,1,129,16,0,1,128,1,129,16,0,1,128,1
        !byte 129,16,0,1,128,1,129,16,0,1,128,1,129,16,0,1
        !byte 128,1,129,16,0,1,128,1,129,17,0,2,129,16,0,1
        !byte 128,1,129,16,0,1,128,1,129,16,0,1,128,1,129,17
        !byte 0,2,129,18,0,1,128,1,129,18,0,1,128,1,129,18
        !byte 0,1,128,1,129,18,0,1,128,1,129,18,0,1,128,1
        !byte 129,18,0,1,128,1,129,18,0,1,128,1,129,18,0,1
        !byte 128,1,130,3,132,0,129,23,0,2,129,17,0,2,129,18
        !byte 0,1,128,1,129,17,0,2,129,15,21,1,128,1,129,17
        !byte 0,2,129,18,0,1,128,1,129,17,0,2,129,15,29,1
        !byte 128,1,129,17,0,2,129,18,0,1,128,1,129,17,0,2
        !byte 129,15,29,1,128,1,129,17,0,2,129,18,0,1,128,1
        !byte 129,17,0,2,129,15,24,1,128,1,129,17,0,2,129,18
        !byte 0,1,128,1,129,17,0,2,129,15,24,1,128,1,129,17
        !byte 0,2,129,18,0,1,128,1,129,17,0,2,129,15,31,1
        !byte 128,1,129,17,0,2,129,18,0,1,128,1,129,17,0,2
        !byte 129,15,31,1,128,1,129,17,0,2,129,18,0,1,128,1
        !byte 129,17,0,2,129,15,21,1,128,1,129,17,0,2,129,18
        !byte 0,1,128,1,129,17,0,2,129,15,21,1,128,1,129,17
        !byte 0,2,129,18,0,1,128,1,129,17,0,2,129,15,29,1
        !byte 128,1,129,17,0,2,129,18,0,1,128,1,129,17,0,2
        !byte 129,15,29,1,128,1,129,17,0,2,129,18,0,1,128,1
        !byte 129,17,0,2,129,15,31,1,128,1,129,17,0,2,129,18
        !byte 0,1,128,1,129,17,0,2,129,15,31,1,128,1,129,17
        !byte 0,2,129,18,0,1,128,1,129,17,0,2,129,15,28,1
        !byte 128,1,129,16,0,1,128,1,129,18,0,1,128,1,129,16
        !byte 0,1,128,1,129,21,0,2,129,20,0,2,129,22,0,2
        !byte 129,22,0,2,130,3,132,0,129,23,0,2,129,17,0,2
        !byte 129,18,0,1,128,1,129,17,0,2,129,15,21,1,128,1
        !byte 129,15,21,1,128,1,129,18,0,1,128,1,129,17,0,2
        !byte 129,15,29,1,128,1,129,17,0,2,129,18,0,1,128,1
        !byte 129,17,0,2,129,15,29,1,128,1,129,15,29,1,128,1
        !byte 129,18,0,1,128,1,129,17,0,2,129,15,24,1,128,1
        !byte 129,17,0,2,129,18,0,1,128,1,129,17,0,2,129,15
        !byte 24,1,128,1,129,15,24,1,128,1,129,18,0,1,128,1
        !byte 129,17,0,2,129,15,31,1,128,1,129,17,0,2,129,18
        !byte 0,1,128,1,129,17,0,2,129,15,31,1,128,1,129,15
        !byte 31,1,128,1,129,18,0,1,128,1,129,17,0,2,129,15
        !byte 21,1,128,1,129,17,0,2,129,18,0,1,128,1,129,17
        !byte 0,2,129,15,21,1,128,1,129,15,21,1,128,1,129,18
        !byte 0,1,128,1,129,17,0,2,129,15,29,1,128,1,129,17
        !byte 0,2,129,18,0,1,128,1,129,17,0,2,129,15,29,1
        !byte 128,1,129,15,29,1,128,1,129,18,0,1,128,1,129,17
        !byte 0,2,129,15,31,1,128,1,129,17,0,2,129,18,0,1
        !byte 128,1,129,17,0,2,129,15,31,1,128,1,129,15,31,1
        !byte 128,1,129,18,0,1,128,1,129,17,0,2,129,15,28,1
        !byte 128,1,129,16,0,1,128,1,129,18,0,1,128,1,129,16
        !byte 0,1,128,1,129,21,0,2,129,20,0,2,129,22,0,2
        !byte 129,22,0,2,130,2,132,0,129,23,0,2,129,17,0,2
        !byte 129,18,0,1,128,1,129,17,0,2,129,15,26,1,128,1
        !byte 129,17,0,2,129,18,0,1,128,1,129,17,0,2,129,15
        !byte 21,1,128,1,129,17,0,2,129,18,0,1,128,1,129,17
        !byte 0,2,129,15,21,1,128,1,129,17,0,2,129,18,0,1
        !byte 128,1,129,17,0,2,129,15,29,1,128,1,129,17,0,2
        !byte 129,18,0,1,128,1,129,17,0,2,129,15,29,1,128,1
        !byte 129,17,0,2,129,18,0,1,128,1,129,17,0,2,129,15
        !byte 28,1,128,1,129,17,0,2,129,18,0,1,128,1,129,17
        !byte 0,2,129,15,28,1,128,1,129,17,0,2,129,18,0,1
        !byte 128,1,129,17,0,2,129,15,26,1,128,1,129,17,0,2
        !byte 129,18,0,1,128,1,129,17,0,2,129,15,26,1,128,1
        !byte 129,17,0,2,129,18,0,1,128,1,129,17,0,2,129,15
        !byte 21,1,128,1,129,17,0,2,129,18,0,1,128,1,129,17
        !byte 0,2,129,15,21,1,128,1,129,17,0,2,129,18,0,1
        !byte 128,1,129,17,0,2,129,15,28,1,128,1,129,17,0,2
        !byte 129,18,0,1,128,1,129,17,0,2,129,15,28,1,128,1
        !byte 129,17,0,2,129,18,0,1,128,1,129,17,0,2,129,15
        !byte 21,1,128,1,129,16,0,1,128,1,129,18,0,1,128,1
        !byte 129,16,0,1,128,1,129,21,0,2,129,20,0,2,129,22
        !byte 0,2,129,22,0,2,130,3,132,0,129,23,0,2,129,17
        !byte 0,2,129,18,0,1,128,1,129,17,0,2,129,15,21,1
        !byte 128,1,129,15,21,1,128,1,129,18,0,1,128,1,129,17
        !byte 0,2,129,15,29,1,128,1,129,17,0,2,129,18,0,1
        !byte 128,1,129,17,0,2,129,15,29,1,128,1,129,15,29,1
        !byte 128,1,129,18,0,1,128,1,129,17,0,2,129,15,24,1
        !byte 128,1,129,17,0,2,129,18,0,1,128,1,129,17,0,2
        !byte 129,15,24,1,128,1,129,15,24,1,128,1,129,18,0,1
        !byte 128,1,129,17,0,2,129,15,31,1,128,1,129,17,0,2
        !byte 129,18,0,1,128,1,129,17,0,2,129,15,31,1,128,1
        !byte 129,15,31,1,128,1,129,18,0,1,128,1,129,17,0,2
        !byte 129,15,21,1,128,1,129,17,0,2,129,18,0,1,128,1
        !byte 129,17,0,2,129,15,21,1,128,1,129,15,21,1,128,1
        !byte 129,18,0,1,128,1,129,17,0,2,129,15,29,1,128,1
        !byte 129,17,0,2,129,18,0,1,128,1,129,17,0,2,129,15
        !byte 29,1,128,1,129,15,29,1,128,1,129,18,0,1,128,1
        !byte 129,17,0,2,129,15,31,1,128,1,129,17,0,2,129,18
        !byte 0,1,128,1,129,17,0,2,129,15,31,1,128,1,129,15
        !byte 31,1,128,1,129,18,0,1,128,1,129,17,0,2,129,15
        !byte 28,1,128,1,129,16,0,1,128,1,129,18,0,1,128,1
        !byte 129,16,0,1,128,1,129,21,0,2,129,20,0,2,129,22
        !byte 0,2,129,22,0,2,130,5,132,0,129,15,21,1,128,7
        !byte 129,15,21,1,128,3,129,19,0,1,128,3,129,15,31,1
        !byte 128,7,129,15,31,1,128,3,129,19,0,1,128,3,129,15
        !byte 29,1,128,7,129,15,29,1,128,3,129,19,0,1,128,3
        !byte 129,15,28,1,128,7,129,15,28,1,128,3,129,19,0,1
        !byte 128,3,129,15,21,1,128,7,129,15,21,1,128,3,129,19
        !byte 0,1,128,3,129,15,31,1,128,7,129,15,31,1,128,3
        !byte 129,19,0,1,128,3,129,15,29,1,128,7,129,15,29,1
        !byte 128,3,129,19,0,1,128,3,129,18,0,1,128,1,129,18
        !byte 0,1,128,1,129,18,0,1,128,1,129,18,0,1,128,1
        !byte 129,18,0,1,128,1,129,18,0,1,128,1,129,18,0,1
        !byte 128,1,129,18,0,1,128,1,130,2,132,2,129,23,0,2
        !byte 129,17,0,2,129,18,0,1,128,1,129,17,0,2,129,15
        !byte 26,1,128,1,129,15,26,1,128,1,129,18,0,1,128,1
        !byte 129,17,0,2,129,15,21,1,128,1,129,17,0,2,129,18
        !byte 0,1,128,1,129,17,0,2,129,15,21,1,128,1,129,15
        !byte 21,1,128,1,129,18,0,1,128,1,129,17,0,2,129,15
        !byte 29,1,128,1,129,17,0,2,129,18,0,1,128,1,129,17
        !byte 0,2,129,15,29,1,128,1,129,15,29,1,128,1,129,18
        !byte 0,1,128,1,129,17,0,2,129,15,28,1,128,1,129,17
        !byte 0,2,129,18,0,1,128,1,129,17,0,2,129,15,28,1
        !byte 128,1,129,15,28,1,128,1,129,18,0,1,128,1,129,17
        !byte 0,2,129,15,26,1,128,1,129,17,0,2,129,18,0,1
        !byte 128,1,129,17,0,2,129,15,26,1,128,1,129,15,26,1
        !byte 128,1,129,18,0,1,128,1,129,17,0,2,129,15,21,1
        !byte 128,1,129,17,0,2,129,18,0,1,128,1,129,17,0,2
        !byte 129,15,21,1,128,1,129,15,21,1,128,1,129,18,0,1
        !byte 128,1,129,17,0,2,129,15,28,1,128,1,129,17,0,2
        !byte 129,18,0,1,128,1,129,17,0,2,129,15,28,1,128,1
        !byte 129,15,28,1,128,1,129,18,0,1,128,1,129,17,0,2
        !byte 129,15,21,1,128,1,129,16,0,1,128,1,129,18,0,1
        !byte 128,1,129,16,0,1,128,1,129,21,0,2,129,20,0,2
        !byte 129,22,0,2,129,22,0,2,130,3,132,2,129,23,0,2
        !byte 129,17,0,2,129,18,0,1,128,1,129,17,0,2,129,15
        !byte 21,1,128,1,129,15,21,1,128,1,129,18,0,1,128,1
        !byte 129,17,0,2,129,15,29,1,128,1,129,17,0,2,129,18
        !byte 0,1,128,1,129,17,0,2,129,15,29,1,128,1,129,15
        !byte 29,1,128,1,129,18,0,1,128,1,129,17,0,2,129,15
        !byte 24,1,128,1,129,17,0,2,129,18,0,1,128,1,129,17
        !byte 0,2,129,15,24,1,128,1,129,15,24,1,128,1,129,18
        !byte 0,1,128,1,129,17,0,2,129,15,31,1,128,1,129,17
        !byte 0,2,129,18,0,1,128,1,129,17,0,2,129,15,31,1
        !byte 128,1,129,15,31,1,128,1,129,18,0,1,128,1,129,17
        !byte 0,2,129,15,21,1,128,1,129,17,0,2,129,18,0,1
        !byte 128,1,129,17,0,2,129,15,21,1,128,1,129,15,21,1
        !byte 128,1,129,18,0,1,128,1,129,17,0,2,129,15,29,1
        !byte 128,1,129,17,0,2,129,18,0,1,128,1,129,17,0,2
        !byte 129,15,29,1,128,1,129,15,29,1,128,1,129,18,0,1
        !byte 128,1,129,17,0,2,129,15,31,1,128,1,129,17,0,2
        !byte 129,18,0,1,128,1,129,17,0,2,129,15,31,1,128,1
        !byte 129,15,31,1,128,1,129,18,0,1,128,1,129,17,0,2
        !byte 129,15,28,1,128,1,129,16,0,1,128,1,129,18,0,1
        !byte 128,1,129,16,0,1,128,1,129,21,0,2,129,20,0,2
        !byte 129,22,0,2,129,22,0,2,130,4,132,0,129,15,26,1
        !byte 128,1,129,17,0,2,129,18,0,1,128,1,129,17,0,2
        !byte 129,15,26,1,128,1,129,17,0,2,129,18,0,1,128,1
        !byte 129,17,0,2,129,15,28,1,128,1,129,17,0,2,129,18
        !byte 0,1,128,1,129,17,0,2,129,15,28,1,128,1,129,17
        !byte 0,2,129,18,0,1,128,1,129,17,0,2,129,18,0,1
        !byte 129,18,0,1,129,18,0,1,129,18,0,1,129,18,0,1
        !byte 129,18,0,1,129,18,0,1,129,18,0,1,129,18,0,1
        !byte 129,18,0,1,129,18,0,1,129,18,0,1,129,18,0,1
        !byte 129,18,0,1,129,18,0,1,129,18,0,1,129,24,0,16
        !byte 254
s_lead:
        !byte 129,4,57,16,129,5,53,16,129,5,48,16,129,5,55,16
        !byte 129,1,57,2,60,2,64,4,69,4,64,4,129,1,65,4
        !byte 64,2,62,2,60,4,57,4,129,1,64,4,67,4,64,2
        !byte 62,2,60,4,129,1,62,4,59,2,62,2,67,4,62,4
        !byte 129,1,69,4,67,2,64,2,69,4,72,4,129,1,69,4
        !byte 67,2,65,2,64,4,60,4,129,1,62,4,67,4,71,4
        !byte 74,4,129,1,68,2,71,2,76,4,74,4,71,4,129,2
        !byte 57,2,60,2,64,4,69,4,64,4,129,2,65,4,64,2
        !byte 62,2,60,4,57,4,129,2,64,4,67,4,64,2,62,2
        !byte 60,4,129,2,62,4,59,2,62,2,67,4,62,4,129,2
        !byte 69,4,67,2,64,2,69,4,72,4,129,2,69,4,67,2
        !byte 65,2,64,4,60,4,129,2,62,4,67,4,71,4,74,4
        !byte 129,2,68,2,71,2,76,4,74,4,71,4,129,1,62,4
        !byte 65,4,69,4,65,4,129,1,64,4,69,4,72,4,69,4
        !byte 129,1,72,4,69,2,65,2,69,4,72,4,129,1,71,4
        !byte 68,4,64,4,128,4,129,1,62,2,65,2,69,4,74,4
        !byte 72,2,69,2,129,1,72,4,71,2,69,2,64,4,69,4
        !byte 129,1,68,4,71,4,76,4,74,2,71,2,129,1,69,8
        !byte 128,8,129,1,57,2,60,2,64,4,69,4,64,4,129,1
        !byte 65,4,64,2,62,2,60,4,57,4,129,1,64,4,67,4
        !byte 64,2,62,2,60,4,129,1,62,4,59,2,62,2,67,4
        !byte 62,4,129,1,69,4,67,2,64,2,69,4,72,4,129,1
        !byte 69,4,67,2,65,2,64,4,60,4,129,1,62,4,67,4
        !byte 71,4,74,4,129,1,68,2,71,2,76,4,74,4,71,4
        !byte 129,7,64,8,69,8,129,7,62,8,67,8,129,7,60,8
        !byte 65,8,129,7,59,4,64,4,68,8,129,3,57,16,129,3
        !byte 55,16,129,3,53,16,129,5,52,16,129,2,62,4,65,4
        !byte 69,4,65,4,129,2,64,4,69,4,72,4,69,4,129,2
        !byte 72,4,69,2,65,2,69,4,72,4,129,2,71,4,68,4
        !byte 64,4,128,4,129,2,62,2,65,2,69,4,74,4,72,2
        !byte 69,2,129,2,72,4,71,2,69,2,64,4,69,4,129,2
        !byte 68,4,71,4,76,4,74,2,71,2,129,2,69,8,128,8
        !byte 129,2,57,2,60,2,64,4,69,4,64,4,129,2,65,4
        !byte 64,2,62,2,60,4,57,4,129,2,64,4,67,4,64,2
        !byte 62,2,60,4,129,2,62,4,59,2,62,2,67,4,62,4
        !byte 129,2,69,4,67,2,64,2,69,4,72,4,129,2,69,4
        !byte 67,2,65,2,64,4,60,4,129,2,62,4,67,4,71,4
        !byte 74,4,129,2,68,2,71,2,76,4,74,4,71,4,129,14
        !byte 50,4,50,4,50,4,50,4,129,14,52,4,52,4,52,4
        !byte 52,4,129,14,50,4,50,4,50,4,50,4,129,14,52,4
        !byte 52,4,52,4,52,4,254

