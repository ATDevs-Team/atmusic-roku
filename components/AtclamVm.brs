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
' AtclamVm.brs - the third conforming ATCLAM runtime (spec section 6.4/6.12): a
' bytecode interpreter written in BrightScript. It executes bytecode format v1/v2
' modules produced by atclam-compiler and behaves like the reference Rust VM
' (atclam-vm/src/interp.rs): same stack machine, same fuel accounting (every
' instruction costs 1), same host-call recording (the VM never performs a
' capability-gated call itself; the host does), same errors (kinds: fuel | type |
' no_handler | unknown_function | stack_underflow | bad_jump | stack_overflow).
'
' Values: Number = Double (always), String, Boolean, invalid (= null), roArray (= list).
' Lists are by VALUE like the reference VM: LoadLocal/arguments/results are deep-copied.
'
' Known BrightScript-specific points (all conformance-tested on a real Roku):
'  * ParseJson() makes decimals 32-bit Floats, so number literals are parsed here exactly.
'  * Division by zero throws in BrightScript, so IEEE results (inf/NaN) are produced by hand.
'  * Call depth is capped (MAX_DEPTH) - the reference VM has no cap; BrightScript's stack is small.
'  * A module's JSON payload is read as ASCII: non-ASCII characters in string literals are not supported.
' ============================================================================

function AtclamInf() as double
    big = 1.0e300#
    return big * big
end function

function AtclamNaN() as double
    inf = AtclamInf()
    return inf - inf
end function

' ---- number literal parsing ("123.456e-7" -> Double, correctly rounded for <= 15 significant digits) ----
function AtclamParseNumber(t as string) as double
    s = t
    neg = false
    if Left(s, 1) = "-"
        neg = true
        s = Mid(s, 2)
    end if
    exp10 = 0
    ePos = Instr(1, UCase(s), "E")
    if ePos > 0
        exp10 = Val(Mid(s, ePos + 1))
        s = Left(s, ePos - 1)
    end if
    mant# = 0.0#
    scale = 0
    seenDot = false
    for i = 1 to Len(s)
        c = Asc(Mid(s, i, 1))
        if c = 46
            seenDot = true
        else if c >= 48 and c <= 57
            mant# = mant# * 10.0# + (c - 48)
            if seenDot then scale = scale + 1
        end if
    end for
    e = exp10 - scale
    r# = mant#
    if e > 0
        for i = 1 to e
            r# = r# * 10.0#
        end for
    else if e < 0
        d# = 1.0#
        for i = 1 to -e
            d# = d# * 10.0#
        end for
        r# = r# / d#
    end if
    if neg then r# = -r#
    return r#
end function

' ---- loading ----------------------------------------------------------------
function AtclamLoad(b64 as string) as object
    ba = CreateObject("roByteArray")
    ba.FromBase64String(b64)
    if ba.Count() < 10 then return {ok: false, kind: "bad_module", msg: "truncated: shorter than the magic+version header"}
    magic = ""
    for i = 0 to 5
        magic = magic + Chr(ba[i])
    end for
    if magic <> "ATCLAM" then return {ok: false, kind: "bad_module", msg: "bad magic bytes - not an ATCLAM bytecode module"}
    ver = ba[6] * 16777216 + ba[7] * 65536 + ba[8] * 256 + ba[9]
    if ver > 2 then return {ok: false, kind: "unsupported_version", msg: "bytecode format version " + ver.ToStr() + " is newer than this runtime supports (2)"}

    ' the header holds NUL bytes (version is a big-endian u32), which would truncate ToAsciiString(),
    ' so copy the JSON payload out into its own byte array first
    pb = CreateObject("roByteArray")
    pb.SetResize(ba.Count() - 10, false)
    for i = 10 to ba.Count() - 1
        pb[i - 10] = ba[i]
    end for
    payload = pb.ToAsciiString()
    ' exact number literals: turn  "PushNumber":<num>  into  "PushNumber":"<num>"  before ParseJson sees it
    rx = CreateObject("roRegex", Chr(34) + "PushNumber" + Chr(34) + ":(-?[0-9.eE+-]+)", "")
    payload = rx.ReplaceAll(payload, Chr(34) + "PushNumber" + Chr(34) + ":" + Chr(34) + "\1" + Chr(34))
    mdl = ParseJson(payload)
    if mdl = invalid or type(mdl) <> "roAssociativeArray" then return {ok: false, kind: "bad_module", msg: "payload is not valid JSON"}

    mdl.fnIndex = {}
    mdl.fnIndex.SetModeCaseSensitive()
    if mdl.functions <> invalid
        for each f in mdl.functions
            AtclamPredecode(f.block)
            mdl.fnIndex[f.name] = f
        end for
    end if
    if mdl.handlers <> invalid
        for each h in mdl.handlers
            AtclamPredecode(h.block)
        end for
    end if
    return {ok: true, module: mdl}
