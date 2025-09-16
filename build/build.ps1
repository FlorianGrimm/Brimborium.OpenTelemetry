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
        [System.Collections.Generic.List[string]] $listRelativeFile = [System.Collections.Generic.List[string]]::new()
        [System.IO.FileInfo[]]$listFileInfo = Get-ChildItem -LiteralPath $folder -Recurse | ? { $_.PSIsContainer -eq $false -and $_ -is [System.IO.FileInfo] }
        [System.IO.FileInfo[]]$listFileInfoFiltered = $listFileInfo | ? { $this.IsExcludedFileInfo($_) -eq $false }
        
        [string]$solutionDirWithSeparator = $this.SolutionDir + [System.IO.Path]::DirectorySeparatorChar
        foreach ($fileInfo in $listFileInfoFiltered) {
            [string]$fullName = $fileInfo.FullName
            if ($fullName.StartsWith($solutionDirWithSeparator) -eq $false) {
                continue
            }
            [string]$relativePath  = $fullName.Substring($solutionDirWithSeparator.Length)
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
                if (Test-Path $srcPath) {
                    [string]$dstPath = $dst.GetAbsolutePath($relativeFile.RelativePath)
                    if (-not(Test-Path $dstPath)) {
                        [string]$dstDirName = [System.IO.Path]::GetDirectoryName($dstPath)
                        [System.IO.Directory]::CreateDirectory($dstDirName) | Out-Null
                        [System.IO.File]::Copy($srcPath, $dstPath, $true)
                    }
                }
                [string]$srcFileContent = $this.ReadFile($relativeFile.RelativePath)
                [string]$dstFileContent = $dst.ReadFile($relativeFile.RelativePath)
                if ($srcFileContent -ne $dstFileContent) {
                    $dst.WriteFile($relativeFile.RelativePath, $srcFileContent)
                }
            }
            if ($relativeFile.Action -eq "delete") {
                $dst.DeleteFile($relativeFile.RelativePath)
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
        [string]$fullPath = GetAbsolutePath($relativePath)
        [System.IO.File]::WriteAllText($fullPath, $content)
    }
    DeleteFile([string] $relativePath) {
        [string]$fullPath = GetAbsolutePath($relativePath)
        if (Test-Path $fullPath) {
            Remove-Item $fullPath
        }
    }
    Diff([FileContentList] $dst) {
        foreach ($relativeFile in $this.DictFileAction.Values) {
            if ($relativeFile.Action -eq "copy") {
                [string]$srcFileContent = $this.ReadFile($relativeFile.RelativePath)
                [string]$dstFileContent = $dst.ReadFile($relativeFile.RelativePath)
                if ($srcFileContent -ne $dstFileContent) {
                    write-host "diff: $($relativeFile.RelativePath)"
                }
            }
            if ($relativeFile.Action -eq "delete") {
                write-host "delete: $($relativeFile.RelativePath)"
            }
        }
    }
    UpdateAction([FileContentList] $dst) {
        foreach ($relativeFile in $this.DictFileAction.Values) {
            if ($relativeFile.Action -eq "") {
                [string]$srcFileContent = $this.ReadFile($relativeFile.RelativePath)
                [string]$dstFileContent = $dst.ReadFile($relativeFile.RelativePath)
                if ($srcFileContent -eq $dstFileContent) {
                    $relativeFile.Action = "copy"
                    write-host "copy: $($relativeFile.RelativePath)"
                }
                elseif ($srcFileContent -eq "") {
                    $relativeFile.Action = "delete"
                    write-host "delete: $($relativeFile.RelativePath)"
                }
                elseif ($dstFileContent -eq "") {
                    $relativeFile.Action = "copy"
                    write-host "copy: $($relativeFile.RelativePath)"
                }
            }
            elseif ($relativeFile.Action -eq "copy") {
                [string]$srcFileContent = $this.ReadFile($relativeFile.RelativePath)
                [string]$dstFileContent = $dst.ReadFile($relativeFile.RelativePath)
                if ($srcFileContent -eq $dstFileContent) {
                    # ok
                }
                elseif ($srcFileContent -eq "") {
                    $relativeFile.Action = "delete"
                    write-host "delete: $($relativeFile.RelativePath)"
                }
                elseif ($srcFileContent -ne $dstFileContent) {
                    $relativeFile.Action = "ignore"
                    write-host "ignore: $($relativeFile.RelativePath)"
                }
            }
            
            # if ($relativeFile.Action -eq "delete") { }
        }
    }
}

# try {
[string] $SolutionDir = [System.IO.Path]::GetDirectoryName($PSScriptRoot)
    
[string] $FilelistOtelDotNetJsonPath = [System.IO.Path]::Combine($SolutionDir, "build", "filelist-opentelemetry-dotnet.json")
[string] $SrcOtelDotNet = [System.IO.Path]::Combine($SolutionDir, "SubModule", "opentelemetry-dotnet")
[string] $DstOtelDotNet = [System.IO.Path]::Combine($SolutionDir, "Brimborium.OpenTelemetry", "opentelemetry-dotnet")

