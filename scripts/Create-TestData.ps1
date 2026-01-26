# Create tiny test data (2 bytes total) in temp folder
# This will be moved to staging by Move-ToColdStorage.ps1
$testDir = 'C:\Temp\cold-storage-test'
if (Test-Path $testDir) {
    Remove-Item $testDir -Recurse -Force
}
New-Item -ItemType Directory -Path $testDir -Force | Out-Null
'a' | Out-File (Join-Path $testDir 'a.txt') -NoNewline -Encoding ASCII
'b' | Out-File (Join-Path $testDir 'b.txt') -NoNewline -Encoding ASCII
Write-Host "Test files created at $testDir (2 bytes total):"
Get-ChildItem $testDir | Select-Object Name, Length