end function

' serde's externally-tagged enum -> {o: "Name", v: payload}
sub AtclamPredecode(block as object)
    dec = []
    for each ins in block.code
        if type(ins) = "roString" or type(ins) = "String"
            dec.Push({o: ins, v: invalid})
        else
            for each k in ins
                v = ins[k]
                if k = "PushNumber" then v = AtclamParseNumber(v)
                dec.Push({o: k, v: v})
            end for
        end if
    end for
    block.dec = dec
end sub

' ---- values -------------------------------------------------------------------
function AtclamCopy(v as dynamic) as dynamic
    if type(v) = "roArray"
        out = []
        for each x in v
            out.Push(AtclamCopy(x))
        end for
        return out
    end if
    return v
end function

' normalize a value coming from the host/JSON into VM values (numbers -> Double)
function AtclamIngest(v as dynamic) as dynamic
    t = type(v)
    if AtclamIsNumType(t)
        return v + 0.0#          ' (CDbl() misbehaves on this firmware)
    else if t = "roArray"
        out = []
        for each x in v
            out.Push(AtclamIngest(x))
        end for
        return out
    end if
    if t = "roString" or t = "String" then return v + ""
    return v
end function

' type() reports a Double that lives in an array/AA as "roFloat" on this firmware even though the value
' keeps full double precision (verified), so every numeric type name counts as a number.
function AtclamIsNumType(t as string) as boolean
    return (t = "Double" or t = "roDouble" or t = "Float" or t = "roFloat" or t = "Integer" or t = "roInt" or t = "roInteger" or t = "LongInteger" or t = "roLongInteger")
end function

function AtclamIsNum(v as dynamic) as boolean
    return AtclamIsNumType(type(v))
end function

