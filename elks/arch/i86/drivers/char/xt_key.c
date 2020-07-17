/*
 * Direct console XT and AT keyboard driver
 *
 * Tables from the Minix book, as that's all I have on XT keyboard
 * controllers. They need to be loadable, this doesn't look good on
 * my Finnish keyboard.
 *
 * Added primitive buffering, and function stubs for vfs calls
 * Removed vfs funcs, they belong better to the console driver
 * Changed this a lot. Made it work, too. ;)
 * Saku Airila 1996
 *
 * Changed code to work with belgian keyboard
 * Stefaan (Stefke) Van Dooren 1998
 *
 * Changed code to support int'l keys 42 + 45, enable caps lock
 * preliminary F11+F12 support, add comments to increase readability
 * Georg Potthast 2017
 *
 * 14 Jul 20 Helge Skrivervik Added LED and NUMLOCK/CAPSLOCK processing.
 * 15 Jul 20 Greg Haerr Added SCRLOCK processing and documentation.
 */

#include <linuxmt/config.h>
#include <linuxmt/kernel.h>
#include <linuxmt/sched.h>
#include <linuxmt/types.h>
#include <linuxmt/errno.h>
#include <linuxmt/fs.h>
#include <linuxmt/fcntl.h>
#include <linuxmt/chqueue.h>
#include <linuxmt/signal.h>
#include <linuxmt/ntty.h>

#include <arch/io.h>
#include <arch/ports.h>
#include <arch/keyboard.h>
#include <arch/system.h>

#ifdef CONFIG_CONSOLE_DIRECT

extern struct tty ttys[];
extern void AddQueue(unsigned char Key);
static void set_leds(void);
static int kb_read(void);

#define ESC	 27	/* ascii value for Escape*/
#define DEL_SCAN 0x53	/* scan code for Delete key*/

/*
 * Include the relevant keymap.
 */
#include "KeyMaps/keymaps.h"

int Current_VCminor = 0;
int kraw = 0;
/*
 *	Keyboard state - the poor little keyboard controller hasnt
 *	got the brains to remember itself.
 */
#define LSHIFT	0x01
#define RSHIFT	0x02
#define CTRL	0x04
#define ALT	0x08
#define CAPS	0x10
#define NUM	0x20
#define ALT_GR	0x40
#define SSC	0xC0	/* simple scan code*/
#define SLOCK	0x100	/* FIXME non functional, need to redefine SSC in order for this to work*/

static unsigned int ModeState = 0;
static int capslock;
static int numlock;
static int scrlock;

/*
 * Table for mapping scancodes >= 0x1C into scan code class.
 * scancodes < 0x1C are all simple scan codes (SSC).
 */
static unsigned int tb_state[] = {
    SSC, CTRL, SSC, SSC,			/*1C->1F*/
    SSC, SSC, SSC, SSC, SSC, SSC, SSC, SSC,	/*20->27*/
    SSC, SSC, LSHIFT, SSC, SSC, SSC, SSC, SSC,	/*28->2F*/
    SSC, SSC, SSC, SSC, SSC, SSC, RSHIFT, SSC,	/*30->37*/
    ALT, SSC, CAPS,				/*38->3A*/
    'a', 'b', 'c', 'd', 'e',			/*3B->3F, Function Keys*/
    'f', 'g', 'h', 'i', 'j',			/*40->44, Function Keys*/
    NUM, SLOCK, SSC,				/*45->47*/
    SSC, SSC, SSC, SSC, SSC, SSC, SSC, SSC,	/*48->4F*/
    SSC, SSC, SSC, SSC, SSC, SSC, SSC, 'k', 'l' /*50->58, F11-F12*/
};

/*
 * Map CAPS|ALT|CTL|SHIFT into NORMAL,SHIFT,CAPS,CTL-ALT,
 * which are used to index into scan_tabs[].
 */
