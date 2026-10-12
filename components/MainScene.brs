' ============================================================================
' MainScene.brs
'
' Two independent background pollers:
'
'   1. Spool health check   -> GET https://atmusic.atdevs.org/api/system/status
'      every 15s. Distinguishes "down" (Cloudflare/edge-level failure: HTTP
'      503 bad gateway, 530 origin DNS error, or a 1033 tunnel-error page)
'      from "updating" (Spool answers fine, but its own status payload says
'      an update is in progress).
'
'   2. Client update check  -> GET https://updates.atdevs.org/check/roku/spool
'      every 30s, per the ATDevs Update API.
'
' Whichever condition is most "blocking" wins the screen:
'   Spool down > Spool updating > client update required > client update
'   available (unless already dismissed) > normal app content.
' ============================================================================

sub init()
    m.currentVersion = "0.4.6"
    m.platform = "roku"
    m.service = "spool"   ' update-service id; the roku/atmusic id is not registered on updates.atdevs.org yet

    m.spoolStatusUrl = "https://atmusic.atdevs.org/api/system/status"
    m.updateApiUrl = "https://updates.atdevs.org/check/" + m.platform + "/" + m.service + "?myversion=" + m.currentVersion

    m.spoolStatus = "checking"        ' checking | down | updating | ok
    m.clientUpdateStatus = "checking" ' checking | none | available | required
    m.updateDismissed = false
    m.dismissedVersion = ""
    m.latestVersion = ""
    m.minimumVersion = ""
    m.updateUrl = ""

    m.focusIndex = 0        ' 0 = Update, 1 = Dismiss
    m.buttonsVisible = false
    m.dismissAllowed = false
    m.appReady = false ' becomes true the first time nothing is blocking

    ' ---- node refs ----
    m.appShell = m.top.findNode("appShell")
    m.messageLayer = m.top.findNode("messageLayer")
    m.titleLabel = m.top.findNode("titleLabel")
    m.bodyLabel = m.top.findNode("bodyLabel")
    m.versionLabel = m.top.findNode("versionLabel")
    m.buttonRow = m.top.findNode("buttonRow")
    m.updateBtnBg = m.top.findNode("updateBtnBg")
    m.updateBtnLabel = m.top.findNode("updateBtnLabel")
    m.dismissBtnBg = m.top.findNode("dismissBtnBg")
    m.dismissBtnLabel = m.top.findNode("dismissBtnLabel")
    m.bannerGroup = m.top.findNode("bannerGroup")

    ' ---- Spool health poller ----
    m.spoolTask = CreateObject("roSGNode", "NetworkTask")
    m.spoolTask.ObserveField("response", "onSpoolResponse")

    m.spoolTimer = CreateObject("roSGNode", "Timer")
    m.spoolTimer.repeat = true
    m.spoolTimer.duration = 15
    m.spoolTimer.ObserveField("fire", "onSpoolTimerFire")

    ' ---- Client update poller (every 30s, per the update API docs) ----
    m.updateTask = CreateObject("roSGNode", "NetworkTask")
    m.updateTask.ObserveField("response", "onUpdateResponse")

    m.updateTimer = CreateObject("roSGNode", "Timer")
    m.updateTimer.repeat = true
    m.updateTimer.duration = 30
    m.updateTimer.ObserveField("fire", "onUpdateTimerFire")

    m.top.setFocus(true)

    ' Kick off an immediate check of both, then let the timers take over.
    checkSpoolStatus()
    checkClientUpdate()
    m.spoolTimer.control = "start"
    m.updateTimer.control = "start"
end sub

' ---------------------------------------------------------------- pollers --

sub onSpoolTimerFire()
    checkSpoolStatus()
end sub

sub onUpdateTimerFire()
    checkClientUpdate()
end sub

sub checkSpoolStatus()
    m.spoolTask.requestId = "spool"
    m.spoolTask.requestUrl = m.spoolStatusUrl
    m.spoolTask.control = "RUN"
end sub

sub checkClientUpdate()
    m.updateTask.requestId = "update"
    m.updateTask.requestUrl = m.updateApiUrl
    m.updateTask.control = "RUN"
end sub

' ------------------------------------------------------------- responses --

sub onSpoolResponse(event as object)
    DLog("status", "health check response")
    result = event.GetData()
    code = result.code
    json = result.json

    if code = 503 or code = 530 or result.cloudflareTunnelError = true
        ' Bad gateway, origin DNS failure, or a Cloudflare tunnel (1033)
        ' error page - Spool's origin is unreachable.
        m.spoolStatus = "down"
    else if result.success and json <> invalid and json.updating = true
        m.spoolStatus = "updating"
    else if result.success and json <> invalid
        m.spoolStatus = "ok"
    else
        ' Anything else we can't make sense of (timeout, DNS failure on the
        ' Roku's side, unexpected body, etc.) - fail safe and treat Spool as
        ' unreachable rather than silently showing a broken app.
        m.spoolStatus = "down"
    end if

    render()
end sub

