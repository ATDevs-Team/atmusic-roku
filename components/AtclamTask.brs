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

' Runs ATCLAM work off the render thread (the VM is an interpreter written in BrightScript - see AtclamVm.brs).
sub init()
    m.top.functionName = "run"
end sub

sub run()
    req = m.top.request
    if req = invalid then return
    if req.kind = "test" or req.kind = "conformance"
        m.top.result = RunConformance()
    else if req.kind = "probe"
        t = ""
        for each nm in ["Poly", "Polygon", "Rectangle", "Poster", "LayoutGroup", "ArrayGrid", "Canvas", "Group"]
            n = CreateObject("roSGNode", nm)
            if n = invalid then t = t + nm + "=none " else t = t + nm + "=" + n.subtype() + " "
        end for
        m.top.result = {ok: true, text: t}
    end if
end sub

' fixtures encode numbers as {"n": "<exact decimal text>"} so they survive ParseJson exactly
function DecodeTagged(j as dynamic) as dynamic
    t = type(j)
    if t = "roAssociativeArray"
        if j.DoesExist("n") then return AtclamParseNumber(j.n)
        return j
    else if t = "roArray"
        out = []
        for each x in j
            out.Push(DecodeTagged(x))
        end for
        return out
    end if
    return j
end function

function RunConformance() as object
    raw = ReadAsciiFile("pkg:/data/atclam-conformance.json")
    if raw = "" then return {ok: false, text: "conformance fixtures missing"}
    suite = ParseJson(raw)
    if suite = invalid then return {ok: false, text: "conformance fixtures unreadable"}
    pass = 0
    total = 0
    fails = []
    clock = CreateObject("roTimespan")
    for each c in suite.cases
        total = total + 1
        why = RunCase(c)
        if why = ""
            pass = pass + 1
        else
            fails.Push(c.name + ": " + why)
            DLog("atclam", "FAIL " + c.name + ": " + why)
        end if
    end for
    text = "ATCLAM conformance on this device: " + pass.ToStr() + " / " + total.ToStr() + " passed (" + clock.TotalMilliseconds().ToStr() + " ms)"
    for each f in fails
        text = text + Chr(10) + "FAIL " + f
    end for
    return {ok: (pass = total), text: text}
end function

function RunCase(c as object) as string
    loaded = AtclamLoad(c.bytecode_b64)
    if not loaded.ok then return "load failed: " + loaded.msg
    values = {}
    values.SetModeCaseSensitive()
    for each kv in c.values
        values[kv[0]] = DecodeTagged(kv[1])
    end for
    tokens = {}
    tokens.SetModeCaseSensitive()
    for each k in c.version_tokens
        tokens[k] = c.version_tokens[k]
    end for
    ctx = AtclamNewContext(values, tokens, c.fuel_budget)
    got = AtclamExecuteHandler(loaded.module, c.event, ctx)
    return CompareOutcome(got, c.expect)
end function

' Expected numbers are decimal text from the reference VM (shortest round-trip form, up to 17 digits);
' BrightScript can't parse >15-digit decimals exactly, so the CHECKER allows 2 ulps (4.5e-16 relative).
' The VM's own arithmetic is not affected - it is plain IEEE doubles.
function SameValue(got as dynamic, exp as dynamic) as boolean
    if type(got) = "roArray" and type(exp) = "roArray"
        if got.Count() <> exp.Count() then return false
        for i = 0 to got.Count() - 1
            if not SameValue(got[i], exp[i]) then return false
        end for
        return true
    end if
    if AtclamIsNum(got) and AtclamIsNum(exp)
        if got = exp then return true
        d = got - exp
        if d < 0 then d = -d
        a = exp
        if a < 0 then a = -a
        return (d <= a * 4.5e-16#)
    end if
    return AtclamEq(got, exp)
end function

function CompareOutcome(got as object, exp as object) as string
    if exp.ok = false
        if got.ok then return "expected error '" + exp.error_kind + "' but it succeeded"
        if got.kind <> exp.error_kind then return "expected error '" + exp.error_kind + "' got '" + got.kind + "' (" + got.msg + ")"
        return ""
    end if
    if not got.ok then return "unexpected error '" + got.kind + "': " + got.msg
    if got.host_calls.Count() <> exp.host_calls.Count() then return "host_calls count " + got.host_calls.Count().ToStr() + " != " + exp.host_calls.Count().ToStr()
    for i = 0 to exp.host_calls.Count() - 1
        eh = exp.host_calls[i]
        gh = got.host_calls[i]
        if gh.name <> eh.name then return "host_calls[" + i.ToStr() + "].name " + gh.name
        ea = DecodeTagged(eh.args)
        if gh.args.Count() <> ea.Count() then return "host_calls[" + i.ToStr() + "] arg count"
        for k = 0 to ea.Count() - 1
            if not SameValue(AtclamIngest(gh.args[k]), ea[k]) then return "host_calls[" + i.ToStr() + "].args[" + k.ToStr() + "]: got " + AtclamShow(gh.args[k]) + " expected " + AtclamShow(ea[k])
        end for
    end for
    if got.storage_ops.Count() <> exp.storage_ops.Count() then return "storage_ops count " + got.storage_ops.Count().ToStr()
    for i = 0 to exp.storage_ops.Count() - 1
        eo = exp.storage_ops[i]
        go = got.storage_ops[i]
        if go.op <> eo.op or go.path <> eo.path then return "storage_ops[" + i.ToStr() + "] op/path"
        if eo.op = "increment"
            if go.by <> DecodeTagged(eo.by) then return "storage_ops[" + i.ToStr() + "].by"
        else
            if not AtclamEq(go.value, DecodeTagged(eo.value)) then return "storage_ops[" + i.ToStr() + "].value"
            if go.expected_version <> eo.expected_version then return "storage_ops[" + i.ToStr() + "].expected_version"
        end if
    end for
    if got.cancelled <> exp.cancelled then return "cancelled " + got.cancelled.ToStr()
    if got.fuel_used <> exp.fuel_used then return "fuel_used " + got.fuel_used.ToStr() + " != " + exp.fuel_used.ToStr()
    return ""
end function
