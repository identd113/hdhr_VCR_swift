import Foundation

// Shared AppleScript building blocks for the live PiP/FEED UI tests (WindowNavigationTests'
// pipFullWorkoutOverLiveRecording and PiPTunerChurnTests). Notes that apply to every script built on these:
//  • `entire contents of <window>` returns an empty list on this macOS build, so everything walks
//    `UI elements` recursively (findWhere) instead.
//  • The PiP's right-click menu is a native NSMenu that AX can't see or trigger — pipMenuKeys right-clicks
//    with tools/ui_events.swift (compiled by the caller, path passed in) and drives the open menu by key.
//  • AppleScript reserved words bite: `which`, `named`, `pick`, `th` are all taken — don't reuse them.

/// The handler block (everything that goes *before* the top-level `tell`). `uiEvents` is the path of the
/// compiled tools/ui_events.swift binary; `axQuery` the compiled tools/ax_query.swift ("" = always use the slow walk).
func pipAXHandlers(uiEvents: String, axQuery: String = axQueryPath) -> String {
    return #"""
    -- Depth-first walk over `UI elements` rather than `entire contents`: on this macOS build
    -- `entire contents of <window>` returns an empty list (for every app, Terminal included)
    -- while the per-element walk still sees the whole tree. mode is "id" (AXIdentifier equals
    -- key) or "help" (AXHelp starts with key) or "role" (AXRole equals key) or "pipLive" (a Watch Now live-channel PiP button).
    --
    -- findWhere is the fast path: tools/ax_query.swift finds the element natively (well under a second, stops at the
    -- first hit) and prints its child-index path from the window; that path is then walked with `UI element N of …`
    -- to get a normal System Events reference. The slow recursive walk (findWhereSlow, one Apple event per element —
    -- minutes on a Watch Now window listing every channel) is only the fallback for a missing binary / non-window `el`
    -- / a path that doesn't resolve. `el` must be a window.
    property axQuery : "\#(axQuery)"

    -- Is the ax_query binary usable on the machine this script runs on? (The FEED churn test runs the same script on
    -- the laptop, where the mini's path doesn't exist — that must fall back to the slow walk, not read as "not found".)
    property axChecked : false
    property axUsable : false
    on axOK()
        if axChecked then return axUsable
        set axChecked to true
        if axQuery is "" then return false
        try
            do shell script "test -x " & (quoted form of axQuery)
            set axUsable to true
        end try
        return axUsable
    end axOK

    on findWhere(el, mode, key)
        set r to my findWhereOpt(el, mode, key, false)
        if class of r is text then return my findWhereSlow(el, mode, key)
        return r
    end findWhere

    -- Fast lookup. Returns the element, `missing value` (searched, nothing there), or the text "NOFAST" when ax_query can't be
    -- used here (callers then fall back to their own slow walk). wantLast = the last match in document order instead of the first.
    on findWhereOpt(el, mode, key, wantLast)
        if not my axOK() then return "NOFAST"
        set winName to ""
        try
            tell application "System Events" to set winName to name of el
        end try
        if winName is "" or winName is missing value then return "NOFAST"
        if mode is "id" then
            set spec to "id=" & key
        else if mode is "role" then
            set spec to "role=" & key
        else if mode is "recPrimary" then
            set spec to "help^=Play the in-progress recording of&help$=starting near live"
        else if mode is "pipLive" then
            set spec to "help^=Watch &help$=alongside what's already open"
        else
            set spec to "help^=" & key
        end if
        set cmd to (quoted form of axQuery) & " find " & (quoted form of winName) & " " & (quoted form of spec)
        if wantLast then set cmd to cmd & " --last"
        set hit to ""
        try
            set hit to do shell script cmd
        on error errMsg number errNum
            -- exit status 1 = searched and found nothing; anything else = the tool itself failed
            if errNum is 1 then return missing value
            return "NOFAST"
        end try
        if hit is "" then return "NOFAST"
        try
            set AppleScript's text item delimiters to "|"
            set pathStr to last text item of hit
            set AppleScript's text item delimiters to "/"
            set idxs to text items of pathStr
            set AppleScript's text item delimiters to ""
            tell application "System Events"
                set cur to el
                repeat with i in idxs
                    set cur to UI element (i as integer) of cur
                end repeat
            end tell
            return cur
        on error
            set AppleScript's text item delimiters to ""
            return "NOFAST"
        end try
    end findWhereOpt

    on findWhereSlow(el, mode, key)
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
                set hit to my findWhereSlow(k, mode, key)
                if hit is not missing value then return hit
            end repeat
        end tell
        return missing value
    end findWhereSlow

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
    on pickPipChannel(win, mode, skipChannel)
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
