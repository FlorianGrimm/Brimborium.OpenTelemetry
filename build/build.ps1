param(
    #[Parameter(Mandatory = $true)][string]$action,
    [Parameter()][string]$action = "filelist-copy",
    [Parameter()][string]$configuration = "Debug",
    [Parameter()][bool]$saveAll = $true
)

Set-StrictMode -Version Latest

#$ErrorActionPreference = "Stop"
#$ErrorActionPreference = "Inquire"

class RelativeFile {
    [string] $RelativePath
    [string] $Action
    RelativeFile([string] $relativePath, [string] $action = "") {
        $this.RelativePath = $relativePath
        $this.Action = $action
    }
}
class FileContent {
    [string] $RelativePath
    [string] $Content
    FileContent([string] $relativePath, [string] $content) {
        $this.RelativePath = $relativePath
        $this.Content = $content
    }
    static [FileContent] Create([string] $relativePath, [string] $fullPath, [string] $content = "") {
        if ("" -eq $content) {
            if (Test-Path $fullPath) {
                [string]$contentRead = [System.IO.File]::ReadAllText($fullPath)
                return [FileContent]::new($relativePath, $contentRead)
            }
            else {
                return [FileContent]::new($relativePath, "")
            }
        }
        else {
            return [FileContent]::new($relativePath, $content)
        }
    }
}
class FileContentList {
    [System.Collections.Generic.Dictionary[string, RelativeFile]] $DictFileAction = [System.Collections.Generic.Dictionary[string, RelativeFile]]::new()
    [System.Collections.Generic.Dictionary[string, FileContent]] $DictFileContent = [System.Collections.Generic.Dictionary[string, FileContent]]::new()
    [string] $RepoDir
    [string] $RootRelativePath
    [string] $SolutionDir
    [string] $FilelistJsonPath
    [System.Collections.Generic.HashSet[string]]$Excludes
    FileContentList(
        [string] $SolutionDir,
        [string] $RepoDir,
        [string] $FilelistJsonPath
    ) {
        $this.SolutionDir = $SolutionDir
        $this.RepoDir = $RepoDir
        $this.RootRelativePath = [System.IO.Path]::GetRelativePath($RepoDir, $SolutionDir)
        $this.FilelistJsonPath = $FilelistJsonPath
        $this.Excludes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $this.Excludes.Add(".git") | Out-Null
        $this.Excludes.Add(".github") | Out-Null
        $this.Excludes.Add(".vscode") | Out-Null
        $this.Excludes.Add("bin") | Out-Null
        $this.Excludes.Add("obj") | Out-Null
        $this.Excludes.Add("Artifacts") | Out-Null
        $this.Excludes.Add("artifacts") | Out-Null
    }
    AddFile([string] $relativePath, [string] $action = "") {
        [RelativeFile] $relativeFile = $null
        if ($this.DictFileAction.TryGetValue($relativePath, [ref]$relativeFile)) {
            if ("" -ne $action) {
                $relativeFile.Action = $action
            }
        }
        else {
            $relativeFile = [RelativeFile]::new($relativePath, $action)
            $this.DictFileAction.Add($relativePath, $relativeFile)
        }
    }
    Load() {
        $this.DictFileAction.Clear()
        $this.DictFileContent.Clear()
        
        if (Test-Path $this.FilelistJsonPath) {
            [string]$json = [System.IO.File]::ReadAllText($this.FilelistJsonPath)
            [System.Collections.Generic.List[RelativeFile]] $listRelativePath = [System.Text.Json.JsonSerializer]::Deserialize($json, [System.Collections.Generic.List[RelativeFile]])
            foreach ($relativeFile in $listRelativePath) {
                $this.AddFile($relativeFile.RelativePath, $relativeFile.Action)
            }
        }
    }
    Save([bool] $saveAll) {
        [RelativeFile[]] $listRelativeFile = (($this.DictFileAction.Values) | ? { ($saveAll -or ("" -ne $_.Action)) } | Sort-Object -Property RelativePath)
        if ($null -eq $listRelativeFile -or $listRelativeFile.Count -eq 0) {
            [string]$json = '[]'
            [System.IO.File]::WriteAllText($this.FilelistJsonPath, $json)
        }
        else {
            [System.Text.Json.JsonSerializerOptions] $options = [System.Text.Json.JsonSerializerOptions]::new()
            $options.WriteIndented = $true
            [string]$json = [System.Text.Json.JsonSerializer]::Serialize($listRelativeFile, [RelativeFile[]], $options)
            [System.IO.File]::WriteAllText($this.FilelistJsonPath, $json)
        }
    }
    Clear() {
        $this.DictFileAction.Clear()
        $this.DictFileContent.Clear()
    }
    [System.Collections.Generic.HashSet[string]] $CachedRelativePath = $null
    ScanFolderInit() {
        $this.CachedRelativePath = [System.Collections.Generic.HashSet[string]]::new($this.DictFileAction.Keys)
    }
    ScanFolder([string] $folder) {
        if ($folder.StartsWith($this.SolutionDir) -eq $false) {
            throw "Folder $folder is not in SolutionDir $this.SolutionDir"
        }
        if ((Test-Path $folder) -eq $false) {
            return
        }
        [System.Collections.Generic.List[string]] $listRelativeFile = [System.Collections.Generic.List[string]]::new()
        [System.IO.FileInfo[]]$listFileInfo = Get-ChildItem -LiteralPath $folder -Recurse | ? { $_.PSIsContainer -eq $false -and $_ -is [System.IO.FileInfo] }
        [System.IO.FileInfo[]]$listFileInfoFiltered = $listFileInfo | ? { $this.IsExcludedFileInfo($_) -eq $false }
        
        [string]$solutionDirWithSeparator = $this.SolutionDir + [System.IO.Path]::DirectorySeparatorChar
        foreach ($fileInfo in $listFileInfoFiltered) {
            [string]$fullName = $fileInfo.FullName
            if ($fullName.StartsWith($solutionDirWithSeparator) -eq $false) {
                continue
            }
            [string]$relativePath = $fullName.Substring($solutionDirWithSeparator.Length)
            $this.AddFile($relativePath, "") | Out-Null
        }
    }
    ScanFolderDone([bool] $setDeleteAction) {
        if ($null -eq $this.CachedRelativePath) {
            return
        }
        $this.CachedRelativePath.ExceptWith($this.DictFileAction.Keys)
        foreach ($relativePath in $this.CachedRelativePath) {
            [RelativeFile] $relativeFile = $null
            if ($this.DictFileAction.TryGetValue($relativePath, [ref]$relativeFile) ) {
                if ($setDeleteAction) {
                    $relativeFile.Action = "delete"
                }
                else {
                    $this.DictFileAction.Remove($relativePath) | Out-Null
                }
            }
        }
        $this.CachedRelativePath = $null
    }
    [bool]IsExcludedFileInfo([System.IO.FileInfo] $fileInfo) {
        if ($null -eq $fileInfo) {
            return $true
        }
        [string] $fullName = $fileInfo.FullName
        if ($fullName.StartsWith($this.SolutionDir) -eq $false) {
            return $true
        }
        if ($fullName.Length -le $this.SolutionDir.Length) {
            return $true
        }
        [string] $relativePath = $fullName.Substring($this.SolutionDir.Length + 1)
        return $this.IsExcludedPath($relativePath)
    }
    [bool]IsExcludedPath([string] $path) {
        [string[]]$listPath = $path.Split([System.IO.Path]::DirectorySeparatorChar)
        foreach ($currentPath in $listPath) {
            if ($this.Excludes.Contains($currentPath)) {
                return $true
            }
        }
        return $false
    }
    Execute([FileContentList] $dst) {
        foreach ($relativeFile in $this.DictFileAction.Values) {
            if ($relativeFile.Action -eq "copy" -or $relativeFile.Action -eq "") {
                [string]$srcPath = $this.GetAbsolutePath($relativeFile.RelativePath)
                [string]$dstPath = $dst.GetAbsolutePath($relativeFile.RelativePath)
                if (-not(Test-Path $dstPath)) {
                    [string]$dstDirName = [System.IO.Path]::GetDirectoryName($dstPath)
                    [System.IO.Directory]::CreateDirectory($dstDirName) | Out-Null
                }
                if ((Test-Path $srcPath) -and -not(Test-Path $dstPath)) {
                    [System.IO.File]::Copy($srcPath, $dstPath, $true)
                    write-host "copy: $($relativeFile.RelativePath)"
                }
                else {
                    [string]$srcFileContent = $this.ReadFile($relativeFile.RelativePath)
                    [string]$dstFileContent = $dst.ReadFile($relativeFile.RelativePath)
                    if ($this.CompareFileContent($srcFileContent, $dstFileContent)) {
                        # no change
                    }
                    else {
                        $dst.WriteFile($relativeFile.RelativePath, $srcFileContent)
                        write-host "copy: $($relativeFile.RelativePath)"
                    }
                }
            }
            if ($relativeFile.Action -eq "delete") {
                if ($dst.DeleteFile($relativeFile.RelativePath)) {
                    write-host "delete: $($relativeFile.RelativePath)"
                }
            }
        }
    }
    [string]ReadFile([string] $relativePath) {
        [FileContent] $fileContent = $null
        if ($this.DictFileContent.TryGetValue($relativePath, [ref]$fileContent)) {
            return $fileContent.Content
        }
        else {
            [string]$fullPath = $this.GetAbsolutePath($relativePath)
            $fileContent = [FileContent]::Create($relativePath, $fullPath, "")
            $this.DictFileContent.Add($relativePath, $fileContent)
            return $fileContent.Content
        }
    }
    [string]GetAbsolutePath([string] $relativePath) {
        return [System.IO.Path]::Combine($this.SolutionDir, $relativePath)
    }
    WriteFile([string] $relativePath, [string] $content) {
        [string]$fullPath = $this.GetAbsolutePath($relativePath)
        [System.IO.File]::WriteAllText($fullPath, $content)
    }
    [bool]DeleteFile([string] $relativePath) {
        [string]$fullPath = $this.GetAbsolutePath($relativePath)
        if (Test-Path $fullPath) {
            Remove-Item $fullPath
            return $true
        }
        return $false
    }
    [bool] CompareFileContent($srcFileContent, $dstFileContent) {
        if ($srcFileContent -eq $dstFileContent) {
            return $true
        }
        $srcFileContent = $srcFileContent.ReplaceLineEndings()
        $dstFileContent = $dstFileContent.ReplaceLineEndings()
        if ($srcFileContent -eq $dstFileContent) {
            return $true
        }
        return $false
    }
    Diff([FileContentList] $dst) {
        foreach ($relativeFile in $this.DictFileAction.Values) {
            if ($relativeFile.Action -eq "copy" -or $relativeFile.Action -eq "") {
                [string]$srcFileContent = $this.ReadFile($relativeFile.RelativePath)
                [string]$dstFileContent = $dst.ReadFile($relativeFile.RelativePath)
                if ($this.CompareFileContent($srcFileContent, $dstFileContent)) {
                    # no change
                }
                else {
                    write-host "diff: $($relativeFile.RelativePath)"
                }
            }
        }
    }
    UpdateAction([FileContentList] $dst) {
        foreach ($relativeFile in $this.DictFileAction.Values) {
            if ($relativeFile.Action -eq "") {
                [string]$srcFileContent = $this.ReadFile($relativeFile.RelativePath)
                [string]$dstFileContent = $dst.ReadFile($relativeFile.RelativePath)
                if ($this.CompareFileContent($srcFileContent, $dstFileContent)) {
                    # ok
                    $relativeFile.Action = "copy"
                    write-host "copy: $($relativeFile.RelativePath)"
                }
                elseif ($srcFileContent -eq "") {
                    $relativeFile.Action = "delete"
                    write-host "delete: $($relativeFile.RelativePath)"
                }
                elseif ($dstFileContent -eq "") {
                    $relativeFile.Action = "delete"
                    write-host "delete: $($relativeFile.RelativePath)"
                }
            }
            elseif ($relativeFile.Action -eq "copy") {
                [string]$srcFileContent = $this.ReadFile($relativeFile.RelativePath)
                [string]$dstFileContent = $dst.ReadFile($relativeFile.RelativePath)
                if ($this.CompareFileContent($srcFileContent, $dstFileContent)) {
                    # ok
                }
                elseif ($srcFileContent -eq "") {
                    $relativeFile.Action = "delete"
                    write-host "delete: $($relativeFile.RelativePath)"
                }
                elseif ($dstFileContent -eq "") {
                    $relativeFile.Action = "delete"
                    write-host "delete: $($relativeFile.RelativePath)"
                }
                else {
                    $relativeFile.Action = "diff"
                    write-host "diff: $($relativeFile.RelativePath)"
                }
            }
            
            # if ($relativeFile.Action -eq "delete") { }
        }
    }
}

