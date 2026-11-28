$ErrorActionPreference = "Stop"
Add-Type -Path "$env:TEMP\sdv-viewport\Mono.Cecil.dll"

$srcTouch = "$env:TEMP\sdv-clean-ui\menubar-touch.dll"
$srcHost  = "$env:TEMP\sdv-clean-ui\menubar-host.dll"
$srcMG    = "$env:TEMP\sdv-clean-ui\MonoGame.Framework.dll"
$outTouch = "$env:TEMP\sdv-clean-ui\v7-touch.dll"
$outHost  = "$env:TEMP\sdv-clean-ui\v7-host.dll"
$outMG    = "$env:TEMP\sdv-clean-ui\v7-monogame.dll"

foreach ($f in @($srcTouch, $srcHost, $srcMG)) {
    if (!(Test-Path $f)) { throw "Missing input DLL: $f" }
}

function Verify-Assembly($path) {
    $a = [Mono.Cecil.AssemblyDefinition]::ReadAssembly($path)
    $mCount = 0
    foreach ($t in $a.MainModule.Types) {
        $allTypes = @($t) + @($t.NestedTypes)
        foreach ($ct in $allTypes) {
            foreach ($m in $ct.Methods) {
                if (-not $m.HasBody) { continue }
                $mCount++
                $set = New-Object 'System.Collections.Generic.HashSet[Mono.Cecil.Cil.Instruction]'
                foreach ($ins in $m.Body.Instructions) { [void]$set.Add($ins) }
                foreach ($ins in $m.Body.Instructions) {
                    if ($ins.Operand -is [Mono.Cecil.Cil.Instruction]) {
                        if (-not $set.Contains($ins.Operand)) {
                            throw "Broken branch target in $($ct.FullName).$($m.Name)"
                        }
                    } elseif ($ins.Operand -is [Mono.Cecil.FieldDefinition]) {
                        $fd = [Mono.Cecil.FieldDefinition]$ins.Operand
                        if ($fd.DeclaringType -ne $ct -and $fd.DeclaringType -ne $ct.DeclaringType -and $fd.IsPrivate) {
                            throw "Illegal private field access: $($ct.FullName).$($m.Name) -> $($fd.DeclaringType.FullName).$($fd.Name)"
                        }
                    } elseif ($ins.Operand -is [Mono.Cecil.MethodDefinition]) {
                        $md = [Mono.Cecil.MethodDefinition]$ins.Operand
                        if ($md.DeclaringType -ne $ct -and $md.DeclaringType -ne $ct.DeclaringType -and $md.IsPrivate) {
                            throw "Illegal private method access: $($ct.FullName).$($m.Name) -> $($md.DeclaringType.FullName).$($md.Name)"
                        }
                    }
                }
                foreach ($eh in $m.Body.ExceptionHandlers) {
                    foreach ($pt in @($eh.TryStart, $eh.TryEnd, $eh.HandlerStart, $eh.HandlerEnd)) {
                        if ($null -ne $pt -and -not $set.Contains($pt)) {
                            throw "Broken EH boundary in $($ct.FullName).$($m.Name)"
                        }
                    }
                }
            }
        }
    }
    $a.Dispose()
    Write-Host "Verified IL, EH & member visibility OK: $path ($mCount methods)"
}

function Retarget-Branches($method, $oldTarget, $newTarget) {
    foreach ($ins in $method.Body.Instructions) {
        if ($ins.Operand -eq $oldTarget) {
            $ins.Operand = $newTarget
        } elseif ($ins.Operand -is [Mono.Cecil.Cil.Instruction[]]) {
            $arr = $ins.Operand
            for ($k = 0; $k -lt $arr.Length; $k++) {
                if ($arr[$k] -eq $oldTarget) { $arr[$k] = $newTarget }
            }
        }
    }
    foreach ($eh in $method.Body.ExceptionHandlers) {
        if ($eh.TryStart -eq $oldTarget) { $eh.TryStart = $newTarget }
        if ($eh.TryEnd -eq $oldTarget) { $eh.TryEnd = $newTarget }
        if ($eh.HandlerStart -eq $oldTarget) { $eh.HandlerStart = $newTarget }
        if ($eh.HandlerEnd -eq $oldTarget) { $eh.HandlerEnd = $newTarget }
    }
}

function Expand-ShortBranches($method) {
    $map = @{
        "br.s"        = [Mono.Cecil.Cil.OpCodes]::Br
        "brfalse.s"   = [Mono.Cecil.Cil.OpCodes]::Brfalse
        "brtrue.s"    = [Mono.Cecil.Cil.OpCodes]::Brtrue
        "beq.s"       = [Mono.Cecil.Cil.OpCodes]::Beq
        "bge.s"       = [Mono.Cecil.Cil.OpCodes]::Bge
        "bgt.s"       = [Mono.Cecil.Cil.OpCodes]::Bgt
        "ble.s"       = [Mono.Cecil.Cil.OpCodes]::Ble
        "blt.s"       = [Mono.Cecil.Cil.OpCodes]::Blt
        "bne.un.s"    = [Mono.Cecil.Cil.OpCodes]::Bne_Un
        "bge.un.s"    = [Mono.Cecil.Cil.OpCodes]::Bge_Un
        "bgt.un.s"    = [Mono.Cecil.Cil.OpCodes]::Bgt_Un
        "ble.un.s"    = [Mono.Cecil.Cil.OpCodes]::Ble_Un
        "blt.un.s"    = [Mono.Cecil.Cil.OpCodes]::Blt_Un
        "leave.s"     = [Mono.Cecil.Cil.OpCodes]::Leave
    }
    foreach ($ins in $method.Body.Instructions) {
        if ($map.ContainsKey($ins.OpCode.Name)) {
            $ins.OpCode = $map[$ins.OpCode.Name]
        }
    }
}

function Find-Ref($mod, $pattern) {
    foreach ($mr in $mod.GetMemberReferences()) {
        if ($mr.FullName -eq $pattern) { return $mr }
    }
    foreach ($t in $mod.Types) {
        foreach ($m in $t.Methods) {
            if (-not $m.HasBody) { continue }
            foreach ($ins in $m.Body.Instructions) {
                if ($ins.Operand -is [Mono.Cecil.MethodReference] -and $ins.Operand.FullName -eq $pattern) {
                    return $ins.Operand
                }
            }
        }
    }
    return $null
}

# ==============================================================================
# PART 1: PATCH SDViOSTouchControls.dll (v7-touch.dll) — LOCKED 2.0x + MENU OPT
# ==============================================================================
Write-Host "Patching TouchControls -> $outTouch ..."
$tAsm = [Mono.Cecil.AssemblyDefinition]::ReadAssembly($srcTouch)
$tMod = $tAsm.MainModule

$padType = $tMod.Types | Where-Object { $_.Name -eq "TouchVirtualPad" }
$mwType  = $tMod.Types | Where-Object { $_.Name -eq "MemoryWatchdog" }
$meType  = $tMod.Types | Where-Object { $_.Name -eq "ModEntry" }
$syncM   = $padType.Methods | Where-Object { $_.Name -eq "SyncMenuBarConfig" }
$fcM     = $mwType.Methods | Where-Object { $_.Name -eq "ForceCollect" -and $_.Parameters.Count -eq 3 }
if (!$padType -or !$mwType -or !$meType -or !$syncM -or !$fcM) { throw "Missing TouchControls target types/methods" }

$mGetFolderPath = Find-Ref $tMod "System.String System.Environment::GetFolderPath(System.Environment/SpecialFolder)"
$mPathCombine   = Find-Ref $tMod "System.String System.IO.Path::Combine(System.String,System.String)"
$mFileExists    = Find-Ref $tMod "System.Boolean System.IO.File::Exists(System.String)"
$mFileDelete    = Find-Ref $tMod "System.Void System.IO.File::Delete(System.String)"
if (!$mGetFolderPath -or !$mPathCombine -or !$mFileExists) { throw "Missing IO/Env refs in TouchControls" }
if (!$mFileDelete) {
    $mFileDelete = New-Object Mono.Cecil.MethodReference("Delete", $tMod.TypeSystem.Void, $mFileExists.DeclaringType)
    $mFileDelete.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition($tMod.TypeSystem.String)))
}

# 1.1 TouchVirtualPad.CheckManualGcFlag() — Prunes stale map tilesheets + runs Compacting Gen2 GC!
$lddType = $tMod.Types | Where-Object { $_.Name -eq "LazyIosDisplayDevice" }
$mLddInst = $lddType.Methods | Where-Object { $_.Name -eq "get_Instance" }
$mLddPrune = $lddType.Methods | Where-Object { $_.Name -eq "PruneTileSheets" }
$mGetCurLoc = Find-Ref $tMod "StardewValley.GameLocation StardewValley.Game1::get_currentLocation()"
$fLocMap = $null
foreach ($t in $tMod.Types) {
    foreach ($m in $t.Methods) {
        if (-not $m.HasBody) { continue }
        foreach ($ins in $m.Body.Instructions) {
            if ($ins.Operand -is [Mono.Cecil.FieldReference] -and $ins.Operand.FullName -eq "xTile.Map StardewValley.GameLocation::map") {
                $fLocMap = $ins.Operand; break
            }
        }
        if ($fLocMap) { break }
    }
    if ($fLocMap) { break }
}

$gcMethod = New-Object Mono.Cecil.MethodDefinition(
    "CheckManualGcFlag",
    [Mono.Cecil.MethodAttributes]"Private, Static",
    $tMod.TypeSystem.Void
)
$gcMethod.Body.InitLocals = $true
$vPath  = New-Object Mono.Cecil.Cil.VariableDefinition($tMod.TypeSystem.String)
$vPath2 = New-Object Mono.Cecil.Cil.VariableDefinition($tMod.TypeSystem.String)
$vDev   = New-Object Mono.Cecil.Cil.VariableDefinition($lddType)
$vLoc   = New-Object Mono.Cecil.Cil.VariableDefinition($mGetCurLoc.ReturnType)
$gcMethod.Body.Variables.Add($vPath)
$gcMethod.Body.Variables.Add($vPath2)
$gcMethod.Body.Variables.Add($vDev)
$gcMethod.Body.Variables.Add($vLoc)
$il = $gcMethod.Body.GetILProcessor()

$lTryStart    = $il.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_5)
$lExit        = $il.Create([Mono.Cecil.Cil.OpCodes]::Ret)
$lLeaveOk     = $il.Create([Mono.Cecil.Cil.OpCodes]::Leave, $lExit)
$lCatch       = $il.Create([Mono.Cecil.Cil.OpCodes]::Pop)
$lAfterPruneF = $il.Create([Mono.Cecil.Cil.OpCodes]::Nop)
$lCallFc      = $il.Create([Mono.Cecil.Cil.OpCodes]::Ldstr, "ManualModGarden")

$il.Append($lTryStart)
$il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Call, $mGetFolderPath))
$il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Ldstr, ".garden/sdv_gc_now.flag"))
$il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Call, $mPathCombine))
$il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vPath))
$il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vPath))
$il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Call, $mFileExists))
$il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $lLeaveOk))
$il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vPath))
$il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Call, $mFileDelete))
# Also delete companion .garden/sdv_prune_now.flag if present so manual GC never runs twice!
$il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_5))
$il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Call, $mGetFolderPath))
$il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Ldstr, ".garden/sdv_prune_now.flag"))
$il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Call, $mPathCombine))
$il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vPath2))
$il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vPath2))
$il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Call, $mFileExists))
$il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $lAfterPruneF))
$il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vPath2))
$il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Call, $mFileDelete))
$il.Append($lAfterPruneF)
# Prune unused tilesheets from other maps before Gen2 GC so finalizers immediately GL.DeleteTextures!
if ($mLddInst -and $mLddPrune -and $mGetCurLoc -and $fLocMap) {
    $il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Call, $mLddInst))
    $il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vDev))
    $il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vDev))
    $il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $lCallFc))
    $il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Call, $mGetCurLoc))
    $il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vLoc))
    $il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vLoc))
    $il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $lCallFc))
    $il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vDev))
    $il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vLoc))
    $il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $fLocMap))
    $il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mLddPrune))
}
$il.Append($lCallFc)
$il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0))
$il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_1))
$il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Call, $fcM))
$il.Append($lLeaveOk)
$il.Append($lCatch)
$il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Leave, $lExit))
$il.Append($lExit)

$eh = New-Object Mono.Cecil.Cil.ExceptionHandler([Mono.Cecil.Cil.ExceptionHandlerType]::Catch)
$eh.CatchType = $tMod.TypeSystem.Object
$eh.TryStart = $lTryStart
$eh.TryEnd = $lCatch
$eh.HandlerStart = $lCatch
$eh.HandlerEnd = $lExit
$gcMethod.Body.ExceptionHandlers.Add($eh)
$padType.Methods.Add($gcMethod)

# Hook SyncMenuBarConfig: 8 frames -> 45 frames (~0.75s) + call CheckManualGcFlag inside poll gate
Expand-ShortBranches $syncM
$sp = $syncM.Body.GetILProcessor()
$sIns = $syncM.Body.Instructions
$bumpedPoll = 0
$hookedGcInGate = $false
for ($i = 0; $i -lt $sIns.Count; $i++) {
    if ($sIns[$i].OpCode.Name -eq "ldc.i4.8" -and $i -ge 2 -and "$($sIns[$i-1].Operand)" -like "*_mbPollTick*") {
        $sIns[$i].OpCode = [Mono.Cecil.Cil.OpCodes]::Ldc_I4
        $sIns[$i].Operand = [int]45
        $bumpedPoll++
    }
    if (-not $hookedGcInGate -and $sIns[$i].OpCode.Name -eq "ldc.i4.5" -and ($i + 1) -lt $sIns.Count -and "$($sIns[$i+1].Operand)" -like "*GetFolderPath*") {
        $targetGate = $sIns[$i]
        $callGc = $sp.Create([Mono.Cecil.Cil.OpCodes]::Call, $gcMethod)
        $sp.InsertBefore($targetGate, $callGc)
        Retarget-Branches $syncM $targetGate $callGc
        $hookedGcInGate = $true
        $i++
    }
}
if (-not $hookedGcInGate) { throw "Could not hook CheckManualGcFlag inside SyncMenuBarConfig poll gate" }

# 1.2 Raise MemoryWatchdog.Loop soft-GC threshold 350 MB -> 600 MB (keeps RAM lower before Jetsam!)
$mwLoop = $mwType.Methods | Where-Object { $_.Name -eq "Loop" }
$bumped = 0
foreach ($ins in $mwLoop.Body.Instructions) {
    if ($ins.OpCode.Name -eq "ldc.i4" -and [int]$ins.Operand -eq 367001600) {
        $ins.Operand = [int]629145600
        $bumped++
    }
}

# 1.2b Disable EnableWarpTilesheetPrewarm by default (avoids eagerly uploading unused SVE tilesheets into VRAM!)
$tosType = $tMod.Types | Where-Object { $_.Name -eq "TouchOverlaySettings" }
$tosCtor = $tosType.Methods | Where-Object { $_.Name -eq ".ctor" }
$prewarmOff = 0
for ($i = 1; $i -lt $tosCtor.Body.Instructions.Count; $i++) {
    $ins = $tosCtor.Body.Instructions[$i]
    if ($ins.OpCode.Name -eq "stfld" -and "$($ins.Operand)" -like "*EnableWarpTilesheetPrewarm*") {
        $prev = $tosCtor.Body.Instructions[$i - 1]
        if ($prev.OpCode.Name -eq "ldc.i4.1") {
            $prev.OpCode = [Mono.Cecil.Cil.OpCodes]::Ldc_I4_0
            $prewarmOff++
        }
    }
}
Write-Host "  RAM Saver (TouchControls): PruneTileSheets on ManualGC + Watchdog 600MB ($bumped) + WarpTilesheetPrewarm=false ($prewarmOff)"

# 1.2c Fix DynamicReflections water/puddle/sky player reflection: make LazyIosDisplayDevice.DrawTile
# delegate to base.DrawTile (XnaDisplayDevice.DrawTile) after TryGetOrLoadTexture so Harmony patches on
# XnaDisplayDevice.DrawTile (like DynamicReflections's DisplayDevicePatch.DrawTilePrefix) fire!
$mLddDraw = $lddType.Methods | Where-Object { $_.Name -eq "DrawTile" }
$mTryTex  = $lddType.Methods | Where-Object { $_.Name -eq "TryGetOrLoadTexture" }
if ($mLddDraw -and $mTryTex) {
    $mTileGetTs = $null
    $mTexIsDisp = $null
    foreach ($m in $lddType.Methods) {
        if (-not $m.HasBody) { continue }
        foreach ($ins in $m.Body.Instructions) {
            if ($ins.Operand -is [Mono.Cecil.MethodReference]) {
                if ($ins.Operand.FullName -like "*Tile::get_TileSheet*") { $mTileGetTs = $ins.Operand }
                elseif ($ins.Operand.FullName -like "*GraphicsResource::get_IsDisposed*") { $mTexIsDisp = $ins.Operand }
            }
        }
    }
    $mBaseDraw = New-Object Mono.Cecil.MethodReference("DrawTile", $tMod.TypeSystem.Void, $lddType.BaseType)
    $mBaseDraw.HasThis = $true
    foreach ($p in $mLddDraw.Parameters) {
        $mBaseDraw.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition($p.Name, $p.Attributes, $p.ParameterType)))
    }
    $mLddDraw.Body.ExceptionHandlers.Clear()
    $mLddDraw.Body.Instructions.Clear()
    $mLddDraw.Body.Variables.Clear()
    $vTs  = New-Object Mono.Cecil.Cil.VariableDefinition($mTryTex.Parameters[0].ParameterType)
    $vTex = New-Object Mono.Cecil.Cil.VariableDefinition($mTryTex.ReturnType)
    $mLddDraw.Body.Variables.Add($vTs)
    $mLddDraw.Body.Variables.Add($vTex)
    $mLddDraw.Body.InitLocals = $true

    $dtIL = $mLddDraw.Body.GetILProcessor()
    $lRetDt = $dtIL.Create([Mono.Cecil.Cil.OpCodes]::Ret)
    $dtIL.Append($dtIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_1))
    $dtIL.Append($dtIL.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $lRetDt))
    $dtIL.Append($dtIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_1))
    $dtIL.Append($dtIL.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mTileGetTs))
    $dtIL.Append($dtIL.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vTs))
    $dtIL.Append($dtIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vTs))
    $dtIL.Append($dtIL.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $lRetDt))
    $dtIL.Append($dtIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
    $dtIL.Append($dtIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vTs))
    $dtIL.Append($dtIL.Create([Mono.Cecil.Cil.OpCodes]::Call, $mTryTex))
    $dtIL.Append($dtIL.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vTex))
    $dtIL.Append($dtIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vTex))
    $dtIL.Append($dtIL.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $lRetDt))
    $dtIL.Append($dtIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vTex))
    $dtIL.Append($dtIL.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mTexIsDisp))
    $dtIL.Append($dtIL.Create([Mono.Cecil.Cil.OpCodes]::Brtrue, $lRetDt))
    $dtIL.Append($dtIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
    $dtIL.Append($dtIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_1))
    $dtIL.Append($dtIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_2))
    $dtIL.Append($dtIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_3))
    $dtIL.Append($dtIL.Create([Mono.Cecil.Cil.OpCodes]::Call, $mBaseDraw))
    $dtIL.Append($lRetDt)
    Write-Host "  DynamicReflections Fix (TouchControls): LazyIosDisplayDevice.DrawTile now delegates to base XnaDisplayDevice.DrawTile!"
}

# 1.3 ModEntry.ApplyPerfResolutionScale(ModEntry self) — LOCKED TO 2.0x ON 3x DEVICES!
# If h <= 1400 && (w % 3 == 0) && (h % 3 == 0): w = (w / 3) * 2; h = (h / 3) * 2;
$dnrM   = $meType.Methods | Where-Object { $_.Name -eq "DetermineNativeResolution" }
$fNatW  = $meType.Fields  | Where-Object { $_.Name -eq "_nativeWidth" }
$fNatH  = $meType.Fields  | Where-Object { $_.Name -eq "_nativeHeight" }
$fSNatW = $meType.Fields  | Where-Object { $_.Name -eq "_staticNativeWidth" }
$fSNatH = $meType.Fields  | Where-Object { $_.Name -eq "_staticNativeHeight" }

$mApplyRes = New-Object Mono.Cecil.MethodDefinition(
    "ApplyPerfResolutionScale",
    [Mono.Cecil.MethodAttributes]"Private, Static",
    $tMod.TypeSystem.Void
)
$mApplyRes.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition("self", [Mono.Cecil.ParameterAttributes]::None, $meType)))
$mApplyRes.Body.InitLocals = $true
$vWT = New-Object Mono.Cecil.Cil.VariableDefinition($tMod.TypeSystem.Int32)
$vHT = New-Object Mono.Cecil.Cil.VariableDefinition($tMod.TypeSystem.Int32)
$mApplyRes.Body.Variables.Add($vWT)
$mApplyRes.Body.Variables.Add($vHT)

$ilR = $mApplyRes.Body.GetILProcessor()
$lRetR = $ilR.Create([Mono.Cecil.Cil.OpCodes]::Ret)
$ilR.Append($ilR.Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $fSNatW))
$ilR.Append($ilR.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vWT))
$ilR.Append($ilR.Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $fSNatH))
$ilR.Append($ilR.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vHT))

# v7: Keep 100% native device resolution (3x on 3x devices, 2x on 2x devices) to avoid aspect/scale glitches across devices

$ilR.Append($lRetR)
$meType.Methods.Add($mApplyRes)

Expand-ShortBranches $dnrM
$dp = $dnrM.Body.GetILProcessor()
$dIns = $dnrM.Body.Instructions
$hookedDnr = $false
for ($i = 0; $i -lt $dIns.Count; $i++) {
    if ($dIns[$i].OpCode.Name -eq "stsfld" -and $dIns[$i].Operand -eq $fSNatH) {
        $afterSts = $dIns[$i + 1]
        $dp.InsertBefore($afterSts, $dp.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
        $dp.InsertBefore($afterSts, $dp.Create([Mono.Cecil.Cil.OpCodes]::Call, $mApplyRes))
        $hookedDnr = $true
        break
    }
}
if (-not $hookedDnr) { throw "Could not hook ModEntry.DetermineNativeResolution" }

# 1.4 Harmony Prefix on iOSGameWindow.get_ClientBounds
$tRect     = $tMod.GetTypeReferences() | Where-Object { $_.FullName -eq "Microsoft.Xna.Framework.Rectangle" } | Select-Object -First 1
$tGameWin  = $tMod.GetTypeReferences() | Where-Object { $_.FullName -eq "Microsoft.Xna.Framework.GameWindow" } | Select-Object -First 1
$tHarmony  = $tMod.GetTypeReferences() | Where-Object { $_.FullName -eq "HarmonyLib.Harmony" } | Select-Object -First 1
$tType     = $tMod.GetTypeReferences() | Where-Object { $_.FullName -eq "System.Type" } | Select-Object -First 1
$tPropInfo = $tMod.GetTypeReferences() | Where-Object { $_.FullName -eq "System.Reflection.PropertyInfo" } | Select-Object -First 1
$tMethInfo = $tMod.GetTypeReferences() | Where-Object { $_.FullName -eq "System.Reflection.MethodInfo" } | Select-Object -First 1
$mRectCtor = Find-Ref $tMod "System.Void Microsoft.Xna.Framework.Rectangle::.ctor(System.Int32,System.Int32,System.Int32,System.Int32)"
$mGetTypeH = Find-Ref $tMod "System.Type System.Type::GetTypeFromHandle(System.RuntimeTypeHandle)"
$mGetAsm   = Find-Ref $tMod "System.Reflection.Assembly System.Type::get_Assembly()"
$mAsmGetT  = Find-Ref $tMod "System.Type System.Reflection.Assembly::GetType(System.String)"
$mGetProp  = Find-Ref $tMod "System.Reflection.PropertyInfo System.Type::GetProperty(System.String,System.Reflection.BindingFlags)"
$mGetGetM  = Find-Ref $tMod "System.Reflection.MethodInfo System.Reflection.PropertyInfo::GetGetMethod()"
$mGetMeth  = Find-Ref $tMod "System.Reflection.MethodInfo System.Type::GetMethod(System.String,System.Reflection.BindingFlags)"
$mHMCtor   = Find-Ref $tMod "System.Void HarmonyLib.HarmonyMethod::.ctor(System.Reflection.MethodInfo)"
$mHPatch   = Find-Ref $tMod "System.Reflection.MethodInfo HarmonyLib.Harmony::Patch(System.Reflection.MethodBase,HarmonyLib.HarmonyMethod,HarmonyLib.HarmonyMethod,HarmonyLib.HarmonyMethod,HarmonyLib.HarmonyMethod)"

$mPrefixCB = New-Object Mono.Cecil.MethodDefinition("PrefixClientBounds", [Mono.Cecil.MethodAttributes]"Private, Static", $tMod.TypeSystem.Boolean)
$byRefRect = New-Object Mono.Cecil.ByReferenceType($tRect)
$mPrefixCB.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition("__result", [Mono.Cecil.ParameterAttributes]::None, $byRefRect)))
$ilCB = $mPrefixCB.Body.GetILProcessor()
$ilCB.Append($ilCB.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
$ilCB.Append($ilCB.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0))
$ilCB.Append($ilCB.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0))
$ilCB.Append($ilCB.Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $fSNatW))
$ilCB.Append($ilCB.Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $fSNatH))
$ilCB.Append($ilCB.Create([Mono.Cecil.Cil.OpCodes]::Newobj, $mRectCtor))
$ilCB.Append($ilCB.Create([Mono.Cecil.Cil.OpCodes]::Stobj, $tRect))
$ilCB.Append($ilCB.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0))
$ilCB.Append($ilCB.Create([Mono.Cecil.Cil.OpCodes]::Ret))
$meType.Methods.Add($mPrefixCB)

$mPatchCB = New-Object Mono.Cecil.MethodDefinition("PatchClientBounds", [Mono.Cecil.MethodAttributes]"Private, Static", $tMod.TypeSystem.Void)
$mPatchCB.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition("harmony", [Mono.Cecil.ParameterAttributes]::None, $tHarmony)))
$mPatchCB.Body.InitLocals = $true
$vWinT  = New-Object Mono.Cecil.Cil.VariableDefinition($tType)
$vProp  = New-Object Mono.Cecil.Cil.VariableDefinition($tPropInfo)
$vGetM  = New-Object Mono.Cecil.Cil.VariableDefinition($tMethInfo)
$vPrefM = New-Object Mono.Cecil.Cil.VariableDefinition($tMethInfo)
foreach ($v in @($vWinT, $vProp, $vGetM, $vPrefM)) { $mPatchCB.Body.Variables.Add($v) }

