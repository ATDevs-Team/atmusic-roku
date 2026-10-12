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
' DebugTask.brs - background thread that collects DLog() entries and emits
' them in batches. Best effort: the buffer is bounded (oldest dropped) and a
' batch that fails to send is not retried.
' ============================================================================

sub init()
    m.top.functionName = "run"
end sub

sub run()
    port = CreateObject("roMessagePort")
    m.global.observeField("dbg", port)
    m.top.observeField("canSend", port)
    m.top.ready = true

    buf = []
    maxBuf = 500
    perBatch = 150
    clock = CreateObject("roTimespan")

    while true
        msg = wait(1000, port)
        if type(msg) = "roSGNodeEvent"
            if msg.GetField() = "dbg"
                d = msg.GetData()
                if d <> invalid
                    buf.Push(d)
                    if buf.Count() > maxBuf then buf.Shift()
                end if
            end if
        end if

        if m.top.canSend and buf.Count() > 0
            if buf.Count() >= 40 or clock.TotalMilliseconds() >= 8000
                n = buf.Count()
                if n > perBatch then n = perBatch
                batch = []
                for i = 1 to n
                    batch.Push(buf.Shift())
                end for
                m.top.batch = {entries: batch, session: m.top.session}
                clock.Mark()
            end if
        else if buf.Count() = 0
            clock.Mark()
        end if
    end while
end sub