class ContentMapping {
    [FileContentList] $Src
    [FileContentList] $Dst
    ContentMapping([FileContentList] $src, [FileContentList] $dst) {
        $this.Src = $src
        $this.Dst = $dst
    }
    static [ContentMapping] Create(
        [string] $SolutionDir,
        [string] $srcFilelistPath,
        [string] $srcPath,
        [string] $dstPath) {
        return [ContentMapping]::new(
            [FileContentList]::new($srcPath, $SolutionDir, $srcFilelistPath),
            [FileContentList]::new($dstPath, $SolutionDir, ""))
    }
    FilelistRead([bool] $saveAll) {
        $this.Src.Load()
        $this.Src.ScanFolderInit()
        $this.Src.ScanFolder($this.Src.SolutionDir)
        $this.Src.ScanFolderDone($true)
        $this.Src.Save($saveAll)
    }
    FilelistDiff() {
        $this.Src.Load()
        $this.Src.ScanFolderInit()
        $this.Src.ScanFolder($this.Src.SolutionDir)
        $this.Src.ScanFolderDone($true)
        $this.Dst.Clear()
        $this.Dst.ScanFolder($this.Dst.SolutionDir)
        $this.Src.Diff($this.Dst)
    }

    FilelistUpdate([bool] $saveAll) {
        $this.Src.Load()
        # $this.Src.ScanFolderInit()
        # $this.Src.ScanFolder($this.Src.SolutionDir)
        # $this.Src.ScanFolderDone($true)
        $this.Dst.Clear()
        $this.Dst.ScanFolder($this.Dst.SolutionDir)
        $this.Src.UpdateAction($this.Dst)
        $this.Src.Save($saveAll)
    }

