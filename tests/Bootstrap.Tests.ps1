[CmdletBinding()]
param([string]$RepositoryRoot = "")

$ErrorActionPreference = "Stop"
$repoRoot = if ($RepositoryRoot) { $RepositoryRoot } else { Split-Path $PSScriptRoot -Parent }
$bootstrapPath = Join-Path $repoRoot "bootstrap.ps1"
$tokens = $null
$parseErrors = $null
$bootstrapAst = [Management.Automation.Language.Parser]::ParseFile($bootstrapPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw "Bootstrap parse failed: $parseErrors" }

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

# Load launcher functions without downloading tools or running active tests.
foreach ($definition in $bootstrapAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($definition.Extent.Text))
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("PC-Diagnose launcher 'quoted' [literal] " + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$BootstrapLogDir = $testRoot
$BootstrapLogPath = Join-Path $testRoot "bootstrap.log"
$script:MockPolicies = @{ MachinePolicy = "Undefined"; UserPolicy = "Undefined"; Effective = "Restricted" }
$TemporarySession = $false
$Branch = "main"
$BootstrapArguments = @{}

try {
    function Get-ExecutionPolicy {
        param([string]$Scope, [switch]$List)
        if ($List) {
            return [pscustomobject]@{ Scope = "Process"; ExecutionPolicy = $script:MockPolicies.Effective }
        }
        if ($Scope) { return $script:MockPolicies[$Scope] }
        return $script:MockPolicies.Effective
    }

    Assert-True ($null -eq (Get-BlockingScriptGroupPolicy)) "Local Restricted does not count as group policy"
    $script:MockPolicies.UserPolicy = "AllSigned"
    Assert-True ((Get-BlockingScriptGroupPolicy) -eq "UserPolicy: AllSigned") "UserPolicy AllSigned blocks a one-time start"
    $script:MockPolicies.MachinePolicy = "Restricted"
    Assert-True ((Get-BlockingScriptGroupPolicy) -eq "MachinePolicy: Restricted") "MachinePolicy takes precedence"
    $script:MockPolicies.MachinePolicy = "RemoteSigned"
    Assert-True ($null -eq (Get-BlockingScriptGroupPolicy)) "Permissive MachinePolicy takes precedence over restrictive UserPolicy"
    $script:MockPolicies.MachinePolicy = "Undefined"
    $script:MockPolicies.UserPolicy = "Restricted"
    $rejected = $false
    try { Start-TemporaryToolProcess -ScriptPath 'C:\unused.ps1' -ToolArguments @{} } catch {
        $rejected = $_.Exception.Message -match "UserPolicy: Restricted"
    }
    Assert-True $rejected "Blocking group policy is rejected before any process or runner is created"
    Assert-True (@(Get-ChildItem -LiteralPath $testRoot -Filter "run-once-*").Count -eq 0) "Group policy rejection leaves no runner files"

    $script:MockPolicies.UserPolicy = "Undefined"
    $script:Answers = New-Object 'System.Collections.Generic.Queue[string]'
    function Read-Host { param([string]$Prompt) return $script:Answers.Dequeue() }
    $script:Answers.Enqueue("2")
    $script:Answers.Enqueue("1")
    Assert-True (Read-TemporaryScriptPermission -ToolName "Fixture") "Policy overview returns to the choice and allows an explicit one-time start"
    $script:Answers.Enqueue("")
    Assert-True (-not (Read-TemporaryScriptPermission -ToolName "Fixture")) "Empty choice cancels without changing policy"

    $manifest = [pscustomobject]@{ tools = @([pscustomobject]@{ id="hardwarestability"; name="Fixture"; requiresAdmin=$false; dependencies=@("Common.psm1") }) }
    $script:Answers.Enqueue("f")
    Assert-True ((Select-ToolFromMenu -Manifest $manifest) -eq "script-permission") "F opens script permission instead of selecting a test"
    $script:Answers.Enqueue("1")
    Assert-True ((Select-ToolFromMenu -Manifest $manifest) -eq "hardwarestability") "Existing numbered selections stay unchanged"
    $script:Answers.Enqueue("0")
    Assert-True ((Select-ToolFromMenu -Manifest $manifest) -eq "exit") "Zero leaves the menu without selecting a test"
    $TemporarySession = $true
    $menuText = Show-ToolList -Manifest $manifest 6>&1 | Out-String
    Assert-True ($menuText -match "Temporaere Skriptfreigabe aktiv" -and $menuText -notmatch '\[F\]') "Temporary session shows active permission and does not offer another permission restart"
    $TemporarySession = $false

    # Cancel before inventory, downloads, or UAC can begin.
    $script:Answers.Enqueue("0")
    Invoke-RemoteTool -Manifest $manifest -SelectedTool "hardwarestability"
    Assert-True ($script:Answers.Count -eq 0) "Restricted policy offers cancellation before launching a stage"

    $manifest.tools[0] | Add-Member -NotePropertyName path -NotePropertyValue "scripts/diagnostics/HardwareStability.ps1"
    $manifest.tools[0].dependencies = @("lib/HardwareStability/Common.psm1", "config/HardwareStabilityTools.json")
    $script:MenuFixtureText = "# Harmless menu fixture"
    function Get-RepositoryFileText {
        param([string]$Path)
        if ($Path -eq "r") { return $script:MenuFixtureText }
        return "# Harmless launcher fixture: $Path"
    }
    function Start-TemporaryToolProcess {
        param([string]$ScriptPath, [hashtable]$ToolArguments, [switch]$RequiresAdmin)
        $script:CapturedLaunch = @{ ScriptPath=$ScriptPath; Arguments=$ToolArguments }
    }
    $originalTemp = $env:TEMP
    try {
        $env:TEMP = $testRoot
        $OutputRoot = Join-Path $testRoot "output"
        $Profile = "Standard"
        $Components = "RAM"
        $NoDownload = $true
        $HsDryRun = $true
        $SurfaceScanMaxBytes = [long]4294967296
        $script:Answers.Enqueue("1")
        Invoke-RemoteTool -Manifest $manifest -SelectedTool "hardwarestability"
        Assert-True ($script:Answers.Count -eq 0) "Numbered start offers one-time permission under Restricted"
        Assert-True ($script:CapturedLaunch.Arguments.Profile -eq "Standard" -and $script:CapturedLaunch.Arguments.Components -eq "RAM") "Selected profile and components reach the one-time process"
        Assert-True ($script:CapturedLaunch.Arguments.DryRun -and $script:CapturedLaunch.Arguments.NoDownload) "DryRun and NoDownload reach the one-time process"
        Assert-True ($script:CapturedLaunch.Arguments.SurfaceScanMaxBytes -eq $SurfaceScanMaxBytes) "Surface limit reaches the one-time process"
        Assert-True (Test-Path -LiteralPath (Join-Path $script:CapturedLaunch.Arguments.ModuleRootOverride "Common.psm1")) "Cached modules retain their directory structure"
        Assert-True (Test-Path -LiteralPath $script:CapturedLaunch.Arguments.ConfigPathOverride) "Cached configuration path is forwarded"
        Invoke-RemoteTool -Manifest $manifest -SelectedTool "hardwarestability-once"
        Assert-True ($script:Answers.Count -eq 0) "Legacy direct one-time tool ID stays compatible"

        $BootstrapArguments = @{ Tool="hardwarestability"; Profile="Extended"; Components="RAM"; NoDownload=$true; DnsTestNames=@("one.test", "two.test"); TemporaryScriptPermission=$true }
        Start-TemporaryMenu
        Assert-True ($script:CapturedLaunch.Arguments.Tool -eq "menu") "Permission action restarts at the menu, never at the previously selected test"
        Assert-True ($script:CapturedLaunch.Arguments.TemporarySession -eq $true) "New menu knows permission is active"
        Assert-True (-not $script:CapturedLaunch.Arguments.ContainsKey("TemporaryScriptPermission")) "Permission action removes the direct-start switch to avoid a restart loop"
        Assert-True ($script:CapturedLaunch.Arguments.Profile -eq "Extended" -and $script:CapturedLaunch.Arguments.NoDownload -and $script:CapturedLaunch.Arguments.DnsTestNames.Count -eq 2) "Menu restart preserves options for all tools"
        Assert-True (-not (Test-Path -LiteralPath $script:CapturedLaunch.ScriptPath)) "Temporary menu script is cleaned up"

        # All regular tools can request temporary permission, not just hardware.
        $TemporaryScriptPermission = $true
        $DaysBackWasProvided = $true
        $DaysBack = 3
        $OutputPath = "fixture-network-output"
        $LocalTargets = @("192.0.2.1")
        $DnsTestNames = @("one.test", "two.test")
        foreach ($toolId in @("pcdiag", "netdiag", "displaydiag")) {
            $toolManifest = [pscustomobject]@{ tools = @([pscustomobject]@{ id=$toolId; name=$toolId; requiresAdmin=$false; path="scripts/$toolId.ps1"; dependencies=@() }) }
            Invoke-RemoteTool -Manifest $toolManifest -SelectedTool $toolId
            Assert-True ($script:CapturedLaunch.ScriptPath -like "*$toolId.ps1") "$toolId supports an explicit temporary start"
            if ($toolId -eq "pcdiag") { Assert-True ($script:CapturedLaunch.Arguments.DaysBack -eq 3) "PC diagnostics keeps the chosen lookback" }
            if ($toolId -eq "netdiag") { Assert-True ($script:CapturedLaunch.Arguments.LocalTargets[0] -eq "192.0.2.1") "Network diagnostics keeps target options" }
        }
        $TemporaryScriptPermission = $false
    } finally {
        $env:TEMP = $originalTemp
        # The fixture cache is rooted in the unique test directory above.
        $fixtureCache = [IO.Path]::GetFullPath((Join-Path $testRoot "PC-Diagnose"))
        if (-not $fixtureCache.StartsWith($testRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Fixture cleanup escaped the test directory"
        }
        Remove-Item -LiteralPath $fixtureCache -Recurse -Force -ErrorAction SilentlyContinue
    }
    $startFunction = $bootstrapAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Start-TemporaryToolProcess" }, $false)
    . ([scriptblock]::Create($startFunction.Extent.Text))

    Remove-Item Function:\Get-ExecutionPolicy
    Remove-Item Function:\Read-Host
    $policiesBefore = Get-ExecutionPolicy -List | ConvertTo-Json -Compress
    $modulePath = Join-Path $testRoot "Fixture.psm1"
    $toolPath = Join-Path $testRoot "Fixture.ps1"
    $resultPath = Join-Path $testRoot "result.clixml"
    [IO.File]::WriteAllText($modulePath, 'function Get-FixtureValue { "MODULE_IMPORTED" }; Export-ModuleMember -Function Get-FixtureValue', [Text.UTF8Encoding]::new($true))
    $fixtureText = @'
param([string]$OutputPath, [string]$ModulePath, [string]$Text, [string[]]$Names, [switch]$Enabled, [long]$Size)
Import-Module -Name $ModulePath -Force
@{ Policy = [string](Get-ExecutionPolicy); Module = Get-FixtureValue; Text = $Text; Names = $Names; Enabled = [bool]$Enabled; Size = $Size } |
    Export-Clixml -LiteralPath $OutputPath
'@
    [IO.File]::WriteAllText($toolPath, $fixtureText, [Text.UTF8Encoding]::new($true))
    if ((Get-ExecutionPolicy) -in @("Restricted", "AllSigned")) {
        $parentBlocked = $false
        try { Import-Module -Name $modulePath -Force -ErrorAction Stop } catch {
            $parentBlocked = $_.Exception -is [Management.Automation.PSSecurityException]
        }
        Assert-True $parentBlocked "Parent policy really blocks importing the unsigned module"
    }
    $toolArguments = @{
        OutputPath = $resultPath
        ModulePath = $modulePath
        Text = 'literal $value; "quotes"; O''Brien; $(throw "must not execute")'
        Names = @("first", "second with spaces")
        Enabled = $true
        Size = [long]4294967296
    }
    Start-TemporaryToolProcess -ScriptPath $toolPath -ToolArguments $toolArguments
    $result = Import-Clixml -LiteralPath $resultPath
    Assert-True ($result.Policy -eq "RemoteSigned") "Child process uses RemoteSigned"
    Assert-True ($result.Module -eq "MODULE_IMPORTED") "Unsigned module imports in the child"
    Assert-True ($result.Text -ceq $toolArguments.Text) "Argument values remain literal, without evaluating code"
    Assert-True ($result.Names.Count -eq 2 -and $result.Names[1] -eq $toolArguments.Names[1]) "Array arguments survive relaunch"
    Assert-True ($result.Enabled -and $result.Size -eq $toolArguments.Size) "Switch and Int64 arguments survive relaunch"
    Assert-True ((Get-ExecutionPolicy -List | ConvertTo-Json -Compress) -ceq $policiesBefore) "Parent and persistent execution policies stay unchanged"
    Assert-True (@(Get-ChildItem -LiteralPath $testRoot -Filter "run-once-*").Count -eq 0) "Temporary runner files are removed"

    [IO.File]::WriteAllText($toolPath, 'throw "fixture failure"', [Text.UTF8Encoding]::new($true))
    $failureDetected = $false
    try { Start-TemporaryToolProcess -ScriptPath $toolPath -ToolArguments @{} } catch {
        $failureDetected = $_.Exception.Message -match "Exitcode 1"
    }
    Assert-True $failureDetected "Child failure reaches the parent"
    Assert-True (@(Get-ChildItem -LiteralPath $testRoot -Filter "run-once-*").Count -eq 0) "Runner files are removed after failure"

    # Exercise the real separate menu process using a harmless menu fixture.
    $showMenuFunction = $bootstrapAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Show-ToolList" }, $false)
    $selectMenuFunction = $bootstrapAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Select-ToolFromMenu" }, $false)
    $script:MenuFixtureText = @'
param([string]$Tool, [switch]$TemporarySession, [string]$Branch, [string]$OutputPath)
'@ + "`n" + $showMenuFunction.Extent.Text + "`n" + $selectMenuFunction.Extent.Text + "`n" + @'
function Read-Host { param([string]$Prompt) return "0" }
$manifest = [pscustomobject]@{ tools = @(
    [pscustomobject]@{ id="pcdiag"; name="PC diagnostics"; requiresAdmin=$true; description="Fixture" },
    [pscustomobject]@{ id="netdiag"; name="Network diagnostics"; requiresAdmin=$false; description="Fixture" },
    [pscustomobject]@{ id="displaydiag"; name="Display diagnostics"; requiresAdmin=$false; description="Fixture" },
    [pscustomobject]@{ id="hardwarestability"; name="Hardware test"; requiresAdmin=$true; description="Fixture" }
) }
$selected = Select-ToolFromMenu -Manifest $manifest
@{ RequestedTool=$Tool; TemporarySession=[bool]$TemporarySession; Selection=$selected; Policy=[string](Get-ExecutionPolicy) } | Export-Clixml -LiteralPath $OutputPath
'@
    $BootstrapArguments = @{ OutputPath=(Join-Path $testRoot "menu-result.clixml") }
    Start-TemporaryMenu
    $menuResult = Import-Clixml -LiteralPath $BootstrapArguments.OutputPath
    Assert-True ($menuResult.RequestedTool -eq "menu" -and $menuResult.TemporarySession) "Real child process opens the test selection with active permission"
    Assert-True ($menuResult.Selection -eq "exit") "Leaving the temporary menu runs no test"
    Assert-True ($menuResult.Policy -eq "RemoteSigned") "Temporary menu process uses RemoteSigned"
    Assert-True ((Get-ExecutionPolicy -List | ConvertTo-Json -Compress) -ceq $policiesBefore) "Menu permission leaves parent and persistent policies unchanged"
    Assert-True (@(Get-ChildItem -LiteralPath $testRoot -Filter "menu-once-*").Count -eq 0) "Temporary menu file is removed"

    Assert-True ([IO.File]::ReadAllText($bootstrapPath) -ceq [IO.File]::ReadAllText((Join-Path $repoRoot "r"))) "bootstrap.ps1 and r stay synchronized"
    Write-Host "Bootstrap tests passed (no hardware load or persistent policy changes)." -ForegroundColor Green
} finally {
    # Only remove files inside the uniquely created fixture directory.
    Get-ChildItem -LiteralPath $testRoot -File | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
    Remove-Item -LiteralPath $testRoot -Force
}