$ilPC = $mPatchCB.Body.GetILProcessor()
$lRetPC   = $ilPC.Create([Mono.Cecil.Cil.OpCodes]::Ret)
$lLeavePC = $ilPC.Create([Mono.Cecil.Cil.OpCodes]::Leave, $lRetPC)
$lCatchPC = $ilPC.Create([Mono.Cecil.Cil.OpCodes]::Pop)
$lTryPC   = $ilPC.Create([Mono.Cecil.Cil.OpCodes]::Ldtoken, $tGameWin)
$ilPC.Append($lTryPC)
$ilPC.Append($ilPC.Create([Mono.Cecil.Cil.OpCodes]::Call, $mGetTypeH))
$ilPC.Append($ilPC.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mGetAsm))
$ilPC.Append($ilPC.Create([Mono.Cecil.Cil.OpCodes]::Ldstr, "Microsoft.Xna.Framework.iOSGameWindow"))
$ilPC.Append($ilPC.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mAsmGetT))
$ilPC.Append($ilPC.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vWinT))
$ilPC.Append($ilPC.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vWinT))
$ilPC.Append($ilPC.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $lLeavePC))
$ilPC.Append($ilPC.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vWinT))
$ilPC.Append($ilPC.Create([Mono.Cecil.Cil.OpCodes]::Ldstr, "ClientBounds"))
$ilPC.Append($ilPC.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4, 52))
$ilPC.Append($ilPC.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mGetProp))
$ilPC.Append($ilPC.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vProp))
$ilPC.Append($ilPC.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vProp))
$ilPC.Append($ilPC.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $lLeavePC))
$ilPC.Append($ilPC.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vProp))
$ilPC.Append($ilPC.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mGetGetM))
$ilPC.Append($ilPC.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vGetM))
$ilPC.Append($ilPC.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vGetM))
$ilPC.Append($ilPC.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $lLeavePC))
$ilPC.Append($ilPC.Create([Mono.Cecil.Cil.OpCodes]::Ldtoken, $meType))
$ilPC.Append($ilPC.Create([Mono.Cecil.Cil.OpCodes]::Call, $mGetTypeH))
$ilPC.Append($ilPC.Create([Mono.Cecil.Cil.OpCodes]::Ldstr, "PrefixClientBounds"))
$ilPC.Append($ilPC.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4, 56))
$ilPC.Append($ilPC.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mGetMeth))
$ilPC.Append($ilPC.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vPrefM))
$ilPC.Append($ilPC.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vPrefM))
$ilPC.Append($ilPC.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $lLeavePC))
$ilPC.Append($ilPC.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
$ilPC.Append($ilPC.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vGetM))
$ilPC.Append($ilPC.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vPrefM))
$ilPC.Append($ilPC.Create([Mono.Cecil.Cil.OpCodes]::Newobj, $mHMCtor))
$ilPC.Append($ilPC.Create([Mono.Cecil.Cil.OpCodes]::Ldnull))
$ilPC.Append($ilPC.Create([Mono.Cecil.Cil.OpCodes]::Ldnull))
$ilPC.Append($ilPC.Create([Mono.Cecil.Cil.OpCodes]::Ldnull))
$ilPC.Append($ilPC.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mHPatch))
$ilPC.Append($ilPC.Create([Mono.Cecil.Cil.OpCodes]::Pop))
$ilPC.Append($lLeavePC)
$ilPC.Append($lCatchPC)
$ilPC.Append($ilPC.Create([Mono.Cecil.Cil.OpCodes]::Leave, $lRetPC))
$ilPC.Append($lRetPC)

$ehPC = New-Object Mono.Cecil.Cil.ExceptionHandler([Mono.Cecil.Cil.ExceptionHandlerType]::Catch)
$ehPC.CatchType = $tMod.TypeSystem.Object
$ehPC.TryStart = $lTryPC
$ehPC.TryEnd = $lCatchPC
$ehPC.HandlerStart = $lCatchPC
$ehPC.HandlerEnd = $lRetPC
$mPatchCB.Body.ExceptionHandlers.Add($ehPC)
$meType.Methods.Add($mPatchCB)

$ahpM = $meType.Methods | Where-Object { $_.Name -eq "ApplyHarmonyPatches" }
Expand-ShortBranches $ahpM
$ap = $ahpM.Body.GetILProcessor()
$afterStloc0 = $ahpM.Body.Instructions[3]
$ap.InsertBefore($afterStloc0, $ap.Create([Mono.Cecil.Cil.OpCodes]::Ldloc_0))
$ap.InsertBefore($afterStloc0, $ap.Create([Mono.Cecil.Cil.OpCodes]::Call, $mPatchCB))

# 1.5 Menu Lag Fixes: Skip Environment.StackTrace in PrefixSetActiveClickableMenu + GameMenu GC 350->140MB
$pSetMenu = $meType.Methods | Where-Object { $_.Name -eq "PrefixSetActiveClickableMenu" }
$mGetVerbose = $meType.Methods | Where-Object { $_.Name -eq "get_VerboseInputLogging" }
if ($pSetMenu -and $mGetVerbose) {
    Expand-ShortBranches $pSetMenu
    $pmp = $pSetMenu.Body.GetILProcessor()
    $pmFirst = $pSetMenu.Body.Instructions[0]
    $m0 = $pmp.Create([Mono.Cecil.Cil.OpCodes]::Call, $mGetVerbose)
    $m1 = $pmp.Create([Mono.Cecil.Cil.OpCodes]::Brtrue, $pmFirst)
    $m2 = $pmp.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_1)
    $m3 = $pmp.Create([Mono.Cecil.Cil.OpCodes]::Ret)
    $pmp.InsertBefore($pmFirst, $m0)
    $pmp.InsertBefore($pmFirst, $m1)
    $pmp.InsertBefore($pmFirst, $m2)
    $pmp.InsertBefore($pmFirst, $m3)
    Retarget-Branches $pSetMenu $pmFirst $m0
    $m1.Operand = $pmFirst
}

$pGMCtor = $meType.Methods | Where-Object { $_.Name -eq "PrefixGameMenuCtor" }
$gmLowered = 0
if ($pGMCtor) {
    foreach ($ins in $pGMCtor.Body.Instructions) {
        if ($ins.OpCode.Name -eq "ldc.i4" -and [int]$ins.Operand -eq 350) {
            $ins.Operand = [int]140
            $gmLowered++
        }
    }
}
# 1.6 Direct IL hooks on TouchVirtualPad.Update & TouchVirtualPad.Draw for SDVMobileControls (zero Harmony/JIT required!)
$coreScope = $tMod.TypeSystem.Object.Scope
$func3Ref = New-Object Mono.Cecil.TypeReference("System", "Func``3", $tMod, $coreScope, $false)
$func3Ref.GenericParameters.Add((New-Object Mono.Cecil.GenericParameter("T1", $func3Ref)))
$func3Ref.GenericParameters.Add((New-Object Mono.Cecil.GenericParameter("T2", $func3Ref)))
$func3Ref.GenericParameters.Add((New-Object Mono.Cecil.GenericParameter("TResult", $func3Ref)))

function Add-MobileHook($targetMethod, [string]$fieldName) {
    $arg1Type = $targetMethod.Parameters[0].ParameterType
    $funcInst = New-Object Mono.Cecil.GenericInstanceType($func3Ref)
    $funcInst.GenericArguments.Add($tMod.TypeSystem.Object)
    $funcInst.GenericArguments.Add($arg1Type)
    $funcInst.GenericArguments.Add($tMod.TypeSystem.Boolean)

    $fld = New-Object Mono.Cecil.FieldDefinition($fieldName, [Mono.Cecil.FieldAttributes]"Public, Static", $funcInst)
    $padType.Fields.Add($fld)

    $mInvoke = New-Object Mono.Cecil.MethodReference("Invoke", $func3Ref.GenericParameters[2], $funcInst)
    $mInvoke.HasThis = $true
    $mInvoke.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition($func3Ref.GenericParameters[0])))
    $mInvoke.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition($func3Ref.GenericParameters[1])))

    Expand-ShortBranches $targetMethod
    $hp = $targetMethod.Body.GetILProcessor()
    $orig0 = $targetMethod.Body.Instructions[0]

    $i0 = $hp.Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $fld)
    $i1 = $hp.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $orig0)
    $i2 = $hp.Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $fld)
    $i3 = $hp.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0)
    $i4 = $hp.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_1)
    $i5 = $hp.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mInvoke)
    $i6 = $hp.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $orig0)
    $i7 = $hp.Create([Mono.Cecil.Cil.OpCodes]::Ret)

    foreach ($ins in @($i0, $i1, $i2, $i3, $i4, $i5, $i6, $i7)) {
        $hp.InsertBefore($orig0, $ins)
    }
    Write-Host "  Injected direct IL hook TouchVirtualPad.$fieldName at instruction 0 of $($targetMethod.Name)($($arg1Type.Name))"
}

$mPadUpdate = $padType.Methods | Where-Object { $_.Name -eq "Update" -and $_.Parameters.Count -eq 1 } | Select-Object -First 1
$mPadDraw   = $padType.Methods | Where-Object { $_.Name -eq "Draw"   -and $_.Parameters.Count -eq 1 } | Select-Object -First 1
if (-not $mPadUpdate -or -not $mPadDraw) { throw "Missing TouchVirtualPad.Update or Draw" }
Add-MobileHook $mPadUpdate "MobileUpdateHook"
Add-MobileHook $mPadDraw   "MobileDrawHook"

# 1.6a Prepend throttled CheckManualGcFlag() BEFORE MobileUpdateHook at instruction 0 of TouchVirtualPad.Update
#      so "Dọn RAM ngay" works immediately even on TitleMenu, GameMenu, GMCM, or Pure Gamepad Mode!
$fGcFastTick = New-Object Mono.Cecil.FieldDefinition("_gcFastPollTick", [Mono.Cecil.FieldAttributes]"Private, Static", $tMod.TypeSystem.Int32)
$padType.Fields.Add($fGcFastTick)
$fExtGpActive = New-Object Mono.Cecil.FieldDefinition("ExternalGamepadActive", [Mono.Cecil.FieldAttributes]"Public, Static", $tMod.TypeSystem.Boolean)
$padType.Fields.Add($fExtGpActive)

Expand-ShortBranches $mPadUpdate
$gfpIL = $mPadUpdate.Body.GetILProcessor()
$uFirst0 = $mPadUpdate.Body.Instructions[0]
foreach ($ins in @(
    $gfpIL.Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $fGcFastTick),
    $gfpIL.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_1),
    $gfpIL.Create([Mono.Cecil.Cil.OpCodes]::Add),
    $gfpIL.Create([Mono.Cecil.Cil.OpCodes]::Dup),
    $gfpIL.Create([Mono.Cecil.Cil.OpCodes]::Stsfld, $fGcFastTick),
    $gfpIL.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_S, [sbyte]30),
    $gfpIL.Create([Mono.Cecil.Cil.OpCodes]::Blt, $uFirst0),
    $gfpIL.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0),
    $gfpIL.Create([Mono.Cecil.Cil.OpCodes]::Stsfld, $fGcFastTick),
    $gfpIL.Create([Mono.Cecil.Cil.OpCodes]::Call, $gcMethod)
)) { $gfpIL.InsertBefore($uFirst0, $ins) }
Write-Host "  Manual GC Anywhere + Hybrid Gamepad Flag (TouchControls): Pre-hook CheckManualGcFlag + ExternalGamepadActive!"

# 1.6b Direct IL hook TouchVirtualPad.MobileExtraKeysHook (Action<HashSet<Keys>>) & MobileExtraKeysListHook (Action<List<Keys>>) for unlimited custom PC hotkey buttons!
$fSimKeys = $padType.Fields | Where-Object { $_.Name -eq "_simKeysSet" }
$fActiveKeysList = $padType.Fields | Where-Object { $_.Name -eq "_activeKeysList" }
$fCachedSetKeys = $padType.Fields | Where-Object { $_.Name -eq "_cachedSetKeys" }
$hashSetKeysType = $fSimKeys.FieldType
$action1Ref = New-Object Mono.Cecil.TypeReference("System", "Action``1", $tMod, $coreScope, $false)
$action1Ref.GenericParameters.Add((New-Object Mono.Cecil.GenericParameter("T", $action1Ref)))
$actionKeysInst = New-Object Mono.Cecil.GenericInstanceType($action1Ref)
$actionKeysInst.GenericArguments.Add($hashSetKeysType)

$fExtraKeys = New-Object Mono.Cecil.FieldDefinition("MobileExtraKeysHook", [Mono.Cecil.FieldAttributes]"Public, Static", $actionKeysInst)
$padType.Fields.Add($fExtraKeys)

$fExtraKeysList = New-Object Mono.Cecil.FieldDefinition("MobileExtraKeysListHook", [Mono.Cecil.FieldAttributes]"Public, Static", $fCachedSetKeys.FieldType)
$padType.Fields.Add($fExtraKeysList)

$mActionInvoke = New-Object Mono.Cecil.MethodReference("Invoke", $tMod.TypeSystem.Void, $actionKeysInst)
$mActionInvoke.HasThis = $true
$mActionInvoke.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition($action1Ref.GenericParameters[0])))

$mListActionInvoke = Find-Ref $tMod "System.Void System.Action``1<System.Collections.Generic.List``1<Microsoft.Xna.Framework.Input.Keys>>::Invoke(!0)"
if (-not $mListActionInvoke) { throw "Missing Action<List<Keys>>::Invoke reference" }

# 1) get_HasActiveHotkeyInput: if (MobileHasExtraKeysHook != null && MobileHasExtraKeysHook()) return true;
$func1Ref = New-Object Mono.Cecil.TypeReference("System", "Func``1", $tMod, $coreScope, $false)
$func1Ref.GenericParameters.Add((New-Object Mono.Cecil.GenericParameter("TResult", $func1Ref)))
$funcBoolInst = New-Object Mono.Cecil.GenericInstanceType($func1Ref)
$funcBoolInst.GenericArguments.Add($tMod.TypeSystem.Boolean)
$fHasExtraKeys = New-Object Mono.Cecil.FieldDefinition("MobileHasExtraKeysHook", [Mono.Cecil.FieldAttributes]"Public, Static", $funcBoolInst)
$padType.Fields.Add($fHasExtraKeys)
$mFuncBoolInvoke = New-Object Mono.Cecil.MethodReference("Invoke", $func1Ref.GenericParameters[0], $funcBoolInst)
$mFuncBoolInvoke.HasThis = $true

$mHasHotkey = $padType.Methods | Where-Object { $_.Name -eq "get_HasActiveHotkeyInput" }
if (-not $mHasHotkey) { throw "Missing get_HasActiveHotkeyInput" }
Expand-ShortBranches $mHasHotkey
$hhp = $mHasHotkey.Body.GetILProcessor()
$hh0 = $mHasHotkey.Body.Instructions[0]
$hhp.InsertBefore($hh0, $hhp.Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $fHasExtraKeys))
$hhp.InsertBefore($hh0, $hhp.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $hh0))
$hhp.InsertBefore($hh0, $hhp.Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $fHasExtraKeys))
$hhp.InsertBefore($hh0, $hhp.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mFuncBoolInvoke))
$hhp.InsertBefore($hh0, $hhp.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $hh0))
$hhp.InsertBefore($hh0, $hhp.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_1))
$hhp.InsertBefore($hh0, $hhp.Create([Mono.Cecil.Cil.OpCodes]::Ret))

# 1b) QuickSaveManager safety hooks: MobileCanSaveBlockReasonHook (Func<object, string>) & MobileOnSaveLoadedHook (Func<object, bool>)
$qsType = $tMod.Types | Where-Object { $_.Name -eq "QuickSaveManager" }
if ($qsType) {
    $func2Ref = New-Object Mono.Cecil.TypeReference("System", "Func``2", $tMod, $coreScope, $false)
    $func2Ref.GenericParameters.Add((New-Object Mono.Cecil.GenericParameter("T", $func2Ref)))
    $func2Ref.GenericParameters.Add((New-Object Mono.Cecil.GenericParameter("TResult", $func2Ref)))

    $funcObjStr = New-Object Mono.Cecil.GenericInstanceType($func2Ref)
    $funcObjStr.GenericArguments.Add($tMod.TypeSystem.Object)
    $funcObjStr.GenericArguments.Add($tMod.TypeSystem.String)
    $fQsCanSave = New-Object Mono.Cecil.FieldDefinition("MobileCanSaveBlockReasonHook", [Mono.Cecil.FieldAttributes]"Public, Static", $funcObjStr)
    $qsType.Fields.Add($fQsCanSave)
    $mFuncObjStrInv = New-Object Mono.Cecil.MethodReference("Invoke", $func2Ref.GenericParameters[1], $funcObjStr)
    $mFuncObjStrInv.HasThis = $true
    $mFuncObjStrInv.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition($func2Ref.GenericParameters[0])))

    $funcObjBool = New-Object Mono.Cecil.GenericInstanceType($func2Ref)
    $funcObjBool.GenericArguments.Add($tMod.TypeSystem.Object)
    $funcObjBool.GenericArguments.Add($tMod.TypeSystem.Boolean)
    $fQsOnLoaded = New-Object Mono.Cecil.FieldDefinition("MobileOnSaveLoadedHook", [Mono.Cecil.FieldAttributes]"Public, Static", $funcObjBool)
    $qsType.Fields.Add($fQsOnLoaded)
    $mFuncObjBoolInv = New-Object Mono.Cecil.MethodReference("Invoke", $func2Ref.GenericParameters[1], $funcObjBool)
    $mFuncObjBoolInv.HasThis = $true
    $mFuncObjBoolInv.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition($func2Ref.GenericParameters[0])))

    $mQsCanSave = $qsType.Methods | Where-Object { $_.Name -eq "CanSaveNow" -and $_.Parameters.Count -eq 1 }
    $mIsNullOrEmptyQs = Find-Ref $tMod "System.Boolean System.String::IsNullOrEmpty(System.String)"
    if ($mQsCanSave -and $mIsNullOrEmptyQs) {
        Expand-ShortBranches $mQsCanSave
        $vBlk = New-Object Mono.Cecil.Cil.VariableDefinition($tMod.TypeSystem.String)
        $mQsCanSave.Body.Variables.Add($vBlk)
        $mQsCanSave.Body.InitLocals = $true
        $qsp = $mQsCanSave.Body.GetILProcessor()
        $qs0 = $mQsCanSave.Body.Instructions[0]
        foreach ($ins in @(
            $qsp.Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $fQsCanSave),
            $qsp.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $qs0),
            $qsp.Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $fQsCanSave),
            $qsp.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0),
            $qsp.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mFuncObjStrInv),
            $qsp.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vBlk),
            $qsp.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vBlk),
            $qsp.Create([Mono.Cecil.Cil.OpCodes]::Call, $mIsNullOrEmptyQs),
            $qsp.Create([Mono.Cecil.Cil.OpCodes]::Brtrue, $qs0),
            $qsp.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_1),
            $qsp.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vBlk),
            $qsp.Create([Mono.Cecil.Cil.OpCodes]::Stind_Ref),
            $qsp.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0),
            $qsp.Create([Mono.Cecil.Cil.OpCodes]::Ret)
        )) { $qsp.InsertBefore($qs0, $ins) }
    }

    $mQsOnLoaded = $qsType.Methods | Where-Object { $_.Name -eq "OnSaveLoaded" -and $_.Parameters.Count -eq 0 }
    if ($mQsOnLoaded) {
        Expand-ShortBranches $mQsOnLoaded
        $olp = $mQsOnLoaded.Body.GetILProcessor()
        $ol0 = $mQsOnLoaded.Body.Instructions[0]
        foreach ($ins in @(
            $olp.Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $fQsOnLoaded),
            $olp.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $ol0),
            $olp.Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $fQsOnLoaded),
            $olp.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0),
            $olp.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mFuncObjBoolInv),
            $olp.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $ol0),
            $olp.Create([Mono.Cecil.Cil.OpCodes]::Ret)
        )) { $olp.InsertBefore($ol0, $ins) }
    }
    Write-Host "  QuickSave Safety Hooks (TouchControls): Injected MobileCanSaveBlockReasonHook + MobileOnSaveLoadedHook!"
}

# 2) get_CurrentSimulatedKeyboardState: right before final _simKeysSet.get_Count(), invoke MobileExtraKeysHook(_simKeysSet)
$mSimKb = $padType.Methods | Where-Object { $_.Name -eq "get_CurrentSimulatedKeyboardState" }
if (-not $mSimKb) { throw "Missing get_CurrentSimulatedKeyboardState" }
Expand-ShortBranches $mSimKb
$skp = $mSimKb.Body.GetILProcessor()
$skIns = $mSimKb.Body.Instructions
$countAnchor = $null
for ($i = $skIns.Count - 1; $i -ge 2; $i--) {
    if ($skIns[$i].OpCode.Name -eq "callvirt" -and "$($skIns[$i].Operand)" -like "*HashSet*get_Count*") {
        # Locate the FIRST of the two get_Count() calls (the `if (_simKeysSet.Count == 0)` check)
        $countAnchor = $skIns[$i - 2]
    }
}
if (-not $countAnchor) { throw "Could not find _simKeysSet.get_Count() anchor in get_CurrentSimulatedKeyboardState" }
$ek0 = $skp.Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $fExtraKeys)
$ek1 = $skp.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $countAnchor)
$ek2 = $skp.Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $fExtraKeys)
$ek3 = $skp.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0)
$ek4 = $skp.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $fSimKeys)
$ek5 = $skp.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mActionInvoke)
foreach ($ins in @($ek0, $ek1, $ek2, $ek3, $ek4, $ek5)) { $skp.InsertBefore($countAnchor, $ins) }
Retarget-Branches $mSimKb $countAnchor $ek0
$ek1.Operand = $countAnchor

# 3) ForwardInputToGame: right after _hotkeyTouchActive[0..7] loop (before get_VerboseInputLogging), invoke MobileExtraKeysListHook(_activeKeysList)
$mFwd = $padType.Methods | Where-Object { $_.Name -eq "ForwardInputToGame" }
if (-not $mFwd) { throw "Missing ForwardInputToGame" }
Expand-ShortBranches $mFwd
$fwp = $mFwd.Body.GetILProcessor()
$verbAnchor = $null
foreach ($ins in $mFwd.Body.Instructions) {
    if ($ins.OpCode.Name -eq "call" -and "$($ins.Operand)" -like "*ModEntry::get_VerboseInputLogging*") {
        $verbAnchor = $ins
        break
    }
}
if (-not $verbAnchor) { throw "Could not find get_VerboseInputLogging anchor in ForwardInputToGame" }
$fl0 = $fwp.Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $fExtraKeysList)
$fl1 = $fwp.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $verbAnchor)
$fl2 = $fwp.Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $fExtraKeysList)
$fl3 = $fwp.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0)
$fl4 = $fwp.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $fActiveKeysList)
$fl5 = $fwp.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mListActionInvoke)
foreach ($ins in @($fl0, $fl1, $fl2, $fl3, $fl4, $fl5)) { $fwp.InsertBefore($verbAnchor, $ins) }
Retarget-Branches $mFwd $verbAnchor $fl0
$fl1.Operand = $verbAnchor
Write-Host "  Injected direct IL hooks TouchVirtualPad.MobileExtraKeysHook + MobileExtraKeysListHook for custom PC buttons!"

# 1.7 Fix CoreAssetPropagator hooks in SDViOSTouchControls:
#   (a) Never hook/suppress CoreAssetPropagator.PropagateTexture (breaks Content Patcher UI/retexture mods like Cat Valley UI!)
#   (b) Gate PrefixPropagateMap on DeferredMapLoader.IsBulkLoading so map propagation works normally after save load.
$tTouchModEntry = $tMod.GetType("SDViOSTouchControls.ModEntry")
if (-not $tTouchModEntry) { throw "Missing SDViOSTouchControls.ModEntry for Patch 1.7!" }
$mApplyHarmony = $tTouchModEntry.Methods | Where-Object { $_.Name -eq "ApplyHarmonyPatches" }
if (-not $mApplyHarmony -or -not $mApplyHarmony.HasBody) { throw "Missing ApplyHarmonyPatches!" }
$ptStrPatched = 0
foreach ($ins in $mApplyHarmony.Body.Instructions) {
    if ($ins.OpCode.Name -eq "ldstr" -and "$($ins.Operand)" -eq "PropagateTexture") {
        $ins.Operand = "__Disabled_PropagateTexture__"
        $ptStrPatched++
    }
}
if ($ptStrPatched -lt 1) { throw "Expected PropagateTexture string in ApplyHarmonyPatches!" }
Write-Host "  Disabled SDViOSTouchControls PropagateTexture suppression ($ptStrPatched hook skipped)."

$mPrefPropMap = $tTouchModEntry.Methods | Where-Object { $_.Name -eq "PrefixPropagateMap" }
$tDefMapLoader = $tMod.GetType("SDViOSTouchControls.DeferredMapLoader")
$mGetBulkLoad = if ($tDefMapLoader) { $tDefMapLoader.Methods | Where-Object { $_.Name -eq "get_IsBulkLoading" } } else { $null }
if (-not $mPrefPropMap -or -not $mPrefPropMap.HasBody -or -not $mGetBulkLoad) { throw "Missing PrefixPropagateMap or DeferredMapLoader.get_IsBulkLoading!" }
$pmIl = $mPrefPropMap.Body.GetILProcessor()
$mPrefPropMap.Body.Instructions.Clear()
$mPrefPropMap.Body.ExceptionHandlers.Clear()
$mPrefPropMap.Body.Variables.Clear()
$lSkipMap = $pmIl.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0)
$pmIl.Append($pmIl.Create([Mono.Cecil.Cil.OpCodes]::Call, $mGetBulkLoad))
$pmIl.Append($pmIl.Create([Mono.Cecil.Cil.OpCodes]::Brtrue_S, $lSkipMap))
$pmIl.Append($pmIl.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_1))
$pmIl.Append($pmIl.Create([Mono.Cecil.Cil.OpCodes]::Ret))
$pmIl.Append($lSkipMap)
$pmIl.Append($pmIl.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0))
$pmIl.Append($pmIl.Create([Mono.Cecil.Cil.OpCodes]::Stind_I1))
$pmIl.Append($pmIl.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0))
$pmIl.Append($pmIl.Create([Mono.Cecil.Cil.OpCodes]::Ret))
Write-Host "  Gated PrefixPropagateMap on DeferredMapLoader.IsBulkLoading!"

