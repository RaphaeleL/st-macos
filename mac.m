/* mac.m - native Cocoa frontend for st. Replaces x.c.
 * st.c (VT parser, pty, screen state) stays untouched; this file
 * implements the win.h interface with AppKit instead of X11. */
#import <Cocoa/Cocoa.h>
#include <locale.h>
#include <string.h>
#include <wchar.h>

/* st.h defines its own MIN/MAX; drop Foundation's to avoid redefinition warnings */
#undef MIN
#undef MAX
#include "st.h"
#include "win.h"

#ifndef IS_TRUECOL
#define IS_TRUECOL(x) (1 << 24 & (x))
#endif

/* ---- settings that x.c normally pulls in from config.h ---- */
char *utmp = NULL;
char *scroll = NULL;
char *stty_args = "stty raw pass8 nl -echo -iexten -cstopb 38400";
char *vtiden = "\033[?6c";
wchar_t *worddelimiters = L" ";
int allowaltscreen = 1;
int allowwindowops = 0;
char *termname = "xterm-256color"; /* st-256color terminfo isn't on macOS */
unsigned int tabspaces = 8;
/* ==================== appearance: edit here ==================== */

static NSString *fontname = @"Comic Code";
static CGFloat fontsize = 15;

/* colors as 0xRRGGBB */
static uint32_t bgcolor     = 0x181818; /* window background */
static uint32_t fgcolor     = 0xffffff; /* default text */
static uint32_t cursorcolor = 0xf5e0dc; /* cursor block */
static uint32_t selbgcolor  = 0x553b48; /* selection background */
static uint32_t selfgcolor  = 0xffffff; /* selection text */

/* initial window size in characters */
static int cols = 110;
static int rows = 50;

/* =============================================================== */

/* palette slots above the 256 terminal colors for the colors above */
enum { COL_BG = 256, COL_FG, COL_CURSOR, COL_SELBG, COL_SELFG };

unsigned int defaultfg = COL_FG;
unsigned int defaultbg = COL_BG;
unsigned int defaultcs = COL_CURSOR;

/* ---- frontend state ---- */
static Glyph *cells;
static int ncol, nrow, curx, cury, started;
static unsigned int winmode;
static NSFont *font, *boldfont;
static CGFloat cw, ch;
static NSWindow *win;
static NSView *view;
static dispatch_source_t ttysrc;

static NSColor * color(uint32_t c) {
	static const uint32_t base[16] = {
        // Ghostty Default Style Dark
		0x000000, 0xca7f7b, 0xc3c683, 0xedd090, 0x99b0c7, 0xbba7c4, 0xa3c7c3, 0xcfd1d0,
		0x797979, 0xcf6c69, 0xc7d06d, 0xe7ce6b, 0x94b4dd, 0xc9abdc, 0x91c8be, 0xeeeeee,
	};
	uint32_t rgb;

	if (IS_TRUECOL(c)) {
		rgb = c & 0xffffff;
	} else if (c < 16) {
		rgb = base[c];
	} else if (c < 232) {
		int i = c - 16, v[3] = { i / 36, (i / 6) % 6, i % 6 };
		for (int k = 0; k < 3; k++)
			v[k] = v[k] ? v[k] * 40 + 55 : 0;
		rgb = v[0] << 16 | v[1] << 8 | v[2];
	} else if (c < 256) {
		int v = 8 + (c - 232) * 10;
		rgb = v << 16 | v << 8 | v;
	} else {
		switch (c) {
		    case COL_BG:     rgb = bgcolor; break;
		    case COL_FG:     rgb = fgcolor; break;
		    case COL_CURSOR: rgb = cursorcolor; break;
		    case COL_SELBG:  rgb = selbgcolor; break;
		    case COL_SELFG:  rgb = selfgcolor; break;
		    default:         rgb = fgcolor; break;
		}
	}
	return [NSColor colorWithSRGBRed:((rgb >> 16) & 0xff) / 255.0 green:((rgb >> 8) & 0xff) / 255.0 blue:(rgb & 0xff) / 255.0 alpha:1];
}

static NSString * runestr(Rune u) {
	unichar buf[2];
	if (u > 0xffff) {
		u -= 0x10000;
		buf[0] = 0xd800 + (u >> 10);
		buf[1] = 0xdc00 + (u & 0x3ff);
		return [NSString stringWithCharacters:buf length:2];
	}
	buf[0] = u;
	return [NSString stringWithCharacters:buf length:1];
}

static void setfont(CGFloat size) {
	fontsize = size;
	font = [NSFont fontWithName:fontname size:size];
	if (!font) font = [NSFont monospacedSystemFontOfSize:size weight:NSFontWeightRegular];
	boldfont = [[NSFontManager sharedFontManager] convertFont:font toHaveTrait:NSBoldFontMask];
	cw = ceil([@"M" sizeWithAttributes:@{ NSFontAttributeName: font }].width);
	ch = ceil(font.ascender - font.descender + font.leading);
}

