import Foundation

// Shared AppleScript building blocks for the live PiP/FEED UI tests (WindowNavigationTests'
// pipFullWorkoutOverLiveRecording and PiPTunerChurnTests). Notes that apply to every script built on these:
//  • `entire contents of <window>` returns an empty list on this macOS build, so everything walks
//    `UI elements` recursively (findWhere) instead.
//  • The PiP's right-click menu is a native NSMenu that AX can't see or trigger — pipMenuKeys right-clicks
//    with tools/ui_events.swift (compiled by the caller, path passed in) and drives the open menu by key.
//  • AppleScript reserved words bite: `which`, `named`, `pick`, `th` are all taken — don't reuse them.

/// The handler block (everything that goes *before* the top-level `tell`). `uiEvents` is the path of the
/// compiled tools/ui_events.swift binary.
func pipAXHandlers(uiEvents: String) -> String {
    return #"""
    -- Depth-first walk over `UI elements` rather than `entire contents`: on this macOS build
    -- `entire contents of <window>` returns an empty list (for every app, Terminal included)
    -- while the per-element walk still sees the whole tree. mode is "id" (AXIdentifier equals
    -- key) or "help" (AXHelp starts with key) or "pipLive" (a Watch Now live-channel PiP button).
    on findWhere(el, mode, key)
        tell application "System Events"
            try
                set kids to UI elements of el
            on error
                return missing value
            end try
            repeat with k in kids
                try
                    if mode is "id" then
                        if ((value of attribute "AXIdentifier" of k) as string) is key then return k
                    else if mode is "recPrimary" then
                        set hlp to (help of k) as string
                        if hlp starts with "Play the in-progress recording of" and hlp ends with "starting near live" then return k
                    else if mode is "pipLive" then
                        set hlp to (help of k) as string
                        if hlp starts with "Watch " and hlp ends with "alongside what's already open" then return k
                    else
                        if ((help of k) as string) starts with key then return k
                    end if
                end try
                set hit to my findWhere(k, mode, key)
                if hit is not missing value then return hit
            end repeat
        end tell
        return missing value
    end findWhere

    on findById(win, ident)
        return my findWhere(win, "id", ident)
    end findById

    on waitById(win, ident, tries)
        repeat tries times
            set e to my findById(win, ident)
            if e is not missing value then return e
            delay 0.25
        end repeat
        return missing value
    end waitById

    property uiEvents : "\#(uiEvents)"

    -- The PiP's context menu is a native NSMenu that AX can't see or trigger, so: real
    -- right-click on the thumbnail's centre, then drive the open menu with arrow keys
    -- (125 down, 126 up, 124 right, 36 return) posted to the app's own process.
    on pipMenuKeys(win, codes)
        tell application "System Events"
            set thumbEl to my waitById(win, "vlc-pip-thumbnail", 20)
            if thumbEl is missing value then return "NO_THUMB"
            set p to position of thumbEl
            set sz to size of thumbEl
            set cx to ((item 1 of p) + (item 1 of sz) / 2) as integer
            set cy to ((item 2 of p) + (item 2 of sz) / 2) as integer
        end tell
        do shell script quoted form of uiEvents & " rightclick " & cx & " " & cy
        delay 0.7
        set arg to ""
        repeat with c in codes
            set arg to arg & " " & (c as string)
        end repeat
        do shell script quoted form of uiEvents & " keys" & arg
        return "OK"
    end pipMenuKeys

    -- Menu order: Top Left, Top Right, Bottom Left, Bottom Right, Channel ▸, Close.
    on moveToCorner(win, idx)
        set codes to {}
        repeat idx times
            set end of codes to 125
        end repeat
        set end of codes to 36
        return my pipMenuKeys(win, codes)
    end moveToCorner

    -- Channel ▸ is the 5th item; Right opens its submenu on the first channel. "second" steps
    -- down once, "last" steps up once (menus wrap).
    on pickPipChannel(win, mode)
        set codes to {125, 125, 125, 125, 125, 124}
        if mode is "last" then
            set end of codes to 126
        else
            set end of codes to 125
        end if
        set end of codes to 36
        return my pipMenuKeys(win, codes)
    end pickPipChannel

    -- Toolbar channel picker: first enabled row that looks like a channel ("5.1  KXYZ") and
    -- isn't what's already selected.
    on pickPrimaryChannel(win, skipChannel)
        tell application "System Events"
            set picker to my waitById(win, "vlc-channel-picker", 20)
            if picker is missing value then return "NO_PICKER"
            set currentVal to ""
            try
                set currentVal to (value of picker) as string
            end try
            click picker
            repeat 10 times
                try
                    repeat with mi in (every menu item of menu 1 of picker)
                        try
                            set nm to name of mi
                            if nm is not missing value and nm is not currentVal and (enabled of mi) and (character 1 of nm) is in "0123456789" and not (nm starts with (skipChannel & " ")) then
                                click mi
                                return "OK:" & nm
                            end if
                        end try
                    end repeat
                end try
                delay 0.25
            end repeat
            key code 53
        end tell
        return "NO_PICKER_ITEM"
    end pickPrimaryChannel

    on thumbPosition(win)
        tell application "System Events"
            set thumb to my waitById(win, "vlc-pip-thumbnail", 20)
            if thumb is missing value then return "NO_THUMB"
            set p to position of thumb
            return ((item 1 of p) as string) & "," & ((item 2 of p) as string)
        end tell
    end thumbPosition

    """#
}