# 1.8 Fix SDViOSTouchControls.ModEntry.PrefixSetWindowSize:
# Allow Game1.SetWindowSize to recreate Game1.screen whenever Game1.screen dimensions don't match
# Ceiling(_staticNativeWidth / zoomLevel) x Ceiling(_staticNativeHeight / zoomLevel) (within 4px).
# Previously it skipped SetWindowSize unconditionally once Game1.screen != null, leaving Game1.screen stuck
# at 1.0x native pixels (e.g. 2436x1125) when Zoom=1.25 (viewport 1949x900), misaligning DynamicShader TiltShift
# blur bands & WaterReflection screen buffers!
$mPrefSws = $tTouchModEntry.Methods | Where-Object { $_.Name -eq "PrefixSetWindowSize" }
$mGame1GetScreen = Find-Ref $tMod "Microsoft.Xna.Framework.Graphics.RenderTarget2D StardewValley.Game1::get_screen()"
$mGame1GetOpts   = Find-Ref $tMod "StardewValley.Options StardewValley.Game1::get_options()"
if ($mPrefSws -and $mGame1GetScreen -and $mGame1GetOpts) {
    $tOptsRef = $mGame1GetOpts.ReturnType
    $mGetZoom = New-Object Mono.Cecil.MethodReference("get_zoomLevel", $tMod.TypeSystem.Single, $tOptsRef)
    $mGetZoom.HasThis = $true
    $tTex2DRef = New-Object Mono.Cecil.TypeReference("Microsoft.Xna.Framework.Graphics", "Texture2D", $tMod, $mGame1GetScreen.ReturnType.Scope, $false)
    $mTexGetW = New-Object Mono.Cecil.MethodReference("get_Width", $tMod.TypeSystem.Int32, $tTex2DRef)
    $mTexGetW.HasThis = $true
    $mTexGetH = New-Object Mono.Cecil.MethodReference("get_Height", $tMod.TypeSystem.Int32, $tTex2DRef)
    $mTexGetH.HasThis = $true
    $tMathRef = New-Object Mono.Cecil.TypeReference("System", "Math", $tMod, $tMod.TypeSystem.Object.Scope, $false)
    $mMathCeil = New-Object Mono.Cecil.MethodReference("Ceiling", $tMod.TypeSystem.Double, $tMathRef)
    $mMathCeil.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition($tMod.TypeSystem.Double)))
    $mMathAbs = New-Object Mono.Cecil.MethodReference("Abs", $tMod.TypeSystem.Int32, $tMathRef)
    $mMathAbs.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition($tMod.TypeSystem.Int32)))
    $fGame1Inst = $null
    foreach ($ins in $mPrefSws.Body.Instructions) {
        if ($ins.OpCode.Name -eq "ldsfld" -and "$($ins.Operand)" -like "*Game1::game1*") { $fGame1Inst = $ins.Operand; break }
    }
    Expand-ShortBranches $mPrefSws
    # Find the `ldc.i4.0; ret` (return false = skip SetWindowSize) site
    $swsIns = $mPrefSws.Body.Instructions
    $skipFalseAnchor = $null
    for ($i = 0; $i -lt ($swsIns.Count - 1); $i++) {
        if ($swsIns[$i].OpCode.Name -eq "ldc.i4.0" -and $swsIns[$i+1].OpCode.Name -eq "ret") {
            $skipFalseAnchor = $swsIns[$i]
            break
        }
    }
    if ($skipFalseAnchor -and $fGame1Inst) {
        $vScr  = New-Object Mono.Cecil.Cil.VariableDefinition($mGame1GetScreen.ReturnType)
        $vOpt  = New-Object Mono.Cecil.Cil.VariableDefinition($tOptsRef)
        $vZoom = New-Object Mono.Cecil.Cil.VariableDefinition($tMod.TypeSystem.Single)
        $vExpW = New-Object Mono.Cecil.Cil.VariableDefinition($tMod.TypeSystem.Int32)
        $vExpH = New-Object Mono.Cecil.Cil.VariableDefinition($tMod.TypeSystem.Int32)
        foreach ($v in @($vScr, $vOpt, $vZoom, $vExpW, $vExpH)) { $mPrefSws.Body.Variables.Add($v) }
        $mPrefSws.Body.InitLocals = $true
        $swsIL = $mPrefSws.Body.GetILProcessor()
        $lRunOrig = $swsIns[$swsIns.Count - 2] # ldc.i4.1; ret
        $lZoomOk  = $swsIL.Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $fSNatW)
        $lCheckScr = $swsIL.Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $fGame1Inst)
        # Insert right before skipFalseAnchor:
        # screen = Game1.game1.screen; z = Game1.options?.zoomLevel ?? 1f; if (z <= 0.05f) z = 1f;
        # expW = (int)Math.Ceiling(_staticNativeWidth / (double)z); expH = (int)Math.Ceiling(_staticNativeHeight / (double)z);
        # if (Math.Abs(screen.Width - expW) > 4 || Math.Abs(screen.Height - expH) > 4) return true;
        $seq = @(
            $lCheckScr,
            $swsIL.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mGame1GetScreen),
            $swsIL.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vScr),
            $swsIL.Create([Mono.Cecil.Cil.OpCodes]::Ldc_R4, [float]1.0),
            $swsIL.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vZoom),
            $swsIL.Create([Mono.Cecil.Cil.OpCodes]::Call, $mGame1GetOpts),
            $swsIL.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vOpt),
            $swsIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vOpt),
            $swsIL.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $lZoomOk),
            $swsIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vOpt),
            $swsIL.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mGetZoom),
            $swsIL.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vZoom),
            $swsIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vZoom),
            $swsIL.Create([Mono.Cecil.Cil.OpCodes]::Ldc_R4, [float]0.05),
            $swsIL.Create([Mono.Cecil.Cil.OpCodes]::Bgt, $lZoomOk),
            $swsIL.Create([Mono.Cecil.Cil.OpCodes]::Ldc_R4, [float]1.0),
            $swsIL.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vZoom),
            # expW = (int)Math.Ceiling(_staticNativeWidth / (double)z)
            $lZoomOk,
            $swsIL.Create([Mono.Cecil.Cil.OpCodes]::Conv_R8),
            $swsIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vZoom),
            $swsIL.Create([Mono.Cecil.Cil.OpCodes]::Conv_R8),
            $swsIL.Create([Mono.Cecil.Cil.OpCodes]::Div),
            $swsIL.Create([Mono.Cecil.Cil.OpCodes]::Call, $mMathCeil),
            $swsIL.Create([Mono.Cecil.Cil.OpCodes]::Conv_I4),
            $swsIL.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vExpW),
            # expH = (int)Math.Ceiling(_staticNativeHeight / (double)z)
            $swsIL.Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $fSNatH),
            $swsIL.Create([Mono.Cecil.Cil.OpCodes]::Conv_R8),
            $swsIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vZoom),
            $swsIL.Create([Mono.Cecil.Cil.OpCodes]::Conv_R8),
            $swsIL.Create([Mono.Cecil.Cil.OpCodes]::Div),
            $swsIL.Create([Mono.Cecil.Cil.OpCodes]::Call, $mMathCeil),
            $swsIL.Create([Mono.Cecil.Cil.OpCodes]::Conv_I4),
            $swsIL.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vExpH),
            # if (Math.Abs(screen.Width - expW) > 4) goto lRunOrig
            $swsIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vScr),
            $swsIL.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mTexGetW),
            $swsIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vExpW),
            $swsIL.Create([Mono.Cecil.Cil.OpCodes]::Sub),
            $swsIL.Create([Mono.Cecil.Cil.OpCodes]::Call, $mMathAbs),
            $swsIL.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_4),
            $swsIL.Create([Mono.Cecil.Cil.OpCodes]::Bgt, $lRunOrig),
            # if (Math.Abs(screen.Height - expH) > 4) goto lRunOrig
            $swsIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vScr),
            $swsIL.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mTexGetH),
            $swsIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vExpH),
            $swsIL.Create([Mono.Cecil.Cil.OpCodes]::Sub),
            $swsIL.Create([Mono.Cecil.Cil.OpCodes]::Call, $mMathAbs),
            $swsIL.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_4),
            $swsIL.Create([Mono.Cecil.Cil.OpCodes]::Bgt, $lRunOrig)
        )
        foreach ($ins in $seq) { $swsIL.InsertBefore($skipFalseAnchor, $ins) }
        Retarget-Branches $mPrefSws $skipFalseAnchor $lCheckScr
        Write-Host "  DynamicShader Screen Sync Fix (TouchControls): PrefixSetWindowSize now allows Game1.screen resize on Zoom change!"
    }
}

# 1.9 Hidden .garden/ config paths in SDViOSTouchControls (keeps iOS Files app Documents/ clean!)
$touchHidden = 0
foreach ($tt in $tMod.Types) {
    foreach ($tm in $tt.Methods) {
        if (-not $tm.HasBody) { continue }
        foreach ($ins in $tm.Body.Instructions) {
            if ($ins.OpCode.Name -eq "ldstr") {
                if ($tm.Name -eq "GetConfigPath" -and $ins.Operand -eq "touch_overlay_config.json") {
                    $ins.Operand = ".garden/touch_overlay_config.json"; $touchHidden++
                } elseif ($tm.Name -eq "SyncMenuBarConfig" -and $ins.Operand -eq "sdv_menubar.cfg") {
                    $ins.Operand = ".garden/sdv_menubar.cfg"; $touchHidden++
                } elseif ($tm.Name -eq "RelocateDisabledModsOnBoot" -and $ins.Operand -eq "DisabledMods") {
                    $ins.Operand = ".garden/DisabledMods"; $touchHidden++
                }
            }
        }
    }
}
if ($touchHidden -lt 3) { throw "Expected >=3 hidden .garden path patches in TouchControls, got $touchHidden!" }
Write-Host "  Hidden Documents Layout (TouchControls): redirected $touchHidden config/relocate paths into Documents/.garden/!"

# 1.10 Fix startup UpdateTicking NullReferenceException in SDViOSTouchControls.ModEntry.OnUpdateTicking
# Guard TouchVirtualPad.Instance.Update(Game1.currentGameTime) against null Instance or null currentGameTime on tick 0!
$mOnUt = $meType.Methods | Where-Object { $_.Name -eq "OnUpdateTicking" } | Select-Object -First 1
if ($mOnUt -and $mOnUt.HasBody) {
    Expand-ShortBranches $mOnUt
    $utIL = $mOnUt.Body.GetILProcessor()
    $utIns = $mOnUt.Body.Instructions
    $utPatched = $false
    for ($i = 0; $i -lt $utIns.Count - 2; $i++) {
        if ($utIns[$i].OpCode.Name -eq "call" -and "$($utIns[$i].Operand)" -like "*TouchVirtualPad::get_Instance*" -and
            $utIns[$i+1].OpCode.Name -eq "ldsfld" -and "$($utIns[$i+1].Operand)" -like "*Game1::currentGameTime*" -and
            $utIns[$i+2].OpCode.Name -eq "callvirt" -and "$($utIns[$i+2].Operand)" -like "*TouchVirtualPad::Update*") {
            $callInst  = $utIns[$i]
            $mGetInst  = $utIns[$i].Operand
            $fGameTime = $utIns[$i+1].Operand
            $afterCall = $utIns[$i+3]
            $vPad = New-Object Mono.Cecil.Cil.VariableDefinition($mGetInst.ReturnType)
            $vGt  = New-Object Mono.Cecil.Cil.VariableDefinition($fGameTime.FieldType)
            $mOnUt.Body.Variables.Add($vPad)
            $mOnUt.Body.Variables.Add($vGt)
            $mOnUt.Body.InitLocals = $true

            $ldInst = $utIL.Create([Mono.Cecil.Cil.OpCodes]::Call, $mGetInst)
            $utIL.InsertBefore($callInst, $ldInst)
            $utIL.InsertBefore($callInst, $utIL.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vPad))
            $utIL.InsertBefore($callInst, $utIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vPad))
            $utIL.InsertBefore($callInst, $utIL.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $afterCall))
            $utIL.InsertBefore($callInst, $utIL.Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $fGameTime))
            $utIL.InsertBefore($callInst, $utIL.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vGt))
            $utIL.InsertBefore($callInst, $utIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vGt))
            $utIL.InsertBefore($callInst, $utIL.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $afterCall))
            Retarget-Branches $mOnUt $callInst $ldInst
            $utPatched = $true
            break
        }
    }
    if (-not $utPatched) { throw "Could not find TouchVirtualPad.Instance.Update(Game1.currentGameTime) in OnUpdateTicking!" }
    Write-Host "  Startup NRE Fix (TouchControls): Guarded OnUpdateTicking against null Instance / currentGameTime!"
}

# 1.10 Pure Gamepad Mode (Documents/.garden/sdv_gamepad_only.flag) in SDViOSTouchControls:
#   - TouchVirtualPad.IsPureGamepadMode(): checks flag file once at boot and caches result in _pureGamepadState (1=ON, 2=OFF).
#   - SDViOSTouchControls.ModEntry.OnUpdateTicking: when ON, skips forcing Game1.options.gamepadMode=ForceOff / gamepadControls=false!
#   - SDViOSTouchControls.TouchDelegatingModHooks.OnGame1_UpdateControlInput: when ON, delegates straight to base DelegatingModHooks!
#   - SDViOSTouchControls.ModEntry.ApplyHarmonyPatches: when ON, skips touch input Harmony overrides (after PatchClientBounds)!
$fPureGpState = New-Object Mono.Cecil.FieldDefinition("_pureGamepadState", [Mono.Cecil.FieldAttributes]"Public, Static", $tMod.TypeSystem.Int32)
$padType.Fields.Add($fPureGpState)

$mIsPureGp = New-Object Mono.Cecil.MethodDefinition("IsPureGamepadMode", [Mono.Cecil.MethodAttributes]"Public, Static", $tMod.TypeSystem.Boolean)
$mIsPureGp.Body.InitLocals = $true
$vGpState = New-Object Mono.Cecil.Cil.VariableDefinition($tMod.TypeSystem.Int32)
$mIsPureGp.Body.Variables.Add($vGpState)
$pgIL = $mIsPureGp.Body.GetILProcessor()
$lPgCheckDisk = $pgIL.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_2)
$lPgDone      = $pgIL.Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $fPureGpState)
$lPgLeave     = $pgIL.Create([Mono.Cecil.Cil.OpCodes]::Leave, $lPgDone)
$lPgCatch     = $pgIL.Create([Mono.Cecil.Cil.OpCodes]::Pop)
$lPgTry       = $pgIL.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_5)

$pgIL.Append($pgIL.Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $fPureGpState))
$pgIL.Append($pgIL.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vGpState))
$pgIL.Append($pgIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vGpState))
$pgIL.Append($pgIL.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $lPgCheckDisk))
$pgIL.Append($pgIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vGpState))
$pgIL.Append($pgIL.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_1))
$pgIL.Append($pgIL.Create([Mono.Cecil.Cil.OpCodes]::Ceq))
$pgIL.Append($pgIL.Create([Mono.Cecil.Cil.OpCodes]::Ret))

$pgIL.Append($lPgCheckDisk)
$pgIL.Append($pgIL.Create([Mono.Cecil.Cil.OpCodes]::Stsfld, $fPureGpState))
$pgIL.Append($lPgTry)
$pgIL.Append($pgIL.Create([Mono.Cecil.Cil.OpCodes]::Call, $mGetFolderPath))
$pgIL.Append($pgIL.Create([Mono.Cecil.Cil.OpCodes]::Ldstr, ".garden/sdv_gamepad_only.flag"))
$pgIL.Append($pgIL.Create([Mono.Cecil.Cil.OpCodes]::Call, $mPathCombine))
$pgIL.Append($pgIL.Create([Mono.Cecil.Cil.OpCodes]::Call, $mFileExists))
$pgIL.Append($pgIL.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $lPgLeave))
$pgIL.Append($pgIL.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_1))
$pgIL.Append($pgIL.Create([Mono.Cecil.Cil.OpCodes]::Stsfld, $fPureGpState))
$pgIL.Append($lPgLeave)
$pgIL.Append($lPgCatch)
$pgIL.Append($pgIL.Create([Mono.Cecil.Cil.OpCodes]::Leave, $lPgDone))
$pgIL.Append($lPgDone)
$pgIL.Append($pgIL.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_1))
$pgIL.Append($pgIL.Create([Mono.Cecil.Cil.OpCodes]::Ceq))
$pgIL.Append($pgIL.Create([Mono.Cecil.Cil.OpCodes]::Ret))

$ehPg = New-Object Mono.Cecil.Cil.ExceptionHandler([Mono.Cecil.Cil.ExceptionHandlerType]::Catch)
$ehPg.CatchType = $tMod.TypeSystem.Object
$ehPg.TryStart = $lPgTry
$ehPg.TryEnd = $lPgCatch
$ehPg.HandlerStart = $lPgCatch
$ehPg.HandlerEnd = $lPgDone
$mIsPureGp.Body.ExceptionHandlers.Add($ehPg)
$padType.Methods.Add($mIsPureGp)

# 1.10a Skip ForceOff / gamepadControls=false in SDViOSTouchControls.ModEntry.OnUpdateTicking when IsPureGamepadMode()
Expand-ShortBranches $mOnUt
$utIns2 = $mOnUt.Body.Instructions
$pgUtPatched = $false
for ($i = 0; $i -lt ($utIns2.Count - 8); $i++) {
    if ($utIns2[$i].OpCode.Name -eq "call" -and "$($utIns2[$i].Operand)" -like "*Game1::get_options*" -and
        $utIns2[$i+1].OpCode.Name -eq "brfalse" -and "$($utIns2[$i+1].Operand.Operand)" -like "*Game1::hudMessages*") {
        $optsStart = $utIns2[$i]
        $afterOpts = $utIns2[$i+1].Operand
        $utIL2 = $mOnUt.Body.GetILProcessor()
        $chk0 = $utIL2.Create([Mono.Cecil.Cil.OpCodes]::Call, $mIsPureGp)
        $chk1 = $utIL2.Create([Mono.Cecil.Cil.OpCodes]::Brtrue, $afterOpts)
        $chk2 = $utIL2.Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $fExtGpActive)
        $chk3 = $utIL2.Create([Mono.Cecil.Cil.OpCodes]::Brtrue, $afterOpts)
        $utIL2.InsertBefore($optsStart, $chk0)
        $utIL2.InsertBefore($optsStart, $chk1)
        $utIL2.InsertBefore($optsStart, $chk2)
        $utIL2.InsertBefore($optsStart, $chk3)
        Retarget-Branches $mOnUt $optsStart $chk0
        $pgUtPatched = $true
        break
    }
}
if (-not $pgUtPatched) { throw "Failed to patch Pure Gamepad Mode bypass in SDViOSTouchControls.ModEntry.OnUpdateTicking!" }

# 1.10b Bypass TouchDelegatingModHooks.OnGame1_UpdateControlInput when IsPureGamepadMode()
$tDelHooks = $tMod.GetType("SDViOSTouchControls.TouchDelegatingModHooks")
$mHookCtrl = if ($tDelHooks) { $tDelHooks.Methods | Where-Object { $_.Name -eq "OnGame1_UpdateControlInput" } | Select-Object -First 1 } else { $null }
if (-not $mHookCtrl) { throw "Missing TouchDelegatingModHooks.OnGame1_UpdateControlInput!" }
Expand-ShortBranches $mHookCtrl
$mBaseCtrl = New-Object Mono.Cecil.MethodReference("OnGame1_UpdateControlInput", $tMod.TypeSystem.Void, $tDelHooks.BaseType)
$mBaseCtrl.HasThis = $true
foreach ($p in $mHookCtrl.Parameters) {
    $mBaseCtrl.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition($p.Name, $p.Attributes, $p.ParameterType)))
}
$hcIL = $mHookCtrl.Body.GetILProcessor()
$hcOrig0 = $mHookCtrl.Body.Instructions[0]
$hcSeq = @(
    $hcIL.Create([Mono.Cecil.Cil.OpCodes]::Call, $mIsPureGp),
    $hcIL.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $hcOrig0),
    $hcIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0),
    $hcIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_1),
    $hcIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_2),
    $hcIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_3),
    $hcIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_S, $mHookCtrl.Parameters[3]),
    $hcIL.Create([Mono.Cecil.Cil.OpCodes]::Call, $mBaseCtrl),
    $hcIL.Create([Mono.Cecil.Cil.OpCodes]::Ret)
)
foreach ($ins in $hcSeq) { $hcIL.InsertBefore($hcOrig0, $ins) }

# 1.10c Also skip TouchControls input Harmony patches (after PatchClientBounds) when IsPureGamepadMode()
$ahpIL2 = $ahpM.Body.GetILProcessor()
for ($i = 0; $i -lt $ahpM.Body.Instructions.Count; $i++) {
    if ($ahpM.Body.Instructions[$i].OpCode.Name -eq "call" -and $ahpM.Body.Instructions[$i].Operand -eq $mPatchCB) {
        $afterPatchCB = $ahpM.Body.Instructions[$i + 1]
        $ahpIL2.InsertBefore($afterPatchCB, $ahpIL2.Create([Mono.Cecil.Cil.OpCodes]::Call, $mIsPureGp))
        $ahpIL2.InsertBefore($afterPatchCB, $ahpIL2.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $afterPatchCB))
        $ahpIL2.InsertBefore($afterPatchCB, $ahpIL2.Create([Mono.Cecil.Cil.OpCodes]::Ret))
        break
    }
}
Write-Host "  Pure Gamepad Mode (TouchControls): Injected TouchVirtualPad.IsPureGamepadMode() bypass in OnUpdateTicking + TouchDelegatingModHooks + ApplyHarmonyPatches!"

# 1.11 Exit-to-Title Deadlock & UI-Stall Fix (credit @Mudkip267):
#      Neutralize blocking System.GC::WaitForPendingFinalizers() calls on the UI thread in TouchControls
#      (MemoryWatchdog.ForceCollect + ModEntry.PurgeNonCoreAssets) so menu transitions & Exit-to-Title never freeze!
$waitFinNopped = 0
function Nop-WaitForPendingFinalizers($typeDef) {
    foreach ($m in $typeDef.Methods) {
        if (-not $m.HasBody) { continue }
        foreach ($ins in $m.Body.Instructions) {
            if (($ins.OpCode.Name -eq "call" -or $ins.OpCode.Name -eq "callvirt") -and
                $ins.Operand -is [Mono.Cecil.MethodReference] -and
                $ins.Operand.DeclaringType.FullName -eq "System.GC" -and
                $ins.Operand.Name -eq "WaitForPendingFinalizers") {
                $ins.OpCode = [Mono.Cecil.Cil.OpCodes]::Nop
                $ins.Operand = $null
                $script:waitFinNopped++
            }
        }
    }
    foreach ($nt in $typeDef.NestedTypes) { Nop-WaitForPendingFinalizers $nt }
}
foreach ($t in $tMod.Types) { Nop-WaitForPendingFinalizers $t }
if ($waitFinNopped -lt 2) { throw "Expected >=2 GC.WaitForPendingFinalizers calls in TouchControls, got $waitFinNopped!" }
Write-Host "  Exit-to-Title & GC-Stall Fix (TouchControls): Neutralized $waitFinNopped blocking GC.WaitForPendingFinalizers() call(s)!"

# 1.12 In-Game Menu 60 FPS Default Fix (TouchControls):
#      TouchOverlaySettings..ctor previously defaulted EnableMenuFrameThrottling = true (forcing Backpack/Chest/Shop menus to 30 FPS!).
#      Change default to false (60 FPS smooth menus); users can still toggle 30 FPS Menu Battery Saver live from Mod Garden!
$tTos = $tMod.GetType("SDViOSTouchControls.TouchOverlaySettings")
$mTosCtor = if ($tTos) { $tTos.Methods | Where-Object { $_.Name -eq ".ctor" -and $_.HasBody } | Select-Object -First 1 } else { $null }
$menuFpsPatched = $false
if ($mTosCtor) {
    $tosIns = $mTosCtor.Body.Instructions
    for ($i = 1; $i -lt $tosIns.Count; $i++) {
        if ($tosIns[$i].OpCode.Name -eq "stfld" -and "$($tosIns[$i].Operand)" -like "*<EnableMenuFrameThrottling>k__BackingField*" -and $tosIns[$i-1].OpCode.Name -eq "ldc.i4.1") {
            $tosIns[$i-1].OpCode = [Mono.Cecil.Cil.OpCodes]::Ldc_I4_0
            $menuFpsPatched = $true
            break
        }
    }
}
if (-not $menuFpsPatched) { throw "Failed to patch EnableMenuFrameThrottling default in TouchOverlaySettings..ctor!" }
Write-Host "  Menu 60 FPS Fix (TouchControls): EnableMenuFrameThrottling default changed true -> false (toggleable 60/30 FPS in Mod Garden)!"

Write-Host "  v7 TouchControls: Native 3x/2x + Direct MobileHooks + PrefixClientBounds + MenuLag(stackSkip, GC 140MB x$gmLowered) + Poll 45f + Watchdog $bumped + WaitFinNop x$waitFinNopped + Menu60FPS"
$tAsm.Write($outTouch)
$tAsm.Dispose()
Verify-Assembly $outTouch

# ==============================================================================
# PART 2: PATCH SDViOS.dll (v7-host.dll) — LOCKED 2.0x + TRACE LOG FILTER
# ==============================================================================
Write-Host "Patching SDViOS.dll -> $outHost ..."
$hAsm = [Mono.Cecil.AssemblyDefinition]::ReadAssembly($srcHost)
$hMod = $hAsm.MainModule

$touchBytes = [System.IO.File]::ReadAllBytes($outTouch)
$resReplaced = $false
for ($r = 0; $r -lt $hMod.Resources.Count; $r++) {
    if ($hMod.Resources[$r].Name -like "*SDViOSTouchControls.dll") {
        $rName = $hMod.Resources[$r].Name
        $hMod.Resources[$r] = New-Object Mono.Cecil.EmbeddedResource($rName, [Mono.Cecil.ManifestResourceAttributes]::Public, $touchBytes)
        Write-Host "  Embedded v6 TouchControls resource: $rName ($($touchBytes.Length) bytes)"
        $resReplaced = $true
    }
}
if (-not $resReplaced) { throw "Could not find embedded SDViOSTouchControls.dll resource!" }

$ghType = $hMod.GetType("SDViOS.Loader.GameHost")
$elType = $hMod.GetType("SDViOS.Diagnostics.EngineLogger")
$linkM  = $ghType.Methods | Where-Object { $_.Name -eq "LinkGameWindowToScene" }
$logM   = $elType.Methods | Where-Object { $_.Name -eq "Log" }
$fActiveView = $ghType.Fields | Where-Object { $_.Name -eq "_activeGameView" }

$hGetFolder   = Find-Ref $hMod "System.String System.Environment::GetFolderPath(System.Environment/SpecialFolder)"
$hPathCombine = Find-Ref $hMod "System.String System.IO.Path::Combine(System.String,System.String)"
$hFileExists  = Find-Ref $hMod "System.Boolean System.IO.File::Exists(System.String)"
$hReadAllText = Find-Ref $hMod "System.String System.IO.File::ReadAllText(System.String)"
$hSetCSF      = Find-Ref $hMod "System.Void UIKit.UIView::set_ContentScaleFactor(System.Runtime.InteropServices.NFloat)"
$hGetLayer    = Find-Ref $hMod "CoreAnimation.CALayer UIKit.UIView::get_Layer()"
$hSetLayerSc  = Find-Ref $hMod "System.Void CoreAnimation.CALayer::set_ContentsScale(System.Runtime.InteropServices.NFloat)"
$hNFloatFromF = Find-Ref $hMod "System.Runtime.InteropServices.NFloat System.Runtime.InteropServices.NFloat::op_Implicit(System.Single)"
$hStrEq       = Find-Ref $hMod "System.Boolean System.String::op_Equality(System.String,System.String)"
$hMathMax     = Find-Ref $hMod "System.Double System.Math::Max(System.Double,System.Double)"
if (!$hReadAllText) {
    $hReadAllText = New-Object Mono.Cecil.MethodReference("ReadAllText", $hMod.TypeSystem.String, $hFileExists.DeclaringType)
    $hReadAllText.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition($hMod.TypeSystem.String)))
}
$hStrContains = Find-Ref $hMod "System.Boolean System.String::Contains(System.String)"
if (!$hStrContains) {
    $hStrContains = New-Object Mono.Cecil.MethodReference("Contains", $hMod.TypeSystem.Boolean, $hMod.TypeSystem.String)
    $hStrContains.HasThis = $true
    $hStrContains.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition($hMod.TypeSystem.String)))
}
$hMathRound = New-Object Mono.Cecil.MethodReference("Round", $hMod.TypeSystem.Double, $hMathMax.DeclaringType)
$hMathRound.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition($hMod.TypeSystem.Double)))

$nfloatType = $hNFloatFromF.ReturnType
$hNFloatToF = New-Object Mono.Cecil.MethodReference("op_Explicit", $hMod.TypeSystem.Single, $nfloatType)
$hNFloatToF.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition($nfloatType)))

$fTrimLogs = New-Object Mono.Cecil.FieldDefinition("_v6TrimLogs", [Mono.Cecil.FieldAttributes]"Public, Static", $hMod.TypeSystem.Int32)
$ghType.Fields.Add($fTrimLogs)

# GameHost.ApplyPerfRenderScale(NFloat nativeScale):
#   1. Reads Documents/sdv_perf.cfg for trimLogs flag (default ON; ",0" -> OFF)
#   2. ALWAYS caps nativeScale to 2.0f max (v6 locked 2.0x!)
$mApplyScale = New-Object Mono.Cecil.MethodDefinition("ApplyPerfRenderScale", [Mono.Cecil.MethodAttributes]"Public, Static", $nfloatType)
$mApplyScale.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition("nativeScale", [Mono.Cecil.ParameterAttributes]::None, $nfloatType)))
$mApplyScale.Body.InitLocals = $true
$vCfgP = New-Object Mono.Cecil.Cil.VariableDefinition($hMod.TypeSystem.String)
$vRaw  = New-Object Mono.Cecil.Cil.VariableDefinition($hMod.TypeSystem.String)
$vNatF = New-Object Mono.Cecil.Cil.VariableDefinition($hMod.TypeSystem.Single)
foreach ($v in @($vCfgP, $vRaw, $vNatF)) { $mApplyScale.Body.Variables.Add($v) }

$il = $mApplyScale.Body.GetILProcessor()
$il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_1))
$il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Stsfld, $fTrimLogs))

