$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    "C:\Users\hana-alice\AppData\Local\nvim\setup.ps1",
    [ref]$tokens,
    [ref]$errors
)
if ($errors.Count -eq 0) {
    Write-Host "SYNTAX OK - $($tokens.Count) tokens"
} else {
    Write-Host "SYNTAX ERRORS:"
    foreach ($e in $errors) {
        Write-Host "  Line $($e.Extent.StartLineNumber): $($e.Message)"
    }
}
