// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// KeyboardLayout.swift — the Latin letter a physical key carries, and the key's
// layout-independent identity.
//
// Bindings are written in ASCII. Under a Russian or Greek layout the character
// a key produces is not, so a chord written `cmd+k` would never match the key
// the user thinks of as K. Asking the current ASCII-CAPABLE layout what that
// physical key would produce recovers it — which is the same recovery the menu
// bar performs for its own key equivalents, and the reason ⌘C keeps working
// when the layout changes.
//
// The Metal arm has this in Objective-C, and that file says in its own header
// not to grow: it is being retired. So this is the Swift arm's, not a bridge
// into it.

import Carbon.HIToolbox
import Foundation

/// The keyboard layouts a physical key is read against.
package enum KeyboardLayout {
    /// The unshifted character a physical key produces under the current
    /// ASCII-capable layout.
    ///
    /// - Parameter keyCode: The hardware key code.
    /// - Returns: The character, or 0 when the layout cannot say.
    static func asciiCapableCharacter(forKeyCode keyCode: UInt16) -> UInt32 {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
            let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else {
            return 0
        }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return OSStatus(paramErr)
            }
            return UCKeyTranslate(
                layout,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0, // no modifiers: the unshifted character is what a chord names
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
        }
        guard status == noErr, length > 0 else { return 0 }
        return UInt32(characters[0])
    }

    /// The unshifted character a physical key carries on the US (ANSI)
    /// layout, whatever layout is active.
    ///
    /// This is the PC-101 identity Kitty's base-layout key names. It is a
    /// fixed table because every Text Input Sources query resolves against an
    /// installed layout, and under a Latin one that layout is the active one:
    /// asking it repeats the key the user pressed.
    ///
    /// - Parameter keyCode: The hardware key code.
    /// - Returns: The character, or 0 for a key with no printable US identity.
    package static func usANSICharacter(forKeyCode keyCode: UInt16) -> UInt32 {
        let scalar: Unicode.Scalar
        switch Int(keyCode) {
        case kVK_ANSI_A: scalar = "a"
        case kVK_ANSI_B: scalar = "b"
        case kVK_ANSI_C: scalar = "c"
        case kVK_ANSI_D: scalar = "d"
        case kVK_ANSI_E: scalar = "e"
        case kVK_ANSI_F: scalar = "f"
        case kVK_ANSI_G: scalar = "g"
        case kVK_ANSI_H: scalar = "h"
        case kVK_ANSI_I: scalar = "i"
        case kVK_ANSI_J: scalar = "j"
        case kVK_ANSI_K: scalar = "k"
        case kVK_ANSI_L: scalar = "l"
        case kVK_ANSI_M: scalar = "m"
        case kVK_ANSI_N: scalar = "n"
        case kVK_ANSI_O: scalar = "o"
        case kVK_ANSI_P: scalar = "p"
        case kVK_ANSI_Q: scalar = "q"
        case kVK_ANSI_R: scalar = "r"
        case kVK_ANSI_S: scalar = "s"
        case kVK_ANSI_T: scalar = "t"
        case kVK_ANSI_U: scalar = "u"
        case kVK_ANSI_V: scalar = "v"
        case kVK_ANSI_W: scalar = "w"
        case kVK_ANSI_X: scalar = "x"
        case kVK_ANSI_Y: scalar = "y"
        case kVK_ANSI_Z: scalar = "z"
        case kVK_ANSI_0: scalar = "0"
        case kVK_ANSI_1: scalar = "1"
        case kVK_ANSI_2: scalar = "2"
        case kVK_ANSI_3: scalar = "3"
        case kVK_ANSI_4: scalar = "4"
        case kVK_ANSI_5: scalar = "5"
        case kVK_ANSI_6: scalar = "6"
        case kVK_ANSI_7: scalar = "7"
        case kVK_ANSI_8: scalar = "8"
        case kVK_ANSI_9: scalar = "9"
        case kVK_ANSI_Minus: scalar = "-"
        case kVK_ANSI_Equal: scalar = "="
        case kVK_ANSI_LeftBracket: scalar = "["
        case kVK_ANSI_RightBracket: scalar = "]"
        case kVK_ANSI_Backslash: scalar = "\\"
        case kVK_ANSI_Semicolon: scalar = ";"
        case kVK_ANSI_Quote: scalar = "'"
        case kVK_ANSI_Comma: scalar = ","
        case kVK_ANSI_Period: scalar = "."
        case kVK_ANSI_Slash: scalar = "/"
        case kVK_ANSI_Grave: scalar = "`"
        default: return 0
        }
        return scalar.value
    }

    /// The character that names the key a press holds, independent of the
    /// active layout: what Kitty's base-layout key reports and what a chord on
    /// a non-ASCII key folds through.
    ///
    /// Under a layout whose own character is not ASCII the ASCII-capable
    /// layout answers, since that is the Latin a Cyrillic, Greek or Hebrew
    /// typist types on. Otherwise, and when that layout names no printable
    /// character for the key (German ü answers itself), the US character does.
    ///
    /// - Parameters:
    ///   - keyCode: The hardware key code.
    ///   - unshifted: The active layout's character for the key with no modifier.
    ///   - shifted: The active layout's character for the key with Shift alone.
    /// - Returns: A printable ASCII code point, or 0 for a key with none.
    package static func baseLayoutCharacter(forKeyCode keyCode: UInt16, unshifted: UInt32, shifted: UInt32) -> UInt32 {
        if unshifted >= 0x80 || shifted >= 0x80 {
            let asciiCapable = asciiCapableCharacter(forKeyCode: keyCode)
            if asciiCapable >= 0x20 && asciiCapable < 0x7F { return asciiCapable }
        }
        return usANSICharacter(forKeyCode: keyCode)
    }
}
