<#
.SYNOPSIS
  Build MbedTLS (static) for Windows and install it into
    windows/third_party/mbedtls-windows
  which windows/CMakeLists.txt points find_package(MbedTLS 3) at (via
  CMAKE_PREFIX_PATH). Windows ships no system OpenSSL, so libdatachannel
  (USE_MBEDTLS) and its bundled libSRTP need this MbedTLS -- built with
  MBEDTLS_SSL_DTLS_SRTP -- before the plugin's Windows build can succeed.

  This is the Windows counterpart of tools/build_mbedtls_macos.sh (host build --
  no cross-compile). DTLS-SRTP key extraction REQUIRES MBEDTLS_SSL_DTLS_SRTP,
  which the default MbedTLS config leaves off.

.PARAMETER Config
  MSVC build configuration to produce. Defaults to Debug because
  `flutter test -d windows` builds the app (and therefore this plugin +
  libdatachannel) in Debug, and the MSVC dynamic runtime (/MDd) baked into these
  static libs must match the consuming build or the link fails with LNK2038
  ("mismatch detected for 'RuntimeLibrary'"). Pass -Config Release to link
  against a release Flutter build instead.

.EXAMPLE
  pwsh tools/build_mbedtls_windows.ps1
  pwsh tools/build_mbedtls_windows.ps1 -Config Release -MbedtlsVersion 3.6.2
#>
[CmdletBinding()]
param(
  [ValidateSet('Debug', 'Release')]
  [string]$Config = 'Debug',
  [string]$MbedtlsVersion = '3.6.2',
  [string]$Cmake = 'cmake',
  [string]$Arch = 'x64'
)

$ErrorActionPreference = 'Stop'

$PluginDir = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Prefix = Join-Path $PluginDir 'windows\third_party\mbedtls-windows'

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ("mbedtls-win-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Work | Out-Null

try {
  $tarball = Join-Path $Work 'mbedtls.tar.bz2'
  $url = "https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-$MbedtlsVersion/mbedtls-$MbedtlsVersion.tar.bz2"
  Write-Host "Downloading MbedTLS $MbedtlsVersion ..."
  Invoke-WebRequest -Uri $url -OutFile $tarball

  # Windows' bundled tar.exe (bsdtar) has no built-in bz2 filter, so extract with
  # Python's tarfile (bz2 is native) -- Python is already required below anyway.
  Write-Host "Extracting ..."
  $tarballPy = $tarball -replace '\\', '/'
  $workPy = $Work -replace '\\', '/'
  & python -c "import tarfile; tarfile.open('$tarballPy','r:bz2').extractall('$workPy')"
  if ($LASTEXITCODE -ne 0) { throw "tar extraction failed ($LASTEXITCODE)" }
  $Src = Join-Path $Work "mbedtls-$MbedtlsVersion"

  # libdatachannel's media path (DTLS-SRTP key extraction) needs MbedTLS built
  # with MBEDTLS_SSL_DTLS_SRTP, which the default config leaves off.
  $cfgPy = Join-Path $Src 'scripts\config.py'
  $cfgH = Join-Path $Src 'include\mbedtls\mbedtls_config.h'
  Write-Host "Enabling MBEDTLS_SSL_DTLS_SRTP ..."
  & python $cfgPy -f $cfgH set MBEDTLS_SSL_DTLS_SRTP
  if ($LASTEXITCODE -ne 0) { throw "config.py failed ($LASTEXITCODE)" }

  # Disable the optional acceleration modules (Everest X25519, p256-m P-256
  # driver). They build as SEPARATE static libs (everest.lib / p256m.lib) that
  # mbedcrypto.lib references but that libdatachannel's FindMbedTLS does not link,
  # which would leave unresolved symbols at plugin link time. Turning them off
  # keeps mbedcrypto self-contained; MbedTLS falls back to its standard X25519 /
  # P-256 implementations, which DTLS-SRTP does not depend on.
  Write-Host "Disabling Everest / p256-m so mbedcrypto is self-contained ..."
  & python $cfgPy -f $cfgH unset MBEDTLS_ECDH_VARIANT_EVEREST_ENABLED
  & python $cfgPy -f $cfgH unset MBEDTLS_PSA_P256M_DRIVER_ENABLED

  $Build = Join-Path $Work 'build'
  Write-Host "=== Building MbedTLS for Windows ($Arch / $Config) -> $Prefix ==="
  if (Test-Path $Prefix) { Remove-Item -Recurse -Force $Prefix }

  # Multi-config Visual Studio generator; select $Config at build/install time.
  # CMAKE_MSVC_RUNTIME_LIBRARY defaults to the dynamic CRT (/MD, /MDd), matching
  # a default Flutter Windows build -- keep it dynamic and config-aware.
  & $Cmake -S $Src -B $Build -G "Visual Studio 17 2022" -A $Arch `
    -DCMAKE_MSVC_RUNTIME_LIBRARY="MultiThreaded`$<`$<CONFIG:Debug>:Debug>DLL" `
    -DGEN_FILES=OFF -DENABLE_TESTING=OFF -DENABLE_PROGRAMS=OFF `
    -DUSE_STATIC_MBEDTLS_LIBRARY=ON -DUSE_SHARED_MBEDTLS_LIBRARY=OFF `
    -DCMAKE_INSTALL_PREFIX="$Prefix"
  if ($LASTEXITCODE -ne 0) { throw "cmake configure failed ($LASTEXITCODE)" }

  & $Cmake --build $Build --config $Config --target install
  if ($LASTEXITCODE -ne 0) { throw "cmake build/install failed ($LASTEXITCODE)" }

  Write-Host "Done. Installed to $Prefix"
  $cfg = Join-Path $Prefix 'include\mbedtls\mbedtls_config.h'
  if ((Get-Content $cfg -Raw) -match '(?m)^\s*#define\s+MBEDTLS_SSL_DTLS_SRTP') {
    Write-Host "  MBEDTLS_SSL_DTLS_SRTP: ON"
  }
  else {
    Write-Warning "MBEDTLS_SSL_DTLS_SRTP not set in $cfg"
  }
}
finally {
  Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
}
