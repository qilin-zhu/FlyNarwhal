# Downloads the minimal Yaoplayer runtime (Yaoplayer.exe + lua51.dll +
# portable_config) and stages it for installation into the bundle's
# yaoplayer/ directory. Used for Dolby Vision profile 5 direct playback,
# where the external Yaoplayer window renders through vo=gpu-next + D3D11
# and applies the Dolby Vision RPU mapping that media_kit's vo=libmpv
# render path cannot reach.
#
# The runtime is published on the fly-narwhal-libmpv mirror as split 7z
# volumes (9 MB each) because the archive exceeds the reliable single-request
# download size on constrained networks. 7-Zip reads split archives natively
# when pointed at the .001 volume and validates every member's CRC during
# extraction, which is the integrity check (a volume hash pin would require
# joining the volumes first, and byte-array joins in Windows PowerShell 5.1
# have already produced one silent 0-byte-file incident in this repo).
function(ensure_yaoplayer_runtime_windows)
  if(NOT FLUTTER_TARGET_PLATFORM STREQUAL "windows-x64")
    return()
  endif()

  set(YAO_TAG "yaoplayer-runtime-v1")
  set(YAO_BASE "yaoplayer-runtime.7z")
  set(YAO_PARTS "001;002;003;004;005;006;007;008")

  set(MIRROR_URL "https://github.com/qilin-zhu/fly-narwhal-libmpv/releases/download/${YAO_TAG}")

  set(YAO_DIR "${CMAKE_BINARY_DIR}/yaoplayer")
  set(YAO_EXE "${YAO_DIR}/Yaoplayer/core-builds/current/Yaoplayer.exe")
  set(YAO_FIRST_VOLUME "${YAO_DIR}/${YAO_BASE}.001")
  file(MAKE_DIRECTORY "${YAO_DIR}")

  # -- Skip everything when the cached extraction is intact ------------------
  set(YAO_STAMP "${YAO_DIR}/runtime-stamp.txt")
  set(NEEDS_FETCH TRUE)
  if(EXISTS "${YAO_EXE}" AND EXISTS "${YAO_STAMP}")
    file(READ "${YAO_STAMP}" STAMP_TAG)
    string(STRIP "${STAMP_TAG}" STAMP_TAG)
    file(SIZE "${YAO_EXE}" EXE_SIZE)
    if(STAMP_TAG STREQUAL YAO_TAG AND EXE_SIZE GREATER 100000000)
      message(STATUS "[yaoplayer] Runtime cached (${EXE_SIZE} bytes), skipping download")
      set(NEEDS_FETCH FALSE)
    endif()
  endif()

  if(NEEDS_FETCH)
    file(TO_NATIVE_PATH "${YAO_DIR}" YAO_DIR_NATIVE)
    set(YAO_PWSH_PARTS "[string[]]@(")
    set(_first TRUE)
    foreach(_part IN LISTS YAO_PARTS)
      if(NOT _first)
        string(APPEND YAO_PWSH_PARTS ", ")
      endif()
      set(_first FALSE)
      string(APPEND YAO_PWSH_PARTS "'${YAO_BASE}.${_part}'")
    endforeach()
    string(APPEND YAO_PWSH_PARTS ")")

    # Download every volume with retry + mirror fallbacks. Each volume is
    # checked for a plausible size; 7z CRC validation during extraction is
    # the authoritative integrity check.
    execute_process(
      COMMAND powershell -NoProfile -ExecutionPolicy Bypass -Command
        "$ProgressPreference = 'SilentlyContinue'; Set-Location '${YAO_DIR_NATIVE}'; $parts = ${YAO_PWSH_PARTS}; $mirrors = @('${MIRROR_URL}', 'https://ghfast.top/${MIRROR_URL}', 'https://gh-proxy.com/${MIRROR_URL}'); foreach ($p in $parts) { $out = Join-Path (Get-Location) $p; $ok = $false; if (Test-Path $out) { if ((Get-Item $out).Length -gt 1000000) { $ok = $true } else { Remove-Item $out -Force } }; if ($ok) { Write-Host \"[yaoplayer] $p cached\"; continue }; foreach ($m in $mirrors) { Write-Host \"[yaoplayer] downloading $p from $m\"; try { Invoke-WebRequest -Uri ($m + '/' + $p) -OutFile $out -MaximumRedirection 10 -UseBasicParsing -TimeoutSec 120; if ((Test-Path $out) -and ((Get-Item $out).Length -gt 1000000)) { $ok = $true; break } } catch { if (Test-Path $out) { Remove-Item $out -Force } } }; if (-not $ok) { Write-Error \"[yaoplayer] failed to download $p\"; exit 1 } }"
      RESULT_VARIABLE YAO_DL_RESULT
      ERROR_VARIABLE YAO_DL_ERROR
    )
    if(NOT YAO_DL_RESULT EQUAL 0)
      message(FATAL_ERROR "[yaoplayer] Failed to fetch runtime volumes: ${YAO_DL_ERROR}")
    endif()

    # Locate 7z (same discovery order as full_libmpv).
    find_program(YAO_SEVENZ_EXE NAMES 7z 7za 7zr)
    if(NOT YAO_SEVENZ_EXE)
      foreach(TRY_PATH
          "C:/Program Files/7-Zip/7z.exe"
          "C:/Program Files (x86)/7-Zip/7z.exe"
        )
        if(EXISTS "${TRY_PATH}")
          set(YAO_SEVENZ_EXE "${TRY_PATH}")
          break()
        endif()
      endforeach()
    endif()
    if(NOT YAO_SEVENZ_EXE)
      set(YAO_SEVENZ_EXE "${YAO_DIR}/7zr.exe")
      if(NOT EXISTS "${YAO_SEVENZ_EXE}")
        file(TO_NATIVE_PATH "${YAO_SEVENZ_EXE}" YAO_SEVENZ_NATIVE)
        execute_process(
          COMMAND powershell -NoProfile -ExecutionPolicy Bypass -Command
            "Invoke-WebRequest -Uri 'https://www.7-zip.org/a/7zr.exe' -OutFile '${YAO_SEVENZ_NATIVE}' -MaximumRedirection 10 -UseBasicParsing"
          RESULT_VARIABLE YAO_7ZR_RESULT
          ERROR_VARIABLE YAO_7ZR_ERROR
        )
        if(NOT YAO_7ZR_RESULT EQUAL 0)
          message(FATAL_ERROR "[yaoplayer] Failed to download 7zr.exe: ${YAO_7ZR_ERROR}")
        endif()
      endif()
    endif()

    message(STATUS "[yaoplayer] Extracting runtime (~205 MB) from split volumes...")
    foreach(_part IN LISTS YAO_PARTS)
      if(EXISTS "${YAO_DIR}/${YAO_BASE}.${_part}")
        file(SIZE "${YAO_DIR}/${YAO_BASE}.${_part}" _part_size)
        message(STATUS "[yaoplayer] volume ${_part}: ${_part_size} bytes")
      else()
        message(STATUS "[yaoplayer] volume ${_part}: MISSING")
      endif()
    endforeach()
    message(STATUS "[yaoplayer] 7z binary: ${YAO_SEVENZ_EXE}")
    file(TO_NATIVE_PATH "${YAO_FIRST_VOLUME}" YAO_VOLUME_NATIVE)
    file(TO_NATIVE_PATH "${YAO_DIR}" YAO_DST_NATIVE)
    execute_process(
      COMMAND "${YAO_SEVENZ_EXE}" x "${YAO_VOLUME_NATIVE}" -o${YAO_DST_NATIVE} -y
      RESULT_VARIABLE YAO_EXTRACT_RESULT
      OUTPUT_VARIABLE YAO_EXTRACT_OUTPUT
      ERROR_VARIABLE YAO_EXTRACT_ERROR
    )
    message(STATUS "[yaoplayer] extract result=${YAO_EXTRACT_RESULT}")
    message(STATUS "[yaoplayer] extract stdout: ${YAO_EXTRACT_OUTPUT}")
    if(NOT YAO_EXTRACT_RESULT EQUAL 0)
      message(FATAL_ERROR "[yaoplayer] Extraction failed:\n${YAO_EXTRACT_OUTPUT}\n${YAO_EXTRACT_ERROR}")
    endif()
    if(NOT EXISTS "${YAO_EXE}")
      file(GLOB _extracted LIST_DIRECTORIES true "${YAO_DIR}/*")
      message(FATAL_ERROR "[yaoplayer] Yaoplayer.exe not found after extraction; dir contents: ${_extracted}")
    endif()
    file(SIZE "${YAO_EXE}" EXE_SIZE)
    if(EXE_SIZE LESS 100000000)
      message(FATAL_ERROR "[yaoplayer] Extracted Yaoplayer.exe is too small (${EXE_SIZE} bytes)")
    endif()
    file(WRITE "${YAO_STAMP}" "${YAO_TAG}")
    message(STATUS "[yaoplayer] Runtime ready (${EXE_SIZE} bytes)")
  endif()

  # Export for install() in parent scope.
  set(YAOPLAYER_RUNTIME_DIR "${YAO_DIR}/Yaoplayer" PARENT_SCOPE)
endfunction()