$lAfterTry = $il.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0)
$lLeave    = $il.Create([Mono.Cecil.Cil.OpCodes]::Leave, $lAfterTry)
$lCatch    = $il.Create([Mono.Cecil.Cil.OpCodes]::Pop)
$lTryStart = $il.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_5)

$il.Append($lTryStart)
$il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Call, $hGetFolder))
$il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Ldstr, ".garden/sdv_perf.cfg"))
$il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Call, $hPathCombine))
$il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vCfgP))
$il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vCfgP))
$il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Call, $hFileExists))
$il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $lLeave))
$il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vCfgP))
$il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Call, $hReadAllText))
$il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vRaw))
$il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vRaw))
$il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Ldstr, ",0"))
$il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $hStrContains))
$il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $lLeave))
$il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_2))
$il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Stsfld, $fTrimLogs))
$il.Append($lLeave)
$il.Append($lCatch)
$il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Leave, $lAfterTry))

# v7: Always return native device scale untouched (3.0x on 3x devices, 2.0x on 2x devices)
$il.Append($lAfterTry)
$il.Append($il.Create([Mono.Cecil.Cil.OpCodes]::Ret))

$ehS = New-Object Mono.Cecil.Cil.ExceptionHandler([Mono.Cecil.Cil.ExceptionHandlerType]::Catch)
$ehS.CatchType = $hMod.TypeSystem.Object
$ehS.TryStart = $lTryStart
$ehS.TryEnd = $lCatch
$ehS.HandlerStart = $lCatch
$ehS.HandlerEnd = $lAfterTry
$mApplyScale.Body.ExceptionHandlers.Add($ehS)
$ghType.Methods.Add($mApplyScale)

# Helper: GameHost.ReapplyViewScale(UIView view, NFloat scale)
$mReapply = New-Object Mono.Cecil.MethodDefinition("ReapplyViewScale", [Mono.Cecil.MethodAttributes]"Public, Static", $hMod.TypeSystem.Void)
$mReapply.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition("view", [Mono.Cecil.ParameterAttributes]::None, $fActiveView.FieldType)))
$mReapply.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition("scale", [Mono.Cecil.ParameterAttributes]::None, $nfloatType)))
$il2 = $mReapply.Body.GetILProcessor()
$lDoneR  = $il2.Create([Mono.Cecil.Cil.OpCodes]::Ret)
$lLeaveR = $il2.Create([Mono.Cecil.Cil.OpCodes]::Leave, $lDoneR)
$lCatchR = $il2.Create([Mono.Cecil.Cil.OpCodes]::Pop)
$lTryR   = $il2.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0)
$il2.Append($lTryR)
$il2.Append($il2.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $lLeaveR))
$il2.Append($il2.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
$il2.Append($il2.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_1))
$il2.Append($il2.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $hSetCSF))
$il2.Append($il2.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
$il2.Append($il2.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $hGetLayer))
$il2.Append($il2.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $lLeaveR))
$il2.Append($il2.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
$il2.Append($il2.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $hGetLayer))
$il2.Append($il2.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_1))
$il2.Append($il2.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $hSetLayerSc))
$il2.Append($lLeaveR)
$il2.Append($lCatchR)
$il2.Append($il2.Create([Mono.Cecil.Cil.OpCodes]::Leave, $lDoneR))
$il2.Append($lDoneR)

$ehR = New-Object Mono.Cecil.Cil.ExceptionHandler([Mono.Cecil.Cil.ExceptionHandlerType]::Catch)
$ehR.CatchType = $hMod.TypeSystem.Object
$ehR.TryStart = $lTryR
$ehR.TryEnd = $lCatchR
$ehR.HandlerStart = $lCatchR
$ehR.HandlerEnd = $lDoneR
$mReapply.Body.ExceptionHandlers.Add($ehR)
$ghType.Methods.Add($mReapply)

# Hook LinkGameWindowToScene
Expand-ShortBranches $linkM
$lp = $linkM.Body.GetILProcessor()
$lIns = $linkM.Body.Instructions
$site1 = $null; $vScaleVar = $null
for ($i = 2; $i -lt $lIns.Count; $i++) {
    if ($lIns[$i].OpCode.Name -eq "callvirt" -and "$($lIns[$i].Operand)" -eq $hSetCSF.FullName) {
        $site1 = $lIns[$i - 2]; $vScaleVar = $lIns[$i - 1].Operand; break
    }
}
$i1a = $lp.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vScaleVar)
$i1b = $lp.Create([Mono.Cecil.Cil.OpCodes]::Call, $mApplyScale)
$i1c = $lp.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vScaleVar)
$lp.InsertBefore($site1, $i1a); $lp.InsertBefore($site1, $i1b); $lp.InsertBefore($site1, $i1c)
Retarget-Branches $linkM $site1 $i1a

$site2 = $null
for ($i = 2; $i -lt $lIns.Count; $i++) {
    if ($lIns[$i].OpCode.Name -eq "ldstr" -and $lIns[$i].Operand -eq "DestroyFramebuffer") {
        $site2 = $lIns[$i - 2]; break
    }
}
$i2a = $lp.Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $fActiveView)
$i2b = $lp.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vScaleVar)
$i2c = $lp.Create([Mono.Cecil.Cil.OpCodes]::Call, $mReapply)
$lp.InsertBefore($site2, $i2a); $lp.InsertBefore($site2, $i2b); $lp.InsertBefore($site2, $i2c)
Retarget-Branches $linkM $site2 $i2a

# Hook GetDisplayPixelWidth & GetDisplayPixelHeight
foreach ($dpName in @("GetDisplayPixelWidth", "GetDisplayPixelHeight")) {
    $dpM = $ghType.Methods | Where-Object { $_.Name -eq $dpName }
    Expand-ShortBranches $dpM
    $dpIL = $dpM.Body.GetILProcessor()
    for ($i = 0; $i -lt $dpM.Body.Instructions.Count; $i++) {
        if ($dpM.Body.Instructions[$i].OpCode.Name -eq "callvirt" -and "$($dpM.Body.Instructions[$i].Operand)" -like "*UIScreen::get_Scale*") {
            $dpIL.InsertBefore($dpM.Body.Instructions[$i + 1], $dpIL.Create([Mono.Cecil.Cil.OpCodes]::Call, $mApplyScale))
            break
        }
    }
    for ($i = 0; $i -lt $dpM.Body.Instructions.Count; $i++) {
        if ($dpM.Body.Instructions[$i].OpCode.Name -eq "conv.i4") {
            $dpIL.InsertBefore($dpM.Body.Instructions[$i], $dpIL.Create([Mono.Cecil.Cil.OpCodes]::Call, $hMathRound))
            break
        }
    }
}

# 2.5 iOS 26/27 Launch Scene-Create Deferral: Use a clean 0.35s NSTimer in AppDelegate.FinishedLaunching
# instead of immediate BeginInvokeOnMainThread, so UIScene (willConnectToSession -> sceneDidBecomeActive)
# completes its FrontBoard handshake in <50ms before GameHost.Launch() starts!
$adType = $hMod.Types | Where-Object { $_.Name -eq "AppDelegate" }
$mFl    = $adType.Methods | Where-Object { $_.Name -eq "FinishedLaunching" }
$mB46   = $adType.Methods | Where-Object { $_.Name -eq "<FinishedLaunching>b__4_6" }
$mCreateTimer = Find-Ref $hMod 'Foundation.NSTimer Foundation.NSTimer::CreateScheduledTimer(System.Double,System.Boolean,System.Action`1<Foundation.NSTimer>)'
$mActTimerCtor = $null
foreach ($t in $hMod.Types) {
    foreach ($m in $t.Methods) {
        if (-not $m.HasBody) { continue }
        foreach ($ins in $m.Body.Instructions) {
            if ($ins.OpCode.Name -eq "newobj" -and "$($ins.Operand)" -like "*Action*<Foundation.NSTimer>::.ctor*") {
                $mActTimerCtor = $ins.Operand; break
            }
        }
        if ($mActTimerCtor) { break }
    }
    if ($mActTimerCtor) { break }
}

if ($adType -and $mFl -and $mB46 -and $mCreateTimer -and $mActTimerCtor) {
    $tNSTimer = $mCreateTimer.ReturnType
    $mTimerCb = New-Object Mono.Cecil.MethodDefinition("DeferredLaunchTimerCallback", [Mono.Cecil.MethodAttributes]"Private", $hMod.TypeSystem.Void)
    $mTimerCb.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition("timer", [Mono.Cecil.ParameterAttributes]::None, $tNSTimer)))
    $ilTC = $mTimerCb.Body.GetILProcessor()
    $ilTC.Append($ilTC.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
    $ilTC.Append($ilTC.Create([Mono.Cecil.Cil.OpCodes]::Call, $mB46))
    $ilTC.Append($ilTC.Create([Mono.Cecil.Cil.OpCodes]::Ret))
    $adType.Methods.Add($mTimerCb)

    Expand-ShortBranches $mFl
    $flIL = $mFl.Body.GetILProcessor()
    $flIns = $mFl.Body.Instructions
    for ($i = 0; $i -lt ($flIns.Count - 4); $i++) {
        if ($flIns[$i].OpCode.Name -eq "call" -and "$($flIns[$i].Operand)" -like "*UIApplication::get_SharedApplication*" -and
            $flIns[$i+4].OpCode.Name -eq "callvirt" -and "$($flIns[$i+4].Operand)" -like "*BeginInvokeOnMainThread*") {
            $flIns[$i].OpCode   = [Mono.Cecil.Cil.OpCodes]::Ldc_R8
            $flIns[$i].Operand  = [double]0.35
            $flIL.InsertAfter($flIns[$i], $flIL.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0))
            # $flIns[$i+2] is now ldarg.0
            $flIns[$i+3].Operand = $mTimerCb
            $flIns[$i+4].Operand = $mActTimerCtor
            $flIns[$i+5].OpCode  = [Mono.Cecil.Cil.OpCodes]::Call
            $flIns[$i+5].Operand = $mCreateTimer
            $flIL.InsertAfter($flIns[$i+5], $flIL.Create([Mono.Cecil.Cil.OpCodes]::Pop))
            Write-Host "  iOS 26/27 Scene Launch Fix (SDViOS): Deferred GameHost.Launch via 0.35s NSTimer after sceneDidBecomeActive!"
            break
        }
    }
}

# EngineLogger.Log TRACE filter (lazy-initializes _v6TrimLogs from .garden/sdv_perf.cfg on 1st log line!) + 10s flush timer
$mDropTrace = New-Object Mono.Cecil.MethodDefinition("ShouldDropTrace", [Mono.Cecil.MethodAttributes]"Private, Static", $hMod.TypeSystem.Boolean)
$mDropTrace.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition("msg", [Mono.Cecil.ParameterAttributes]::None, $hMod.TypeSystem.String)))
$mDropTrace.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition("lvl", [Mono.Cecil.ParameterAttributes]::None, $hMod.TypeSystem.String)))
$il3 = $mDropTrace.Body.GetILProcessor()
$lInitTrimDone = $il3.Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $fTrimLogs)
$lRetFalse = $il3.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0)
$il3.Append($il3.Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $fTrimLogs))
$il3.Append($il3.Create([Mono.Cecil.Cil.OpCodes]::Brtrue, $lInitTrimDone))
$il3.Append($il3.Create([Mono.Cecil.Cil.OpCodes]::Ldc_R4, [float]2.0))
$il3.Append($il3.Create([Mono.Cecil.Cil.OpCodes]::Call, $hNFloatFromF))
$il3.Append($il3.Create([Mono.Cecil.Cil.OpCodes]::Call, $mApplyScale))
$il3.Append($il3.Create([Mono.Cecil.Cil.OpCodes]::Pop))
$il3.Append($lInitTrimDone)
$il3.Append($il3.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_2))
$il3.Append($il3.Create([Mono.Cecil.Cil.OpCodes]::Beq, $lRetFalse))
$il3.Append($il3.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
$il3.Append($il3.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $lRetFalse))
$il3.Append($il3.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_1))
$il3.Append($il3.Create([Mono.Cecil.Cil.OpCodes]::Ldstr, "INFO"))
$il3.Append($il3.Create([Mono.Cecil.Cil.OpCodes]::Call, $hStrEq))
$il3.Append($il3.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $lRetFalse))
$il3.Append($il3.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
$il3.Append($il3.Create([Mono.Cecil.Cil.OpCodes]::Ldstr, " TRACE "))
$il3.Append($il3.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $hStrContains))
$il3.Append($il3.Create([Mono.Cecil.Cil.OpCodes]::Ret))
$il3.Append($lRetFalse)
$il3.Append($il3.Create([Mono.Cecil.Cil.OpCodes]::Ret))
$elType.Methods.Add($mDropTrace)

Expand-ShortBranches $logM
$ep = $logM.Body.GetILProcessor()
$logFirst = $logM.Body.Instructions[0]
$g0 = $ep.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0)
$g1 = $ep.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_1)
$g2 = $ep.Create([Mono.Cecil.Cil.OpCodes]::Call, $mDropTrace)
$g3 = $ep.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $logFirst)
$g4 = $ep.Create([Mono.Cecil.Cil.OpCodes]::Ret)
$ep.InsertBefore($logFirst, $g0); $ep.InsertBefore($logFirst, $g1); $ep.InsertBefore($logFirst, $g2); $ep.InsertBefore($logFirst, $g3); $ep.InsertBefore($logFirst, $g4)
Retarget-Branches $logM $logFirst $g0
$g3.Operand = $logFirst

# 2.4b Real-Time Native Boot Progress Bridge in EngineLogger.Log (runs BEFORE ShouldDropTrace so ALL
#      EngineLogger + [SMAPI] INFO & TRACE lines pump the native pixel loading UI smoothly on Thread 0,
#      then short-circuits in 2 instructions once gSdvBootDone == 1 so 0% UTF-8 marshaling occurs in gameplay!)
$mCfgAudio = $adType.Methods | Where-Object { $_.Name -eq "ConfigureAudioSession" } | Select-Object -First 1
if ($mCfgAudio -and $mCfgAudio.HasBody) {
    $mCfgAudio.Body.ExceptionHandlers.Clear()
    $mCfgAudio.Body.Variables.Clear()
    $mCfgAudio.Body.Instructions.Clear()
    $caIL = $mCfgAudio.Body.GetILProcessor()
    $caIL.Append($caIL.Create([Mono.Cecil.Cil.OpCodes]::Ret))
    Write-Host "  Mute Switch Preservation (Host): Neutralized AppDelegate.ConfigureAudioSession (native Embedded.m owns AVAudioSession)!"
}

$modGardenRef = New-Object Mono.Cecil.ModuleReference("@rpath/SDVModGarden.framework/SDVModGarden")
$hMod.ModuleReferences.Add($modGardenRef)
$mNativeBootLog = New-Object Mono.Cecil.MethodDefinition(
    "sdv_boot_on_log",
    [Mono.Cecil.MethodAttributes]"Private, Static, HideBySig, PInvokeImpl",
    $hMod.TypeSystem.Void
)
$mNativeBootLog.ImplAttributes = [Mono.Cecil.MethodImplAttributes]"IL, PreserveSig"
$mNativeBootLog.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition("line", [Mono.Cecil.ParameterAttributes]::None, $hMod.TypeSystem.String)))
$mNativeBootLog.PInvokeInfo = New-Object Mono.Cecil.PInvokeInfo([Mono.Cecil.PInvokeAttributes]"CallConvWinapi, CharSetAnsi", "sdv_boot_on_log", $modGardenRef)
$elType.Methods.Add($mNativeBootLog)

$mNativeBootDone = New-Object Mono.Cecil.MethodDefinition(
    "sdv_is_boot_done",
    [Mono.Cecil.MethodAttributes]"Private, Static, HideBySig, PInvokeImpl",
    $hMod.TypeSystem.Int32
)
$mNativeBootDone.ImplAttributes = [Mono.Cecil.MethodImplAttributes]"IL, PreserveSig"
$mNativeBootDone.PInvokeInfo = New-Object Mono.Cecil.PInvokeInfo([Mono.Cecil.PInvokeAttributes]"CallConvWinapi", "sdv_is_boot_done", $modGardenRef)
$elType.Methods.Add($mNativeBootDone)

$fBootNotifyFailed = New-Object Mono.Cecil.FieldDefinition("_bootNotifyFailed", [Mono.Cecil.FieldAttributes]"Private, Static", $hMod.TypeSystem.Boolean)
$elType.Fields.Add($fBootNotifyFailed)
$fBootDoneCached = New-Object Mono.Cecil.FieldDefinition("_bootDoneCached", [Mono.Cecil.FieldAttributes]"Private, Static", $hMod.TypeSystem.Boolean)
$elType.Fields.Add($fBootDoneCached)

$mNotifyBoot = New-Object Mono.Cecil.MethodDefinition("NotifyBootLine", [Mono.Cecil.MethodAttributes]"Private, Static", $hMod.TypeSystem.Void)
$mNotifyBoot.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition("msg", [Mono.Cecil.ParameterAttributes]::None, $hMod.TypeSystem.String)))
$nbIL = $mNotifyBoot.Body.GetILProcessor()
$nbRet = $nbIL.Create([Mono.Cecil.Cil.OpCodes]::Ret)
$nbTry = $nbIL.Create([Mono.Cecil.Cil.OpCodes]::Call, $mNativeBootDone)
$nbSend = $nbIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0)
$nbLeave = $nbIL.Create([Mono.Cecil.Cil.OpCodes]::Leave, $nbRet)
$nbCatch = $nbIL.Create([Mono.Cecil.Cil.OpCodes]::Pop)
$nbIL.Append($nbIL.Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $fBootDoneCached))
$nbIL.Append($nbIL.Create([Mono.Cecil.Cil.OpCodes]::Brtrue, $nbRet))
$nbIL.Append($nbIL.Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $fBootNotifyFailed))
$nbIL.Append($nbIL.Create([Mono.Cecil.Cil.OpCodes]::Brtrue, $nbRet))
$nbIL.Append($nbIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
$nbIL.Append($nbIL.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $nbRet))
$nbIL.Append($nbTry)
$nbIL.Append($nbIL.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $nbSend))
$nbIL.Append($nbIL.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_1))
$nbIL.Append($nbIL.Create([Mono.Cecil.Cil.OpCodes]::Stsfld, $fBootDoneCached))
$nbIL.Append($nbIL.Create([Mono.Cecil.Cil.OpCodes]::Leave, $nbRet))
$nbIL.Append($nbSend)
$nbIL.Append($nbIL.Create([Mono.Cecil.Cil.OpCodes]::Call, $mNativeBootLog))
$nbIL.Append($nbLeave)
$nbIL.Append($nbCatch)
$nbIL.Append($nbIL.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_1))
$nbIL.Append($nbIL.Create([Mono.Cecil.Cil.OpCodes]::Stsfld, $fBootNotifyFailed))
$nbIL.Append($nbIL.Create([Mono.Cecil.Cil.OpCodes]::Leave, $nbRet))
$nbIL.Append($nbRet)
$ehNb = New-Object Mono.Cecil.Cil.ExceptionHandler([Mono.Cecil.Cil.ExceptionHandlerType]::Catch)
$ehNb.CatchType = $hMod.TypeSystem.Object
$ehNb.TryStart = $nbTry
$ehNb.TryEnd = $nbCatch
$ehNb.HandlerStart = $nbCatch
$ehNb.HandlerEnd = $nbRet
$mNotifyBoot.Body.ExceptionHandlers.Add($ehNb)
$elType.Methods.Add($mNotifyBoot)

$b0 = $ep.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0)
$b1 = $ep.Create([Mono.Cecil.Cil.OpCodes]::Call, $mNotifyBoot)
$ep.InsertBefore($g0, $b0)
$ep.InsertBefore($g0, $b1)
Retarget-Branches $logM $g0 $b0
Write-Host "  Real-Time Boot Progress Hook (Host): EngineLogger.Log -> sdv_boot_on_log (pumps pixel UI live on Thread 0)!"

foreach ($ins in $logM.Body.Instructions) {
    if ($ins.OpCode.Name -eq "ldc.i4" -and [int]$ins.Operand -eq 1500) {
        $ins.Operand = [int]10000
    }
}

# 2.5 Visible StardewValley/ + Hidden .garden/ Layout in SDViOS.dll (restores direct user Content/*.xnb access in iOS Files app!)
$tGameHostType = $hMod.GetType("SDViOS.Loader.GameHost")
$mGetGameRoot = $tGameHostType.Methods | Where-Object { $_.Name -eq "get_GameRootDir" } | Select-Object -First 1
if (-not $mGetGameRoot) { throw "Missing GameHost.get_GameRootDir!" }
$hostVisibleGame = 0
$hostHiddenGarden = 0
$hostSmapiInternalSwap = 0
foreach ($ht in $hMod.Types) {
    foreach ($hm in $ht.Methods) {
        if (-not $hm.HasBody) { continue }
        $insList = $hm.Body.Instructions
        for ($i = 0; $i -lt $insList.Count; $i++) {
            $ins = $insList[$i]
            if ($ins.OpCode.Name -eq "ldstr") {
                if (($hm.Name -eq "InitializeFileSystem" -or $hm.Name -eq "TryFindGameBinary") -and $ins.Operand -eq "StardewValley") {
                    # Keep "StardewValley" visible in Documents/ so users can view & edit Content/*.xnb in Tệp!
                    $hostVisibleGame++
                } elseif ($hm.Name -eq "RelocateDisabledMods" -and $ins.Operand -eq "DisabledMods") {
                    $ins.Operand = ".garden/DisabledMods"; $hostHiddenGarden++
                } elseif ($hm.Name -eq "GetConfigPath" -and $ins.Operand -eq "touch_overlay_config.json") {
                    $ins.Operand = ".garden/touch_overlay_config.json"; $hostHiddenGarden++
                } elseif ($hm.Name -eq "SyncMenuBarConfig" -and $ins.Operand -eq "sdv_menubar.cfg") {
                    $ins.Operand = ".garden/sdv_menubar.cfg"; $hostHiddenGarden++
                } elseif ($ins.Operand -eq "smapi-internal" -and $i -gt 0) {
                    $prev = $insList[$i - 1]
                    if ($prev.OpCode.Name -eq "call" -and $prev.Operand -and $prev.Operand.ToString() -match "GameHost::get_DocumentsDir") {
                        $prev.Operand = $mGetGameRoot
                        $hostSmapiInternalSwap++
                    }
                }
            }
        }
    }
}
if ($hostVisibleGame -ne 3 -or $hostHiddenGarden -lt 3 -or $hostSmapiInternalSwap -ne 4) {
    throw "Unexpected layout patch counts in SDViOS.dll: visibleGame=$hostVisibleGame (want 3), garden=$hostHiddenGarden (want >=3), smapiInternal=$hostSmapiInternalSwap (want 4)!"
}
Write-Host "  Visible StardewValley Layout (Host): StardewValley x$hostVisibleGame, .garden x$hostHiddenGarden, smapi-internal->GameRootDir x$hostSmapiInternalSwap!"

# 2.11 Prevent RuntimeHarmonyPatcher.EnsureHarmonyPatched from trying to overwrite read-only .app bundle 0Harmony.dll
# (eliminates spurious UnauthorizedAccessException stack trace on every launch!)
$tRhp = $hMod.GetType("SDViOS.Compatibility.RuntimeHarmonyPatcher")
$mEhp = if ($tRhp) { $tRhp.Methods | Where-Object { $_.Name -eq "EnsureHarmonyPatched" } | Select-Object -First 1 } else { $null }
if ($mEhp -and $mEhp.HasBody) {
    Expand-ShortBranches $mEhp
    $mStrContains = New-Object Mono.Cecil.MethodReference("Contains", $hMod.TypeSystem.Boolean, $hMod.TypeSystem.String)
    $mStrContains.HasThis = $true
    $mStrContains.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition($hMod.TypeSystem.String)))
    $rhpIL = $mEhp.Body.GetILProcessor()
    $firstIns = $mEhp.Body.Instructions[0]
    $gStart = $rhpIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0)
    $rhpIL.InsertBefore($firstIns, $gStart)
    $rhpIL.InsertBefore($firstIns, $rhpIL.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $firstIns))
    $rhpIL.InsertBefore($firstIns, $rhpIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
    $rhpIL.InsertBefore($firstIns, $rhpIL.Create([Mono.Cecil.Cil.OpCodes]::Ldstr, ".app/"))
    $rhpIL.InsertBefore($firstIns, $rhpIL.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mStrContains))
    $rhpIL.InsertBefore($firstIns, $rhpIL.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $firstIns))
    $rhpIL.InsertBefore($firstIns, $rhpIL.Create([Mono.Cecil.Cil.OpCodes]::Ret))
    Write-Host "  Read-Only Bundle Guard (Host): RuntimeHarmonyPatcher skips read-only .app/ bundle paths (zero UnauthorizedAccessException)!"
}

