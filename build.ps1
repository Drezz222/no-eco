# Builds no-eco.exe for ARM64 and x64 Windows into dist/. Requires Zig (https://ziglang.org) on PATH.
# Works on Windows PowerShell and on pwsh (Linux/macOS), since Zig cross-compiles.
#
#   powershell -ExecutionPolicy Bypass -File build.ps1

$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    New-Item -ItemType Directory -Force dist | Out-Null
    foreach ($arch in @(@{ Name = 'arm64'; Target = 'aarch64-windows-gnu' }, @{ Name = 'x64'; Target = 'x86_64-windows-gnu' })) {
        $out = "dist/no-eco-$($arch.Name).exe"
        zig cc -target $arch.Target -O2 -s -Wall -Wextra -Werror '-Wl,--subsystem,windows' src/no-eco.c -o $out -lkernel32 -lpsapi -lshell32
        if ($LASTEXITCODE) { throw "build failed for $($arch.Name)" }
        Remove-Item "dist/no-eco-$($arch.Name).pdb", "dist/no-eco-$($arch.Name).lib" -ErrorAction SilentlyContinue
        "built $out ({0:N0} KB)" -f ((Get-Item $out).Length / 1KB)
    }
} finally {
    Pop-Location
}
