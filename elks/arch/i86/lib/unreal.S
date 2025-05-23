####################################################################################
# Use unreal or protected mode to set the segment cache register limits.
#
# Unreal mode routines for 80386+ CPUs
# derived from UNREAL.ASM and A20.ASM code by Chris Giese
#  8 Nov 2021 Greg Haerr
# 18 Apr 2025 Greg Haerr added full protected mode entry from Helge Skrivervik
#
# void enable_unreal_mode(void)	- Set segment cache register limits, requires 386+
# void linear32_fmemcpyw (void *dst_off, addr_t dst_seg, void *src_off, addr_t src_seg,
#		size_t count)	- Copy words between XMS and far memory
# void linear32_fmemcpyb (void *dst_off, addr_t dst_seg, void *src_off, addr_t src_seg,
#		size_t count)	- Copy bytes between XMS and far memory
# NOTE: the linear32_fmemcpy routines use "unprotected" EBX, EBX, ESI and EDI registers,
#  and interrupts are left on so as to minimize device driver problems.
#  This means that these routines CANNOT be called from an interrupt service routine,
#  as the unprotected registers would be overwritten. This could be solved by
#  turning interrupts off in the routine at the cost of delaying interrupt service
#  for the duration of the copy, which might be too long for time-sensitive drivers,
#  like fast serial ports. Further, no other routines should be written that use
#  the 32-bit register set without coordinating with the functions in this file.
#

	.arch	i386,nojumps
	.code16
	.text

	.global	enable_unreal_mode
	.global	linear32_fmemcpyw
	.global	linear32_fmemcpyb
	.global	linear32_fmemset

# Enter full protected mode to set the segment cache register limits.
# Requires 32-bit CPU (386+) to call!
enable_unreal_mode:
	xorl %eax,%eax
	movw %ds,%ax
	shll $4,%eax

	addl $gdt, %eax         # point gdt_ptr to gdt
	movl %eax, gdt_ptr+2

	pushf			# save interrupt status
	cli                     # interrupts off
	pushl %ds
	pushl %es
	pushl %fs
	pushl %gs

	push %cs		# push real mode return address for later lret
	push $rmode
	xorl %eax,%eax
	mov %cs,%ax		# set up the GDT entry for current 16-bit code segment
	shll $4,%eax
	mov %ax,codesel+2       # base 15:0
	ror $16,%eax
	mov %al,codesel+4       # base 23:16
	mov %ah,codesel+7       # base 31:24

	lgdt gdt_ptr
	movl %cr0, %eax         # CR0.PE=1: enable protected mode
	orb $1,%al
	movl %eax, %cr0

	ljmp $CODE_SEL,$pmode	# enter protected mode by clearing prefetch & reloading CS
pmode:

	movw $LINEAR_SEL, %bx 	# selector of segment with 4GB-1 limit
	movw %bx,%ds            # set segment limits in descriptor caches
	movw %bx,%es
	movw %bx,%fs
	movw %bx,%gs

	decb %al                # CR0.PE=0: back to real mode
	movl %eax, %cr0

	lret			# return to real mode at next line
rmode:

# loading segment registers after protected mode changes their base address
# but not the segment limit; which remains 4GB-1
	popl %gs
	popl %fs
	popl %es
	popl %ds
	popf			# restore interrupt status
	ret			# system is in real mode with 4GB segment limits

#
# void linear32_fmemcpyw(void *dst_off, addr_t dst_seg, void *src_off, addr_t src_seg,
#		size_t count)
# WARNING: Requires 32-bit CPU, segment descriptor cache set and A20 gate enabled!
#          Trashes EBX, ECX, ESI and EDI without saving.
#
linear32_fmemcpyw:
	push   %es
	mov    %si,%ax
	mov    %di,%dx

	xorl   %esi,%esi
	mov    %sp,%si

	xorl   %ecx,%ecx
	mov    16(%si),%cx    // word count -> ECX

	xorl   %ebx,%ebx
	mov    4(%si),%bx     // word dest offset -> EBX
	movl   6(%esi),%edi   // long dest address -> EDI
	addl   %ebx,%edi      // EDI is linear destination

	xorl   %ebx,%ebx
	mov    10(%si),%bx    // word src offset -> EBX
	movl   12(%esi),%esi  // long src address -> ESI
	addl   %ebx,%esi      // ESI is linear source

	xor    %bx,%bx        // ES = DS = 0 for 32-bit linear addressing
	mov    %bx,%es
	mov    %bx,%ds

	cld
	addr32 rep movsw      // word [ES:EDI++] <- [DS:ESI++], ECX times
	addr32 nop            // 80386 B1 step chip bug on address size mixing

	mov    %ax,%si
	mov    %dx,%di
	mov    %ss,%ax
	mov    %ax,%ds
	pop    %es
	ret