# 2.12 Cold-Boot Stamp Cache for RuntimeSmapiPatcher (EnsureGameRunnerPatched, EnsureSmapiPatched, EnsureModsPatched):
#      Skips re-parsing 6.5MB Stardew Valley.dll + 934KB StardewModdingAPI.dll + SpaceCore.dll via Mono.Cecil on 0% JIT
#      whenever file size + UTC mtime match Documents/.garden/patch_stamps/*.stamp (-2..5s faster boot, -50MB peak RAM)!
$tRsp = $hMod.GetType("SDViOS.Compatibility.RuntimeSmapiPatcher")
$hCreateDir  = Find-Ref $hMod "System.IO.DirectoryInfo System.IO.Directory::CreateDirectory(System.String)"
$hPathComb3  = Find-Ref $hMod "System.String System.IO.Path::Combine(System.String,System.String,System.String)"
$hWriteText  = Find-Ref $hMod "System.Void System.IO.File::WriteAllText(System.String,System.String)"
$hGetMtime   = Find-Ref $hMod "System.DateTime System.IO.File::GetLastWriteTimeUtc(System.String)"
$hDtToStr    = Find-Ref $hMod "System.String System.DateTime::ToString(System.String)"
$hFiCtor     = Find-Ref $hMod "System.Void System.IO.FileInfo::.ctor(System.String)"
$hFiGetLen   = Find-Ref $hMod "System.Int64 System.IO.FileInfo::get_Length()"
$hIsNullOrE  = Find-Ref $hMod "System.Boolean System.String::IsNullOrEmpty(System.String)"
$hStrConcat2 = Find-Ref $hMod "System.String System.String::Concat(System.String,System.String)"
$hStrConcat4 = Find-Ref $hMod "System.String System.String::Concat(System.String,System.String,System.String,System.String)"
if ($tRsp -and $hCreateDir -and $hPathComb3 -and $hWriteText -and $hGetMtime -and $hDtToStr -and $hFiCtor -and $hFiGetLen -and $hIsNullOrE -and $hStrConcat2 -and $hStrConcat4) {
    $mI64ToStr = New-Object Mono.Cecil.MethodReference("ToString", $hMod.TypeSystem.String, $hMod.TypeSystem.Int64)
    $mI64ToStr.HasThis = $true
    $mStartsWith = New-Object Mono.Cecil.MethodReference("StartsWith", $hMod.TypeSystem.Boolean, $hMod.TypeSystem.String)
    $mStartsWith.HasThis = $true
    $mStartsWith.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition($hMod.TypeSystem.String)))
    $mStrLen = New-Object Mono.Cecil.MethodReference("get_Length", $hMod.TypeSystem.Int32, $hMod.TypeSystem.String)
    $mStrLen.HasThis = $true
    $mSubstr1 = New-Object Mono.Cecil.MethodReference("Substring", $hMod.TypeSystem.String, $hMod.TypeSystem.String)
    $mSubstr1.HasThis = $true
    $mSubstr1.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition($hMod.TypeSystem.Int32)))

    # Helper 1: BuildStampPrefix(string inputPath) -> "v110|<inputPath>|<len>|<mtimeO>\n"
    $mBuildSig = New-Object Mono.Cecil.MethodDefinition("BuildStampPrefix", [Mono.Cecil.MethodAttributes]"Private, Static", $hMod.TypeSystem.String)
    $mBuildSig.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition("inputPath", [Mono.Cecil.ParameterAttributes]::None, $hMod.TypeSystem.String)))
    $mBuildSig.Body.InitLocals = $true
    $vLen = New-Object Mono.Cecil.Cil.VariableDefinition($hMod.TypeSystem.Int64)
    $vDt  = New-Object Mono.Cecil.Cil.VariableDefinition($hGetMtime.ReturnType)
    $mBuildSig.Body.Variables.Add($vLen)
    $mBuildSig.Body.Variables.Add($vDt)
    $bsIL = $mBuildSig.Body.GetILProcessor()
    $bsIL.Append($bsIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
    $bsIL.Append($bsIL.Create([Mono.Cecil.Cil.OpCodes]::Newobj, $hFiCtor))
    $bsIL.Append($bsIL.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $hFiGetLen))
    $bsIL.Append($bsIL.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vLen))
    $bsIL.Append($bsIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
    $bsIL.Append($bsIL.Create([Mono.Cecil.Cil.OpCodes]::Call, $hGetMtime))
    $bsIL.Append($bsIL.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vDt))
    $bsIL.Append($bsIL.Create([Mono.Cecil.Cil.OpCodes]::Ldstr, "v113|"))
    $bsIL.Append($bsIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
    $bsIL.Append($bsIL.Create([Mono.Cecil.Cil.OpCodes]::Ldstr, "|"))
    $bsIL.Append($bsIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloca, $vLen))
    $bsIL.Append($bsIL.Create([Mono.Cecil.Cil.OpCodes]::Call, $mI64ToStr))
    $bsIL.Append($bsIL.Create([Mono.Cecil.Cil.OpCodes]::Call, $hStrConcat4))
    $bsIL.Append($bsIL.Create([Mono.Cecil.Cil.OpCodes]::Ldstr, "|"))
    $bsIL.Append($bsIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloca, $vDt))
    $bsIL.Append($bsIL.Create([Mono.Cecil.Cil.OpCodes]::Ldstr, "O"))
    $bsIL.Append($bsIL.Create([Mono.Cecil.Cil.OpCodes]::Call, $hDtToStr))
    $bsIL.Append($bsIL.Create([Mono.Cecil.Cil.OpCodes]::Ldstr, "`n"))
    $bsIL.Append($bsIL.Create([Mono.Cecil.Cil.OpCodes]::Call, $hStrConcat4))
    $bsIL.Append($bsIL.Create([Mono.Cecil.Cil.OpCodes]::Ret))
    $tRsp.Methods.Add($mBuildSig)

    # Helper 2: TryGetValidStamp(string stampFile, string inputPath) -> cachedOutPath or null
    $mTryStamp = New-Object Mono.Cecil.MethodDefinition("TryGetValidStamp", [Mono.Cecil.MethodAttributes]"Private, Static", $hMod.TypeSystem.String)
    $mTryStamp.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition("stampFile", [Mono.Cecil.ParameterAttributes]::None, $hMod.TypeSystem.String)))
    $mTryStamp.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition("inputPath", [Mono.Cecil.ParameterAttributes]::None, $hMod.TypeSystem.String)))
    $mTryStamp.Body.InitLocals = $true
    $vSp   = New-Object Mono.Cecil.Cil.VariableDefinition($hMod.TypeSystem.String)
    $vRawS = New-Object Mono.Cecil.Cil.VariableDefinition($hMod.TypeSystem.String)
    $vPfx  = New-Object Mono.Cecil.Cil.VariableDefinition($hMod.TypeSystem.String)
    $vOutP = New-Object Mono.Cecil.Cil.VariableDefinition($hMod.TypeSystem.String)
    $vResS = New-Object Mono.Cecil.Cil.VariableDefinition($hMod.TypeSystem.String)
    foreach ($vv in @($vSp, $vRawS, $vPfx, $vOutP, $vResS)) { $mTryStamp.Body.Variables.Add($vv) }
    $tsIL = $mTryStamp.Body.GetILProcessor()
    $lTsTry   = $tsIL.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_5)
    $lTsDone  = $tsIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vResS)
    $lTsLeave = $tsIL.Create([Mono.Cecil.Cil.OpCodes]::Leave, $lTsDone)
    $lTsCatch = $tsIL.Create([Mono.Cecil.Cil.OpCodes]::Pop)
    $tsIL.Append($lTsTry)
    $tsIL.Append($tsIL.Create([Mono.Cecil.Cil.OpCodes]::Call, $hGetFolder))
    $tsIL.Append($tsIL.Create([Mono.Cecil.Cil.OpCodes]::Ldstr, ".garden/patch_stamps"))
    $tsIL.Append($tsIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
    $tsIL.Append($tsIL.Create([Mono.Cecil.Cil.OpCodes]::Call, $hPathComb3))
    $tsIL.Append($tsIL.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vSp))
    $tsIL.Append($tsIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vSp))
    $tsIL.Append($tsIL.Create([Mono.Cecil.Cil.OpCodes]::Call, $hFileExists))
    $tsIL.Append($tsIL.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $lTsLeave))
    $tsIL.Append($tsIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vSp))
    $tsIL.Append($tsIL.Create([Mono.Cecil.Cil.OpCodes]::Call, $hReadAllText))
    $tsIL.Append($tsIL.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vRawS))
    $tsIL.Append($tsIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vRawS))
    $tsIL.Append($tsIL.Create([Mono.Cecil.Cil.OpCodes]::Call, $hIsNullOrE))
    $tsIL.Append($tsIL.Create([Mono.Cecil.Cil.OpCodes]::Brtrue, $lTsLeave))
    $tsIL.Append($tsIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_1))
    $tsIL.Append($tsIL.Create([Mono.Cecil.Cil.OpCodes]::Call, $mBuildSig))
    $tsIL.Append($tsIL.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vPfx))
    $tsIL.Append($tsIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vRawS))
    $tsIL.Append($tsIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vPfx))
    $tsIL.Append($tsIL.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mStartsWith))
    $tsIL.Append($tsIL.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $lTsLeave))
    $tsIL.Append($tsIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vRawS))
    $tsIL.Append($tsIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vPfx))
    $tsIL.Append($tsIL.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mStrLen))
    $tsIL.Append($tsIL.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mSubstr1))
    $tsIL.Append($tsIL.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vOutP))
    $tsIL.Append($tsIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vOutP))
    $tsIL.Append($tsIL.Create([Mono.Cecil.Cil.OpCodes]::Call, $hIsNullOrE))
    $tsIL.Append($tsIL.Create([Mono.Cecil.Cil.OpCodes]::Brtrue, $lTsLeave))
    $tsIL.Append($tsIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vOutP))
    $tsIL.Append($tsIL.Create([Mono.Cecil.Cil.OpCodes]::Call, $hFileExists))
    $tsIL.Append($tsIL.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $lTsLeave))
    $tsIL.Append($tsIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vOutP))
    $tsIL.Append($tsIL.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vResS))
    $tsIL.Append($lTsLeave)
    $tsIL.Append($lTsCatch)
    $tsIL.Append($tsIL.Create([Mono.Cecil.Cil.OpCodes]::Leave, $lTsDone))
    $tsIL.Append($lTsDone)
    $tsIL.Append($tsIL.Create([Mono.Cecil.Cil.OpCodes]::Ret))
    $ehTs = New-Object Mono.Cecil.Cil.ExceptionHandler([Mono.Cecil.Cil.ExceptionHandlerType]::Catch)
    $ehTs.CatchType = $hMod.TypeSystem.Object
    $ehTs.TryStart = $lTsTry; $ehTs.TryEnd = $lTsCatch; $ehTs.HandlerStart = $lTsCatch; $ehTs.HandlerEnd = $lTsDone
    $mTryStamp.Body.ExceptionHandlers.Add($ehTs)
    $tRsp.Methods.Add($mTryStamp)

    # Helper 3: SaveStampAndReturn(string outPath, string stampFile, string inputPath) -> outPath
    $mSaveStamp = New-Object Mono.Cecil.MethodDefinition("SaveStampAndReturn", [Mono.Cecil.MethodAttributes]"Private, Static", $hMod.TypeSystem.String)
    $mSaveStamp.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition("outPath", [Mono.Cecil.ParameterAttributes]::None, $hMod.TypeSystem.String)))
    $mSaveStamp.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition("stampFile", [Mono.Cecil.ParameterAttributes]::None, $hMod.TypeSystem.String)))
    $mSaveStamp.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition("inputPath", [Mono.Cecil.ParameterAttributes]::None, $hMod.TypeSystem.String)))
    $mSaveStamp.Body.InitLocals = $true
    $vDirS = New-Object Mono.Cecil.Cil.VariableDefinition($hMod.TypeSystem.String)
    $mSaveStamp.Body.Variables.Add($vDirS)
    $ssIL = $mSaveStamp.Body.GetILProcessor()
    $lSsTry   = $ssIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0)
    $lSsDone  = $ssIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0)
    $lSsLeave = $ssIL.Create([Mono.Cecil.Cil.OpCodes]::Leave, $lSsDone)
    $lSsCatch = $ssIL.Create([Mono.Cecil.Cil.OpCodes]::Pop)
    $ssIL.Append($lSsTry)
    $ssIL.Append($ssIL.Create([Mono.Cecil.Cil.OpCodes]::Call, $hIsNullOrE))
    $ssIL.Append($ssIL.Create([Mono.Cecil.Cil.OpCodes]::Brtrue, $lSsLeave))
    $ssIL.Append($ssIL.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_5))
    $ssIL.Append($ssIL.Create([Mono.Cecil.Cil.OpCodes]::Call, $hGetFolder))
    $ssIL.Append($ssIL.Create([Mono.Cecil.Cil.OpCodes]::Ldstr, ".garden/patch_stamps"))
    $ssIL.Append($ssIL.Create([Mono.Cecil.Cil.OpCodes]::Call, $hPathCombine))
    $ssIL.Append($ssIL.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vDirS))
    $ssIL.Append($ssIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vDirS))
    $ssIL.Append($ssIL.Create([Mono.Cecil.Cil.OpCodes]::Call, $hCreateDir))
    $ssIL.Append($ssIL.Create([Mono.Cecil.Cil.OpCodes]::Pop))
    $ssIL.Append($ssIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vDirS))
    $ssIL.Append($ssIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_1))
    $ssIL.Append($ssIL.Create([Mono.Cecil.Cil.OpCodes]::Call, $hPathCombine))
    $ssIL.Append($ssIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_2))
    $ssIL.Append($ssIL.Create([Mono.Cecil.Cil.OpCodes]::Call, $mBuildSig))
    $ssIL.Append($ssIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
    $ssIL.Append($ssIL.Create([Mono.Cecil.Cil.OpCodes]::Call, $hStrConcat2))
    $ssIL.Append($ssIL.Create([Mono.Cecil.Cil.OpCodes]::Call, $hWriteText))
    $ssIL.Append($lSsLeave)
    $ssIL.Append($lSsCatch)
    $ssIL.Append($ssIL.Create([Mono.Cecil.Cil.OpCodes]::Leave, $lSsDone))
    $ssIL.Append($lSsDone)
    $ssIL.Append($ssIL.Create([Mono.Cecil.Cil.OpCodes]::Ret))
    $ehSs = New-Object Mono.Cecil.Cil.ExceptionHandler([Mono.Cecil.Cil.ExceptionHandlerType]::Catch)
    $ehSs.CatchType = $hMod.TypeSystem.Object
    $ehSs.TryStart = $lSsTry; $ehSs.TryEnd = $lSsCatch; $ehSs.HandlerStart = $lSsCatch; $ehSs.HandlerEnd = $lSsDone
    $mSaveStamp.Body.ExceptionHandlers.Add($ehSs)
    $tRsp.Methods.Add($mSaveStamp)

    # Wire EnsureGameRunnerPatched & EnsureSmapiPatched
    foreach ($pair in @(
        @("EnsureGameRunnerPatched", "gamerunner_v1.stamp"),
        @("EnsureSmapiPatched",      "smapi_v1.stamp")
    )) {
        $pm = $tRsp.Methods | Where-Object { $_.Name -eq $pair[0] } | Select-Object -First 1
        $stampName = $pair[1]
        Expand-ShortBranches $pm
        $pil = $pm.Body.GetILProcessor()
        $vHit = New-Object Mono.Cecil.Cil.VariableDefinition($hMod.TypeSystem.String)
        $pm.Body.Variables.Add($vHit)
        $pm.Body.InitLocals = $true

        # Insert fast-hit check right before outer try block (instruction right after initial `ldarg.0; ret` guard)
        $entryAnchor = $null
        for ($i = 0; $i -lt 12; $i++) {
            if ($pm.Body.Instructions[$i].OpCode.Name -eq "ret") {
                $entryAnchor = $pm.Body.Instructions[$i + 1]
                break
            }
        }
        if (-not $entryAnchor) { throw "Missing entry anchor in $($pair[0])!" }
        $chkStart = $pil.Create([Mono.Cecil.Cil.OpCodes]::Ldstr, $stampName)
        foreach ($ins in @(
            $chkStart,
            $pil.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0),
            $pil.Create([Mono.Cecil.Cil.OpCodes]::Call, $mTryStamp),
            $pil.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vHit),
            $pil.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vHit),
            $pil.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $entryAnchor),
            $pil.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vHit),
            $pil.Create([Mono.Cecil.Cil.OpCodes]::Ret)
        )) { $pil.InsertBefore($entryAnchor, $ins) }
        foreach ($bIns in $pm.Body.Instructions) {
            if ($bIns -ne $pm.Body.Instructions[$pm.Body.Instructions.IndexOf($entryAnchor) - 3] -and $bIns.Operand -eq $entryAnchor) {
                $bIns.Operand = $chkStart
            }
        }

        # Save stamp on both non-exception return paths ("is already patched." and SavePatchedAssembly)
        $savedSites = 0
        for ($i = 2; $i -lt ($pm.Body.Instructions.Count - 2); $i++) {
            $cur = $pm.Body.Instructions[$i]
            $prev = $pm.Body.Instructions[$i - 1]
            $prev2 = $pm.Body.Instructions[$i - 2]
            $isAlreadySite = ($cur.OpCode.Name -like "stloc*" -and $prev.OpCode.Name -eq "ldarg.0" -and "$($prev2.Operand)" -like "*EngineLogger::Log(*")
            $isSavedSite   = ($cur.OpCode.Name -like "stloc*" -and $prev.OpCode.Name -eq "call" -and "$($prev.Operand)" -like "*SavePatchedAssembly*")
            if ($isAlreadySite -or $isSavedSite) {
                $pil.InsertBefore($cur, $pil.Create([Mono.Cecil.Cil.OpCodes]::Ldstr, $stampName))
                $pil.InsertBefore($cur, $pil.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
                $pil.InsertBefore($cur, $pil.Create([Mono.Cecil.Cil.OpCodes]::Call, $mSaveStamp))
                $savedSites++
                $i += 3
            }
        }
        if ($savedSites -ne 2) { throw "Expected 2 SaveStamp sites in $($pair[0]), got $savedSites!" }
    }

    # Wire EnsureModsPatched (SpaceCore.dll loop)
    $mEmp = $tRsp.Methods | Where-Object { $_.Name -eq "EnsureModsPatched" } | Select-Object -First 1
    if ($mEmp -and $mEmp.HasBody) {
        Expand-ShortBranches $mEmp
        $empIL = $mEmp.Body.GetILProcessor()
        $loopInc = $null
        for ($i = 0; $i -lt ($mEmp.Body.Instructions.Count - 3); $i++) {
            if ($mEmp.Body.Instructions[$i].OpCode.Name -eq "ldloc.1" -and
                $mEmp.Body.Instructions[$i+1].OpCode.Name -eq "ldc.i4.1" -and
                $mEmp.Body.Instructions[$i+2].OpCode.Name -eq "add") {
                $loopInc = $mEmp.Body.Instructions[$i]
                break
            }
        }
        $afterStloc2 = $null
        $innerDoneLeave = $null
        for ($i = 0; $i -lt ($mEmp.Body.Instructions.Count - 2); $i++) {
            if (-not $afterStloc2 -and $mEmp.Body.Instructions[$i].OpCode.Name -eq "stloc.2") {
                $afterStloc2 = $mEmp.Body.Instructions[$i + 1]
            }
            if ($mEmp.Body.Instructions[$i].OpCode.Name -eq "endfinally" -and
                $mEmp.Body.Instructions[$i+1].OpCode.Name -eq "leave" -and
                $mEmp.Body.Instructions[$i+1].Operand -eq $loopInc) {
                $innerDoneLeave = $mEmp.Body.Instructions[$i + 1]
            }
        }
        if ($loopInc -and $afterStloc2 -and $innerDoneLeave) {
            $empIL.InsertBefore($afterStloc2, $empIL.Create([Mono.Cecil.Cil.OpCodes]::Ldstr, "spacecore_v1.stamp"))
            $empIL.InsertBefore($afterStloc2, $empIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc_2))
            $empIL.InsertBefore($afterStloc2, $empIL.Create([Mono.Cecil.Cil.OpCodes]::Call, $mTryStamp))
            $empIL.InsertBefore($afterStloc2, $empIL.Create([Mono.Cecil.Cil.OpCodes]::Brtrue, $loopInc))

            $saveStart = $empIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc_2)
            $empIL.InsertBefore($innerDoneLeave, $saveStart)
            $empIL.InsertBefore($innerDoneLeave, $empIL.Create([Mono.Cecil.Cil.OpCodes]::Ldstr, "spacecore_v1.stamp"))
            $empIL.InsertBefore($innerDoneLeave, $empIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc_2))
            $empIL.InsertBefore($innerDoneLeave, $empIL.Create([Mono.Cecil.Cil.OpCodes]::Call, $mSaveStamp))
            $empIL.InsertBefore($innerDoneLeave, $empIL.Create([Mono.Cecil.Cil.OpCodes]::Pop))
            Retarget-Branches $mEmp $innerDoneLeave $saveStart
        }
    }
    Write-Host "  Cold-Boot Stamp Cache (Host): RuntimeSmapiPatcher caches StardewValley.dll, SMAPI.dll & SpaceCore.dll stamps!"
}

$hAsm.Write($outHost)
$hAsm.Dispose()
Verify-Assembly $outHost

# ==============================================================================
# PART 3: PATCH MonoGame.Framework.dll (v7-monogame.dll)
# ==============================================================================
Write-Host "Patching MonoGame.Framework.dll -> $outMG ..."
$rp = New-Object Mono.Cecil.ReaderParameters
$res = New-Object Mono.Cecil.DefaultAssemblyResolver
# Self-healing reference extraction: ensure System.Private.CoreLib.dll, System.Runtime.InteropServices.dll & Microsoft.iOS.dll exist in $env:TEMP\sdv-clean-ui
$baseCleanIpa = Join-Path (Split-Path $PSScriptRoot -Parent) "SVE-iOS\Stardew-Valley-Base-Clean-UI.ipa"
if ((!(Test-Path "$env:TEMP\sdv-clean-ui\System.Private.CoreLib.dll") -or !(Test-Path "$env:TEMP\sdv-clean-ui\System.Runtime.InteropServices.dll") -or !(Test-Path "$env:TEMP\sdv-clean-ui\Microsoft.iOS.dll")) -and (Test-Path $baseCleanIpa)) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [System.IO.Compression.ZipFile]::OpenRead($baseCleanIpa)
    try {
        foreach ($needDll in @("System.Private.CoreLib.dll", "System.Runtime.InteropServices.dll", "Microsoft.iOS.dll")) {
            $dstDll = Join-Path "$env:TEMP\sdv-clean-ui" $needDll
            if (!(Test-Path $dstDll)) {
                $ze = $z.GetEntry("Payload/SDViOS.app/$needDll")
                if ($ze) { [System.IO.Compression.ZipFileExtensions]::ExtractToFile($ze, $dstDll, $true) }
            }
        }
    } finally { $z.Dispose() }
}
$res.AddSearchDirectory("$env:TEMP\sdv-clean-ui")
if (Test-Path "$env:TEMP\sdv-refs") {
    $res.AddSearchDirectory("$env:TEMP\sdv-refs")
}
$rp.AssemblyResolver = $res
$mgAsm = [Mono.Cecil.AssemblyDefinition]::ReadAssembly($srcMG, $rp)
$mgMod = $mgAsm.MainModule
$mgWin = $mgMod.Types | Where-Object { $_.Name -eq "iOSGameWindow" }
$cbM   = $mgWin.Methods | Where-Object { $_.Name -eq "get_ClientBounds" }
$mgNFloatToD = Find-Ref $mgMod "System.Double System.Runtime.InteropServices.NFloat::op_Implicit(System.Runtime.InteropServices.NFloat)"
$mgMathRound = Find-Ref $mgMod "System.Double System.Math::Round(System.Double)"
Expand-ShortBranches $cbM
$mp = $cbM.Body.GetILProcessor()
$mIns = $cbM.Body.Instructions
$patchedMul = 0
for ($i = 1; $i -lt ($mIns.Count - 2); $i++) {
    if ($mIns[$i].OpCode.Name -eq "ldloc.1" -and
        $mIns[$i+1].OpCode.Name -eq "call" -and "$($mIns[$i+1].Operand)" -eq "System.Int32 System.Runtime.InteropServices.NFloat::op_Explicit(System.Runtime.InteropServices.NFloat)" -and
        $mIns[$i+2].OpCode.Name -eq "mul") {
        $iLdloc1 = $mIns[$i]; $iExpl = $mIns[$i+1]; $iMul = $mIns[$i+2]
        $mp.InsertBefore($iLdloc1, $mp.Create([Mono.Cecil.Cil.OpCodes]::Conv_R8))
        $iExpl.Operand = $mgNFloatToD
        $mp.InsertAfter($iMul, $mp.Create([Mono.Cecil.Cil.OpCodes]::Conv_I4))
        $mp.InsertAfter($iMul, $mp.Create([Mono.Cecil.Cil.OpCodes]::Call, $mgMathRound))
        $patchedMul++
        $i += 4
    }
}

# 3.2 (REMOVED WaveBank LoadSoundEffect RAM Eviction hook — it injected cross-class private field access
#      on OALSoundBuffer.dataSize which caused Mono Interpreter to throw FieldAccessException on every sound!)

# 3.3 CRITICAL iOS AUDIO FIX in OpenALSoundController.OpenSoundController():
#   a) Pass NULL (not "") to alcOpenDevice(NULL)
#   b) NOP out invalid AVAudioSession.SharedInstance().Init() which resets/breaks AVAudioSession on modern iOS!
#   c) Pass NULL (not unterminated int[0]) to alcCreateContext(_device, NULL)
#   d) Explicitly call Alc.ProcessContext(_context) after MakeContextCurrent(_context)
$tOalCtrl = $mgMod.Types | Where-Object { $_.Name -eq "OpenALSoundController" }
$mOpenSC  = $tOalCtrl.Methods | Where-Object { $_.Name -eq "OpenSoundController" }
$tAlc     = $mgMod.Types | Where-Object { $_.Name -eq "Alc" }
$fProcCtx = $tAlc.Fields | Where-Object { $_.Name -eq "ProcessContext" }
$fCtxFld  = $tOalCtrl.Fields | Where-Object { $_.Name -eq "_context" }
$tProcDel = $fProcCtx.FieldType.Resolve()
$mProcInv = $tProcDel.Methods | Where-Object { $_.Name -eq "Invoke" }
if (-not $mOpenSC -or -not $fProcCtx -or -not $fCtxFld -or -not $mProcInv) {
    throw "Missing OpenALSoundController / Alc audio targets!"
}
$tOalCtrl.IsPublic = $true
$tAlc.IsPublic = $true
if ($tProcDel.IsNested) { $tProcDel.IsNestedPublic = $true } else { $tProcDel.IsPublic = $true }
$fProcCtx.IsPublic = $true
$fCtxFld.IsPublic = $true
$mProcInv.IsPublic = $true
Expand-ShortBranches $mOpenSC
$oscP = $mOpenSC.Body.GetILProcessor()
$oIns = $mOpenSC.Body.Instructions
$fixOpenDev = 0; $fixAvInit = 0; $fixNullAttr = 0; $fixProcCtx = 0
for ($i = 0; $i -lt $oIns.Count; $i++) {
    # a) ldsfld string.Empty -> ldnull right before d_alcopendevice::Invoke
    if ($oIns[$i].OpCode.Name -eq "ldsfld" -and "$($oIns[$i].Operand)" -like "*String::Empty*" -and ($i + 1) -lt $oIns.Count -and "$($oIns[$i+1].Operand)" -like "*d_alcopendevice::Invoke*") {
        $oIns[$i].OpCode = [Mono.Cecil.Cil.OpCodes]::Ldnull
        $oIns[$i].Operand = $null
        $fixOpenDev++
    }
    # b) NOP out AVAudioSession.SharedInstance().Init()
    if ($oIns[$i].OpCode.Name -eq "call" -and "$($oIns[$i].Operand)" -like "*AVAudioSession::SharedInstance*" -and ($i + 1) -lt $oIns.Count -and $oIns[$i+1].OpCode.Name -eq "callvirt" -and "$($oIns[$i+1].Operand)" -like "*NSObject::Init*") {
        $oIns[$i].OpCode = [Mono.Cecil.Cil.OpCodes]::Nop; $oIns[$i].Operand = $null
        $oIns[$i+1].OpCode = [Mono.Cecil.Cil.OpCodes]::Nop; $oIns[$i+1].Operand = $null
        $fixAvInit++
    }
    # c) ldc.i4.0; newarr System.Int32 -> ldnull; nop right before stloc.1 for Alc.CreateContext
    if ($oIns[$i].OpCode.Name -eq "ldc.i4.0" -and ($i + 1) -lt $oIns.Count -and $oIns[$i+1].OpCode.Name -eq "newarr" -and "$($oIns[$i+1].Operand)" -eq "System.Int32") {
        $oIns[$i].OpCode = [Mono.Cecil.Cil.OpCodes]::Ldnull; $oIns[$i].Operand = $null
        $oIns[$i+1].OpCode = [Mono.Cecil.Cil.OpCodes]::Nop; $oIns[$i+1].Operand = $null
        $fixNullAttr++
    }
    # d) Call Alc.ProcessContext(_context) right after Alc.MakeContextCurrent(_context)
    if ($fixProcCtx -eq 0 -and $oIns[$i].OpCode.Name -eq "callvirt" -and "$($oIns[$i].Operand)" -like "*d_alcmakecontextcurrent::Invoke*") {
        $afterMake = $oIns[$i + 1]
        $oscP.InsertBefore($afterMake, $oscP.Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $fProcCtx))
        $oscP.InsertBefore($afterMake, $oscP.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
        $oscP.InsertBefore($afterMake, $oscP.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $fCtxFld))
        $oscP.InsertBefore($afterMake, $oscP.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mProcInv))
        $fixProcCtx++
        $i += 4
    }
}
if ($fixOpenDev -ne 1 -or $fixAvInit -ne 1 -or $fixNullAttr -ne 1 -or $fixProcCtx -ne 1) {
    throw "OpenALSoundController audio fix mismatch: openDev=$fixOpenDev avInit=$fixAvInit nullAttr=$fixNullAttr procCtx=$fixProcCtx"
}
Write-Host "  iOS Audio Fix (MonoGame): OpenDevice(NULL) + Removed AVAudioSession.Init() + CreateContext(NULL) + ProcessContext()!"

