# Links the sibling repositories the 3D DIS demo (demo/dis3d.tscn) needs into this project:
#   addons\dis        <- ..\godot-dis\addons\dis          (DIS GDExtension; build it there first)
#   addons\milsymbol  <- ..\godot-milsymbol\addons\milsymbol
#   demo\dis          <- ..\godot-dis\demo                 (its scenario, unit mover and tactical map)
# Directory junctions, no admin rights needed; all three are git-ignored. The terrain addon and its tests work
# without them. Usage (from the repo root): .\tools\link_siblings.ps1 [-Workspace ..]
param(
	[string]$Workspace = (Join-Path $PSScriptRoot "..\..")
)

$root = Join-Path $PSScriptRoot ".."
$links = @(
	@{ Target = "addons\dis"; Source = "godot-dis\addons\dis" },
	@{ Target = "addons\milsymbol"; Source = "godot-milsymbol\addons\milsymbol" },
	@{ Target = "demo\dis"; Source = "godot-dis\demo" }
)
foreach ($link in $links) {
	$target = Join-Path $root $link.Target
	$source = Join-Path $Workspace $link.Source
	if (Test-Path $target) {
		Write-Host "$($link.Target) already exists"
		continue
	}
	$source = (Resolve-Path $source -ErrorAction Stop).Path
	New-Item -ItemType Junction -Path $target -Target $source | Out-Null
	Write-Host "linked $($link.Target) -> $source"
}
Write-Host "Run once so Godot registers the classes: <godot> --headless --path . --import"
