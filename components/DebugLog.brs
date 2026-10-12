' ============================================================================
' DebugLog.brs - client debug logging, shared by every component.
'
' DLog(level, msg) prints to the BrightScript console AND (when debug mode is
' on, the default) posts the entry to m.global.dbg. A background DebugTask
' observes that field, batches entries and hands them to AppShell, which
' sends them to POST /api/debug/logs (same endpoint the web client's debug
' mode uses). It is safe to call from the render thread and from tasks.
'
' Never put secrets in a message: no passwords, codes, tokens, cookie values
' or request bodies. Use LogPath() for URLs.
' ============================================================================

sub DLog(level as string, msg as string)
    print "[atm] " + level + " " + msg
    g = m.global
    if g = invalid then return
    if g.debugOn <> true then return
    g.dbg = {level: level, msg: Left(msg, 1800), ts: CreateObject("roDateTime").ToISOString(), screen: Txt0(g.screenName)}
end sub

function Txt0(v as dynamic) as string
    if v = invalid then return ""
    if GetInterface(v, "ifToStr") <> invalid then return v.ToStr()
    return ""
end function

' "https://host/api/qr-login/status/SECRET?x=1" -> "/api/qr-login/status/<token>"
function LogPath(url as string) as string
    p = url
    i = Instr(1, p, "://")
    if i > 0
        p = Mid(p, i + 3)
        j = Instr(1, p, "/")
        if j > 0 then p = Mid(p, j) else p = "/"
    end if
    q = Instr(1, p, "?")
    if q > 0 then p = Left(p, q - 1)
    st = Instr(1, p, "/qr-login/status/")
    if st > 0 then p = Left(p, st + Len("/qr-login/status/") - 1) + "<token>"
    return p
end function