static unsigned char state_code[] = {
    0,	/*0= All status are 0 */
    1,	/*1= SHIFT */
    0,	/*2= CTRL */
    1,	/*3= SHIFT CTRL */
    0,	/*4= ALT */
    1,	/*5= SHIFT ALT */
    3,	/*6= CTRL ALT */
    1,	/*7= SHIFT CTRL ALT */
    2,	/*8= CAPS */ /* CAPS >>1 */
    0,	/*9= CAPS SHIFT */
    2,	/*10= CAPS CTRL */
    0,	/*11= CAPS SHIFT CTRL */
    2,	/*12= CAPS ALT */
    0,	/*13= CAPS SHIFT ALT */
    2,	/*14= CAPS CTRL ALT */
    3,	/*15= CAPS SHIFT CTRL ALT */
};

/*
 * Map NORMAL,SHIFT,CAPS,CTL-ALT into per-country kbd tables
 * defined in KeyMaps/keys-xx.h files by config option.
 */
static unsigned char *scan_tabs[] = {
    xtkb_scan,		/*mode = 0*/
    xtkb_scan_shifted,	/*mode = 1*/
    xtkb_scan_caps,	/*mode = 2*/
    xtkb_scan_ctrl_alt,	/*mode = 3*/
};

void xtk_init(void)
{
    /* Set off the initial keyboard interrupt handler */

    if (request_irq(KBD_IRQ, keyboard_irq, NULL))
	panic("Unable to get keyboard");

    set_leds();
    kb_read();      /* discard any unread keyboard input*/
}

/*
 *	XT style keyboard I/O is almost civilised compared
 *	with the monstrosity AT keyboards became.
 */