    FilelistCopy() {
        $this.Src.Load()
        $this.Dst.Clear()
        $this.Dst.ScanFolder($this.Dst.SolutionDir)
        $this.Src.Execute($this.Dst)
    }
}

# try {
[string] $SolutionDir = [System.IO.Path]::GetDirectoryName($PSScriptRoot)
write-host "`$SolutionDir='$($SolutionDir)'"
[System.Collections.Generic.List[ContentMapping]] $listContentMapping = [System.Collections.Generic.List[ContentMapping]]::new()

$listContentMapping.Add(
    [ContentMapping]::Create(
        $SolutionDir,
        [System.IO.Path]::Combine($SolutionDir, "build", "filelist-OpenTelemetry-Shared.json"),
        [System.IO.Path]::Combine($SolutionDir, "SubModule", "opentelemetry-dotnet", "src", "Shared"),
        [System.IO.Path]::Combine($SolutionDir, "Brimborium.OpenTelemetry.Shared")
    )
)

$listContentMapping.Add(
    [ContentMapping]::Create(
        $SolutionDir,
        [System.IO.Path]::Combine($SolutionDir, "build", "filelist-OpenTelemetry.json"),
        [System.IO.Path]::Combine($SolutionDir, "SubModule", "opentelemetry-dotnet", "src", "OpenTelemetry"),
        [System.IO.Path]::Combine($SolutionDir, "Brimborium.OpenTelemetry", "OpenTelemetry", "OpenTelemetry")
    )
)
$listContentMapping.Add(
    [ContentMapping]::Create(
        $SolutionDir,
        [System.IO.Path]::Combine($SolutionDir, "build", "filelist-OpenTelemetry-Api.json"),
        [System.IO.Path]::Combine($SolutionDir, "SubModule", "opentelemetry-dotnet", "src", "OpenTelemetry.Api"),
        [System.IO.Path]::Combine($SolutionDir, "Brimborium.OpenTelemetry", "OpenTelemetry", "OpenTelemetry.Api")
    )
)
$listContentMapping.Add(
    [ContentMapping]::Create(
        $SolutionDir,
        [System.IO.Path]::Combine($SolutionDir, "build", "filelist-OpenTelemetry-Api-ProviderBuilderExtensions.json"),
        [System.IO.Path]::Combine($SolutionDir, "SubModule", "opentelemetry-dotnet", "src", "OpenTelemetry.Api.ProviderBuilderExtensions"),
        [System.IO.Path]::Combine($SolutionDir, "Brimborium.OpenTelemetry", "OpenTelemetry", "OpenTelemetry.Api.ProviderBuilderExtensions")
    )
)
$listContentMapping.Add(
    [ContentMapping]::Create(
        $SolutionDir,
        [System.IO.Path]::Combine($SolutionDir, "build", "filelist-OpenTelemetry-Exporter-Console.json"),
        [System.IO.Path]::Combine($SolutionDir, "SubModule", "opentelemetry-dotnet", "src", "OpenTelemetry.Exporter.Console"),
        [System.IO.Path]::Combine($SolutionDir, "Brimborium.OpenTelemetry", "OpenTelemetry", "OpenTelemetry.Exporter.Console")
    )
)