sub onUpdateResponse(event as object)
    DLog("status", "update check response")
    result = event.GetData()
    json = result.json

    if not result.success or json = invalid
        ' Couldn't reach the update API this round - keep whatever state we
        ' already had and just try again on the next 30s tick.
        return
    end if

    status = json.status
    if json.latest_version <> invalid then m.latestVersion = json.latest_version
    if json.minimum_version <> invalid then m.minimumVersion = json.minimum_version
    if json.update_url <> invalid then m.updateUrl = json.update_url

    if status = "update_required"
        m.clientUpdateStatus = "required"
    else if status = "update_available"
        ' If a *new* version showed up since the user last dismissed one,
        ' surface the prompt again instead of leaving it dismissed forever.
        if m.updateDismissed and m.dismissedVersion <> m.latestVersion
            m.updateDismissed = false
        end if
        m.clientUpdateStatus = "available"
    else
        m.clientUpdateStatus = "none"
    end if

    render()
end sub

' ------------------------------------------------------------------ view --

sub render()
    DLog("status", "render spool=" + m.spoolStatus + " update=" + m.clientUpdateStatus)
    if m.spoolStatus = "down"
        showFullScreenMessage("ATMusic is Down", "We can't reach ATMusic's servers right now. Please try again in a few minutes.", false, false, false)
        m.appShell.visible = false
        m.bannerGroup.visible = false
        return
    end if

    if m.spoolStatus = "updating"
        showFullScreenMessage("ATMusic is Updating", "ATMusic's servers are currently being updated. Hang tight, this shouldn't take long.", false, false, false)
        m.appShell.visible = false
        m.bannerGroup.visible = false
        return
    end if

    if m.clientUpdateStatus = "required"
        showFullScreenMessage("Update Required", "An update is required to continue using the app.", true, false, true)
        m.appShell.visible = false
        m.bannerGroup.visible = false
        return
    end if

    if m.clientUpdateStatus = "available" and not m.updateDismissed
        showFullScreenMessage("Update Available", "A new version of ATMusic is available.", true, true, true)
        m.appShell.visible = false
        m.bannerGroup.visible = false
        return
    end if

    ' Nothing blocking - show normal app content. Only hand real SceneGraph
    ' focus to AppShell the first time we get here; on later render() calls
    ' (the pollers keep firing every 15s/30s) AppShell may already hold
    ' focus deep inside a dialog or the grid, and re-stealing it would be
    ' disruptive.
    m.messageLayer.visible = false
    m.buttonsVisible = false
    m.appShell.visible = true
    m.bannerGroup.visible = (m.updateDismissed and m.clientUpdateStatus <> "none")

    if not m.appReady
        m.appReady = true
        m.appShell.setFocus(true)
    end if
end sub

sub showFullScreenMessage(title as string, body as string, showButtons as boolean, allowDismiss as boolean, showVersion as boolean)
    m.titleLabel.text = title
    m.bodyLabel.text = body

    if showVersion and m.latestVersion <> ""
        m.versionLabel.text = "Current version: " + m.currentVersion + "    Latest version: " + m.latestVersion
        m.versionLabel.visible = true
    else
        m.versionLabel.visible = false
    end if

    m.buttonsVisible = showButtons
    m.dismissAllowed = showButtons and allowDismiss
    m.buttonRow.visible = showButtons
    m.dismissBtnBg.visible = m.dismissAllowed
    m.dismissBtnLabel.visible = m.dismissAllowed

    if showButtons
        m.focusIndex = 0
        updateButtonFocusVisual()
    end if

    m.messageLayer.visible = true
end sub

sub updateButtonFocusVisual()
    focusedBg = "0xFFFFFFFF"
    unfocusedBg = "0x2A2A2FFF"
    focusedText = "0x111111FF"
    unfocusedText = "0xFFFFFFFF"

    if m.focusIndex = 0
        m.updateBtnBg.color = focusedBg
        m.updateBtnLabel.color = focusedText
        m.dismissBtnBg.color = unfocusedBg
        m.dismissBtnLabel.color = unfocusedText
    else
        m.updateBtnBg.color = unfocusedBg
        m.updateBtnLabel.color = unfocusedText
        m.dismissBtnBg.color = focusedBg
        m.dismissBtnLabel.color = focusedText
    end if
end sub

' --------------------------------------------------------------- actions --

sub onUpdatePressed()
    DLog("ui", "update button pressed")
    ' "click Update -> quit()". We can't launch the Channel Store /
    ' sideload flow ourselves, so exiting is the correct behavior: it drops
    ' the user back at the Home screen so they can grab the new version.
    m.top.exitApp = true
end sub

sub onDismissPressed()
    if not m.dismissAllowed then return
    m.updateDismissed = true
    m.dismissedVersion = m.latestVersion
    render()
end sub

' ------------------------------------------------------------- remote in --

function onKeyEvent(key as string, press as boolean) as boolean
    if not press then return false

    if m.buttonsVisible
        if key = "left"
            if m.dismissAllowed and m.focusIndex <> 0
                m.focusIndex = 0
                updateButtonFocusVisual()
            end if
            return true

        else if key = "right"
            if m.dismissAllowed and m.focusIndex <> 1
                m.focusIndex = 1
                updateButtonFocusVisual()
            end if
            return true

        else if key = "OK"
            if m.focusIndex = 0
                onUpdatePressed()
            else if m.dismissAllowed
                onDismissPressed()
            end if
            return true

        else if key = "back"
            ' On blocking screens (no dismiss button) swallow back entirely
            ' so the user can't escape a down/updating/required screen. When
            ' a dismiss button exists, back behaves like Dismiss.
            if m.dismissAllowed
                onDismissPressed()
            end if
            return true
        end if

        return false
    end if

    ' Gating screen isn't showing - let the app handle its own navigation.
    if m.appReady
        return m.appShell.callFunc("HandleKey", key, press)
    end if

    return false
end function