void keyboard_irq(int irq, struct pt_regs *regs, void *dev_id)
{
    static int E0Prefix = 0;
    int code, mode;
    int E0key = 0;
    unsigned int key;
    int keyReleased;

    /* read XT or AT keyboard*/
    code = kb_read();

    if (kraw) {
	AddQueue((unsigned char) code);
	return;
    }

    /*extended keys are preceded by a E0 scancode*/
    if (code == 0xE0) {		/* Remember this has been received */
	E0Prefix = 1;
	return;
    }
    if (E0Prefix) {
	E0key = 1;
	E0Prefix = 0;
    }

    /* high bit set when key released */
    keyReleased = code & 0x80;
    code &= 0x7F;

    //printk("scan %x\n", code);
    /*
     * Three tables and seven steps are used to get from scancode to returned keyboard character:
     * First, scancode is classified into Status, FnKey, Extended or Simple
     *	directly by value if < 0x1C, or using tb_state[] lookup if >= 0x1C.
     *	Status, FnKey or Extended scan code classes are handled specially.
     * For simple scan codes, ModeState (CAPS|ALT|CTL|SHIFT) values are used to
     *	index into state_code[] to map state to NORMAL, SHIFT, CAPS or CTL-ALT.
     * Then, further processing is done to the map state for some special status cases (ALTGR, NUM and CTL).
     * The NORMAL,SHIFT,CAPS,CTL-ALT map state is used to index the per-country scan-tabs[]
     *	array to get the keyboard character.
     * Further process the keyboard character based on special status cases (CTL and ALT).
     * Finally, if the keyboard character is octal 0260-277, it is converted into an ANSI
     *	function key sequence.
     */

    /*
     * Step 1: Classify scancode such that
     *  mode = 00xx xxxxB, 0x00 Status key
     *         01xx xxxxB, 0x40 Function key
     *         10xx xxxxB, 0x80 Extended scan code
     *         11xx xxxxB, 0xC0 Simple Scan Code
     */
    if (code >= 0x1C)
	mode = tb_state[code - 0x1C]; /*is key a modifier key?*/
    else
        mode = SSC;

    /* --------------Process status keys-------------- */
    if (!(mode & 0xC0) || mode == SLOCK) {  /* Not a simple scancode*/
#if defined(CONFIG_KEYMAP_DE) || defined(CONFIG_KEYMAP_SE) /* || defined(CONFIG_KEYMAP_ES) */
	/* ALT_GR has a E0 prefix*/
	if ((mode == ALT) && E0key)
	    mode = ALT_GR;
#endif
	if (keyReleased) {
	    switch (mode) {
	    case CAPS:
		capslock = !capslock;
		if (capslock) mode = 0;
		//printk("C%d", capslock);
		set_leds();
		break;
	    case NUM:
		numlock = !numlock;
		if (numlock) mode = 0;
		//printk("N%d", numlock);
		set_leds();
		break;
	    case SLOCK:
		scrlock = !scrlock;
		if (scrlock) mode = 0;
		//printk("S%d", scrclock);
		set_leds();
		break;
	    }
	    ModeState &= ~mode;		/* key up: clear these and other modes*/
        } else
	    ModeState |= mode;		/* key down: set mode bit */

        /* ModeState updated - now return */
        //printk("[%02x]", ModeState);
        return;
    }
    
    /* no further processing on key release for non-status keys*/
    if (keyReleased)
	return;

    switch(mode & 0xC0) {
    /* --------------Handle Function keys-------------- */
    case 0x40:	/* F1 .. F10*/
    /* F11 and F12 function keys need 89 byte table like keys-de.h */
    /* function keys are not posix standard here */
    
	/* AltF1-F3 are console switch*/
	if ((ModeState & ALT) || code <= 0x3D) {/* temp console switch on F1-F3*/
	    Console_set_vc(code - 0x3B);
	    return;
	}

	AddQueue(ESC);		/* F1 = ESC a, F2 = ESC b, etc*/
	AddQueue(mode);
	return;

    /* --------------Handle extended scancodes-------------- */
    case 0x80:
	if (E0key) {		/* Is extended scancode? */
	    mode &= 0x3F;
	    if (mode) {
		AddQueue(ESC);	/* Up=0x37 -> ESC [ A, Down=0x38 -> ESC [ B, etc*/
#ifdef CONFIG_EMUL_ANSI
		AddQueue('[');
#endif
	    }
	    //printk("key 0%o 0x%x\n", mode, mode);
	    AddQueue(mode + 10);
	    return;
	}
	/* fall through*/

    default:
    /* --------------Handle simple scan codes-------------- */
	if (code == DEL_SCAN && ((ModeState & (CTRL|ALT)) == (CTRL|ALT)))
	    ctrl_alt_del();

        /* Steps 2 & 3:
	 * Pick the right keymap determined by ModeState bits:
	 *  8    7   6    5    4    3    2   1   0
	 *  SLCK SSC AGR  NUM CAPS ALT  CTL  RS  LS
	 *
	 * CAPS|ALT|CTL|RS are shifted right and OR'd with LS, forming
	 * 4-bit entry into state_code[], which maps multiple status keys
	 * (CAPS|ALT|CTL|SHIFT) into into a 2-bit table of per-country tables
	 * which are indexed by (NORMAL,SHIFT,CAPS,CTL-ALT) in scan_tabs[] which
	 * point to the actual keyboard maps, which then have ASCII or octal
	 * values for keys or function keys.
	 */
	mode = ((ModeState & (CAPS|ALT|CTRL|RSHIFT)) >> 1) | (ModeState & LSHIFT);
	//printk("{%x,%d}", ModeState, mode);
	mode = state_code[mode];
	
	/* Step 4:
	 * Perform additional special processing for:
	 * NORMAL+ALTGR			-> CTL-ALT
	 * CAPS & SHIFT & code < 0x0E	-> SHIFT	handle top row shift when capslock
	 * NUM & code >= 0x46		-> SHIFT	handle 10 keypad when numlock
	 * ALT-code			-> code | 0x80
	 * CTL-code			-> code & 0x1f
	 * '\0'				-> '@'
	 */
	if (!mode && (ModeState & ALT_GR))
	    mode = 3;		/* CTRL-ALT-.. */

	if (!mode && capslock && code < 0x0E)		/* main top row 1-0,-,= */
	    mode = 1;		/* SHIFT-.. */

	if ((ModeState & NUM) && code >= 0x46)		/* 10 key keypad */
	    if (ModeState & LSHIFT)			/* LSHIFT added by controller for arrow keys*/
	        mode = 0;	/* NORMAL for arrow keys*/
	    else mode = 1;	/* SHIFT-.. for keypad keys*/

	/* Step 5: Read the key code from the selected table by mode */
	key = *(scan_tabs[mode] + code);

        /* Step 6: Modify keyboard character based on some special states*/
	if ((ModeState & (CTRL|ALT)) == ALT)
	    key |= 0x80;	/* META-.. (assume codepage is OEM 437) */
	    
	if (!key)		/* non meta-@ is 64 */
	    key = '@';
	    
	if ((ModeState & (CTRL|ALT)) == CTRL)
	    key &= 0x1F;	/* CTRL-.. */
	    
#ifdef CONFIG_EMUL_ANSI
	/* Step 7: Convert octal 0260-0277 values to ANSI escape sequences*/
	code = mode = 0;
	switch (key) {					/* FIXME need octal func key list*/
	case 0270: code = 'A'; break;			/* up*/
	case 0262: code = 'B'; break;			/* down*/
	case 0266: code = 'C'; break;			/* right*/
	case 0264: code = 'D'; break;			/* left*/
	case 0267: code = 'H'; break;			/* home*/
	case 0261: code = 'F'; break;			/* end*/
	case 0272: code = '2'; mode = '~'; break;	/* insert*/
	case 0271: code = '5'; mode = '~'; break;	/* page up*/
	case 0263: code = '6'; mode = '~'; break;	/* page dn*/
	//default: if (key > 127) printk("Unknown key (0%o 0x%x)\n", key, key);
	}
	if (code) {
	    AddQueue(ESC);
	    AddQueue('[');
	    AddQueue(code);
	    if (mode)
		AddQueue(mode);
	    return;
	}
#endif
	//printk("key 0%o 0x%x\n", key, key);
	AddQueue(key);
    }
}