#
# void linear32_fmemcpyb(void *dst_off, addr_t dst_seg, void *src_off, addr_t src_seg,
#		size_t count)
# WARNING: Requires 32-bit CPU, segment descriptor cache set and A20 gate enabled!
#          Trashes EBX, ECX, ESI and EDI without saving.
#
linear32_fmemcpyb:
	push   %es
	mov    %si,%ax
	mov    %di,%dx
	xorl   %esi,%esi
	mov    %sp,%si

	xorl   %ecx,%ecx
	mov    16(%si),%cx    // word count -> ECX

	xorl   %ebx,%ebx
	mov    4(%si),%bx     // word dest offset -> EBX
	movl   6(%esi),%edi   // long dest address -> EDI
	addl   %ebx,%edi      // EDI is linear destination

	xorl   %ebx,%ebx
	mov    10(%si),%bx    // word src offset -> EBX
	movl   12(%esi),%esi  // long src address -> ESI
	addl   %ebx,%esi      // ESI is linear source

	xor    %bx,%bx        // ES = DS = 0 for 32-bit linear addressing
	mov    %bx,%es
	mov    %bx,%ds

	cld
	shrl   $1,%ecx        // copy words
	addr32 rep movsw      // word [ES:EDI++] <- [DS:ESI++], ECX times
	addr32 nop            // 80386 B1 step chip bug on address size mixing

	rcll    $1,%ecx       // then possibly final byte
	addr32 rep movsb      // byte [ES:EDI++] <- [DS:ESI++], ECX times
	addr32 nop            // 80386 B1 step chip bug on address size mixing

	mov    %ax,%si
	mov    %dx,%di
	mov    %ss,%ax
	mov    %ax,%ds
	pop    %es
	ret

#
# void linear32_fmemset(void *dst_off, addr_t dst_seg, byte_t val, size_t count)
# WARNING: Requires 32-bit CPU, segment descriptor cache set and A20 gate enabled!
#          Trashes EAX, EBX, ECX, ESI and EDI without saving.
#
linear32_fmemset:
	push   %si
	push   %es
	mov    %di,%dx
	xorl   %esi,%esi
	mov    %sp,%si

	xorl   %ecx,%ecx
	mov    14(%si),%cx    // word count -> ECX

	xorl   %ebx,%ebx
	mov    6(%si),%bx     // word dest offset -> EBX
	movl   8(%esi),%edi   // long dest address -> EDI
	addl   %ebx,%edi      // EDI is linear destination

	xorl   %eax,%eax
	mov    12(%si),%al    // byte val -> EAX
	mov    %al,%ah

	xor    %bx,%bx        // ES = DS = 0 for 32-bit linear addressing
	mov    %bx,%es
	mov    %bx,%ds

	cld
	shrl   $1,%ecx        // store words
	addr32 rep stosw      // word [ES:EDI++] <- AX, ECX times
	addr32 nop            // 80386 B1 step chip bug on address size mixing

	rcll    $1,%ecx       // then possibly final byte
	addr32 rep stosb      // byte [ES:EDI++] <- AL, ECX times
	addr32 nop            // 80386 B1 step chip bug on address size mixing

	mov    %dx,%di
	mov    %ss,%ax
	mov    %ax,%ds
	pop    %es
	pop    %si
	ret

#if UNUSED
#
# word_t linear32_peekw(void *src_off, addr_t src_seg)
# WARNING: Requires 32-bit CPU, segment descriptor cache set and A20 gate enabled!
#          Trashes EBX and ESI without saving.
#
	.global	linear32_peekw
linear32_peekw:
	mov    %si,%dx

	xorl   %esi,%esi
	mov    %sp,%si

	xorl   %ebx,%ebx
	mov    2(%si),%bx     // word src offset -> EBX
	movl   4(%esi),%esi   // long src address -> ESI
	addl   %ebx,%esi      // ESI is linear destination

	xor    %bx,%bx        // DS = 0 for 32-bit linear addressing
	mov    %bx,%ds

	cld
	addr32 lodsw          // AX = [DS:ESI++]

	mov    %dx,%si
	mov    %ss,%bx
	mov    %bx,%ds
	ret
#endif