function AtclamTruthy(v as dynamic) as boolean
    t = type(v)
    if t = "Boolean" or t = "roBoolean" then return v
    if AtclamIsNumType(t) then return (v <> 0.0#)
    if t = "roString" or t = "String" then return Len(v) > 0
    if t = "roArray" then return v.Count() > 0
    return false
end function

function AtclamEq(a as dynamic, b as dynamic) as boolean
    ta = type(a)
    tb = type(b)
    if ta = "roString" or ta = "String"
        if tb = "roString" or tb = "String" then return (a = b)
        return false
    end if
    if AtclamIsNumType(ta)
        if AtclamIsNumType(tb) then return (a = b)
        return false
    end if
    if ta = "Boolean" or ta = "roBoolean"
        if tb = "Boolean" or tb = "roBoolean" then return (a = b)
        return false
    end if
    if ta = "roArray"
        if tb <> "roArray" then return false
        if a.Count() <> b.Count() then return false
        for i = 0 to a.Count() - 1
            if not AtclamEq(a[i], b[i]) then return false
        end for
        return true
    end if
    ' null == null
    return (a = invalid and b = invalid)
end function

function AtclamShow(v as dynamic) as string
    t = type(v)
    if AtclamIsNumType(t) then return Str(v).Trim()
    if t = "roString" or t = "String" then return v
    if t = "Boolean" or t = "roBoolean" then
        if v then return "true"
        return "false"
    end if
    if t = "roArray" then return "[list]"
    return "null"
end function

' ---- context -----------------------------------------------------------------
function AtclamNewContext(values as object, tokens as object, fuelBudget as integer) as object
    return {
        values: values
        tokens: tokens
        host_calls: []
        storage_ops: []
        cancelled: false
        fuel: fuelBudget
        budget: fuelBudget
        fuel_used: 0
        err: ""
        errMsg: ""
        depth: 0
        linked: {}
    }
end function

sub AtclamFail(ctx as object, kind as string, msg as string)
    if ctx.err = "" then
        ctx.err = kind
        ctx.errMsg = msg
    end if
end sub

' ---- entry points ---------------------------------------------------------------
' Returns {ok:true, host_calls, storage_ops, cancelled, fuel_used} or {ok:false, kind, msg}.
function AtclamResult(ctx as object) as object
    if ctx.err <> "" then return {ok: false, kind: ctx.err, msg: ctx.errMsg}
    return {ok: true, host_calls: ctx.host_calls, storage_ops: ctx.storage_ops, cancelled: ctx.cancelled, fuel_used: ctx.fuel_used}
end function

function AtclamExecuteHandler(mdl as object, eventName as object, ctx as object) as object
    handler = invalid
    for each h in mdl.handlers
        if AtclamEq(h.event_name, eventName)
            handler = h
            exit for
        end if
    end for
    if handler = invalid
        AtclamFail(ctx, "no_handler", "no handler registered for event '" + AtclamJoin(eventName, ".") + "'")
        return AtclamResult(ctx)
    end if
    AtclamRunBlock(ctx, mdl, handler.block, [])
    return AtclamResult(ctx)
end function

' every handler for an event, highest priority first (stable), same ctx
function AtclamExecuteHandlersForEvent(mdl as object, eventName as object, ctx as object) as object
    matching = []
    for each h in mdl.handlers
        if AtclamEq(h.event_name, eventName) then matching.Push(h)
    end for
    ' stable insertion sort by priority descending
    for i = 1 to matching.Count() - 1
        cur = matching[i]
        j = i - 1
        while j >= 0 and matching[j].priority < cur.priority
            matching[j + 1] = matching[j]
            j = j - 1
        end while
        matching[j + 1] = cur
    end for
    for each h in matching
        ctx.fuel = ctx.budget
        AtclamRunBlock(ctx, mdl, h.block, [])
        if ctx.err <> "" then exit for
    end for
    return AtclamResult(ctx)
end function

function AtclamCallFunction(mdl as object, fnName as string, args as object, ctx as object) as dynamic
    f = mdl.fnIndex[fnName]
    if f = invalid
        AtclamFail(ctx, "unknown_function", fnName)
        return invalid
    end if
    return AtclamRunBlock(ctx, mdl, f.block, args)
end function

function AtclamJoin(a as object, sep as string) as string
    s = ""
    for i = 0 to a.Count() - 1
        if i > 0 then s = s + sep
        s = s + a[i]
    end for
    return s
end function

' ---- the interpreter ----------------------------------------------------------------
function AtclamRunBlock(ctx as object, mdl as object, block as object, args as object) as dynamic
    ctx.depth = ctx.depth + 1
    if ctx.depth > 64
        AtclamFail(ctx, "stack_overflow", "call depth limit (64) exceeded on this runtime")
        ctx.depth = ctx.depth - 1
        return invalid
    end if

    code = block.dec
    n = code.Count()
    locals = []
    for i = 1 to block.local_count
        locals.Push(invalid)
    end for
    for i = 0 to args.Count() - 1
        if i < locals.Count() then locals[i] = args[i]
    end for
    stack = []
    ip = 0
    ret = invalid

    while ip < n
        if ctx.fuel <= 0
            AtclamFail(ctx, "fuel", "instruction fuel exhausted (budget " + ctx.budget.ToStr() + ")")
            exit while
        end if
        ctx.fuel = ctx.fuel - 1
        ctx.fuel_used = ctx.fuel_used + 1
        ins = code[ip]
        o = ins.o
        nextIp = ip + 1

        if o = "LoadLocal"
            if ins.v >= locals.Count()
                AtclamFail(ctx, "type", "local slot " + ins.v.ToStr() + " out of range")
                exit while
            end if
            stack.Push(AtclamCopy(locals[ins.v]))
        else if o = "PushNumber"
            stack.Push(ins.v)
        else if o = "StoreLocal"
            if stack.Count() = 0
                AtclamFail(ctx, "stack_underflow", "at instruction " + ip.ToStr())
                exit while
            end if
            if ins.v >= locals.Count()
                AtclamFail(ctx, "type", "local slot " + ins.v.ToStr() + " out of range")
                exit while
            end if
            locals[ins.v] = stack.Pop()
        else if o = "BinaryOp"
            if stack.Count() < 2
                AtclamFail(ctx, "stack_underflow", "at instruction " + ip.ToStr())
                exit while
            end if
            rhs = stack.Pop()
            lhs = stack.Pop()
            r = AtclamBinary(ctx, ins.v, lhs, rhs)
            if ctx.err <> "" then exit while
            stack.Push(r)
        else if o = "JumpIfFalse"
            if stack.Count() = 0
                AtclamFail(ctx, "stack_underflow", "at instruction " + ip.ToStr())
                exit while
            end if
            cond = stack.Pop()
            if not AtclamTruthy(cond)
                if ins.v > n
                    AtclamFail(ctx, "bad_jump", "jump target " + ins.v.ToStr() + " out of bounds")
                    exit while
                end if
                nextIp = ins.v
            end if
        else if o = "Jump"
            if ins.v > n
                AtclamFail(ctx, "bad_jump", "jump target " + ins.v.ToStr() + " out of bounds")
                exit while
            end if
            nextIp = ins.v
        else if o = "PushString"
            stack.Push(ins.v + "")
        else if o = "PushBool"
            stack.Push(ins.v)
        else if o = "LoadPath"
            key = ""
            for i = 0 to ins.v.Count() - 1
                if i > 0 then key = key + "."
                key = key + ins.v[i]
            end for
            if ctx.values.DoesExist(key)
                stack.Push(AtclamCopy(ctx.values[key]))
            else
                stack.Push(invalid)
            end if
        else if o = "Call"
            argc = ins.v.arg_count
            if stack.Count() < argc
                AtclamFail(ctx, "stack_underflow", "at instruction " + ip.ToStr())
                exit while
            end if
            callArgs = []
            for i = 1 to argc
                callArgs.Unshift(stack.Pop())      ' popped in reverse order
            end for
            name = ins.v.name
            fn = mdl.fnIndex[name]
            if fn <> invalid
                r = AtclamRunBlock(ctx, mdl, fn.block, callArgs)
                if ctx.err <> "" then exit while
                stack.Push(r)
            else
                lib = AtclamResolveLibrary(ctx, name)
                if lib <> invalid
                    r = AtclamRunBlock(ctx, lib.mdl, lib.fn.block, callArgs)
                    if ctx.err <> "" then exit while
                    stack.Push(r)
                else
                    ctx.host_calls.Push({name: name, args: callArgs})
                    stack.Push(invalid)
                end if
            end if
        else if o = "UnaryOp"
            if stack.Count() = 0
                AtclamFail(ctx, "stack_underflow", "at instruction " + ip.ToStr())
                exit while
            end if
            v = stack.Pop()
            if ins.v = "Neg"
                if not AtclamIsNum(v)
                    AtclamFail(ctx, "type", "cannot negate " + AtclamShow(v))
                    exit while
                end if
                stack.Push(-v)
            else
                stack.Push(not AtclamTruthy(v))
            end if
        else if o = "Pop"
            if stack.Count() = 0
                AtclamFail(ctx, "stack_underflow", "at instruction " + ip.ToStr())
                exit while
            end if
            stack.Pop()
        else if o = "Return"
            if stack.Count() > 0 then ret = stack.Pop()
            exit while
        else if o = "CancelEvent"
            ctx.cancelled = true
            exit while
        else if o = "IncrementStorage"
            if stack.Count() = 0
                AtclamFail(ctx, "stack_underflow", "at instruction " + ip.ToStr())
                exit while
            end if
            by = stack.Pop()
            if not AtclamIsNum(by)
                AtclamFail(ctx, "type", "increment amount must be a number, got " + AtclamShow(by))
                exit while
            end if
            ctx.storage_ops.Push({op: "increment", path: AtclamPath(ins.v), by: by})
        else if o = "SetStorage"
            if stack.Count() = 0
                AtclamFail(ctx, "stack_underflow", "at instruction " + ip.ToStr())
                exit while
            end if
            value = stack.Pop()
            key = AtclamPath(ins.v)
            tok = invalid
            if ctx.tokens <> invalid and ctx.tokens.DoesExist(key) then tok = ctx.tokens[key]
            ctx.storage_ops.Push({op: "set", path: key, value: value, expected_version: tok})
        else if o = "MakeList"
            cnt = ins.v
            if stack.Count() < cnt
                AtclamFail(ctx, "stack_underflow", "at instruction " + ip.ToStr())
                exit while
            end if
            items = []
            for i = 1 to cnt
                items.Unshift(stack.Pop())
            end for
            stack.Push(items)
        else if o = "IndexGet"
            if stack.Count() < 2
                AtclamFail(ctx, "stack_underflow", "at instruction " + ip.ToStr())
                exit while
            end if
            idxV = stack.Pop()
            base = stack.Pop()
            if type(base) <> "roArray"
                AtclamFail(ctx, "type", "cannot index into " + AtclamShow(base) + " - not a list")
                exit while
            end if
            if not AtclamIsNum(idxV)
                AtclamFail(ctx, "type", "list index must be a number, got " + AtclamShow(idxV))
                exit while
            end if
            idx = AtclamToIndex(idxV)
            if idx < 0 or idx >= base.Count()
                AtclamFail(ctx, "type", "list index out of range")
                exit while
            end if
            stack.Push(AtclamCopy(base[idx]))
        else if o = "IndexSetLocal"
            if stack.Count() < 2
                AtclamFail(ctx, "stack_underflow", "at instruction " + ip.ToStr())
                exit while
            end if
            idxV = stack.Pop()
            value = stack.Pop()
            if not AtclamIsNum(idxV)
                AtclamFail(ctx, "type", "list index must be a number, got " + AtclamShow(idxV))
                exit while
            end if
            idx = AtclamToIndex(idxV)
            if ins.v >= locals.Count()
                AtclamFail(ctx, "type", "local slot " + ins.v.ToStr() + " out of range")
                exit while
            end if
            lst = locals[ins.v]
            if type(lst) <> "roArray"
                AtclamFail(ctx, "type", "cannot index-assign into " + AtclamShow(lst) + " - not a list")
                exit while
            end if
            if idx < 0 or idx >= lst.Count()
                AtclamFail(ctx, "type", "list index out of range")
                exit while
            end if
            lst[idx] = value
        else if o = "Len"
            if stack.Count() = 0
                AtclamFail(ctx, "stack_underflow", "at instruction " + ip.ToStr())
                exit while
            end if
            v = stack.Pop()
            if type(v) = "roArray"
                stack.Push(v.Count() + 0.0#)
            else if type(v) = "roString" or type(v) = "String"
                stack.Push(Len(v) + 0.0#)
            else
                AtclamFail(ctx, "type", "len() expects a list or string, got " + AtclamShow(v))
                exit while
            end if
        else
            AtclamFail(ctx, "bad_module", "unknown instruction " + o)
            exit while
        end if
        ip = nextIp
    end while

    ctx.depth = ctx.depth - 1
    return ret
end function

function AtclamPath(parts as object) as string
    key = ""
    for i = 0 to parts.Count() - 1
        if i > 0 then key = key + "."
        key = key + parts[i]
    end for
    return key
end function

' Rust: `index as i64` (truncate toward zero, NaN -> 0, saturating)
function AtclamToIndex(v as double) as integer
    if v <> v then return 0
    if v > 2000000000.0# then return 2000000000
    if v < -2000000000.0# then return -2000000000
    return Fix(v)
end function

function AtclamResolveLibrary(ctx as object, name as string) as dynamic
    dot = Instr(1, name, ".")
    if dot < 2 then return invalid
    libName = Left(name, dot - 1)
    fnName = Mid(name, dot + 1)
    lm = ctx.linked[libName]
    if lm = invalid then return invalid
    f = lm.fnIndex[fnName]
    if f = invalid then return invalid
    return {mdl: lm, fn: f}
end function

function AtclamBinary(ctx as object, op as string, lhs as dynamic, rhs as dynamic) as dynamic
    if op = "Eq" then return AtclamEq(lhs, rhs)
    if op = "NotEq" then return not AtclamEq(lhs, rhs)
    if op = "And" then return (AtclamTruthy(lhs) and AtclamTruthy(rhs))
    if op = "Or" then return (AtclamTruthy(lhs) or AtclamTruthy(rhs))
    if not AtclamIsNum(lhs)
        AtclamFail(ctx, "type", "expected number, got " + AtclamShow(lhs) + " [" + type(lhs) + "]")
        return invalid
    end if
    if not AtclamIsNum(rhs)
        AtclamFail(ctx, "type", "expected number, got " + AtclamShow(rhs) + " [" + type(rhs) + "]")
        return invalid
    end if
    a = lhs
    b = rhs
    if op = "Add" then return a + b
    if op = "Sub" then return a - b
    if op = "Mul" then return a * b
    if op = "Div"
        if b = 0.0#
            ' IEEE-754 (BrightScript would throw): x/0 = +-inf, 0/0 = NaN
            if a = 0.0# or a <> a then return AtclamNaN()
            if a > 0.0# then return AtclamInf()
            return -AtclamInf()
        end if
        return a / b
    end if
    if op = "Lt" then return (a < b)
    if op = "Gt" then return (a > b)
    if op = "LtEq" then return (a <= b)
    if op = "GtEq" then return (a >= b)
    AtclamFail(ctx, "bad_module", "unknown binary op " + op)
    return invalid
end function