/* LED routines from MINIX 2*/

/* Standard and AT keyboard.  (PS/2 MCA implies AT throughout.) */
#define KEYBD		0x60	/* I/O port for keyboard data */

/* AT keyboard. */
#define KB_COMMAND	0x64	/* I/O port for commands on AT */
#define KB_STATUS	0x64	/* I/O port for status on AT */
#define KB_ACK		0xFA	/* keyboard ack response */
#define KB_OUT_FULL	0x01	/* status bit set when keypress char pending */
#define KB_IN_FULL	0x02	/* status bit set when not ready to receive */
#define LED_CODE	0xED	/* command to keyboard to set LEDs */
#define MAX_KB_ACK_RETRIES 0x1000	/* max #times to wait for kb ack */
#define MAX_KB_BUSY_RETRIES 0x1000	/* max #times to loop while kb busy */
#define KBIT		0x80	/* bit used to ack characters to keyboard */

/* Read keyboard and acknowledge controller */
static int kb_read(void)
{
    int code, mode;

    code = inb_p(KBD_IO);
    mode = inb_p(KBD_CTL);

    outb_p((mode | 0x80), KBD_CTL);
    outb_p(mode, KBD_CTL);

    return(code);
}

/* Wait until the controller is ready; return zero if this times out. */
static int kb_wait(void)
{
    int retries;
    unsigned char status;

    retries = MAX_KB_BUSY_RETRIES + 1;	/* wait until not busy */
    while (--retries != 0 && (status = inb_p(KB_STATUS)) & (KB_IN_FULL|KB_OUT_FULL)) {
	if (status & KB_OUT_FULL)
	    inb_p(KEYBD);		/* discard */
    }
    return(retries);		/* nonzero if ready */
}

/* Wait until kbd acknowledges last command; return zero if this times out. */
static int kb_ack(void)
{
    int retries;

    retries = MAX_KB_ACK_RETRIES + 1;
    while (--retries != 0 && inb_p(KEYBD) != KB_ACK)
	;			/* wait for ack */
    return(retries);		/* nonzero if ack received */
}

/* Set the LEDs on the caps, num, and scroll lock keys */
static void set_leds(void)
{
    unsigned char leds;

    if (arch_cpu <= 5) return;	/* PC/XT doesn't have LEDs */

    kb_wait();			/* wait for buffer empty  */
    outb_p(LED_CODE, KEYBD);	/* prepare keyboard to accept LED values */
    kb_ack();			/* wait for ack response  */

    kb_wait();			/* wait for buffer empty  */
    leds = scrlock | (numlock << 1) | (capslock << 2);	/* encode led bits*/
    outb_p(leds, KEYBD);	/* give keyboard LED values */
    kb_ack();			/* wait for ack response  */
}

#endif /* CONFIG_CONSOLE_DIRECT*/
