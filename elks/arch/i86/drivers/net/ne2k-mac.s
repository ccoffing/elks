;------------------------------------------------------------------------------
; NE2K driver - low part - MAC routines
;------------------------------------------------------------------------------

; TODO: move definitions to ne2k.h

; I/O base @ 300h

io_eth_command    EQU $300

io_eth_rx_first   EQU $301  ; page 0
io_eth_rx_last    EQU $302  ; page 0
io_eth_rx_get     EQU $303  ; page 0

io_eth_rx_put1    EQU $306  ; page 0 - read

io_eth_tx_start   EQU $304  ; page 0 - write
io_eth_tx_len1    EQU $305  ; page 0 - write
io_eth_tx_len2    EQU $306  ; page 0 - write

io_eth_int_stat   EQU $307  ; page 0

io_eth_dma_addr1  EQU $308  ; page 0
io_eth_dma_addr2  EQU $309  ; page 0
io_eth_dma_len1   EQU $30A  ; page 0 - write
io_eth_dma_len2   EQU $30B  ; page 0 - write

io_eth_rx_stat    EQU $30C  ; page 0 - read

io_eth_rx_conf    EQU $30C  ; page 0 - write
io_eth_tx_conf    EQU $30D  ; page 0 - write
io_eth_data_conf  EQU $30E  ; page 0 - write
io_eth_int_mask   EQU $30F  ; page 0 - write

io_eth_unicast    EQU $301  ; page 1 - 6 bytes
io_eth_rx_put2    EQU $307  ; page 1
io_eth_multicast  EQU $308  ; page 1 - 8 bytes

io_eth_data_io    EQU $310  ; 2 bytes


tx_first          EQU $40
rx_first          EQU $46
rx_last           EQU $80


	.TEXT

;-------------------------------------------------------------------------------
; Static data
;-------------------------------------------------------------------------------

; Temporary location in code segment

rx_put_count:  DW 0
rx_get_count:  DW 0


;-------------------------------------------------------------------------------
; Select register page
;-------------------------------------------------------------------------------

; AL : page number (0 or 1)

ne2k_page_sel:

	push    ax
	push    dx

	mov     ah, al
	and     ah, #$FE
	shl     ah, #6

	mov     dx, #io_eth_command
	in      al, dx
	and     al, #$3F
	or      al, ah
	out     dx, al

	pop     dx
	pop     ax
	ret


;-------------------------------------------------------------------------------
; Internal DMA initialization
;-------------------------------------------------------------------------------

; BX : chip memory address
; CX : byte count

ne2k_dma_init:

	push    ax
	push    bx
	push    cx
	push    dx

	; select page 0

	xor     al, al
	call    ne2k_page_sel

	; TODO: abort any previous DMA

	; set DMA start address

	mov     dx, #io_eth_dma_addr1
	mov     al, bl
	out     dx, al

	inc     dx
	mov     al, bh
	out     dx, al

	; set DMA byte count

	inc     dx
	mov     al, cl
	out     dx, al

	inc     dx
	mov     al, ch
	out     dx, al

	pop     dx
	pop     cx
	pop     bx
	pop     ax
	ret


;-------------------------------------------------------------------------------
; Write block to chip with internal DMA
;-------------------------------------------------------------------------------

; BX    : chip memory (to write to)
; CX    : byte count
; DS:SI : host memory (to read from)

ne2k_dma_write:

	push    ax

	call    ne2k_dma_init

	; start DMA write

	mov     dx, #io_eth_command
	in      al, dx
	and     al, #$C7
	or      al, #$10
	out     dx, al

	; I/O write loop

	mov     dx, #io_eth_data_io

emw_loop:

	lodsb
	out     dx, al
	loop    emw_loop

	; maybe check DMA completed ?

	pop     si
	pop     dx
	pop     cx
	pop     bx
	pop     ax
	ret


;------------------------------------------------------------------------------
; Read block from chip with internal DMA
;------------------------------------------------------------------------------

; BX    : chip memory to read from
; CX    : byte count
; ES:DI : host memory to write to

ne2k_dma_read:

	push    ax
	push    cx
	push    dx
	push    di

	call    ne2k_dma_init

	; start DMA read

	mov     dx, #io_eth_command
	in      al, dx
	and     al, #$C7
	or      al, #$08
	out     dx, al

	; I/O read loop

	mov     dx, #io_eth_data_io

emr_loop:

	in      al, dx
	stosb
	loop    emr_loop

	; maybe check DMA stopped ?

	pop     di
	pop     dx
	pop     cx
	pop     ax
	ret


;------------------------------------------------------------------------------
; Get packet
;------------------------------------------------------------------------------

; ES:DI : packet buffer to fill

; returns:

; CX : packet size (0 = no packet)

_ne2k_pack_get:

	push    ax
	push    bx
	push    dx

	xor     al,al
	call    ne2k_page_sel

	; get RX pointers
	; compute available length

	mov     dx, #io_eth_rx_put1
	in      al, dx
	mov     ch, al
	xor     cl, cl

	mov     dx, #io_eth_rx_get
	in      al, dx
	sub     ch, al
	jz      epg_exit
	jnc     epg_nowrap
	add     ch, [rx_first]

epg_nowrap:

	xor     bl, bl
	mov     bh, al

	; get packet header

	mov     cx, #4
	call    ne2k_dma_read

	eseg
	mov     ax, [di + 0]  ; AH : next record, AL : status
	eseg
	mov     cx, [di + 2]  ; packet size

	; get packet body

	add     bx, #4
	call    ne2k_dma_read

	; update RX get pointer

	xchg    ah, al
	mov     dx, #io_eth_rx_get
	out     dx, al

	; increment RX get counter

	mov     ax, [rx_get_count]
	inc     ax
	mov     [rx_get_count], ax