static void resizebuf(int c, int r) {
	Glyph blank = { .u = ' ', .mode = 0, .fg = defaultfg, .bg = defaultbg };
	free(cells);
	cells = malloc(sizeof(Glyph) * c * r);
	for (int i = 0; i < c * r; i++) cells[i] = blank;
	ncol = c;
	nrow = r;
}

static void ttyresizeall(void) {
	if (!started)
		return;
	tresize(ncol, nrow);
	ttyresize(ncol * cw, nrow * ch);
	redraw();
}

static void paste(void) {
	NSString *t = [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];
	if (!t)
		return;
	t = [t stringByReplacingOccurrencesOfString:@"\n" withString:@"\r"];
	const char *s = t.UTF8String;
	if (winmode & MODE_BRCKTPASTE)
		ttywrite("\033[200~", 6, 0);
	ttywrite(s, strlen(s), 1);
	if (winmode & MODE_BRCKTPASTE)
		ttywrite("\033[201~", 6, 0);
}

/* ---- the view ---- */
@interface TermView : NSView
@end

@implementation TermView

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }

- (void)setFrameSize:(NSSize)s {
	[super setFrameSize:s];
	int c = MAX(1, (int)(s.width / cw)), r = MAX(1, (int)(s.height / ch));
	if (c == ncol && r == nrow)
		return;
	resizebuf(c, r);
	ttyresizeall();
}

- (void)drawRect:(NSRect)dirty {
	[color(defaultbg) setFill];
	NSRectFill(self.bounds);
	if (!cells)
		return;

	for (int y = 0; y < nrow; y++) {
		for (int x = 0; x < ncol; x++) {
			Glyph g = cells[y * ncol + x];
			if (g.mode & ATTR_WDUMMY)
				continue;

			uint32_t fg = g.fg, bg = g.bg, t;
			if (g.mode & ATTR_REVERSE) { t = fg; fg = bg; bg = t; }
			if (started && selected(x, y)) { /*fg = COL_SELFG; */bg = COL_SELBG; }
			if (x == curx && y == cury && !(winmode & MODE_HIDE)) { fg = COL_BG; bg = COL_CURSOR; }

			NSRect r = NSMakeRect(x * cw, y * ch, cw * ((g.mode & ATTR_WIDE) ? 2 : 1), ch);
			if (bg != defaultbg) {
				[color(bg) setFill];
				NSRectFill(r);
			}
			if (g.u > ' ' && !(g.mode & ATTR_INVISIBLE)) {
				[runestr(g.u) drawAtPoint:r.origin withAttributes:@{
					NSFontAttributeName: (g.mode & ATTR_BOLD) ? boldfont : font,
					NSForegroundColorAttributeName: color(fg),
				}];
			}
			if (g.mode & ATTR_UNDERLINE) {
				[color(fg) setFill];
				NSRectFill(NSMakeRect(r.origin.x, r.origin.y + ch - 1, r.size.width, 1));
			}
		}
	}
}

- (void)keyDown:(NSEvent *)e {
	NSEventModifierFlags m = e.modifierFlags;
	NSString *raw = e.charactersIgnoringModifiers;
	unichar k = raw.length ? [raw characterAtIndex:0] : 0;
	int app = winmode & MODE_APPCURSOR;
	const char *seq = NULL;

	if (m & NSEventModifierFlagCommand) {
		switch (k) {
		case 'v': paste(); return;
		case 'c': xclipcopy(); return;
		case '=': case '+': setfont(fontsize + 1); [self setFrameSize:self.frame.size]; return;
		case '-': setfont(MAX(6, fontsize - 1)); [self setFrameSize:self.frame.size]; return;
		default: [super keyDown:e]; return; /* let the menu handle cmd-q etc. */
		}
	}

	switch (k) {
	case NSUpArrowFunctionKey:    seq = app ? "\033OA" : "\033[A"; break;
	case NSDownArrowFunctionKey:  seq = app ? "\033OB" : "\033[B"; break;
	case NSRightArrowFunctionKey: seq = app ? "\033OC" : "\033[C"; break;
	case NSLeftArrowFunctionKey:  seq = app ? "\033OD" : "\033[D"; break;
	case NSHomeFunctionKey:       seq = "\033[H"; break;
	case NSEndFunctionKey:        seq = "\033[F"; break;
	case NSPageUpFunctionKey:     seq = "\033[5~"; break;
	case NSPageDownFunctionKey:   seq = "\033[6~"; break;
	case NSDeleteFunctionKey:     seq = "\033[3~"; break;
	case NSF1FunctionKey:         seq = "\033OP"; break;
	case NSF2FunctionKey:         seq = "\033OQ"; break;
	case NSF3FunctionKey:         seq = "\033OR"; break;
	case NSF4FunctionKey:         seq = "\033OS"; break;
	}
	if (seq) {
		ttywrite(seq, strlen(seq), 1);
		return;
	}

	/* Option = Meta: send ESC + key */
	if ((m & NSEventModifierFlagOption) && raw.length) {
		const char *s = raw.UTF8String;
		ttywrite("\033", 1, 1);
		ttywrite(s, strlen(s), 1);
		return;
	}

	const char *s = e.characters.UTF8String;
	if (s && *s)
		ttywrite(s, strlen(s), 1);
}

