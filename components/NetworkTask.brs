' ATMusic for Roku
' Copyright (C) 2026 ATDevs Team
'
' This program is free software: you can redistribute it and/or modify
' it under the terms of the GNU General Public License as published by
' the Free Software Foundation, either version 3 of the License, or
' (at your option) any later version.
'
' This program is distributed in the hope that it will be useful,
' but WITHOUT ANY WARRANTY; without even the implied warranty of
' MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
' GNU General Public License for more details.
'
' You should have received a copy of the GNU General Public License
' along with this program.  If not, see <https://www.gnu.org/licenses/>.

' ============================================================================
' NetworkTask.brs
'
' One task type for every API call the app makes: Spool health checks, the
' ATDevs update check, and every /api/... call to the Spool backend itself
' (feed, search, playlists, auth, likes, favorites, ...).
'
' Uses the ASYNC roUrlTransfer methods + a message port, because the HTTP
' status code is only available on the roUrlEvent that comes back from
' those - the synchronous GetToString() call doesn't expose a response
' code at all (mixing sync GET with a sync-returned-code POST just to get
' a status code isn't worth the inconsistency), so everything goes through
' the same async + wait() pattern.
'
' Session auth uses Flask's cookie-based session, so EnableCookies() is
' called on every request - Roku's ifHttpAgent keeps a shared cookie cache
' for the app, so the session cookie set by /api/auth/login is automatically
' attached to every request after that, with no manual cookie plumbing.
' ============================================================================

sub init()
    m.top.functionName = "doRequest"
end sub

sub doRequest()
    url = m.top.requestUrl
    id = m.top.requestId
    httpMethod = m.top.requestMethod
    if httpMethod = invalid or httpMethod = "" then httpMethod = "GET"

    result = {
        requestId: id
        success: false
        code: -1
        body: ""
        json: invalid
    }

    if httpMethod = "RESTORE"
        RestoreCookies()
        result.success = true
        result.code = 200
        m.top.response = result
        return
    end if

    xfer = CreateObject("roUrlTransfer")
    port = CreateObject("roMessagePort")
    xfer.SetMessagePort(port)
    xfer.SetCertificatesFile("common:/certs/ca-bundle.crt")
    xfer.InitClientCertificates()
    xfer.EnableCookies()
    EnsureSavedSession(xfer)
    xfer.SetUrl(url)
    xfer.EnableEncodings(true)
    xfer.RetainBodyOnError(true)
    xfer.AddHeader("Accept", "application/json")
    xfer.AddHeader("User-Agent", "Spool-Roku")

    ' CSRF: the backend (app.py enforce_csrf) requires every mutating request made
    ' with a session to echo the non-HttpOnly csrf_token cookie ("<token>.<version>")
    ' as X-CSRF-Token (token part only). The cookie jar is shared via EnableCookies().
    if httpMethod <> "GET"
        csrf = FindCsrfToken(xfer)
        if csrf <> "" then xfer.AddHeader("X-CSRF-Token", csrf)
    end if

    started = false
    clock = CreateObject("roTimespan")

    if httpMethod = "GET" or httpMethod = "DELETE"
        xfer.SetRequest(httpMethod)
        started = xfer.AsyncGetToString()
    else
        ' POST / PATCH - both send whatever's in requestJson (or an empty
        ' JSON body if the endpoint doesn't need one, e.g. logout).
        xfer.SetRequest(httpMethod)
        xfer.AddHeader("Content-Type", "application/json")
        payload = m.top.requestJson
        if payload = invalid then payload = {}
        jsonBody = FormatJson(payload)
        started = xfer.AsyncPostFromString(jsonBody)
    end if

    if not started
        DLog("error", "http couldn't start " + httpMethod + " " + LogPath(url))
        ' Couldn't even issue the request (malformed URL, etc).
        m.top.response = result
        return
    end if

    msg = wait(20000, port) ' 20s timeout
    isDbg = (Instr(1, url, "/api/debug/") > 0)

    if msg = invalid
        if not isDbg then DLog("error", "http timeout " + httpMethod + " " + LogPath(url) + " after " + clock.TotalMilliseconds().ToStr() + "ms")
        xfer.AsyncCancel()
        m.top.response = result
        return
    end if

    if type(msg) <> "roUrlEvent"
        m.top.response = result
        return
    end if

    code = msg.GetResponseCode()
    body = msg.GetString()
    if not isDbg
        lvl = "net"
        if code < 0 or code >= 400 then lvl = "error"
        DLog(lvl, "http " + httpMethod + " " + LogPath(url) + " -> " + code.ToStr() + " in " + clock.TotalMilliseconds().ToStr() + "ms bytes=" + Len(body).ToStr())
    end if

    result.code = code
    result.body = body
    result.success = (code >= 200 and code < 300)

    if body <> invalid and body <> ""
        parsed = ParseJson(body)
        if parsed <> invalid
            result.json = parsed
        end if
    end if

    ' Belt-and-suspenders detection of Cloudflare's "Argo Tunnel error"
    ' (internal error 1033) page, used by the Spool health check - it's
    ' normally an HTTP 530, but flag the body text too just in case.
    if body <> invalid and (Instr(1, body, "Error 1033") > 0 or Instr(1, body, "Argo Tunnel") > 0)
        result.cloudflareTunnelError = true
    else
        result.cloudflareTunnelError = false
    end if

    ' Keep the login across app restarts: persist the cookie jar after a successful
    ' login, remove it on logout (RestoreCookies() reads it back at startup).
    if result.success and Instr(1, url, "/api/auth/logout") = 0
        SaveCookies(xfer)
    end if
    if Instr(1, url, "/api/auth/logout") > 0
        reg = CreateObject("roRegistrySection", "atmusic")
        reg.Delete("cookies")
        reg.Flush()
    end if

    m.top.response = result