epg_exit:

	pop     dx
	pop     bx
	pop     ax
	ret


;-------------------------------------------------------------------------------
; Interrupt handler
;-------------------------------------------------------------------------------

; On Advantech SNMP-1000 SBC, the ethernet interrupt is INT0 (0Ch)

int_eth:

	push    ax
	push    bx
	push    dx
	push    ds

	; get data segment

	mov     ax, cs
	mov     ds, ax

	; read interrupt status

	mov     dx, #io_eth_int_stat
	in      al, dx
	push    ax

	; packet received without error ?

	test    al, #$01
	jz      ie_next1

	; increment RX put count

	mov     bx, [rx_put_count]
	mov     ax, [bx]
	inc     ax
	mov     [bx], ax

ie_next1:

	; clear interrupt flags

	pop     ax
	mov     dx, #io_eth_int_stat
	out     dx, al

	; end of interrupt handling

	mov     ax, #$0C
	mov     dx, #$FF22
	out     dx, ax

	pop     ds
	pop     dx
	pop     bx
	pop     ax
	iret


;-------------------------------------------------------------------------------
; Start MAC
;-------------------------------------------------------------------------------

_ne2k_mac_start:

	push    ax
	push    dx

	mov     dx, #io_eth_command
	in      al, dx
	and     al, #$FC
	or      al, #$02
	out     dx, al

	pop     dx
	pop     ax
	ret


;-------------------------------------------------------------------------------
; Stop MAC
;-------------------------------------------------------------------------------

_ne2k_mac_stop:

	push    ax
	push    dx

	; select page 0

	xor     al, al
	call    ne2k_page_sel

	; internal loopback to insulate
	; from any external packet
	; and ensure finally the TX end

	; TBC

	; then stop the transceiver

	mov     dx, #io_eth_command
	in      al, dx
	and     al, #$FC
	or      al, #$01
	out     dx, al

	pop     dx
	pop     ax
	ret


;-------------------------------------------------------------------------------
; NE2K termination
;-------------------------------------------------------------------------------

_ne2k_term:

	push    ax
	push    dx

	; select page 0

	xor     al, al
	call    ne2k_page_sel

	; internal loopback to insulate
	; from any external packet
	; and ensure finally the TX end

	; TODO

	; then stop the transceiver

	call _ne2k_mac_stop

	; and wait for chip get stable

	; TODO

	pop     dx
	pop     ax
	ret


;-------------------------------------------------------------------------------
; NE2K initialization
;-------------------------------------------------------------------------------

_ne2k_init:

	push    ax
	push    dx

	xor     al,al
	call    ne2k_page_sel

	; data I/O in single bytes for 80188

	mov     dx, #io_eth_data_conf
	mov     al, #$48
	out     dx, al

	; accept all packet without error
	; broadcast, multicast and promiscuous

	mov     dx, #io_eth_rx_conf
	mov     al, #$5C
	out     dx, al

	; half-duplex and internal loopback
	; TODO: read PHY status to update the TX mode
	; TODO: return error on link down

	; call phy_stat

	mov     dx, #io_eth_tx_conf
	mov     al, #2
	out     dx, al

	; set RX ring limits
	; all 16KB on-chip memory
	; except one TX frame at beginning (6 x 256B)

	mov     dx, #io_eth_rx_first
	mov     al, #rx_first
	out     dx, al

	mov     dx, #io_eth_rx_last
	mov     al, #rx_last
	out     dx, al

	mov     dx, #io_eth_tx_start
	mov     al, #tx_first
	out     dx, al

	; set RX get pointer

	mov     dx, #io_eth_rx_get
	mov     al, #rx_first
	out     dx, al

	; clear all interrupt flags

	mov     dx, #io_eth_int_stat
	mov     al, #$FF
	out     dx, al

	; set interrupt mask

	mov     dx, #io_eth_int_mask
	mov     al, #$01
	out     dx, al

	; select page 1

	mov     al, #1
	call    ne2k_page_sel

	; clear unicast address

	mov     cx, #6
	mov     dx, #io_eth_unicast
	xor     al, al

ei_loop_u:

	out     dx, al
	inc     dx
	loop    ei_loop_u

	; clear multicast bitmap

	mov     cx, #8
	mov     dx, #io_eth_multicast
	xor     al, al

ei_loop_m:

	out     dx, al
	inc     dx
	loop    ei_loop_m

	; set RX put pointer to start

	mov     dx, #io_eth_rx_put2
	mov     al, #rx_first
	out     dx, al

	pop     dx
	pop     ax
	ret


;-------------------------------------------------------------------------------
; Set unicast address (aka MAC address)
;-------------------------------------------------------------------------------

; DS:SI : unicast address (6 bytes)

_ne2k_addr_set:

	push ax
	push cx
	push dx
	push si

	; select page 1

	mov     al, #1
	call    ne2k_page_sel

	; load MAC address

	mov     dx, #io_eth_unicast
	mov     cx, #6
	cld

ems_loop:

	lodsb
	out     dx, al
	inc     dx
	loop    ems_loop

	pop     si
	pop     dx
	pop     cx
	pop     ax
	ret


;------------------------------------------------------------------------------
; Get RX state
;------------------------------------------------------------------------------

_ne2k_rx_stat:

	mov     ax, [rx_put_count]
	xor     ax, [rx_get_count]
	ret


;------------------------------------------------------------------------------

	EXPORT  _ne2k_mac_start
	EXPORT  _ne2k_mac_stop
	EXPORT  _ne2k_init
	EXPORT  _ne2k_term
	EXPORT  _ne2k_addr_set
	EXPORT  _ne2k_pack_get
	EXPORT  _ne2k_rx_stat

	END

;------------------------------------------------------------------------------
