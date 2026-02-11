//
//  Use this file to import your target's public headers that you would like to expose to Swift.
//

#import <AppKit/AppKit.h>

AXError _AXUIElementGetWindow(AXUIElementRef element, uint32_t *identifier);

// Private CoreGraphics SPI for disabling system symbolic hot keys (e.g. Cmd+Tab app switcher)
// Signature: (hotKeyID, isEnabled) — no connection ID needed
extern CGError CGSSetSymbolicHotKeyEnabled(int hotKey, _Bool enabled);