# The GDT contains 8-byte DESCRIPTORS for each protected-mode segment.
# Each descriptor contains a 32-bit segment base address, a 20-bit segment
# limit, and 12 bits describing the segment type. The descriptors look
# like this:
#
#           MSB    bit 6   bit 5   bit 4   bit 3   bit 2   bit 1   LSB
#        +-------+-------+-------+-------+-------+-------+-------+-------+
#byte 0  | bit 7<---------------- segment limit------------------->bit 0 |
#        +-------+-------+-------+-------+-------+-------+-------+-------+
#
#        +-------+-------+-------+-------+-------+-------+-------+-------+
#byte 1  |bit 15<---------------- segment limit------------------->bit 8 |
#        +-------+-------+-------+-------+-------+-------+-------+-------+
#
#        +-------+-------+-------+-------+-------+-------+-------+-------+
#byte 2  | bit 7<---------------- segment base-------------------->bit 0 |
#        +-------+-------+-------+-------+-------+-------+-------+-------+
#
#        +-------+-------+-------+-------+-------+-------+-------+-------+
#byte 3  |bit 15<---------------- segment base-------------------->bit 8 |
#        +-------+-------+-------+-------+-------+-------+-------+-------+
#
#        +-------+-------+-------+-------+-------+-------+-------+-------+
#byte 4  |bit 23<---------------- segment base-------------------->bit 16|
#        +-------+-------+-------+-------+-------+-------+-------+-------+
#
#        +-------+-------+-------+-------+-------+-------+-------+-------+
#byte 5  |   P   |      DPL      |   S   |   E   |  D/C  |  W/R  |   A   |
#        +-------+-------+-------+-------+-------+-------+-------+-------+
#
# This is the access/descriptor type byte, which sets the type of descriptor,
# and the permissions for the associated segment. The permissions are
# interpreted differently based on whether the segment is loaded into
# a code, data, or stack segment register.
#
# P is the Segment Present bit. It should always be 1.
#
# DPL is the DESCRIPTOR PRIVILEGE LEVEL. For simple code like this, these
# two bits should always be zeroes.
#
# S is the descriptor type bit. 0 for System segment, 1 for code or data.
#
# E specifies Executable. 0 for data, 1 for code segments.
#
# The D/C bit specifies Direction bit for data segments, 0=Expand Up else Down,
# For code segments, 0 is nonconfirming, 1 Confirming.
#
# The W/R bit specifies Writable for data segments, Readable for code.
#
# The A bit is written to 1 by the CPU when the segment is accessed.
#
# For unreal mode data segments, the P, S and W bits would be set, which gives hex 92.
#
# For protected mode 16-bit code, set the P, S, E and R bits, giving hex 9A.
#
#        +-------+-------+-------+-------+-------+-------+-------+-------+
#byte 6  |   G   |  B/D  |   0   | Avail | bit 19<-- seg limit--->bit 16 |
#        +-------+-------+-------+-------+-------+-------+-------+-------+
#
# G is the Limit Granularity. If zero, the segment limit is in bytes
# (0 to 1M, in 1-byte increments). If one, the segment limit is in 4K PAGES
# (0 to 4G, in 4K increments). For unreal mode, set this bit to 1, and
# set the segment limit to its highest value (FFFFF hex). You now have
# segments that are 4G in size! The Intel CPUs can address no more than
# 4G of memory, so this is like having no segments at all. No wonder
# protected mode is popular.
#
# For code segments, B is the Big bit. When set, this specifies that
# all instructions will use 32-bit operands and addresses by default
# (BITS 32, in NASM syntax, USE32 in Microsoft syntax). For 16-bit
# code segments, the operand and address override instruction prefixes
# (hex 66 and 67) are used to specify access to 32-bit data, which are used
# to implement unreal mode access to extended memory.
#
# For data segments, D is the Default bit. When set, this specifies the
# width of ESP/SP when used as a stack segment. It should be set to 1
# when creating a 32-bit sized segment, otherwise 0.
#
# The Avail bit is available for operating system use by the programmer.
#
# For unreal mode data, the G and D bits would be set, along with bits 19:16
# specifying a 4GB-1 segment limit, giving hex CF.
#
#        +-------+-------+-------+-------+-------+-------+-------+-------+
#byte 7  |bit 31<---------------- segment base------------------->bit 24 |
#        +-------+-------+-------+-------+-------+-------+-------+-------+
#
# None of these notes apply to the NULL descriptor. All of its bytes
# should be set to zero.
#

        .data
        .p2align 1
# Global Descriptor Table
# NULL descriptor (required):
gdt:    .word 0         # limit 15:0
        .word 0         # base 15:0
        .byte 0         # base 23:16
        .byte 0         # access byte (descriptor type)
        .byte 0         # b7-4=flags, b3-0=limit 19:16
        .byte 0         # base 31:24
        
# linear data segment descriptor:
LINEAR_SEL = . - gdt
        .word 0xFFFF    # limit 15:0
        .word 0         # base  15:0
        .byte 0         # base  23:16
        .byte 0x92      # present, ring 0, data, expand-up, writable
#       .byte 0         # byte-granular, 16-bit, limit=64K-1 (disables 4GB segments)
        .byte 0xCF      # page-granular, 32-bit, limit=4GB-1 (largest flat segment)
        .byte 0         # base  31:24

# code segment descriptor for protected mode using 16-bit code segment
CODE_SEL = . - gdt
codesel:.word 0xFFFF    # limit 15:0
        .word 0         # base  15:0
        .byte 0         # base  23:16
        .byte 0x9A      # present, ring 0, code, nonconforming, readable
        .byte 0x0F      # byte-granular, 16-bit, limit=1M-1 (16-bit PM code segment)
        .byte 0         # base  31:24

gdt_len = . - gdt
gdt_ptr:.word gdt_len - 1
        .long gdt