# 3.4 Home Indicator / Edge Gesture Deferral: ALWAYS return UIRectEdge.All (15) in iOSGameViewController
$tGameVC = $mgMod.Types | Where-Object { $_.Name -eq "iOSGameViewController" }
$mDeferEdges = $tGameVC.Methods | Where-Object { $_.Name -eq "get_PreferredScreenEdgesDeferringSystemGestures" }
if ($mDeferEdges) {
    $mDeferEdges.Body.ExceptionHandlers.Clear()
    $mDeferEdges.Body.Instructions.Clear()
    $deIL = $mDeferEdges.Body.GetILProcessor()
    $deIL.Append($deIL.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_S, [sbyte]15))
    $deIL.Append($deIL.Create([Mono.Cecil.Cil.OpCodes]::Conv_I8))
    $deIL.Append($deIL.Create([Mono.Cecil.Cil.OpCodes]::Ret))
    Write-Host "  iOS Home Bar Fix (MonoGame): iOSGameViewController.PreferredScreenEdgesDeferringSystemGestures -> ALWAYS UIRectEdge.All (15)!"
}

# 3.5 iOS Shader Mod Compatibility Fix (Dual MGFX v9 + v10 Binary Reader + Desktop GLSL -> GLSL ES 1.00 auto-translator):
$tEffect    = $mgMod.Types | Where-Object { $_.Name -eq "Effect" }
$tMgfxHdr   = $tEffect.NestedTypes | Where-Object { $_.Name -eq "MGFXHeader" }
$fHdrVer    = $tMgfxHdr.Fields | Where-Object { $_.Name -eq "Version" }
$fMgfxSig   = $tMgfxHdr.Fields | Where-Object { $_.Name -eq "MGFXSignature" }
$mBrReadByte= Find-Ref $mgMod "System.Byte System.IO.BinaryReader::ReadByte()"
$mBrReadI32 = Find-Ref $mgMod "System.Int32 System.IO.BinaryReader::ReadInt32()"
$tBinReader = $mBrReadI32.DeclaringType

if ($tEffect -and $fHdrVer -and $fMgfxSig -and $mBrReadByte -and $mBrReadI32) {
    $fCurVer = New-Object Mono.Cecil.FieldDefinition("CurrentMgfxVersion", [Mono.Cecil.FieldAttributes]"Public, Static", $mgMod.TypeSystem.Int32)
    $tThreadStatic = New-Object Mono.Cecil.TypeReference("System", "ThreadStaticAttribute", $mgMod, $mgMod.TypeSystem.Object.Scope, $false)
    $mTsCtor = New-Object Mono.Cecil.MethodReference(".ctor", $mgMod.TypeSystem.Void, $tThreadStatic)
    $mTsCtor.HasThis = $true
    $fCurVer.CustomAttributes.Add((New-Object Mono.Cecil.CustomAttribute($mTsCtor)))
    $tEffect.Fields.Add($fCurVer)

    # 3.5a Effect.ReadHeader: accept MGFX Version 8..10 and store Effect.CurrentMgfxVersion = header.Version
    $mReadHdr = $tEffect.Methods | Where-Object { $_.Name -eq "ReadHeader" }
    Expand-ShortBranches $mReadHdr
    $rhIL = $mReadHdr.Body.GetILProcessor()
    for ($i = 0; $i -lt $mReadHdr.Body.Instructions.Count; $i++) {
        $ins = $mReadHdr.Body.Instructions[$i]
        if ($ins.OpCode.Name -eq "ldc.i4.s" -and [int]$ins.Operand -eq 10) {
            $ins.Operand = [sbyte]8
            break
        }
    }
    $rhLastRet = $mReadHdr.Body.Instructions[$mReadHdr.Body.Instructions.Count - 1]
    $rhIL.InsertBefore($rhLastRet, $rhIL.Create([Mono.Cecil.Cil.OpCodes]::Dup))
    $rhIL.InsertBefore($rhLastRet, $rhIL.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $fHdrVer))
    $rhIL.InsertBefore($rhLastRet, $rhIL.Create([Mono.Cecil.Cil.OpCodes]::Stsfld, $fCurVer))

    # 3.5b Build Effect.ReadMgfxCount(BinaryReader r) -> (CurrentMgfxVersion < 10) ? (int)r.ReadByte() : r.ReadInt32()
    $mReadCnt = New-Object Mono.Cecil.MethodDefinition("ReadMgfxCount", [Mono.Cecil.MethodAttributes]"Public, Static", $mgMod.TypeSystem.Int32)
    $mReadCnt.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition("r", [Mono.Cecil.ParameterAttributes]::None, $tBinReader)))
    $ilRC = $mReadCnt.Body.GetILProcessor()
    $lV10Cnt = $ilRC.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0)
    $ilRC.Append($ilRC.Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $fCurVer))
    $ilRC.Append($ilRC.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_S, [sbyte]10))
    $ilRC.Append($ilRC.Create([Mono.Cecil.Cil.OpCodes]::Bge, $lV10Cnt))
    $ilRC.Append($ilRC.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
    $ilRC.Append($ilRC.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mBrReadByte))
    $ilRC.Append($ilRC.Create([Mono.Cecil.Cil.OpCodes]::Ret))
    $ilRC.Append($lV10Cnt)
    $ilRC.Append($ilRC.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mBrReadI32))
    $ilRC.Append($ilRC.Create([Mono.Cecil.Cil.OpCodes]::Ret))
    $tEffect.Methods.Add($mReadCnt)

    # 3.5c Build Effect.ReadMgfxShaderIndex(BinaryReader r) -> (CurrentMgfxVersion < 10) ? (int)(sbyte)r.ReadByte() : r.ReadInt32()
    $mReadIdx = New-Object Mono.Cecil.MethodDefinition("ReadMgfxShaderIndex", [Mono.Cecil.MethodAttributes]"Public, Static", $mgMod.TypeSystem.Int32)
    $mReadIdx.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition("r", [Mono.Cecil.ParameterAttributes]::None, $tBinReader)))
    $ilRI = $mReadIdx.Body.GetILProcessor()
    $lV10Idx = $ilRI.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0)
    $ilRI.Append($ilRI.Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $fCurVer))
    $ilRI.Append($ilRI.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_S, [sbyte]10))
    $ilRI.Append($ilRI.Create([Mono.Cecil.Cil.OpCodes]::Bge, $lV10Idx))
    $ilRI.Append($ilRI.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
    $ilRI.Append($ilRI.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mBrReadByte))
    $ilRI.Append($ilRI.Create([Mono.Cecil.Cil.OpCodes]::Conv_I1))
    $ilRI.Append($ilRI.Create([Mono.Cecil.Cil.OpCodes]::Ret))
    $ilRI.Append($lV10Idx)
    $ilRI.Append($ilRI.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mBrReadI32))
    $ilRI.Append($ilRI.Create([Mono.Cecil.Cil.OpCodes]::Ret))
    $tEffect.Methods.Add($mReadIdx)

    # 3.5d Build Effect.ReadMgfxTailSignature(BinaryReader r) -> (CurrentMgfxVersion < 10) ? MGFXHeader.MGFXSignature : r.ReadInt32()
    $mReadTail = New-Object Mono.Cecil.MethodDefinition("ReadMgfxTailSignature", [Mono.Cecil.MethodAttributes]"Public, Static", $mgMod.TypeSystem.Int32)
    $mReadTail.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition("r", [Mono.Cecil.ParameterAttributes]::None, $tBinReader)))
    $ilRT = $mReadTail.Body.GetILProcessor()
    $lV10Tail = $ilRT.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0)
    $ilRT.Append($ilRT.Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $fCurVer))
    $ilRT.Append($ilRT.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_S, [sbyte]10))
    $ilRT.Append($ilRT.Create([Mono.Cecil.Cil.OpCodes]::Bge, $lV10Tail))
    $ilRT.Append($ilRT.Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $fMgfxSig))
    $ilRT.Append($ilRT.Create([Mono.Cecil.Cil.OpCodes]::Ret))
    $ilRT.Append($lV10Tail)
    $ilRT.Append($ilRT.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mBrReadI32))
    $ilRT.Append($ilRT.Create([Mono.Cecil.Cil.OpCodes]::Ret))
    $tEffect.Methods.Add($mReadTail)

    # 3.5e Redirect ReadInt32() in ReadEffect (5 calls), ReadParameters (1 call), ReadAnnotations (1 call)
    foreach ($mName in @("ReadEffect", "ReadParameters", "ReadAnnotations")) {
        $em = $tEffect.Methods | Where-Object { $_.Name -eq $mName }
        foreach ($ins in $em.Body.Instructions) {
            if ($ins.OpCode.Name -eq "callvirt" -and "$($ins.Operand)" -eq "System.Int32 System.IO.BinaryReader::ReadInt32()") {
                $ins.OpCode  = [Mono.Cecil.Cil.OpCodes]::Call
                $ins.Operand = $mReadCnt
            }
        }
    }

    # 3.5f Redirect first 3 ReadInt32() in ReadPasses (passCount -> ReadMgfxCount, vsIdx & psIdx -> ReadMgfxShaderIndex)
    $mReadPasses = $tEffect.Methods | Where-Object { $_.Name -eq "ReadPasses" }
    $rpIdx = 0
    foreach ($ins in $mReadPasses.Body.Instructions) {
        if ($ins.OpCode.Name -eq "callvirt" -and "$($ins.Operand)" -eq "System.Int32 System.IO.BinaryReader::ReadInt32()") {
            $rpIdx++
            if ($rpIdx -eq 1) {
                $ins.OpCode  = [Mono.Cecil.Cil.OpCodes]::Call
                $ins.Operand = $mReadCnt
            } elseif ($rpIdx -eq 2 -or $rpIdx -eq 3) {
                $ins.OpCode  = [Mono.Cecil.Cil.OpCodes]::Call
                $ins.Operand = $mReadIdx
            }
        }
    }

    # 3.5g Redirect trailing ReadInt32() in Effect..ctor(GraphicsDevice, byte[], int, int)
    foreach ($em in ($tEffect.Methods | Where-Object { $_.Name -eq ".ctor" -and $_.Parameters.Count -eq 4 })) {
        for ($i = 0; $i -lt ($em.Body.Instructions.Count - 1); $i++) {
            $ins = $em.Body.Instructions[$i]
            if ($ins.OpCode.Name -eq "callvirt" -and "$($ins.Operand)" -eq "System.Int32 System.IO.BinaryReader::ReadInt32()" -and
                "$($em.Body.Instructions[$i+1].Operand)" -like "*MGFXSignature*") {
                $ins.OpCode  = [Mono.Cecil.Cil.OpCodes]::Call
                $ins.Operand = $mReadTail
                break
            }
        }
    }
    Write-Host "  iOS Shader Fix (MonoGame): Full dual MGFX v9 (ReadByte/ReadSByte) + MGFX v10 (ReadInt32) parser active!"
}

$tShader = $mgMod.Types | Where-Object { $_.Name -eq "Shader" }
$mStrReplace  = Find-Ref $mgMod "System.String System.String::Replace(System.String,System.String)"
$mStrContains = Find-Ref $mgMod "System.Boolean System.String::Contains(System.String)"
$mStrConcat2  = Find-Ref $mgMod "System.String System.String::Concat(System.String,System.String)"
$mConWrite    = Find-Ref $mgMod "System.Void System.Console::WriteLine(System.String)"

if ($tShader -and $mStrReplace -and $mStrContains -and $mStrConcat2) {
    $mStrLastIdx = New-Object Mono.Cecil.MethodReference("LastIndexOf", $mgMod.TypeSystem.Int32, $mgMod.TypeSystem.String)
    $mStrLastIdx.HasThis = $true
    $mStrLastIdx.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition($mgMod.TypeSystem.String)))
    $mStrIdxChar = New-Object Mono.Cecil.MethodReference("IndexOf", $mgMod.TypeSystem.Int32, $mgMod.TypeSystem.String)
    $mStrIdxChar.HasThis = $true
    $mStrIdxChar.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition($mgMod.TypeSystem.Char)))
    $mStrIdxChar.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition($mgMod.TypeSystem.Int32)))
    $mStrInsert = New-Object Mono.Cecil.MethodReference("Insert", $mgMod.TypeSystem.String, $mgMod.TypeSystem.String)
    $mStrInsert.HasThis = $true
    $mStrInsert.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition($mgMod.TypeSystem.Int32)))
    $mStrInsert.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition($mgMod.TypeSystem.String)))

    $mPatchGlsl = New-Object Mono.Cecil.MethodDefinition("PatchGlslForIosEs", [Mono.Cecil.MethodAttributes]"Public, Static", $mgMod.TypeSystem.String)
    $mPatchGlsl.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition("src", [Mono.Cecil.ParameterAttributes]::None, $mgMod.TypeSystem.String)))
    $mPatchGlsl.Body.InitLocals = $true
    $vExtIdx = New-Object Mono.Cecil.Cil.VariableDefinition($mgMod.TypeSystem.Int32)
    $vNlIdx  = New-Object Mono.Cecil.Cil.VariableDefinition($mgMod.TypeSystem.Int32)
    $mPatchGlsl.Body.Variables.Add($vExtIdx)
    $mPatchGlsl.Body.Variables.Add($vNlIdx)

    $ilG = $mPatchGlsl.Body.GetILProcessor()
    $lRetG = $ilG.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0)
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $lRetG))
    # Strip longer desktop `#version XXX core/compatibility` directives BEFORE bare `#version XXX` so " core" never dangles!
    foreach ($ver in @(
        "#version 150 core", "#version 330 core", "#version 400 core", "#version 410 core", "#version 420 core", "#version 430 core", "#version 440 core", "#version 450 core", "#version 460 core",
        "#version 150 compatibility", "#version 330 compatibility", "#version 400 compatibility", "#version 410 compatibility", "#version 420 compatibility", "#version 430 compatibility", "#version 440 compatibility", "#version 450 compatibility", "#version 460 compatibility",
        "#version 110", "#version 120", "#version 130", "#version 140", "#version 150", "#version 330", "#version 400", "#version 410", "#version 420", "#version 430", "#version 440", "#version 450", "#version 460"
    )) {
        $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
        $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Ldstr, $ver))
        $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Ldstr, ""))
        $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mStrReplace))
        $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Starg, $mPatchGlsl.Parameters[0]))
    }
    foreach ($rep in @(
        @("precision lowp float;",    "precision highp float;"),
        @("precision mediump float;", "precision highp float;"),
        @("precision mediump int;",   "precision highp int;"),
        @("GL_ARB_shader_texture_lod","GL_EXT_shader_texture_lod"),
        @("texture2DLod(",            "texture2DLodEXT(")
    )) {
        $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
        $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Ldstr, $rep[0]))
        $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Ldstr, $rep[1]))
        $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mStrReplace))
        $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Starg, $mPatchGlsl.Parameters[0]))
    }
    # If shader already declares explicit GLSL ES `#version` (e.g. `#version 300 es` or `#version 100`), never prepend lines before `#version`!
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Ldstr, "#version "))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mStrContains))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Brtrue, $lRetG))

    # 1) Prepend missing `#extension` directives FIRST at line 1
    $lCheckLodExt = $ilG.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0)
    $lAddDeriv = $ilG.Create([Mono.Cecil.Cil.OpCodes]::Ldstr, "#extension GL_OES_standard_derivatives : enable`n")
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Ldstr, "GL_OES_standard_derivatives"))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mStrContains))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Brtrue, $lCheckLodExt))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Ldstr, "dFdx("))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mStrContains))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Brtrue, $lAddDeriv))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Ldstr, "dFdy("))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mStrContains))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Brtrue, $lAddDeriv))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Ldstr, "fwidth("))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mStrContains))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $lCheckLodExt))
    $ilG.Append($lAddDeriv)
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Call, $mStrConcat2))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Starg, $mPatchGlsl.Parameters[0]))

    $lCheckPrec = $ilG.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0)
    $ilG.Append($lCheckLodExt)
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Ldstr, "GL_EXT_shader_texture_lod"))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mStrContains))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Brtrue, $lCheckPrec))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Ldstr, "texture2DLodEXT("))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mStrContains))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $lCheckPrec))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Ldstr, "#extension GL_EXT_shader_texture_lod : enable`n"))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Call, $mStrConcat2))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Starg, $mPatchGlsl.Parameters[0]))

    # 2) Inject `precision highp` AFTER the last `#extension` line so `#extension` is strictly before non-preprocessor tokens!
    $lPrependPrec = $ilG.Create([Mono.Cecil.Cil.OpCodes]::Ldstr, "#ifdef GL_ES`nprecision highp float;`nprecision highp int;`n#endif`n")
    $ilG.Append($lCheckPrec)
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Ldstr, "precision "))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mStrContains))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Brtrue, $lRetG))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Ldstr, "#extension"))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mStrLastIdx))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vExtIdx))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vExtIdx))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Blt, $lPrependPrec))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_S, [sbyte]10))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vExtIdx))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mStrIdxChar))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vNlIdx))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vNlIdx))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Blt, $lPrependPrec))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vNlIdx))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_1))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Add))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Ldstr, "#ifdef GL_ES`nprecision highp float;`nprecision highp int;`n#endif`n"))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mStrInsert))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Starg, $mPatchGlsl.Parameters[0]))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Br, $lRetG))

    $ilG.Append($lPrependPrec)
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Call, $mStrConcat2))
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Starg, $mPatchGlsl.Parameters[0]))
    $ilG.Append($lRetG)
    $ilG.Append($ilG.Create([Mono.Cecil.Cil.OpCodes]::Ret))
    $tShader.Methods.Add($mPatchGlsl)

    $mPlatConst = $tShader.Methods | Where-Object { $_.Name -eq "PlatformConstruct" }
    $pcIL = $mPlatConst.Body.GetILProcessor()
    for ($i = 0; $i -lt $mPlatConst.Body.Instructions.Count; $i++) {
        $ins = $mPlatConst.Body.Instructions[$i]
        if ($ins.OpCode.Name -eq "stfld" -and "$($ins.Operand)" -like "*_glslCode*") {
            $pcIL.InsertBefore($ins, $pcIL.Create([Mono.Cecil.Cil.OpCodes]::Call, $mPatchGlsl))
            break
        }
    }

    # Build Shader.LogGlslDiag(string msg) -> Console.WriteLine + persistent Documents/ErrorLogs/shader-diag.log
    $mLogTarget = $mConWrite
    $mGetFolderPath = Find-Ref $mgMod "System.String System.Environment::GetFolderPath(System.Environment/SpecialFolder)"
    $mPathComb3     = Find-Ref $mgMod "System.String System.IO.Path::Combine(System.String,System.String,System.String)"
    $tSysFileRef    = $mgMod.GetTypeReferences() | Where-Object { $_.FullName -eq "System.IO.File" -and $_.Scope.Name -eq "System.Private.CoreLib" } | Select-Object -First 1
    $tSysExcRef     = $mgMod.GetTypeReferences() | Where-Object { $_.FullName -eq "System.Exception" } | Select-Object -First 1
    if ($mConWrite -and $mGetFolderPath -and $mPathComb3 -and $tSysFileRef -and $tSysExcRef) {
        $mAppendAllText = New-Object Mono.Cecil.MethodReference("AppendAllText", $mgMod.TypeSystem.Void, $tSysFileRef)
        $mAppendAllText.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition("path", [Mono.Cecil.ParameterAttributes]::None, $mgMod.TypeSystem.String)))
        $mAppendAllText.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition("contents", [Mono.Cecil.ParameterAttributes]::None, $mgMod.TypeSystem.String)))

        $mLogGlsl = New-Object Mono.Cecil.MethodDefinition("LogGlslDiag", [Mono.Cecil.MethodAttributes]"Public, Static", $mgMod.TypeSystem.Void)
        $mLogGlsl.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition("msg", [Mono.Cecil.ParameterAttributes]::None, $mgMod.TypeSystem.String)))
        $mLogGlsl.Body.MaxStackSize = 8
        $ilLD = $mLogGlsl.Body.GetILProcessor()

        $lTryLD   = $ilLD.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0)
        $lRetLD   = $ilLD.Create([Mono.Cecil.Cil.OpCodes]::Ret)
        $lLeaveLD = $ilLD.Create([Mono.Cecil.Cil.OpCodes]::Leave, $lRetLD)
        $lCatchLD = $ilLD.Create([Mono.Cecil.Cil.OpCodes]::Pop)

        $ilLD.Append($ilLD.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
        $ilLD.Append($ilLD.Create([Mono.Cecil.Cil.OpCodes]::Call, $mConWrite))
        $ilLD.Append($lTryLD)
        $ilLD.Append($ilLD.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $lLeaveLD))
        $ilLD.Append($ilLD.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_5)) # Environment.SpecialFolder.Personal
        $ilLD.Append($ilLD.Create([Mono.Cecil.Cil.OpCodes]::Call, $mGetFolderPath))
        $ilLD.Append($ilLD.Create([Mono.Cecil.Cil.OpCodes]::Ldstr, "ErrorLogs"))
        $ilLD.Append($ilLD.Create([Mono.Cecil.Cil.OpCodes]::Ldstr, "shader-diag.log"))
        $ilLD.Append($ilLD.Create([Mono.Cecil.Cil.OpCodes]::Call, $mPathComb3))
        $ilLD.Append($ilLD.Create([Mono.Cecil.Cil.OpCodes]::Ldstr, "[GLSL-ERR] "))
        $ilLD.Append($ilLD.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
        $ilLD.Append($ilLD.Create([Mono.Cecil.Cil.OpCodes]::Call, $mStrConcat2))
        $ilLD.Append($ilLD.Create([Mono.Cecil.Cil.OpCodes]::Ldstr, "`n"))
        $ilLD.Append($ilLD.Create([Mono.Cecil.Cil.OpCodes]::Call, $mStrConcat2))
        $ilLD.Append($ilLD.Create([Mono.Cecil.Cil.OpCodes]::Call, $mAppendAllText))
        $ilLD.Append($lLeaveLD)
        $ilLD.Append($lCatchLD)
        $ilLD.Append($ilLD.Create([Mono.Cecil.Cil.OpCodes]::Leave, $lRetLD))
        $ilLD.Append($lRetLD)

        $ehLD = New-Object Mono.Cecil.Cil.ExceptionHandler([Mono.Cecil.Cil.ExceptionHandlerType]::Catch)
        $ehLD.CatchType    = $tSysExcRef
        $ehLD.TryStart     = $lTryLD
        $ehLD.TryEnd       = $lCatchLD
        $ehLD.HandlerStart = $lCatchLD
        $ehLD.HandlerEnd   = $lRetLD
        $mLogGlsl.Body.ExceptionHandlers.Add($ehLD)
        $tShader.Methods.Add($mLogGlsl)
        $mLogTarget = $mLogGlsl
    }

    $mGetSH = $tShader.Methods | Where-Object { $_.Name -eq "GetShaderHandle" }
    if ($mGetSH -and $mLogTarget) {
        for ($i = 1; $i -lt $mGetSH.Body.Instructions.Count; $i++) {
            if ($mGetSH.Body.Instructions[$i].OpCode.Name -eq "pop" -and "$($mGetSH.Body.Instructions[$i-1].Operand)" -like "*GetShaderInfoLog*") {
                $mGetSH.Body.Instructions[$i].OpCode = [Mono.Cecil.Cil.OpCodes]::Call
                $mGetSH.Body.Instructions[$i].Operand = $mLogTarget
                break
            }
        }
    }

    $tProgCache = $mgMod.Types | Where-Object { $_.Name -eq "ShaderProgramCache" }
    $mProgLink  = if ($tProgCache) { $tProgCache.Methods | Where-Object { $_.Name -eq "Link" } | Select-Object -First 1 } else { $null }
    if ($mProgLink -and $mLogTarget) {
        for ($i = 1; $i -lt $mProgLink.Body.Instructions.Count; $i++) {
            if ($mProgLink.Body.Instructions[$i].OpCode.Name -eq "call" -and "$($mProgLink.Body.Instructions[$i-1].Operand)" -like "*GetProgramInfoLog*") {
                $mProgLink.Body.Instructions[$i].Operand = $mLogTarget
                break
            }
        }
    }
    Write-Host "  iOS Shader Fix (MonoGame): MGFX v8..10 + highp float/int GLSL ES upgrade + persistent shader-diag.log on compile/link errors!"
}

# 3.6 Implement Texture2D.CopyFromTexture(Texture2D src) in MonoGame.Framework.dll!
# Base SDViosport MonoGame stubbed CopyFromTexture as a 1-instruction `ret`, silently discarding ALL
# SMAPI CoreAssetPropagator.PropagateTexture() updates (TitleButtons, Clouds, MenuTiles, Cursors, fonts,
# portraits, recolors, UI packs such as Cat Valley UI, Earthy Interface, Vintage Interface, etc.)!
$tTex2D    = $mgMod.GetType("Microsoft.Xna.Framework.Graphics.Texture2D")
$tTexBase  = $mgMod.GetType("Microsoft.Xna.Framework.Graphics.Texture")
$tGfxRes   = $mgMod.GetType("Microsoft.Xna.Framework.Graphics.GraphicsResource")
$tGfxDev   = $mgMod.GetType("Microsoft.Xna.Framework.Graphics.GraphicsDevice")
$tTexColl  = $mgMod.GetType("Microsoft.Xna.Framework.Graphics.TextureCollection")
$tColor    = $mgMod.GetType("Microsoft.Xna.Framework.Color")
$mCopyFrom = if ($tTex2D) { $tTex2D.Methods | Where-Object { $_.Name -eq "CopyFromTexture" -and $_.Parameters.Count -eq 1 } } else { $null }
if (-not $mCopyFrom) { throw "Missing Texture2D.CopyFromTexture(Texture2D) in MonoGame.Framework.dll!" }

$fTexWidth     = $tTex2D.Fields   | Where-Object { $_.Name -eq "width" }
$fTexHeight    = $tTex2D.Fields   | Where-Object { $_.Name -eq "height" }
$fActWidth     = $tTex2D.Fields   | Where-Object { $_.Name -eq "_actualWidth" }
$fActHeight    = $tTex2D.Fields   | Where-Object { $_.Name -eq "_actualHeight" }
$fTexFormat    = $tTexBase.Fields | Where-Object { $_.Name -eq "_format" }
$fLevelCount   = $tTexBase.Fields | Where-Object { $_.Name -eq "_levelCount" }
$fGlTexture    = $tTexBase.Fields | Where-Object { $_.Name -eq "glTexture" }
$fGlLastSamp   = $tTexBase.Fields | Where-Object { $_.Name -eq "glLastSamplerState" }
$mGetDisposed  = $tGfxRes.Methods | Where-Object { $_.Name -eq "get_IsDisposed" }
$mGetGD        = $tGfxRes.Methods | Where-Object { $_.Name -eq "get_GraphicsDevice" }
$mDeleteGL     = $tTexBase.Methods| Where-Object { $_.Name -eq "DeleteGLTexture" }
$mGetData1Def  = $tTex2D.Methods  | Where-Object { $_.Name -eq "GetData" -and $_.Parameters.Count -eq 1 }
$mSetData1Def  = $tTex2D.Methods  | Where-Object { $_.Name -eq "SetData" -and $_.Parameters.Count -eq 1 }
$mGetColorData = $tTex2D.Methods  | Where-Object { $_.Name -eq "GetColorData" }
$mSetTexelW    = $tTex2D.Methods  | Where-Object { $_.Name -eq "set_TexelWidth" }
$mSetTexelH    = $tTex2D.Methods  | Where-Object { $_.Name -eq "set_TexelHeight" }
$mTexPlatCtor  = $tTex2D.Methods  | Where-Object { $_.Name -eq "PlatformConstruct" }
$mGetTextures  = $tGfxDev.Methods | Where-Object { $_.Name -eq "get_Textures" }
$mTexCollDirty = $tTexColl.Methods| Where-Object { $_.Name -eq "Dirty" }
$tSysException = $mgMod.GetTypeReferences() | Where-Object { $_.FullName -eq "System.Exception" } | Select-Object -First 1