end sub

sub SaveCookies(xfer as object)
    cookies = xfer.GetCookies("atmusic.atdevs.org", "/")
    if cookies = invalid or cookies.Count() = 0 then return
    ' only persist once there is a login session (the "session" cookie), so an
    ' anonymous visitor's csrf-only jar never overwrites/clobbers anything
    hasSession = false
    for each c in cookies
        if c.Name = "session" then hasSession = true
    end for
    if not hasSession then return
    ' FormatJson() returns "" if any value isn't plain JSON (e.g. a date object), so
    ' flatten every field to a string/number/boolean first
    plain = []
    for each c in cookies
        o = {}
        for each key in c
            v = c[key]
            tv = type(v)
            if tv = "roString" or tv = "String" or tv = "roInt" or tv = "Integer" or tv = "roBoolean" or tv = "Boolean" or tv = "roFloat" or tv = "Float"
                o[key] = v
            else if v <> invalid and GetInterface(v, "ifToStr") <> invalid
                o[key] = v.ToStr()
            end if
        end for
        plain.push(o)
    end for
    js = FormatJson(plain)
    keys = ""
    for each key in plain[0]
        keys = keys + key + ","
    end for
    print "[atmusic] cookie fields: " + keys
    reg = CreateObject("roRegistrySection", "atmusic")
    reg.Write("cookies", js)
    ok = reg.Flush()
    print "[atmusic] saved " + cookies.Count().ToStr() + " cookies (" + Len(js).ToStr() + " bytes) flush=" + ok.ToStr()
end sub

sub RestoreCookies()
    reg = CreateObject("roRegistrySection", "atmusic")
    if not reg.Exists("cookies") then return
    saved = ParseJson(reg.Read("cookies"))
    if saved = invalid then return
    xfer = CreateObject("roUrlTransfer")
    xfer.EnableCookies()
    ok = xfer.AddCookies(saved)
    print "[atmusic] restored " + saved.Count().ToStr() + " cookies ok=" + ok.ToStr()
end sub

function FindCsrfToken(xfer as object) as string
    cookies = xfer.GetCookies("atmusic.atdevs.org", "/")
    if cookies = invalid then return ""
    for each c in cookies
        if c.Name = "csrf_token"
            raw = c.Value
            if raw = invalid then return ""
            ' value is "<token>.<VERSION>": the token itself is URL-safe base64 and has no dots
            dot = Instr(1, raw, ".")
            if dot > 1 then return Left(raw, dot - 1)
            return raw
        end if
    end for
    return ""
end function

' If this request's cookie jar has no login session but one was saved in the
' registry, load it. Done per request (not once at startup) because the jar is
' not reliably shared between task threads.
sub EnsureSavedSession(xfer as object)
    cookies = xfer.GetCookies("atmusic.atdevs.org", "/")
    if cookies <> invalid
        for each c in cookies
            if c.Name = "session" then return
        end for
    end if
    reg = CreateObject("roRegistrySection", "atmusic")
    if not reg.Exists("cookies") then return
    saved = ParseJson(reg.Read("cookies"))
    if saved <> invalid then xfer.AddCookies(saved)
end sub
