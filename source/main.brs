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
' main.brs
'
' Entry point for the Spool Roku channel. Boots the SceneGraph screen,
' hosts MainScene, and owns the top-level message loop. MainScene signals
' "please exit" by setting its exitApp field to true (see the Update button
' handler in MainScene.brs) - this loop is what actually turns that into a
' real quit by closing the screen.
' ============================================================================

sub Main(args as dynamic)
    screen = CreateObject("roSGScreen")
    port = CreateObject("roMessagePort")
    screen.SetMessagePort(port)

    ' ---- client debug mode (ON by default; toggle in Info > Debug logging) ----
    g = screen.GetGlobalNode()
    g.AddField("dbg", "assocarray", true)       ' alwaysNotify: every DLog() entry
    g.AddField("debugOn", "boolean", false)
    g.AddField("screenName", "string", false)
    g.AddField("sessionId", "string", false)
    reg = CreateObject("roRegistrySection", "atmusic")
    debugOn = true
    if reg.Exists("debug") and reg.Read("debug") = "0" then debugOn = false
    g.debugOn = debugOn
    g.AddField("launchAction", "string", false)   ' deep-link / ECP launch parameter, e.g. ?atclam=test
    if args <> invalid and args.atclam <> invalid then g.launchAction = "atclam:" + args.atclam
    g.sessionId = CreateObject("roDeviceInfo").GetRandomUUID()

    scene = screen.CreateScene("MainScene")
    scene.ObserveField("exitApp", port)

    screen.Show()

    while true
        msg = wait(0, port)
        msgType = type(msg)

        if msgType = "roSGScreenEvent"
            if msg.isScreenClosed()
                return
            end if
        else if msgType = "roSGNodeEvent"
            if msg.GetField() = "exitApp" and msg.GetData() = true
                ' This is the "quit()" the update prompt triggers when the
                ' user taps Update. Closing the screen exits the channel
                ' back to the Roku Home screen.
                screen.Close()
                return
            end if
        end if
    end while
end sub