foreach ($req in @($fTexWidth,$fTexHeight,$fActWidth,$fActHeight,$fTexFormat,$fLevelCount,$fGlTexture,$fGlLastSamp,$mGetDisposed,$mGetGD,$mDeleteGL,$mGetData1Def,$mSetData1Def,$mGetColorData,$mSetTexelW,$mSetTexelH,$mTexPlatCtor,$mGetTextures,$mTexCollDirty,$tColor,$tSysException)) {
    if (-not $req) { throw "Missing required MonoGame member for Texture2D.CopyFromTexture implementation!" }
}
# Ensure Texture.DeleteGLTexture is assembly-visible so subclass Texture2D.CopyFromTexture never throws MethodAccessException on resize!
$mDeleteGL.IsPrivate = $false
$mDeleteGL.IsAssembly = $true

$mGetDataColor = New-Object Mono.Cecil.GenericInstanceMethod($mGetData1Def)
$mGetDataColor.GenericArguments.Add($tColor)
$mSetDataColor = New-Object Mono.Cecil.GenericInstanceMethod($mSetData1Def)
$mSetDataColor.GenericArguments.Add($tColor)
$tColorArray = New-Object Mono.Cecil.ArrayType($tColor)

$mCopyFrom.Body.Instructions.Clear()
$mCopyFrom.Body.ExceptionHandlers.Clear()
$mCopyFrom.Body.Variables.Clear()
$mCopyFrom.Body.InitLocals = $true
$mCopyFrom.Body.MaxStackSize = 8

$vW    = New-Object Mono.Cecil.Cil.VariableDefinition($mgMod.TypeSystem.Int32)
$vH    = New-Object Mono.Cecil.Cil.VariableDefinition($mgMod.TypeSystem.Int32)
$vData = New-Object Mono.Cecil.Cil.VariableDefinition($tColorArray)
$vGd   = New-Object Mono.Cecil.Cil.VariableDefinition($tGfxDev)
$mCopyFrom.Body.Variables.Add($vW)
$mCopyFrom.Body.Variables.Add($vH)
$mCopyFrom.Body.Variables.Add($vData)
$mCopyFrom.Body.Variables.Add($vGd)

$cil = $mCopyFrom.Body.GetILProcessor()
$lTryStart    = $cil.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_1)
$lGetColData  = $cil.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_1)
$lAfterRead   = $cil.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vData)
$lResize      = $cil.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0)
$lSyncActual  = $cil.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0)
$lRet         = $cil.Create([Mono.Cecil.Cil.OpCodes]::Ret)
$lLeaveTry    = $cil.Create([Mono.Cecil.Cil.OpCodes]::Leave, $lRet)
$lCatchStart  = $cil.Create([Mono.Cecil.Cil.OpCodes]::Pop)

# Early guards: null, self, disposed, invalid dimensions, uninitialized GL handle
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_1))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $lRet))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_1))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Beq, $lRet))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Call, $mGetDisposed))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Brtrue, $lRet))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_1))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Call, $mGetDisposed))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Brtrue, $lRet))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_1))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $fTexWidth))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vW))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_1))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $fTexHeight))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vH))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vW))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ble, $lRet))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vH))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ble, $lRet))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_1))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $fGlTexture))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ble, $lRet))

# try { Scissor/ColorMask-immune CPU GetData<Color> + SetData<Color> (GL.BlitFramebuffer is clipped by LoadGameMenu GL_SCISSOR_TEST -> #GL-V53YS2!) }
$cil.Append($lTryStart)
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $fTexFormat))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Brtrue, $lGetColData))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vW))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vH))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Mul))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Newarr, $tColor))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vData))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_1))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vData))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Call, $mGetDataColor))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Br, $lAfterRead))

$cil.Append($lGetColData)
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Call, $mGetColorData))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vData))

$cil.Append($lAfterRead)
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $lLeaveTry))

# Check if destination needs resize / format reset / GL texture recreation
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $fTexWidth))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vW))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Bne_Un, $lResize))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $fTexHeight))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vH))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Bne_Un, $lResize))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $fTexFormat))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Brtrue, $lResize))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $fLevelCount))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_1))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Bne_Un, $lResize))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $fGlTexture))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ble, $lResize))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Br, $lSyncActual))

# Resize & re-create GL texture cleanly
$cil.Append($lResize)
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Call, $mDeleteGL))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vW))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Stfld, $fTexWidth))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vH))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Stfld, $fTexHeight))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldc_R4, [float]1.0))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vW))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Conv_R4))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Div))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Call, $mSetTexelW))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldc_R4, [float]1.0))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vH))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Conv_R4))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Div))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Call, $mSetTexelH))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Stfld, $fTexFormat))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_1))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Stfld, $fLevelCount))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldnull))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Stfld, $fGlLastSamp))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vW))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vH))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Call, $mTexPlatCtor))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Call, $mGetGD))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vGd))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vGd))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $lSyncActual))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vGd))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mGetTextures))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mTexCollDirty))

# Sync ActualWidth/ActualHeight and upload pixels on UI thread
$cil.Append($lSyncActual)
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_1))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $fActWidth))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Stfld, $fActWidth))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_1))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $fActHeight))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Stfld, $fActHeight))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vData))
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Call, $mSetDataColor))
$cil.Append($lLeaveTry)

# catch (Exception) { }
$cil.Append($lCatchStart)
$cil.Append($cil.Create([Mono.Cecil.Cil.OpCodes]::Leave, $lRet))
$cil.Append($lRet)

$eh = New-Object Mono.Cecil.Cil.ExceptionHandler([Mono.Cecil.Cil.ExceptionHandlerType]::Catch)
$eh.CatchType    = $tSysException
$eh.TryStart     = $lTryStart
$eh.TryEnd       = $lCatchStart
$eh.HandlerStart = $lCatchStart
$eh.HandlerEnd   = $lRet
$mCopyFrom.Body.ExceptionHandlers.Add($eh)
Write-Host "  iOS Content Patcher Texture Propagation Fix (MonoGame): Implemented real Texture2D.CopyFromTexture(Texture2D) with dynamic resize + GL cache invalidation!"

# 3.7 CRITICAL iOS Shader Mod Fix (DynamicShader ShadowAlphaBoundsCache + WaterTileArtMaskCache):
# Texture2D.PlatformGetData creates & deletes a temporary FBO without restoring GL_FRAMEBUFFER_BINDING!
# Wrap BindFramebuffer..ReadPixels in try/finally so DeleteFramebuffers + BindFramebuffer(prevFbo) ALWAYS run!
$tGL = $mgMod.GetType("MonoGame.OpenGL.GL")
$mGlGetInt = if ($tGL) { $tGL.Methods | Where-Object { $_.Name -eq "GetInteger" -and $_.Parameters.Count -eq 2 -and $_.Parameters[0].ParameterType.FullName -eq "System.Int32" } | Select-Object -First 1 } else { $null }
$mPlatGetData = $tTex2D.Methods | Where-Object { $_.Name -eq "PlatformGetData" } | Select-Object -First 1
if (-not $mPlatGetData -or -not $mGlGetInt) { throw "Missing Texture2D.PlatformGetData or GL.GetInteger(int, out int)!" }
$fBindFb = $null; $mBindFbInv = $null; $fDelFbPd = $null; $mDelFbInvPd = $null
foreach ($ins in $mPlatGetData.Body.Instructions) {
    if ($ins.OpCode.Name -eq "ldsfld" -and "$($ins.Operand)" -like "*GL::BindFramebuffer*") { $fBindFb = $ins.Operand }
    elseif ($ins.OpCode.Name -eq "callvirt" -and "$($ins.Operand)" -like "*BindFramebufferDelegate::Invoke*") { $mBindFbInv = $ins.Operand }
    elseif ($ins.OpCode.Name -eq "ldsfld" -and "$($ins.Operand)" -like "*GL::DeleteFramebuffers*") { $fDelFbPd = $ins.Operand }
    elseif ($ins.OpCode.Name -eq "callvirt" -and "$($ins.Operand)" -like "*DeleteFramebuffersDelegate::Invoke*") { $mDelFbInvPd = $ins.Operand }
}
if (-not $fBindFb -or -not $mBindFbInv -or -not $fDelFbPd -or -not $mDelFbInvPd) { throw "Missing GL FBO delegate refs in PlatformGetData!" }
Expand-ShortBranches $mPlatGetData
$vTempFbo = $mPlatGetData.Body.Variables[0]
$vPrevFbo = New-Object Mono.Cecil.Cil.VariableDefinition($mgMod.TypeSystem.Int32)
$mPlatGetData.Body.Variables.Add($vPrevFbo)
$mPlatGetData.Body.InitLocals = $true
$gdIL = $mPlatGetData.Body.GetILProcessor()
$afterEnsureUi = $mPlatGetData.Body.Instructions[1] # right after Threading.EnsureUIThread()
$gdIL.InsertBefore($afterEnsureUi, $gdIL.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0))
$gdIL.InsertBefore($afterEnsureUi, $gdIL.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vPrevFbo))
$gdIL.InsertBefore($afterEnsureUi, $gdIL.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4, [int]36006)) # GL_FRAMEBUFFER_BINDING
$gdIL.InsertBefore($afterEnsureUi, $gdIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloca, $vPrevFbo))
$gdIL.InsertBefore($afterEnsureUi, $gdIL.Create([Mono.Cecil.Cil.OpCodes]::Call, $mGlGetInt))

$tryStartPd = $null; $delStartPd = $null
foreach ($ins in $mPlatGetData.Body.Instructions) {
    if (-not $tryStartPd -and $ins.OpCode.Name -eq "ldsfld" -and $ins.Operand -eq $fBindFb) { $tryStartPd = $ins }
    if (-not $delStartPd -and $ins.OpCode.Name -eq "ldsfld" -and $ins.Operand -eq $fDelFbPd) { $delStartPd = $ins }
}
if (-not $tryStartPd -or -not $delStartPd) { throw "Missing tryStart or delStart in PlatformGetData!" }
$idxDel = $mPlatGetData.Body.Instructions.IndexOf($delStartPd)
while ($mPlatGetData.Body.Instructions.Count -gt $idxDel) {
    $mPlatGetData.Body.Instructions.RemoveAt($idxDel)
}
$lPdFinStart = $gdIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vTempFbo)
$lPdRestBind = $gdIL.Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $fBindFb)
$lPdRet      = $gdIL.Create([Mono.Cecil.Cil.OpCodes]::Ret)
$gdIL.Append($gdIL.Create([Mono.Cecil.Cil.OpCodes]::Leave, $lPdRet))
$gdIL.Append($lPdFinStart)
$gdIL.Append($gdIL.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $lPdRestBind))
$gdIL.Append($gdIL.Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $fDelFbPd))
$gdIL.Append($gdIL.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_1))
$gdIL.Append($gdIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloca, $vTempFbo))
$gdIL.Append($gdIL.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mDelFbInvPd))
$gdIL.Append($lPdRestBind)
$gdIL.Append($gdIL.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4, [int]36160)) # FramebufferTarget.Framebuffer
$gdIL.Append($gdIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vPrevFbo))
$gdIL.Append($gdIL.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mBindFbInv))
$gdIL.Append($gdIL.Create([Mono.Cecil.Cil.OpCodes]::Endfinally))
$gdIL.Append($lPdRet)
$ehPd = New-Object Mono.Cecil.Cil.ExceptionHandler([Mono.Cecil.Cil.ExceptionHandlerType]::Finally)
$ehPd.TryStart = $tryStartPd; $ehPd.TryEnd = $lPdFinStart; $ehPd.HandlerStart = $lPdFinStart; $ehPd.HandlerEnd = $lPdRet
$mPlatGetData.Body.ExceptionHandlers.Add($ehPd)
Write-Host "  iOS DynamicShader Fix #1 (MonoGame): Texture2D.PlatformGetData wrapped in try/finally FBO cleanup + binding restore!"

# 3.8 CRITICAL iOS Multi-Pass Shader Fix (posFixup Y-flip & half-pixel offset):
# GraphicsDevice only uploads `posFixup` inside ActivateShaderProgram(), which only runs when
# _vertexShaderDirty || _pixelShaderDirty! Switching between offscreen RenderTarget2D <-> BackBuffer
# (or changing Viewport) while reusing the same vertex shader left posFixup.y inverted (-1 vs +1)!
$fVsDirty = $tGfxDev.Fields | Where-Object { $_.Name -eq "_vertexShaderDirty" }
$fRastDirty = $tGfxDev.Fields | Where-Object { $_.Name -eq "_rasterizerStateDirty" }
if (-not $fVsDirty -or -not $fRastDirty) { throw "Missing _vertexShaderDirty or _rasterizerStateDirty in GraphicsDevice!" }
$posFixPatched = 0
foreach ($mName in @("PlatformApplyDefaultRenderTarget", "PlatformApplyRenderTargets")) {
    $rm = $tGfxDev.Methods | Where-Object { $_.Name -eq $mName } | Select-Object -First 1
    if (-not $rm) { throw "Missing GraphicsDevice.$mName!" }
    Expand-ShortBranches $rm
    $ril = $rm.Body.GetILProcessor()
    for ($i = 0; $i -lt $rm.Body.Instructions.Count; $i++) {
        if ($rm.Body.Instructions[$i].OpCode.Name -eq "stfld" -and $rm.Body.Instructions[$i].Operand -eq $fRastDirty) {
            $nextIns = $rm.Body.Instructions[$i + 1]
            $ril.InsertBefore($nextIns, $ril.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
            $ril.InsertBefore($nextIns, $ril.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_1))
            $ril.InsertBefore($nextIns, $ril.Create([Mono.Cecil.Cil.OpCodes]::Stfld, $fVsDirty))
            $posFixPatched++
            break
        }
    }
}
$mSetVp = $tGfxDev.Methods | Where-Object { $_.Name -eq "set_Viewport" } | Select-Object -First 1
if ($mSetVp) {
    $vpil = $mSetVp.Body.GetILProcessor()
    $vpRet = $mSetVp.Body.Instructions[$mSetVp.Body.Instructions.Count - 1]
    $vpil.InsertBefore($vpRet, $vpil.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
    $vpil.InsertBefore($vpRet, $vpil.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_1))
    $vpil.InsertBefore($vpRet, $vpil.Create([Mono.Cecil.Cil.OpCodes]::Stfld, $fVsDirty))
    $posFixPatched++
}
if ($posFixPatched -ne 3) { throw "Expected 3 posFixup invalidation sites, got $posFixPatched!" }
Write-Host "  iOS DynamicShader Fix #2 (MonoGame): Invalidated _vertexShaderDirty on RT/Viewport switches ($posFixPatched sites) so posFixup never goes stale!"

# 3.9 OpenGL ES 3.0 Core NPOT Capability Fix:
# GraphicsCapabilities.PlatformInitialize only checked GL_OES_texture_npot extension string,
# missing core OpenGL ES 3.0 NPOT support (device.glMajorVersion >= 3)!
$tGfxCap = $mgMod.GetType("Microsoft.Xna.Framework.Graphics.GraphicsCapabilities")
$mCapInit = if ($tGfxCap) { $tGfxCap.Methods | Where-Object { $_.Name -eq "PlatformInitialize" } | Select-Object -First 1 } else { $null }
$fGlMaj = $tGfxDev.Fields | Where-Object { $_.Name -eq "glMajorVersion" }
$mSetNpot = if ($tGfxCap) { $tGfxCap.Methods | Where-Object { $_.Name -eq "set_SupportsNonPowerOfTwo" } | Select-Object -First 1 } else { $null }
if ($mCapInit -and $fGlMaj -and $mSetNpot) {
    Expand-ShortBranches $mCapInit
    $cil2 = $mCapInit.Body.GetILProcessor()
    $npotPatched = $false
    for ($i = 0; $i -lt $mCapInit.Body.Instructions.Count; $i++) {
        if ($mCapInit.Body.Instructions[$i].OpCode.Name -eq "call" -and $mCapInit.Body.Instructions[$i].Operand -eq $mSetNpot) {
            $afterNpot = $mCapInit.Body.Instructions[$i + 1]
            $cil2.InsertBefore($afterNpot, $cil2.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_1))
            $cil2.InsertBefore($afterNpot, $cil2.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $fGlMaj))
            $cil2.InsertBefore($afterNpot, $cil2.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_3))
            $cil2.InsertBefore($afterNpot, $cil2.Create([Mono.Cecil.Cil.OpCodes]::Blt, $afterNpot))
            $cil2.InsertBefore($afterNpot, $cil2.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
            $cil2.InsertBefore($afterNpot, $cil2.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_1))
            $cil2.InsertBefore($afterNpot, $cil2.Create([Mono.Cecil.Cil.OpCodes]::Call, $mSetNpot))
            $npotPatched = $true
            break
        }
    }
    if (-not $npotPatched) { throw "Failed to patch SupportsNonPowerOfTwo in GraphicsCapabilities.PlatformInitialize!" }
    Write-Host "  iOS DynamicShader Fix #3 (MonoGame): Enabled SupportsNonPowerOfTwo for OpenGL ES 3.0+!"
}

# 3.10 Fix BOTH vanilla/modded audio playback AND SVE Data/AudioChanges NullReferenceException:
# - SoundBank.Exists(string) must check _sounds.TryGetValue(name, out _) instead of returning hardcoded false (which mutes ALL game audio!).
# - SoundBank.GetCueDefinition(string) must return a non-null CueDefinition { name = name } so AudioCueModificationManager never throws NRE!
$tSoundBank = $mgMod.GetType("Microsoft.Xna.Framework.Audio.SoundBank")
if ($tSoundBank) {
    $fSbSounds = $tSoundBank.Fields | Where-Object { $_.Name -eq "_sounds" } | Select-Object -First 1
    $mSbPlayCue = $tSoundBank.Methods | Where-Object { $_.Name -eq "PlayCue" -and $_.Parameters.Count -eq 1 } | Select-Object -First 1
    $mSbExists = $tSoundBank.Methods | Where-Object { $_.Name -eq "Exists" -and $_.Parameters.Count -eq 1 } | Select-Object -First 1
    if ($fSbSounds -and $mSbPlayCue -and $mSbExists -and $mSbExists.HasBody) {
        $mIsNullOrEmpty = ($mSbPlayCue.Body.Instructions | Where-Object { $_.Operand -and $_.Operand.ToString().Contains("IsNullOrEmpty") } | Select-Object -First 1).Operand
        $mTryGetValue = ($mSbPlayCue.Body.Instructions | Where-Object { $_.Operand -and $_.Operand.ToString().Contains("TryGetValue") -and $_.Operand.ToString().Contains("XactSound") } | Select-Object -First 1).Operand
        if ($mIsNullOrEmpty -and $mTryGetValue) {
            $tXactArr = ($fSbSounds.FieldType -as [Mono.Cecil.GenericInstanceType]).GenericArguments[1]
            $mSbExists.Body.Variables.Clear()
            $mSbExists.Body.ExceptionHandlers.Clear()
            $mSbExists.Body.Instructions.Clear()
            $mSbExists.Body.InitLocals = $true
            $vDummy = New-Object Mono.Cecil.Cil.VariableDefinition($tXactArr)
            $mSbExists.Body.Variables.Add($vDummy)
            $ilSb = $mSbExists.Body.GetILProcessor()
            $lblFalse = $ilSb.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0)
            $ilSb.Append($ilSb.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_1))
            $ilSb.Append($ilSb.Create([Mono.Cecil.Cil.OpCodes]::Call, [Mono.Cecil.MethodReference]$mIsNullOrEmpty))
            $ilSb.Append($ilSb.Create([Mono.Cecil.Cil.OpCodes]::Brtrue_S, $lblFalse))
            $ilSb.Append($ilSb.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
            $ilSb.Append($ilSb.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $fSbSounds))
            $ilSb.Append($ilSb.Create([Mono.Cecil.Cil.OpCodes]::Brfalse_S, $lblFalse))
            $ilSb.Append($ilSb.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
            $ilSb.Append($ilSb.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $fSbSounds))
            $ilSb.Append($ilSb.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_1))
            $ilSb.Append($ilSb.Create([Mono.Cecil.Cil.OpCodes]::Ldloca_S, $vDummy))
            $ilSb.Append($ilSb.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, [Mono.Cecil.MethodReference]$mTryGetValue))
            $ilSb.Append($ilSb.Create([Mono.Cecil.Cil.OpCodes]::Ret))
            $ilSb.Append($lblFalse)
            $ilSb.Append($ilSb.Create([Mono.Cecil.Cil.OpCodes]::Ret))
            Write-Host "  iOS Audio Fix (MonoGame): SoundBank.Exists now checks _sounds.TryGetValue (full audio + music restored)!"
        }
    }
    $tCueDef = $mgMod.GetType("Microsoft.Xna.Framework.Audio.CueDefinition")
    $mSbGetCueDef = $tSoundBank.Methods | Where-Object { $_.Name -eq "GetCueDefinition" -and $_.Parameters.Count -eq 1 } | Select-Object -First 1
    if ($tCueDef -and $mSbGetCueDef -and $mSbGetCueDef.HasBody) {
        $mCdCtor = $tCueDef.Methods | Where-Object { $_.Name -eq ".ctor" -and $_.Parameters.Count -eq 0 } | Select-Object -First 1
        $fCdName = $tCueDef.Fields | Where-Object { $_.Name -eq "name" } | Select-Object -First 1
        if ($mCdCtor -and $fCdName) {
            $mSbGetCueDef.Body.Variables.Clear()
            $mSbGetCueDef.Body.ExceptionHandlers.Clear()
            $mSbGetCueDef.Body.Instructions.Clear()
            $ilCd = $mSbGetCueDef.Body.GetILProcessor()
            $ilCd.Append($ilCd.Create([Mono.Cecil.Cil.OpCodes]::Newobj, $mCdCtor))
            $ilCd.Append($ilCd.Create([Mono.Cecil.Cil.OpCodes]::Dup))
            $ilCd.Append($ilCd.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_1))
            $ilCd.Append($ilCd.Create([Mono.Cecil.Cil.OpCodes]::Stfld, $fCdName))
            $ilCd.Append($ilCd.Create([Mono.Cecil.Cil.OpCodes]::Ret))
            Write-Host "  iOS AudioChanges Fix (MonoGame): SoundBank.GetCueDefinition now returns valid CueDefinition (fixes SVE NRE without muting audio)!"
        }
    }
}

# 3.11 Add missing PC Stardew CueDefinition members required by UI Info Suite 2 v2.3.7+ (SoundHelper.RegisterSound):
#      CueDefinition.LimitBehavior, instanceLimit, limitBehavior, SetSound(SoundEffect, int, bool, bool), and 5-arg .ctors!
$cd = $mgMod.GetType("Microsoft.Xna.Framework.Audio.CueDefinition")
if (-not $cd) { throw "CueDefinition not found in MonoGame.Framework.dll!" }
$tInt32 = $mgMod.TypeSystem.Int32
$tBool  = $mgMod.TypeSystem.Boolean
$tVoid  = $mgMod.TypeSystem.Void
$tStr   = $mgMod.TypeSystem.String
$tEnum  = ($mgMod.Types | Where-Object { $_.IsEnum } | Select-Object -First 1).BaseType
$tSoundEffect = $mgMod.GetType("Microsoft.Xna.Framework.Audio.SoundEffect")
$tSoundEffectArr = New-Object Mono.Cecil.ArrayType($tSoundEffect)

$lb = $cd.NestedTypes | Where-Object { $_.Name -eq "LimitBehavior" } | Select-Object -First 1
if (-not $lb) {
    $enumAttrs = [Mono.Cecil.TypeAttributes]([int][Mono.Cecil.TypeAttributes]::NestedPublic -bor [int][Mono.Cecil.TypeAttributes]::Sealed)
    $lb = New-Object Mono.Cecil.TypeDefinition("", "LimitBehavior", $enumAttrs, $tEnum)
    $valAttrs = [Mono.Cecil.FieldAttributes]([int][Mono.Cecil.FieldAttributes]::Public -bor [int][Mono.Cecil.FieldAttributes]::SpecialName -bor [int][Mono.Cecil.FieldAttributes]::RTSpecialName)
    $lb.Fields.Add((New-Object Mono.Cecil.FieldDefinition("value__", $valAttrs, $tInt32)))
    $constAttrs = [Mono.Cecil.FieldAttributes]([int][Mono.Cecil.FieldAttributes]::Public -bor [int][Mono.Cecil.FieldAttributes]::Static -bor [int][Mono.Cecil.FieldAttributes]::Literal -bor [int][Mono.Cecil.FieldAttributes]::HasDefault)
    foreach ($kv in @(
        @("FailToPlay", 0),
        @("Queue", 1),
        @("ReplaceOldest", 2),
        @("ReplaceLowestPriority", 3),
        @("ReplaceQuiet", 4)
    )) {
        $ef = New-Object Mono.Cecil.FieldDefinition($kv[0], $constAttrs, $lb)
        $ef.Constant = [int]$kv[1]
        $lb.Fields.Add($ef)
    }
    $cd.NestedTypes.Add($lb)
}
if (-not ($cd.Fields | Where-Object { $_.Name -eq "instanceLimit" })) {
    $cd.Fields.Add((New-Object Mono.Cecil.FieldDefinition("instanceLimit", [Mono.Cecil.FieldAttributes]::Public, $tInt32)))
}
if (-not ($cd.Fields | Where-Object { $_.Name -eq "limitBehavior" })) {
    $cd.Fields.Add((New-Object Mono.Cecil.FieldDefinition("limitBehavior", [Mono.Cecil.FieldAttributes]::Public, $lb)))
}
$optParam = [Mono.Cecil.ParameterAttributes]([int][Mono.Cecil.ParameterAttributes]::Optional -bor [int][Mono.Cecil.ParameterAttributes]::HasDefault)
$arrSetSound = $cd.Methods | Where-Object {
    $_.Name -eq "SetSound" -and $_.Parameters.Count -eq 4 -and $_.Parameters[0].ParameterType.FullName -eq "Microsoft.Xna.Framework.Audio.SoundEffect[]"
} | Select-Object -First 1
$singleSetSound = $cd.Methods | Where-Object {
    $_.Name -eq "SetSound" -and $_.Parameters.Count -eq 4 -and $_.Parameters[0].ParameterType.FullName -eq "Microsoft.Xna.Framework.Audio.SoundEffect"
} | Select-Object -First 1
if (-not $singleSetSound) {
    $mAttrs = [Mono.Cecil.MethodAttributes]([int][Mono.Cecil.MethodAttributes]::Public -bor [int][Mono.Cecil.MethodAttributes]::HideBySig)
    $mSet = New-Object Mono.Cecil.MethodDefinition("SetSound", $mAttrs, $tVoid)
    $mSet.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition("sound_effect", [Mono.Cecil.ParameterAttributes]::None, $tSoundEffect)))
    $mSet.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition("category_id", [Mono.Cecil.ParameterAttributes]::None, $tInt32)))
    $pLoop = New-Object Mono.Cecil.ParameterDefinition("loop", $optParam, $tBool); $pLoop.Constant = $false; $mSet.Parameters.Add($pLoop)
    $pRev  = New-Object Mono.Cecil.ParameterDefinition("use_reverb", $optParam, $tBool); $pRev.Constant = $false; $mSet.Parameters.Add($pRev)
    $ilSet = $mSet.Body.GetILProcessor()
    if ($arrSetSound) {
        $ilSet.Append($ilSet.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
        $ilSet.Append($ilSet.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_1))
        $ilSet.Append($ilSet.Create([Mono.Cecil.Cil.OpCodes]::Newarr, $tSoundEffect))
        $ilSet.Append($ilSet.Create([Mono.Cecil.Cil.OpCodes]::Dup))
        $ilSet.Append($ilSet.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0))
        $ilSet.Append($ilSet.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_1))
        $ilSet.Append($ilSet.Create([Mono.Cecil.Cil.OpCodes]::Stelem_Ref))
        $ilSet.Append($ilSet.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_2))
        $ilSet.Append($ilSet.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_3))
        $ilSet.Append($ilSet.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_S, $pRev))
        $ilSet.Append($ilSet.Create([Mono.Cecil.Cil.OpCodes]::Call, [Mono.Cecil.MethodReference]$arrSetSound))
    }
    $ilSet.Append($ilSet.Create([Mono.Cecil.Cil.OpCodes]::Ret))
    $cd.Methods.Add($mSet)
    $singleSetSound = $mSet
}
$defCtor = $cd.Methods | Where-Object { $_.Name -eq ".ctor" -and $_.Parameters.Count -eq 0 } | Select-Object -First 1
$objCtor = ($defCtor.Body.Instructions | Where-Object { $_.OpCode -eq [Mono.Cecil.Cil.OpCodes]::Call } | Select-Object -First 1).Operand
$fName   = $cd.Fields | Where-Object { $_.Name -eq "name" } | Select-Object -First 1
foreach ($sndType in @($tSoundEffect, $tSoundEffectArr)) {
    $exists = $cd.Methods | Where-Object {
        $_.Name -eq ".ctor" -and $_.Parameters.Count -eq 5 -and $_.Parameters[1].ParameterType.FullName -eq $sndType.FullName
    }
    if (-not $exists) {
        $cAttrs = [Mono.Cecil.MethodAttributes]([int][Mono.Cecil.MethodAttributes]::Public -bor [int][Mono.Cecil.MethodAttributes]::HideBySig -bor [int][Mono.Cecil.MethodAttributes]::SpecialName -bor [int][Mono.Cecil.MethodAttributes]::RTSpecialName)
        $ctor = New-Object Mono.Cecil.MethodDefinition(".ctor", $cAttrs, $tVoid)
        $ctor.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition("new_name", [Mono.Cecil.ParameterAttributes]::None, $tStr)))
        $ctor.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition("sound_effect", [Mono.Cecil.ParameterAttributes]::None, $sndType)))
        $ctor.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition("category_id", [Mono.Cecil.ParameterAttributes]::None, $tInt32)))
        $pL = New-Object Mono.Cecil.ParameterDefinition("loop", $optParam, $tBool); $pL.Constant = $false; $ctor.Parameters.Add($pL)
        $pR = New-Object Mono.Cecil.ParameterDefinition("use_reverb", $optParam, $tBool); $pR.Constant = $false; $ctor.Parameters.Add($pR)
        $cilC = $ctor.Body.GetILProcessor()
        $cilC.Append($cilC.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
        $cilC.Append($cilC.Create([Mono.Cecil.Cil.OpCodes]::Call, [Mono.Cecil.MethodReference]$objCtor))
        $cilC.Append($cilC.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
        $cilC.Append($cilC.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_1))
        $cilC.Append($cilC.Create([Mono.Cecil.Cil.OpCodes]::Stfld, $fName))
        $targetSet = if ($sndType -eq $tSoundEffect) { $singleSetSound } else { $arrSetSound }
        if ($targetSet) {
            $cilC.Append($cilC.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
            $cilC.Append($cilC.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_2))
            $cilC.Append($cilC.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_3))
            $cilC.Append($cilC.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_S, $pL))
            $cilC.Append($cilC.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_S, $pR))
            $cilC.Append($cilC.Create([Mono.Cecil.Cil.OpCodes]::Call, [Mono.Cecil.MethodReference]$targetSet))
        }
        $cilC.Append($cilC.Create([Mono.Cecil.Cil.OpCodes]::Ret))
        $cd.Methods.Add($ctor)
    }
}
Write-Host "  iOS UI Info Suite 2 Audio Fix (MonoGame): CueDefinition(LimitBehavior, instanceLimit, limitBehavior, SetSound, 5-arg .ctors) added!"