[string] $FilelistOtelContribJsonPath = [System.IO.Path]::Combine($SolutionDir, "build", "filelist-opentelemetry-dotnet-contrib.json")
[string] $SrcOtelContrib = [System.IO.Path]::Combine($SolutionDir, "SubModule", "opentelemetry-dotnet-contrib")
[string] $DstOtelContrib = [System.IO.Path]::Combine($SolutionDir, "Brimborium.OpenTelemetry", "opentelemetry-dotnet-contrib")

    
[FileContentList] $fclSrcOtelDotNet = [FileContentList]::new($SrcOtelDotNet, $SolutionDir, $FilelistOtelDotNetJsonPath)
[FileContentList] $fclSrcOtelContrib = [FileContentList]::new($SrcOtelContrib, $SolutionDir, $FilelistOtelContribJsonPath)
[FileContentList] $fclDstOtelDotNet = [FileContentList]::new($DstOtelDotNet, $SolutionDir, "")
[FileContentList] $fclDstOtelContrib = [FileContentList]::new($DstOtelContrib, $SolutionDir, "")

[string] $SolutionFile = [System.IO.Path]::Combine($SolutionDir, "Brimborium.OpenTelemetry", "Brimborium.OpenTelemetry.sln")
write-host "`$SolutionDir='$($SolutionDir)'"
write-host "`$SolutionFile='$($SolutionFile)'"
write-host "`$SrcOtelDotNet='$($SrcOtelDotNet)'"
write-host "`$SrcOtelContrib='$($SrcOtelContrib)'"

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

        $fclSrcOtelDotNet.Load()
        $fclSrcOtelDotNet.ScanFolderInit()
        $fclSrcOtelDotNet.ScanFolder($fclSrcOtelDotNet.SolutionDir)
        $fclSrcOtelDotNet.ScanFolderDone($true)
        $fclSrcOtelDotNet.Save($saveAll)

        $fclSrcOtelContrib.Load()
        $fclSrcOtelContrib.ScanFolderInit()
        $fclSrcOtelContrib.ScanFolder($fclSrcOtelContrib.SolutionDir)
        $fclSrcOtelContrib.ScanFolderDone($true)
        $fclSrcOtelContrib.Save($saveAll)
    }
    if ($currentAction -eq "filelist-diff") {
        $actionKnown = $true
        write-host "filelist-diff"

        $fclSrcOtelDotNet.Load()
        $fclSrcOtelDotNet.ScanFolderInit()
        $fclSrcOtelDotNet.ScanFolder($fclSrcOtelDotNet.SolutionDir)
        $fclSrcOtelDotNet.ScanFolderDone($true)
        $fclDstOtelDotNet.Clear()
        $fclDstOtelDotNet.ScanFolder($fclDstOtelDotNet.SolutionDir)
        $fclSrcOtelDotNet.Diff($fclDstOtelDotNet)

        $fclSrcOtelContrib.Load()
        $fclSrcOtelContrib.ScanFolderInit()
        $fclSrcOtelContrib.ScanFolder($fclSrcOtelContrib.SolutionDir)
        $fclSrcOtelContrib.ScanFolderDone($true)
        $fclSrcOtelContrib.Clear()
        $fclDstOtelContrib.ScanFolder($fclDstOtelContrib.SolutionDir)
        $fclSrcOtelContrib.Diff($fclDstOtelContrib)
    }
    if ($currentAction -eq "filelist-update") {
        $actionKnown = $true
        write-host "filelist-update"

        $fclSrcOtelDotNet.Load()
        # $fclSrcOtelDotNet.ScanFolderInit()
        # $fclSrcOtelDotNet.ScanFolder($fclSrcOtelDotNet.SolutionDir)
        # $fclSrcOtelDotNet.ScanFolderDone($true)
        $fclDstOtelDotNet.Clear()
        $fclDstOtelDotNet.ScanFolder($fclDstOtelDotNet.SolutionDir)
        $fclSrcOtelDotNet.UpdateAction($fclDstOtelDotNet)
        $fclSrcOtelDotNet.Save($saveAll)

        $fclSrcOtelContrib.Load()
        # $fclSrcOtelContrib.ScanFolderInit()
        # $fclSrcOtelContrib.ScanFolder($fclSrcOtelContrib.SolutionDir)
        # $fclSrcOtelContrib.ScanFolderDone($true)
        $fclSrcOtelContrib.Clear()
        $fclDstOtelContrib.ScanFolder($fclDstOtelContrib.SolutionDir)
        $fclSrcOtelContrib.UpdateAction($fclDstOtelContrib)
        $fclSrcOtelContrib.Save($saveAll)
    }
    if ($currentAction -eq "filelist-copy") {
        $actionKnown = $true
        write-host "filelist-copy"
        $fclSrcOtelDotNet.Load()
        $fclDstOtelDotNet.Clear()
        $fclDstOtelDotNet.ScanFolder($fclDstOtelDotNet.SolutionDir)
        $fclSrcOtelDotNet.Execute($fclDstOtelDotNet)

        $fclSrcOtelContrib.Load()
        $fclSrcOtelContrib.Clear()
        $fclDstOtelContrib.ScanFolder($fclDstOtelContrib.SolutionDir)
        $fclSrcOtelContrib.Execute($fclDstOtelContrib)
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