$listContentMapping.Add(
    [ContentMapping]::Create(
        $SolutionDir,
        [System.IO.Path]::Combine($SolutionDir, "build", "filelist-OpenTelemetry-Instrumentation-Shared.json"),
        [System.IO.Path]::Combine($SolutionDir, "SubModule", "opentelemetry-dotnet-contrib", "src", "Shared"),
        [System.IO.Path]::Combine($SolutionDir, "Brimborium.OpenTelemetry.Instrumentation.Shared")
    )
)

$listContentMapping.Add(
    [ContentMapping]::Create(
        $SolutionDir,
        [System.IO.Path]::Combine($SolutionDir, "build", "filelist-OpenTelemetry-Instrumentation-AspNetCore.json"),
        [System.IO.Path]::Combine($SolutionDir, "SubModule", "opentelemetry-dotnet-contrib", "src", "OpenTelemetry.Instrumentation.AspNetCore"),
        [System.IO.Path]::Combine($SolutionDir, "Brimborium.OpenTelemetry.AspNetCore", "OpenTelemetry", "OpenTelemetry.Instrumentation.AspNetCore")
    )
)

$listContentMapping.Add(
    [ContentMapping]::Create(
        $SolutionDir,
        [System.IO.Path]::Combine($SolutionDir, "build", "filelist-OpenTelemetry-Instrumentation-Runtime.json"),
        [System.IO.Path]::Combine($SolutionDir, "SubModule", "opentelemetry-dotnet-contrib", "src", "OpenTelemetry.Instrumentation.Runtime"),
        [System.IO.Path]::Combine($SolutionDir, "Brimborium.OpenTelemetry.Runtime", "OpenTelemetry", "OpenTelemetry.Instrumentation.Runtime")
    )
)