# 3.11b Full Custom SoundEffect Playback for SoundBank.AddCue + CueDefinition.SetSound + XactSound.Play!
#       Fixes UI Info Suite 2 v2.3.7+ SoundHelper.RegisterSound ArgumentException & custom mod audio cues!
$tXactSound = $mgMod.GetType("Microsoft.Xna.Framework.Audio.XactSound")
$tSeInst    = $mgMod.GetType("Microsoft.Xna.Framework.Audio.SoundEffectInstance")
$tAudioEng  = $mgMod.GetType("Microsoft.Xna.Framework.Audio.AudioEngine")
if ($tXactSound -and $tSeInst -and $tAudioEng -and $tSoundBank -and $cd -and $arrSetSound) {
    $fCdEffects = New-Object Mono.Cecil.FieldDefinition("_customEffects",    [Mono.Cecil.FieldAttributes]::Public, $tSoundEffectArr)
    $fCdCatId   = New-Object Mono.Cecil.FieldDefinition("_customCategoryId", [Mono.Cecil.FieldAttributes]::Public, $tInt32)
    $fCdLoop    = New-Object Mono.Cecil.FieldDefinition("_customLoop",       [Mono.Cecil.FieldAttributes]::Public, $tBool)
    $fCdReverb  = New-Object Mono.Cecil.FieldDefinition("_customReverb",     [Mono.Cecil.FieldAttributes]::Public, $tBool)
    foreach ($cf in @($fCdEffects, $fCdCatId, $fCdLoop, $fCdReverb)) { $cd.Fields.Add($cf) }

    # Populate CueDefinition._custom* fields inside SetSound(SoundEffect[], int, bool, bool)
    $arrSetSound.Body.Variables.Clear()
    $arrSetSound.Body.ExceptionHandlers.Clear()
    $arrSetSound.Body.Instructions.Clear()
    $asIL = $arrSetSound.Body.GetILProcessor()
    $asIL.Append($asIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
    $asIL.Append($asIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_1))
    $asIL.Append($asIL.Create([Mono.Cecil.Cil.OpCodes]::Stfld, $fCdEffects))
    $asIL.Append($asIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
    $asIL.Append($asIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_2))
    $asIL.Append($asIL.Create([Mono.Cecil.Cil.OpCodes]::Stfld, $fCdCatId))
    $asIL.Append($asIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
    $asIL.Append($asIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_3))
    $asIL.Append($asIL.Create([Mono.Cecil.Cil.OpCodes]::Stfld, $fCdLoop))
    $asIL.Append($asIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
    $asIL.Append($asIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_S, $arrSetSound.Parameters[3]))
    $asIL.Append($asIL.Create([Mono.Cecil.Cil.OpCodes]::Stfld, $fCdReverb))
    $asIL.Append($asIL.Create([Mono.Cecil.Cil.OpCodes]::Ret))

    # Add _customEffect & _customLoop on XactSound and patch XactSound.Play
    $fXsCustEff   = New-Object Mono.Cecil.FieldDefinition("_customEffect", [Mono.Cecil.FieldAttributes]::Public, $tSoundEffect)
    $fXsCustLoop  = New-Object Mono.Cecil.FieldDefinition("_customLoop",   [Mono.Cecil.FieldAttributes]::Public, $tBool)
    $tXactSound.Fields.Add($fXsCustEff)
    $tXactSound.Fields.Add($fXsCustLoop)

    $fXsVol       = $tXactSound.Fields | Where-Object { $_.Name -eq "_volume" }
    $fXsCueVol    = $tXactSound.Fields | Where-Object { $_.Name -eq "_cueVolume" }
    $fXsCatId     = $tXactSound.Fields | Where-Object { $_.Name -eq "_categoryID" }
    $fXsReverb    = $tXactSound.Fields | Where-Object { $_.Name -eq "_useReverb" }
    $fXsWave      = $tXactSound.Fields | Where-Object { $_.Name -eq "_wave" }
    $fXsStreaming = $tXactSound.Fields | Where-Object { $_.Name -eq "_streaming" }
    $fXsSoundBank = $tXactSound.Fields | Where-Object { $_.Name -eq "_soundBank" }
    # Promote private/initonly XactSound fields written by SoundBank.AddCue so Mono .NET 8 never throws FieldAccessException!
    foreach ($pf in @($fXsVol, $fXsCueVol, $fXsReverb)) {
        if ($pf) { $pf.IsPrivate = $false; $pf.IsAssembly = $true; $pf.IsInitOnly = $false }
    }
    if ($fXsCatId) { $fXsCatId.IsInitOnly = $false }
    $mXsCtor3     = $tXactSound.Methods | Where-Object { $_.Name -eq ".ctor" -and $_.Parameters.Count -eq 3 -and $_.Parameters[1].ParameterType.Name -eq "Int32" } | Select-Object -First 1
    $mXsPlay      = $tXactSound.Methods | Where-Object { $_.Name -eq "Play" -and $_.Parameters.Count -eq 2 } | Select-Object -First 1
    $mSeCreate    = $tSoundEffect.Methods | Where-Object { $_.Name -eq "CreateInstance" -and $_.Parameters.Count -eq 0 } | Select-Object -First 1
    $mSeiSetLoop  = $tSeInst.Methods | Where-Object { $_.Name -eq "set_IsLooped" -and $_.Parameters.Count -eq 1 } | Select-Object -First 1
    $mAeGetCats   = $tAudioEng.Methods | Where-Object { $_.Name -eq "get_Categories" } | Select-Object -First 1

    Expand-ShortBranches $mXsPlay
    $xpIL = $mXsPlay.Body.GetILProcessor()
    $vCats = New-Object Mono.Cecil.Cil.VariableDefinition($mAeGetCats.ReturnType)
    $mXsPlay.Body.Variables.Add($vCats)
    $mXsPlay.Body.InitLocals = $true

    # 1) Clamp _categoryID against AudioEngine.Categories.Length in XactSound.Play
    $catAnchor = $null
    foreach ($ins in $mXsPlay.Body.Instructions) {
        if ($ins.OpCode.Name -eq "ldarg.2") { $catAnchor = $ins; break }
    }
    $xpEarlyRet = $mXsPlay.Body.Instructions[$mXsPlay.Body.Instructions.Count - 1]
    foreach ($ins in @(
        $xpIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_2),
        $xpIL.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $xpEarlyRet),
        $xpIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_2),
        $xpIL.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mAeGetCats),
        $xpIL.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vCats),
        $xpIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vCats),
        $xpIL.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $xpEarlyRet),
        $xpIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vCats),
        $xpIL.Create([Mono.Cecil.Cil.OpCodes]::Ldlen),
        $xpIL.Create([Mono.Cecil.Cil.OpCodes]::Conv_I4),
        $xpIL.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0),
        $xpIL.Create([Mono.Cecil.Cil.OpCodes]::Ble, $xpEarlyRet),
        $xpIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0),
        $xpIL.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $fXsCatId),
        $xpIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vCats),
        $xpIL.Create([Mono.Cecil.Cil.OpCodes]::Ldlen),
        $xpIL.Create([Mono.Cecil.Cil.OpCodes]::Conv_U4),
        $xpIL.Create([Mono.Cecil.Cil.OpCodes]::Blt_Un, $catAnchor),
        $xpIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0),
        $xpIL.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0),
        $xpIL.Create([Mono.Cecil.Cil.OpCodes]::Stfld, $fXsCatId)
    )) { $xpIL.InsertBefore($catAnchor, $ins) }

    # 2) Instantiate SoundEffectInstance from _customEffect (with _streaming=true for auto-Dispose!) when _customEffect != null
    $waveAssignStart = $null; $afterWaveStfld = $null
    for ($i = 2; $i -lt ($mXsPlay.Body.Instructions.Count - 3); $i++) {
        if ($mXsPlay.Body.Instructions[$i].OpCode.Name -eq "ldfld" -and $mXsPlay.Body.Instructions[$i].Operand -eq $fXsSoundBank) {
            $waveAssignStart = $mXsPlay.Body.Instructions[$i - 2]
            for ($j = $i + 1; $j -lt $mXsPlay.Body.Instructions.Count; $j++) {
                if ($mXsPlay.Body.Instructions[$j].OpCode.Name -eq "stfld" -and $mXsPlay.Body.Instructions[$j].Operand -eq $fXsWave) {
                    $afterWaveStfld = $mXsPlay.Body.Instructions[$j + 1]
                    break
                }
            }
            break
        }
    }
    if (-not $waveAssignStart -or -not $afterWaveStfld) { throw "Could not locate _soundBank.GetSoundEffectInstance block in XactSound.Play!" }
    $custChk0 = $xpIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0)
    $custSeq = @(
        $custChk0,
        $xpIL.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $fXsCustEff),
        $xpIL.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $waveAssignStart),
        $xpIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0),
        $xpIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0),
        $xpIL.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $fXsCustEff),
        $xpIL.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mSeCreate),
        $xpIL.Create([Mono.Cecil.Cil.OpCodes]::Stfld, $fXsWave),
        $xpIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0),
        $xpIL.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $fXsWave),
        $xpIL.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $afterWaveStfld),
        $xpIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0),
        $xpIL.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $fXsWave),
        $xpIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0),
        $xpIL.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $fXsCustLoop),
        $xpIL.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mSeiSetLoop),
        $xpIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0),
        $xpIL.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_1),
        $xpIL.Create([Mono.Cecil.Cil.OpCodes]::Stfld, $fXsStreaming),
        $xpIL.Create([Mono.Cecil.Cil.OpCodes]::Br, $afterWaveStfld)
    )
    foreach ($ins in $custSeq) { $xpIL.InsertBefore($waveAssignStart, $ins) }
    foreach ($bIns in $mXsPlay.Body.Instructions) {
        if ($bIns -ne $custSeq[2] -and $bIns.Operand -eq $waveAssignStart) {
            $bIns.Operand = $custChk0
        }
    }

    # 3) Implement SoundBank.AddCue(CueDefinition cue_definition)
    $mSbAddCue = $tSoundBank.Methods | Where-Object { $_.Name -eq "AddCue" -and $_.Parameters.Count -eq 1 } | Select-Object -First 1
    $fSbProbs  = $tSoundBank.Fields  | Where-Object { $_.Name -eq "_probabilities" } | Select-Object -First 1
    $mIsNullOrEmptySb = Find-Ref $mgMod "System.Boolean System.String::IsNullOrEmpty(System.String)"
    if ($mSbAddCue -and $fSbSounds -and $fSbProbs -and $mIsNullOrEmptySb) {
        $gitSounds = [Mono.Cecil.GenericInstanceType]$fSbSounds.FieldType
        $openDict  = $gitSounds.ElementType
        $mSetSoundsItem = New-Object Mono.Cecil.MethodReference("set_Item", $tVoid, $gitSounds)
        $mSetSoundsItem.HasThis = $true
        $mSetSoundsItem.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition($openDict.GenericParameters[0])))
        $mSetSoundsItem.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition($openDict.GenericParameters[1])))

        $gitProbs = [Mono.Cecil.GenericInstanceType]$fSbProbs.FieldType
        $mSetProbsItem = New-Object Mono.Cecil.MethodReference("set_Item", $tVoid, $gitProbs)
        $mSetProbsItem.HasThis = $true
        $mSetProbsItem.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition($openDict.GenericParameters[0])))
        $mSetProbsItem.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition($openDict.GenericParameters[1])))

        $tXsArr    = New-Object Mono.Cecil.ArrayType($tXactSound)
        $tFloatArr = New-Object Mono.Cecil.ArrayType($mgMod.TypeSystem.Single)

        $mSbAddCue.Body.Variables.Clear()
        $mSbAddCue.Body.ExceptionHandlers.Clear()
        $mSbAddCue.Body.Instructions.Clear()
        $mSbAddCue.Body.InitLocals = $true
        $mSbAddCue.Body.MaxStackSize = 8

        $vEffs  = New-Object Mono.Cecil.Cil.VariableDefinition($tSoundEffectArr)
        $vCount = New-Object Mono.Cecil.Cil.VariableDefinition($tInt32)
        $vCatU  = New-Object Mono.Cecil.Cil.VariableDefinition($mgMod.TypeSystem.UInt32)
        $vXsArr = New-Object Mono.Cecil.Cil.VariableDefinition($tXsArr)
        $vPrArr = New-Object Mono.Cecil.Cil.VariableDefinition($tFloatArr)
        $vProb  = New-Object Mono.Cecil.Cil.VariableDefinition($mgMod.TypeSystem.Single)
        $vIdx   = New-Object Mono.Cecil.Cil.VariableDefinition($tInt32)
        $vSe    = New-Object Mono.Cecil.Cil.VariableDefinition($tSoundEffect)
        $vXs    = New-Object Mono.Cecil.Cil.VariableDefinition($tXactSound)
        foreach ($vv in @($vEffs, $vCount, $vCatU, $vXsArr, $vPrArr, $vProb, $vIdx, $vSe, $vXs)) { $mSbAddCue.Body.Variables.Add($vv) }

        $acIL = $mSbAddCue.Body.GetILProcessor()
        $lAcRet      = $acIL.Create([Mono.Cecil.Cil.OpCodes]::Ret)
        $lCatPos     = $acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_1)
        $lAfterCat   = $acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vCount)
        $lLoopBody   = $acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vEffs)
        $lLoopCheck  = $acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vIdx)

        # Validate cue_definition, name, _customEffects, _sounds, _probabilities
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_1))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $lAcRet))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_1))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $fName))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Call, $mIsNullOrEmptySb))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Brtrue, $lAcRet))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $fSbSounds))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $lAcRet))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $fSbProbs))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $lAcRet))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_1))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $fCdEffects))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vEffs))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vEffs))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $lAcRet))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vEffs))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldlen))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Conv_I4))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vCount))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vCount))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ble, $lAcRet))

        # uint catU = cue_definition._customCategoryId < 0 ? 0u : (uint)cue_definition._customCategoryId
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_1))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $fCdCatId))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Bge, $lCatPos))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vCatU))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Br, $lAfterCat))
        $acIL.Append($lCatPos)
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $fCdCatId))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Conv_U4))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vCatU))

        # Allocate XactSound[count] and float[count]
        $acIL.Append($lAfterCat)
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Newarr, $tXactSound))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vXsArr))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vCount))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Newarr, $mgMod.TypeSystem.Single))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vPrArr))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldc_R4, [float]1.0))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vCount))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Conv_R4))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Div))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vProb))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vIdx))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Br, $lLoopCheck))

        $acIL.Append($lLoopBody)
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vIdx))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldelem_Ref))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vSe))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vSe))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $lAcRet))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Newobj, $mXsCtor3))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vXs))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vXs))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldc_R4, [float]1.0))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Stfld, $fXsVol))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vXs))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldc_R4, [float]1.0))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Stfld, $fXsCueVol))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vXs))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vCatU))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Stfld, $fXsCatId))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vXs))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_1))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $fCdReverb))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Stfld, $fXsReverb))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vXs))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vSe))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Stfld, $fXsCustEff))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vXs))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_1))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $fCdLoop))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Stfld, $fXsCustLoop))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vXsArr))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vIdx))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vXs))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Stelem_Ref))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vPrArr))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vIdx))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vProb))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Stelem_R4))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vIdx))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_1))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Add))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vIdx))

        $acIL.Append($lLoopCheck)
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vCount))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Blt, $lLoopBody))

        # _sounds[name] = xsArr; _probabilities[name] = prArr;
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $fSbSounds))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_1))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $fName))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vXsArr))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mSetSoundsItem))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $fSbProbs))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_1))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $fName))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vPrArr))
        $acIL.Append($acIL.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mSetProbsItem))
        $acIL.Append($lAcRet)
        Write-Host "  iOS Custom SoundBank Fix (MonoGame): SoundBank.AddCue + CueDefinition.SetSound + XactSound custom playback active!"
    }
}

# 3.12 Direct IL Hook GamePad.ExternalGetStateHook (Func<int, GamePadState>) in GamePad.PlatformGetState:
#      Feeds physical Xbox/DualSense/Switch/MFi controller state directly into SMAPI SInputState.TrueUpdate() on 0% JIT!
$tGamePad = $mgMod.GetType("Microsoft.Xna.Framework.Input.GamePad")
$tGpState = $mgMod.GetType("Microsoft.Xna.Framework.Input.GamePadState")
$mPlatGpState = if ($tGamePad) { $tGamePad.Methods | Where-Object { $_.Name -eq "PlatformGetState" -and $_.Parameters.Count -eq 3 } | Select-Object -First 1 } else { $null }
$mGpIsConn = if ($tGpState) { $tGpState.Methods | Where-Object { $_.Name -eq "get_IsConnected" } | Select-Object -First 1 } else { $null }
if (-not $tGamePad -or -not $tGpState -or -not $mPlatGpState -or -not $mGpIsConn) {
    throw "Missing GamePad.PlatformGetState or GamePadState.get_IsConnected in MonoGame.Framework.dll!"
}
$mgCoreScope = $mgMod.TypeSystem.Object.Scope
$mgFunc2Ref = New-Object Mono.Cecil.TypeReference("System", "Func``2", $mgMod, $mgCoreScope, $false)
$mgFunc2Ref.GenericParameters.Add((New-Object Mono.Cecil.GenericParameter("T", $mgFunc2Ref)))
$mgFunc2Ref.GenericParameters.Add((New-Object Mono.Cecil.GenericParameter("TResult", $mgFunc2Ref)))
$mgFuncIntGp = New-Object Mono.Cecil.GenericInstanceType($mgFunc2Ref)
$mgFuncIntGp.GenericArguments.Add($mgMod.TypeSystem.Int32)
$mgFuncIntGp.GenericArguments.Add($tGpState)
$fExtGpHook = New-Object Mono.Cecil.FieldDefinition("ExternalGetStateHook", [Mono.Cecil.FieldAttributes]"Public, Static", $mgFuncIntGp)
$tGamePad.Fields.Add($fExtGpHook)
$mExtGpInvoke = New-Object Mono.Cecil.MethodReference("Invoke", $mgFunc2Ref.GenericParameters[1], $mgFuncIntGp)
$mExtGpInvoke.HasThis = $true
$mExtGpInvoke.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition($mgFunc2Ref.GenericParameters[0])))

Expand-ShortBranches $mPlatGpState
$vHookGp = New-Object Mono.Cecil.Cil.VariableDefinition($tGpState)
$mPlatGpState.Body.Variables.Add($vHookGp)
$mPlatGpState.Body.InitLocals = $true
$gpIL = $mPlatGpState.Body.GetILProcessor()
$gp0 = $mPlatGpState.Body.Instructions[0]
foreach ($ins in @(
    $gpIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0),
    $gpIL.Create([Mono.Cecil.Cil.OpCodes]::Brtrue, $gp0),
    $gpIL.Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $fExtGpHook),
    $gpIL.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $gp0),
    $gpIL.Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $fExtGpHook),
    $gpIL.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0),
    $gpIL.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $mExtGpInvoke),
    $gpIL.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vHookGp),
    $gpIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloca, $vHookGp),
    $gpIL.Create([Mono.Cecil.Cil.OpCodes]::Call, $mGpIsConn),
    $gpIL.Create([Mono.Cecil.Cil.OpCodes]::Brfalse, $gp0),
    $gpIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vHookGp),
    $gpIL.Create([Mono.Cecil.Cil.OpCodes]::Ret)
)) { $gpIL.InsertBefore($gp0, $ins) }
Write-Host "  iOS 0% JIT GamePad Fix (MonoGame): Injected GamePad.ExternalGetStateHook into PlatformGetState!"

# 3.13 iOS CADisplayLink 60Hz VSync Frame-Pacing Snap in Microsoft.Xna.Framework.Game.Tick():
#      Eliminates main-thread spin-wait / Thread.Sleep(1) and 2x-DoUpdate movement judder when iOS CADisplayLink fires
#      up to 2.0ms early (e.g. 16.2-16.6ms < 16.6667ms TargetElapsedTime). Keeps exact 60.0Hz logic speed!
$tMgGame = $mgMod.GetType("Microsoft.Xna.Framework.Game")
$mMgTick = if ($tMgGame) { $tMgGame.Methods | Where-Object { $_.Name -eq "Tick" -and $_.Parameters.Count -eq 0 -and $_.HasBody } | Select-Object -First 1 } else { $null }
$fAccum  = if ($tMgGame) { $tMgGame.Fields  | Where-Object { $_.Name -eq "_accumulatedElapsedTime" } | Select-Object -First 1 } else { $null }
$mGetTet = if ($tMgGame) { $tMgGame.Methods | Where-Object { $_.Name -eq "get_TargetElapsedTime" } | Select-Object -First 1 } else { $null }
$mTsTicks = Find-Ref $mgMod "System.Int64 System.TimeSpan::get_Ticks()"
if (-not $mMgTick -or -not $fAccum -or -not $mGetTet -or -not $mTsTicks) {
    throw "Missing Game.Tick / _accumulatedElapsedTime / get_TargetElapsedTime / TimeSpan.get_Ticks!"
}
Expand-ShortBranches $mMgTick
$tkIns = $mMgTick.Body.Instructions
$vsyncAnchor = $null
for ($i = 0; $i -lt ($tkIns.Count - 4); $i++) {
    if ($tkIns[$i].OpCode.Name -eq "ldarg.0" -and
        $tkIns[$i+1].OpCode.Name -eq "ldfld" -and $tkIns[$i+1].Operand -eq $fAccum -and
        $tkIns[$i+2].OpCode.Name -eq "ldarg.0" -and
        $tkIns[$i+3].OpCode.Name -eq "call" -and $tkIns[$i+3].Operand -eq $mGetTet -and
        $tkIns[$i+4].OpCode.Name -eq "call" -and "$($tkIns[$i+4].Operand)" -like "*TimeSpan::op_LessThan*") {
        $vsyncAnchor = $tkIns[$i]
        break
    }
}
if (-not $vsyncAnchor) { throw "Could not locate _accumulatedElapsedTime < TargetElapsedTime check in Game.Tick()!" }
$vTmpTs   = New-Object Mono.Cecil.Cil.VariableDefinition($fAccum.FieldType)
$vDeficit = New-Object Mono.Cecil.Cil.VariableDefinition($mgMod.TypeSystem.Int64)
$mMgTick.Body.Variables.Add($vTmpTs)
$mMgTick.Body.Variables.Add($vDeficit)
$mMgTick.Body.InitLocals = $true
$tkIL = $mMgTick.Body.GetILProcessor()
$vsSeq = @(
    $tkIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0),
    $tkIL.Create([Mono.Cecil.Cil.OpCodes]::Call, $mGetTet),
    $tkIL.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vTmpTs),
    $tkIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloca, $vTmpTs),
    $tkIL.Create([Mono.Cecil.Cil.OpCodes]::Call, $mTsTicks),
    $tkIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0),
    $tkIL.Create([Mono.Cecil.Cil.OpCodes]::Ldflda, $fAccum),
    $tkIL.Create([Mono.Cecil.Cil.OpCodes]::Call, $mTsTicks),
    $tkIL.Create([Mono.Cecil.Cil.OpCodes]::Sub),
    $tkIL.Create([Mono.Cecil.Cil.OpCodes]::Stloc, $vDeficit),
    $tkIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vDeficit),
    $tkIL.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0),
    $tkIL.Create([Mono.Cecil.Cil.OpCodes]::Conv_I8),
    $tkIL.Create([Mono.Cecil.Cil.OpCodes]::Ble, $vsyncAnchor),
    $tkIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vDeficit),
    $tkIL.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4, [int]20000),
    $tkIL.Create([Mono.Cecil.Cil.OpCodes]::Conv_I8),
    $tkIL.Create([Mono.Cecil.Cil.OpCodes]::Bgt, $vsyncAnchor),
    $tkIL.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0),
    $tkIL.Create([Mono.Cecil.Cil.OpCodes]::Ldloc, $vTmpTs),
    $tkIL.Create([Mono.Cecil.Cil.OpCodes]::Stfld, $fAccum)
)
foreach ($ins in $vsSeq) { $tkIL.InsertBefore($vsyncAnchor, $ins) }
Write-Host "  iOS 60Hz VSync Smoothness Fix (MonoGame): Injected 2.0ms VSync frame-pacing snap in Game.Tick()!"

$mgAsm.Write($outMG)
$mgAsm.Dispose()
Verify-Assembly $outMG
Write-Host "ALL V7.8 (AUDIO + HOME BAR + MENU OPT + RAM SAVER) PATCHES COMPLETE!"