- (void)cellAt:(NSEvent *)e x:(int *)x y:(int *)y {
	NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
	*x = MAX(0, MIN(ncol - 1, (int)(p.x / cw)));
	*y = MAX(0, MIN(nrow - 1, (int)(p.y / ch)));
}

- (void)mouseDown:(NSEvent *)e {
	int x, y;
	[self cellAt:e x:&x y:&y];
	int snap = e.clickCount == 2 ? SNAP_WORD : e.clickCount >= 3 ? SNAP_LINE : 0;
	selstart(x, y, snap);
	self.needsDisplay = YES;
}

- (void)mouseDragged:(NSEvent *)e {
	int x, y;
	[self cellAt:e x:&x y:&y];
	selextend(x, y, SEL_REGULAR, 0);
	self.needsDisplay = YES;
}

- (void)mouseUp:(NSEvent *)e {
	int x, y;
	[self cellAt:e x:&x y:&y];
	selextend(x, y, SEL_REGULAR, 1);
	self.needsDisplay = YES;
}

@end

/* ---- win.h implementation (what st.c calls) ---- */
void xbell(void) { NSBeep(); }

void xclipcopy(void) {
	char *s = getsel();
	if (!s)
		return;
	NSPasteboard *pb = [NSPasteboard generalPasteboard];
	[pb clearContents];
	[pb setString:@(s) forType:NSPasteboardTypeString];
	free(s);
}

void xdrawcursor(int cx, int cy, Glyph g, int ox, int oy, Glyph og) {
	curx = cx;
	cury = cy;
}

void xdrawline(Line line, int x1, int y1, int x2) {
	if (y1 >= nrow)
		return;
	for (int x = x1; x < x2 && x < ncol; x++)
		cells[y1 * ncol + x] = line[x];
}

void xfinishdraw(void) { view.needsDisplay = YES; }
void xloadcols(void) {}
int xsetcolorname(int x, const char *name) { return 1; }
int xgetcolor(int x, unsigned char *r, unsigned char *g, unsigned char *b) { return 1; }
void xseticontitle(char *p) {}
void xsettitle(char *p) { win.title = (p && *p) ? @(p) : @"suckless simple terminal for macos"; }
void xsetmode(int set, unsigned int flags) { winmode = set ? winmode | flags : winmode & ~flags; }
void xsetpointermotion(int set) {}
int xsetcursor(int cursor) { return 0; } /* DECSCUSR cursor shape; block cursor only for now */
void xsetsel(char *str) { free(str); } /* no PRIMARY selection on macOS */
int xstartdraw(void) { return 1; }
void xximspot(int x, int y) {}

/* ---- app setup ---- */
@interface AppDelegate : NSObject <NSApplicationDelegate>
@end
@implementation AppDelegate
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)a { return YES; }
@end

int main(int argc, char *argv[]) {
	@autoreleasepool {
		setlocale(LC_CTYPE, "");

		[NSApplication sharedApplication];
		NSApp.activationPolicy = NSApplicationActivationPolicyRegular;
		static AppDelegate *delegate;
		delegate = [AppDelegate new];
		NSApp.delegate = delegate;

		NSMenu *bar = [NSMenu new], *appmenu = [NSMenu new];
		NSMenuItem *item = [NSMenuItem new];
		[appmenu addItemWithTitle:@"Quit st" action:@selector(terminate:) keyEquivalent:@"q"];
		item.submenu = appmenu;
		[bar addItem:item];
		NSApp.mainMenu = bar;

		setfont(fontsize);
		resizebuf(cols, rows);

		win = [[NSWindow alloc]
			initWithContentRect:NSMakeRect(0, 0, ncol * cw, nrow * ch)
			          styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
			                    NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
			            backing:NSBackingStoreBuffered
			              defer:NO];
		win.title = @"suckless simple terminal for macos";
		/* dark title bar, tinted with the terminal background */
		win.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
		win.titlebarAppearsTransparent = YES;
		win.backgroundColor = color(COL_BG);
		win.contentResizeIncrements = NSMakeSize(cw, ch);
		view = [[TermView alloc] initWithFrame:NSMakeRect(0, 0, ncol * cw, nrow * ch)];
		win.contentView = view;
		[win makeFirstResponder:view];
		[win center];
		[win makeKeyAndOrderFront:nil];

		tnew(ncol, nrow);
		char *sh = getenv("SHELL");
		int fd = ttynew(NULL, sh ? sh : "/bin/zsh", NULL, NULL);
		started = 1;
		ttyresize(ncol * cw, nrow * ch);

		/* replaces x.c's select() loop: wake up whenever the pty has data */
		ttysrc = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, dispatch_get_main_queue());
		dispatch_source_set_event_handler(ttysrc, ^{
			ttyread();
			draw();
		});
		dispatch_resume(ttysrc);

		[NSApp activateIgnoringOtherApps:YES];
		[NSApp run];
	}
	return 0;
}