<#
OpenTelemetry.Extensions.Hosting
$listContentMapping.Add(
    [ContentMapping]::Create(
        $SolutionDir,
        [System.IO.Path]::Combine($SolutionDir, "build", "filelist-OpenTelemetry-Exporter-InMemory.json"),
        [System.IO.Path]::Combine($SolutionDir, "SubModule", "opentelemetry-dotnet", "src", "OpenTelemetry.Exporter.InMemory"),
        [System.IO.Path]::Combine($SolutionDir, "Brimborium.OpenTelemetry", "OpenTelemetry", "OpenTelemetry.Exporter.InMemory")
    )
)
#>
[string] $SolutionFile = [System.IO.Path]::Combine($SolutionDir, "Brimborium.OpenTelemetry", "Brimborium.OpenTelemetry.sln")

[string[]] $listAction = $action.Split(",")
foreach ($currentAction in $listAction) {
    [bool] $actionKnown = $false
    if ($currentAction -eq "submodule") {
        $actionKnown = $true
        write-host "submodule"
        git submodule init
        #git submodule update --init --recursive
        # git submodule foreach git clean -fdx
        # git submodule foreach git reset --hard
        if ($LASTEXITCODE -ne 0) {
            throw "git submodule failed"
        }
    }
    if ($currentAction -eq "restore") {
        $actionKnown = $true
        write-host "restore"
        dotnet restore $SolutionFile
        if ($LASTEXITCODE -ne 0) {
            throw "dotnet restore failed"
        }
    }
    if ($currentAction -eq "build") {
        $actionKnown = $true
        write-host "build"
        dotnet build $SolutionFile -c $configuration
        if ($LASTEXITCODE -ne 0) {
            throw "dotnet build failed"
        }
    }
    if ($currentAction -eq "test") {
        $actionKnown = $true
        write-host "test"
        dotnet test $SolutionFile -c $configuration
        if ($LASTEXITCODE -ne 0) {
            throw "dotnet test failed"
        }
    }
    if ($currentAction -eq "clean") {
        $actionKnown = $true
        write-host "clean"
        dotnet clean $SolutionFile -c $configuration
        if ($LASTEXITCODE -ne 0) {
            throw "dotnet clean failed"
        }
    }
    if ($currentAction -eq "pack") {
        $actionKnown = $true
        write-host "pack"
        dotnet pack $SolutionFile -c $configuration
        if ($LASTEXITCODE -ne 0) {
            throw "dotnet pack failed"
        }
    }
    if ($currentAction -eq "filelist-read") {
        $actionKnown = $true
        write-host "filelist-read"
        foreach ($cm in $listContentMapping) {
            $cm.FilelistRead($saveAll)
        }
    }
    if ($currentAction -eq "filelist-diff") {
        $actionKnown = $true
        write-host "filelist-diff"
        foreach ($cm in $listContentMapping) {
            $cm.FilelistDiff()
        }
    }
    if ($currentAction -eq "filelist-update") {
        $actionKnown = $true
        write-host "filelist-update"
        foreach ($cm in $listContentMapping) {
            $cm.FilelistUpdate($saveAll)
        }
    }
    if ($currentAction -eq "filelist-copy") {
        $actionKnown = $true
        write-host "filelist-copy"
        foreach ($cm in $listContentMapping) {
            $cm.FilelistCopy()
        }
    }
    if ($false -eq $actionKnown) {
        throw "unknown action: $currentAction"
    }
}
#}
#catch {
#    write-host ($_ | out-string)
#    exit 1
#}