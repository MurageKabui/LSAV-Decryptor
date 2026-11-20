@echo off
:: ===========================================================================
::  LSAV Decryptor - batch edition
::  Recover MIUI / HyperOS Gallery "Secret Album" photos (.lsa) and
::  videos (.lsav). Free, offline, open source.
::
::  Double-click this file. Everything it creates stays in this folder:
::    pulled\      encrypted files copied from the phone
::    decrypted\   your recovered photos and videos
::    tools\       ADB, if you let the tool download it
::    keys.txt     extra decryption keys (the default key is built in)
:: ===========================================================================
setlocal EnableExtensions EnableDelayedExpansion
title LSAV Decryptor
chcp 65001 >nul 2>&1

set "VERSION=1.1.0"
set "URL_GUIDE=https://blog.denniskabui.com/writing/decrypting-miui-cloud"
set "URL_REPO=https://github.com/MurageKabui/LSAV-Decryptor"
set "ROOT=%~dp0"
set "ROOT=%ROOT:~0,-1%"
set "ENGINE=%ROOT%\engine\lsa-engine.ps1"
set "KEYS=%ROOT%\keys.txt"
set "TMPD=%TEMP%\lsav-decryptor"
set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set ENGINE_CALL="%PSEXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%ENGINE%"

:: ---------------------------------------------------------------- colours
:: Black background + bright text everywhere, so nothing depends on the
:: terminal theme. "color" with no argument restores it on quit.
color 0F
set "NOCOLOR="
ver | find "10.0." >nul || set "NOCOLOR=1"
if defined NOCOLOR goto init_plain
for /f %%a in ('echo prompt $E^| cmd') do set "ESC=%%a"
set "R=%ESC%[0m"
set "B=%ESC%[1;97m"
set "D=%ESC%[37m"
set "C=%ESC%[96m"
set "G=%ESC%[92m"
set "Y=%ESC%[93m"
set "E=%ESC%[91m"
set "K=%ESC%[0;30;106m"
set "LN=%ESC%(0"
set "LF=%ESC%(B"
set "CLR=%ESC%[2K%ESC%[G"
set "HT=  %C%%LN%lqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqk%LF%%R%"
set "H1=  %C%%LN%x%LF%%R%%B%  LSAV DECRYPTOR                                      %R%%D%v1.1.0  %R%%C%%LN%x%LF%%R%"
set "H2=  %C%%LN%x%LF%%R%  Recover MIUI / HyperOS Secret Album photos and videos       %C%%LN%x%LF%%R%"
set "H3=  %C%%LN%x%LF%%R%%D%  Free  .  offline  .  nothing leaves your PC                 %R%%C%%LN%x%LF%%R%"
set "HS=  %C%%LN%tqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqu%LF%%R%"
set "H4=  %C%%LN%x%LF%%R%  %D%Guide   %R%%C%blog.denniskabui.com/writing/decrypting-miui-cloud  %R%%C%%LN%x%LF%%R%"
set "H5=  %C%%LN%x%LF%%R%  %D%Source  %R%%C%github.com/MurageKabui/LSAV-Decryptor               %R%%C%%LN%x%LF%%R%"
set "HB=  %C%%LN%mqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqj%LF%%R%"
set "BAR_FULL=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
set "BAR_EMPTY=qqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"
goto init_done

:init_plain
set "R=" & set "B=" & set "D=" & set "C=" & set "G=" & set "Y=" & set "E=" & set "K=" & set "CLR="
set "HT=  +--------------------------------------------------------------+"
set "H1=  |  LSAV DECRYPTOR                                      v1.1.0  |"
set "H2=  |  Recover MIUI / HyperOS Secret Album photos and videos       |"
set "H3=  |  Free  .  offline  .  nothing leaves your PC                 |"
set "HS=  +--------------------------------------------------------------+"
set "H4=  |  Guide   blog.denniskabui.com/writing/decrypting-miui-cloud  |"
set "H5=  |  Source  github.com/MurageKabui/LSAV-Decryptor               |"
set "HB=  +--------------------------------------------------------------+"
set "BAR_FULL=##############################"
set "BAR_EMPTY=.............................."

:init_done

:: ---------------------------------------------------------------- checks
if not exist "%PSEXE%" (
    echo.
    echo   Windows PowerShell was not found at:
    echo   %PSEXE%
    echo   LSAV Decryptor needs Windows 10 or 11, which include it.
    echo.
    pause
    exit /b 1
)
if not exist "%ENGINE%" (
    echo.
    echo   The engine folder is missing. Keep LSAV-Decryptor.bat next to the
    echo   "engine" folder it came with, then run it again.
    echo.
    pause
    exit /b 1
)
if not exist "%TMPD%" mkdir "%TMPD%" >nul 2>&1
if not exist "%KEYS%" call :write_keys_file

set "ADB="
set "SERIAL="
set "MODEL="
set "SCAN_SERIAL="
set "LAST_IN="
set "LAST_OUT="
set "PULLDIR="
set "RETRY_READY="


:: ===========================================================================
::  MAIN MENU
:: ===========================================================================
:menu
call :header "Main menu"
echo.
echo    %K% 1 %R%  %B%Decrypt .lsa / .lsav files that are on this PC%R%
echo         %D%Paste or drag in a file, or a folder that holds them%R%
echo.
echo    %K% 2 %R%  %B%Scan a phone over ADB, pull the files and decrypt%R%
echo         %D%Needs USB debugging on and the phone plugged in%R%
echo.
echo    %K% 3 %R%  %B%Key tools%R%
echo         %D%For files that will not decrypt: get their key%R%
echo.
echo    %K% 4 %R%  Open the decrypted folder
echo    %K% G %R%  Open the guide and source code in your browser
echo    %K% H %R%  How to turn on USB debugging
echo    %K% Q %R%  Quit
echo.
choice /C 1234GHQ /N /M "   Press a key: "
set "CH=%errorlevel%"
if "%CH%"=="1" goto local
if "%CH%"=="2" goto device
if "%CH%"=="3" goto keys
if "%CH%"=="4" goto open_root
if "%CH%"=="5" goto open_links
if "%CH%"=="6" (call :help & goto menu)
if "%CH%"=="7" goto quit
goto menu


:: ===========================================================================
::  1. DECRYPT FILES ALREADY ON THIS PC
:: ===========================================================================
:local
call :header "Main menu > Decrypt files on this PC"
echo.
echo    Paste the path to a %B%.lsa%R% or %B%.lsav%R% file, or to a folder that holds them.
echo.
echo    %D%- Easiest: drag the file or folder onto this window, then press Enter.%R%
echo    %D%- Folders are searched together with all their subfolders.%R%
echo    %D%- Press Enter on an empty line to go back.%R%
echo.
set "IN="
set /p "IN=%C%   Path%R% : "
if not defined IN goto menu
call :clean_path IN
if not defined IN goto menu
if not exist "!IN!" (
    echo.
    echo    %E%That path does not exist:%R% !IN!
    echo.
    pause
    goto local
)
call :stamp
set "LAST_IN=!IN!"
set "LAST_OUT=%ROOT%\decrypted\pc_!STAMP!"
set "CTX=local"
goto run_decrypt


:: ===========================================================================
::  2. SCAN A PHONE OVER ADB
:: ===========================================================================
:device
call :need_adb
if errorlevel 1 goto menu
call :pick_device "Main menu > Scan a phone"
if errorlevel 1 goto menu

:dev_scan
call :header "Scan a phone > !MODEL!"
echo.
echo    Searching %B%internal storage%R% and the %B%SD card%R% for .lsa / .lsav files...
echo    %D%Phones with lots of files can take a minute. Keep the phone connected.%R%
echo.
set "SCAN=%TMPD%\scan.txt"
"!ADB!" -s "!SERIAL!" exec-out "for d in /sdcard /storage/????-????; do [ -d $d/ ] || continue; if stat -c %%s / >/dev/null 2>&1; then find $d/ -type f \( -iname '*.lsa' -o -iname '*.lsav' \) -exec stat -c '%%s|%%n' {} + 2>/dev/null; else find $d/ -type f \( -iname '*.lsa' -o -iname '*.lsav' \) 2>/dev/null; fi; done" > "!SCAN!" 2>nul
set "SCAN_SERIAL=!SERIAL!"
%ENGINE_CALL% -Action NormalizeList -ListFile "!SCAN!"
set /a FOUND=0
for /f "usebackq delims=" %%l in ("!SCAN!") do set /a FOUND+=1
if !FOUND! GTR 0 goto dev_found

call :header "Scan a phone > !MODEL!"
echo.
echo    %Y%No .lsa or .lsav files were found on !MODEL!.%R%
echo.
echo    %D%- If the Secret Album is empty there is nothing to recover.%R%
echo    %D%- If it has items, open the Secret Album once on the phone, then scan again.%R%
echo    %D%- Some Gallery versions keep the album in private app storage that ADB%R%
echo    %D%  cannot read without root.%R%
echo.
echo    %K% S %R%  Scan again
echo    %K% B %R%  Back to the main menu
choice /C SB /N /M "   Press a key: "
if errorlevel 2 goto menu
goto dev_scan

:dev_found
call :header "Scan a phone > !MODEL!"
echo.
%ENGINE_CALL% -Action ScanSummary -ListFile "!SCAN!" -OutDir "%ROOT%" -Device "!MODEL!"
echo.
echo    %K% A %R%  %B%Pull all files and decrypt them%R%  %D%(recommended)%R%
echo    %K% P %R%  Pull all files only  %D%(decrypt later with option 1)%R%
echo    %K% L %R%  %B%Pick specific files%R% from the full list
echo    %K% S %R%  Scan again
echo    %K% B %R%  Back to the main menu
echo.
choice /C APLSB /N /M "   Press a key: "
set "CH=%errorlevel%"
if "%CH%"=="1" (set "DO_DECRYPT=1" & goto dev_pull_all)
if "%CH%"=="2" (set "DO_DECRYPT=" & goto dev_pull_all)
if "%CH%"=="3" goto dev_list
if "%CH%"=="4" goto dev_scan
if "%CH%"=="5" goto menu
goto dev_found

:dev_list
call :header "Scan a phone > !MODEL! > Pick files"
echo.
%ENGINE_CALL% -Action ScanSummary -ListFile "!SCAN!" -Device "!MODEL!" -Full
:dev_pick
echo.
echo    %B%Type which files to pull, then press Enter.%R%
echo.
echo      %C%7%R%              one file
echo      %C%3-12%R%           a range
echo      %C%1,4,9-12%R%       several, separated by commas or spaces
echo      %C%photos%R%         every .lsa      %C%videos%R%  every .lsav      %C%all%R%  everything
echo      %C%secretAlbum%R%    every file whose path contains that text
echo      %C%-5%R%  %C%-DCIM%R%      a minus leaves files out, e.g. %C%videos -DCIM%R%
echo.
echo    %D%Press Enter on an empty line to go back.%R%
echo.
set "SEL="
set /p "SEL=%C%   Files%R% : "
if not defined SEL goto dev_found
>"%TMPD%\selection.txt" echo(!SEL!
echo.
%ENGINE_CALL% -Action Select -ListFile "!SCAN!" -InputPath "%TMPD%\selection.txt" -OutDir "%TMPD%\selected.txt"
if errorlevel 1 goto dev_pick
set "PULLLIST=%TMPD%\selected.txt"
set /a PCOUNT=0
for /f "usebackq delims=" %%l in ("!PULLLIST!") do set /a PCOUNT+=1
echo.
echo    %K% A %R%  %B%Pull these !PCOUNT! file^(s^) and decrypt them%R%
echo    %K% P %R%  Pull these only
echo    %K% C %R%  Change the selection
echo    %K% L %R%  Show the full list again
echo    %K% B %R%  Back
echo.
choice /C APCLB /N /M "   Press a key: "
set "CH=%errorlevel%"
if "%CH%"=="1" (set "DO_DECRYPT=1" & goto dev_pull)
if "%CH%"=="2" (set "DO_DECRYPT=" & goto dev_pull)
if "%CH%"=="3" goto dev_pick
if "%CH%"=="4" goto dev_list
goto dev_found

:dev_pull_all
set "PULLLIST=!SCAN!"
set "PCOUNT=!FOUND!"

:dev_pull
call :stamp
set "SAFE=!SERIAL::=-!"
set "PULLDIR=%ROOT%\pulled\!SAFE!_!STAMP!"
if not exist "!PULLDIR!" mkdir "!PULLDIR!" >nul 2>&1
set "FAILLIST=!PULLDIR!\pull-failed.txt"
set /a PI=0, POK=0, PFAIL=0
call :header "Scan a phone > !MODEL! > Pulling"
echo.
echo    Copying !PCOUNT! file^(s^) from !MODEL! into:
echo    %C%!PULLDIR!%R%
echo    %D%Keep the phone connected and unlocked.%R%
echo.
for /f "usebackq tokens=1* delims=|" %%a in ("!PULLLIST!") do (
    if "%%b"=="" (set "RP=%%a") else (set "RP=%%b")
    call :pull_one
)
echo.
echo.
echo    Pulled %G%!POK!%R% of !PCOUNT! file^(s^).
if !PFAIL! GTR 0 (
    echo    %Y%!PFAIL! file^(s^) could not be copied. The list is in:%R%
    echo    !FAILLIST!
)
if !POK! EQU 0 (
    echo.
    echo    %E%Nothing was copied.%R% Check the cable and that the phone is unlocked, then try again.
    echo.
    pause
    goto dev_found
)
if not defined DO_DECRYPT goto dev_pulled_only

echo.
echo    %B%Decrypting...%R%
set "LAST_IN=!PULLDIR!"
set "LAST_OUT=%ROOT%\decrypted\!SAFE!_!STAMP!"
set "CTX=device"
goto run_decrypt

:dev_pulled_only
echo.
echo    The encrypted files are saved in:
echo    %C%!PULLDIR!%R%
echo    %D%Decrypt them any time: main menu, option 1, then paste that folder.%R%
echo.
echo    %K% D %R%  Decrypt them now
echo    %K% O %R%  Open that folder
echo    %K% M %R%  Main menu
choice /C DOM /N /M "   Press a key: "
set "CH=%errorlevel%"
if "%CH%"=="1" (
    set "LAST_IN=!PULLDIR!"
    set "LAST_OUT=%ROOT%\decrypted\!SAFE!_!STAMP!"
    set "CTX=device"
    goto run_decrypt
)
if "%CH%"=="2" start "" explorer.exe "!PULLDIR!"
goto menu


:: ===========================================================================
::  DECRYPT + RESULT SCREEN (shared by both flows)
:: ===========================================================================
:run_decrypt
if "!CTX!"=="local" call :header "Main menu > Decrypt files on this PC"
echo.
%ENGINE_CALL% -Action Decrypt -InputPath "!LAST_IN!" -OutDir "!LAST_OUT!" -KeysFile "%KEYS%"
set "RC=!errorlevel!"

:after_decrypt
echo.
if "!RC!"=="2" goto ad_nothing
if "!RC!"=="9" goto ad_engine_error
if "!RC!"=="0" (set "RETRY_READY=") else (set "RETRY_READY=1")
if "!RC!"=="3" goto ad_none_saved
if not exist "!LAST_OUT!" goto ad_none_saved
echo    %B%Your recovered photos and videos are in:%R%
echo    %C%!LAST_OUT!%R%
if "!CTX!"=="device" echo    %D%Encrypted originals kept in: !PULLDIR!%R%
echo.
:ad_menu
echo    %K% O %R%  Open that folder
if defined RETRY_READY echo    %K% K %R%  %Y%Key tools%R%  %D%(get the key for the files that failed)%R%
if defined RETRY_READY echo    %K% R %R%  Retry the files that failed
echo    %K% M %R%  Main menu
echo.
choice /C OKRM /N /M "   Press a key: "
set "CH=%errorlevel%"
if "%CH%"=="1" (
    if exist "!LAST_OUT!" start "" explorer.exe "!LAST_OUT!"
    goto ad_menu
)
if "%CH%"=="2" goto keys
if "%CH%"=="3" goto ad_retry
goto menu

:ad_none_saved
echo    %Y%No file could be decrypted.%R% The list above says why for each file.
if exist "!LAST_OUT!\decryption-report.txt" echo    %D%Report: !LAST_OUT!\decryption-report.txt%R%
echo.
goto ad_menu

:ad_retry
if not defined RETRY_READY goto ad_menu
call :header "Retry"
echo.
echo    Retrying with every saved key. Files that already worked are skipped.
%ENGINE_CALL% -Action Decrypt -InputPath "!LAST_IN!" -OutDir "!LAST_OUT!" -KeysFile "%KEYS%"
set "RC=!errorlevel!"
goto after_decrypt

:ad_nothing
echo    %Y%Nothing to decrypt there.%R% Point it at .lsa / .lsav files or a folder that holds them.
echo.
pause
goto menu

:ad_engine_error
echo    %E%The engine stopped with an error%R% (shown above).
echo    %D%If it mentions PowerShell being locked down, run the tool on a personal PC.%R%
echo.
pause
goto menu


:: ===========================================================================
::  3. KEY TOOLS
:: ===========================================================================
:keys
call :header "Main menu > Key tools"
echo.
echo    %D%MIUI encrypts with a key taken from the Gallery app's signing certificate.%R%
echo    %D%One key is built in. Phones on another Gallery build use another key, and%R%
echo    %D%their file names carry its fingerprint, so a wrong key is always detected.%R%
echo.
echo    %K% 1 %R%  %B%Extract the key from a connected phone%R%  %D%(most reliable)%R%
echo    %K% 2 %R%  Extract the key from a Gallery APK file on this PC
echo    %K% 3 %R%  Deep key search  %D%(recover the key from file names, offline)%R%
echo    %K% 4 %R%  Show saved keys
if defined RETRY_READY echo    %K% R %R%  %G%Retry the files that failed%R%
echo    %K% B %R%  Back
echo.
choice /C 1234RB /N /M "   Press a key: "
set "CH=%errorlevel%"
if "%CH%"=="1" goto keys_phone
if "%CH%"=="2" goto keys_apk
if "%CH%"=="3" goto keys_search
if "%CH%"=="4" goto keys_list
if "%CH%"=="5" goto keys_retry
goto menu

:keys_retry
if not defined RETRY_READY goto keys
goto ad_retry

:keys_phone
call :need_adb
if errorlevel 1 goto keys
call :pick_device "Key tools > Extract from a phone"
if errorlevel 1 goto keys
call :header "Key tools > Extract from !MODEL!"
echo.
echo    Looking for the Gallery app on !MODEL!...
"!ADB!" -s "!SERIAL!" exec-out pm path com.miui.gallery > "%TMPD%\pm.txt" 2>nul
set "APKREMOTE="
for /f "usebackq tokens=1* delims=:" %%a in ("%TMPD%\pm.txt") do (
    if /i "%%a"=="package" if not defined APKREMOTE set "APKREMOTE=%%b"
)
if not defined APKREMOTE (
    echo.
    echo    %E%The MIUI Gallery app ^(com.miui.gallery^) is not installed on this phone.%R%
    echo.
    pause
    goto keys
)
set "SAFE=!SERIAL::=-!"
set "APKDIR=%ROOT%\tools\gallery-apk"
if not exist "!APKDIR!" mkdir "!APKDIR!" >nul 2>&1
set "APKLOCAL=!APKDIR!\!SAFE!-gallery.apk"
echo    Copying it to this PC %D%(only the app, nothing personal)%R%...
"!ADB!" -s "!SERIAL!" pull "!APKREMOTE!" "!APKLOCAL!" >nul 2>&1
if errorlevel 1 (
    echo.
    echo    %E%Could not copy the Gallery app from the phone.%R%
    echo    %D%!APKREMOTE!%R%
    echo.
    pause
    goto keys
)
set "CMPARG="
if "!SCAN_SERIAL!"=="!SERIAL!" if exist "%TMPD%\scan.txt" set CMPARG=-Compare "%TMPD%\scan.txt"
if not defined CMPARG if defined LAST_IN set CMPARG=-Compare "!LAST_IN!"
echo.
%ENGINE_CALL% -Action ExtractKey -Apk "!APKLOCAL!" -KeysFile "%KEYS%" !CMPARG!
echo.
pause
goto keys

:keys_apk
call :header "Key tools > Extract from an APK file"
echo.
echo    Paste the path to the Gallery APK %D%(for example MiuiGallery.apk or base.apk)%R%.
echo    %D%Press Enter on an empty line to go back.%R%
echo.
set "IN="
set /p "IN=%C%   APK%R% : "
if not defined IN goto keys
call :clean_path IN
if not exist "!IN!" (
    echo    %E%That file does not exist.%R%
    pause
    goto keys_apk
)
set "CMPARG="
if defined LAST_IN set CMPARG=-Compare "!LAST_IN!"
echo.
%ENGINE_CALL% -Action ExtractKey -Apk "!IN!" -KeysFile "%KEYS%" !CMPARG!
echo.
pause
goto keys

:keys_search
call :header "Key tools > Deep key search"
echo.
echo    Every encrypted file name carries the MD5 fingerprint of its key. Android
echo    signing certificates all start the same way, so the key can be rebuilt
echo    from the fingerprint alone. No phone and no internet needed.
echo.
echo    Paste the path to the files that failed, or a folder that holds them.
if defined LAST_IN echo    %D%Press Enter to use:%R% !LAST_IN!
if not defined LAST_IN echo    %D%Press Enter on an empty line to go back.%R%
echo.
set "IN="
set /p "IN=%C%   Path%R% : "
if not defined IN if defined LAST_IN set "IN=!LAST_IN!"
if not defined IN goto keys
call :clean_path IN
if not exist "!IN!" (
    echo    %E%That path does not exist.%R%
    pause
    goto keys_search
)
echo.
%ENGINE_CALL% -Action FindKey -InputPath "!IN!" -KeysFile "%KEYS%"
set "RC=!errorlevel!"
if not "!RC!"=="4" goto keys_search_done
echo.
echo    %K% Y %R%  Run the extended search  %D%(rarer certificate types, takes longer)%R%
echo    %K% N %R%  No, go back
choice /C YN /N /M "   Press a key: "
if errorlevel 2 goto keys
echo.
%ENGINE_CALL% -Action FindKey -InputPath "!IN!" -KeysFile "%KEYS%" -Extended
:keys_search_done
echo.
pause
goto keys

:keys_list
call :header "Key tools > Saved keys"
echo.
%ENGINE_CALL% -Action ListKeys -KeysFile "%KEYS%"
echo.
echo    %D%Add your own keys to keys.txt, one per line (32 hex characters).%R%
echo    %D%!KEYS!%R%
echo.
pause
goto keys


:: ===========================================================================
::  SMALL SCREENS
:: ===========================================================================
:open_links
start "" "%URL_GUIDE%"
start "" "%URL_REPO%"
goto menu

:open_root
if not exist "%ROOT%\decrypted" mkdir "%ROOT%\decrypted" >nul 2>&1
start "" explorer.exe "%ROOT%\decrypted"
goto menu

:quit
color
cls
echo.
echo    Thanks for using LSAV Decryptor.
echo.
echo    Guide   %URL_GUIDE%
echo    Source  %URL_REPO%
echo.
endlocal
exit /b 0

:help
call :header "Help > Turn on USB debugging"
echo.
echo    %B%On the phone%R%  %D%(Xiaomi, Redmi and POCO; MIUI and HyperOS)%R%
echo.
echo    %C%1%R%  Settings ^> About phone. Tap %B%MIUI version%R% or %B%OS version%R% 7 times
echo       until it says you are now a developer.
echo    %C%2%R%  Settings ^> Additional settings ^> Developer options.
echo       Turn on %B%USB debugging%R%.
echo    %C%3%R%  Plug the phone into this PC with a USB data cable and unlock it.
echo    %C%4%R%  A prompt appears: "Allow USB debugging?". Tick
echo       "Always allow from this computer" and tap %B%Allow%R%.
echo.
echo    %B%If the phone does not show up%R%
echo.
echo    %D%-%R% Pull the notification shade, tap the USB notice, choose %B%File transfer%R%.
echo    %D%-%R% Try another cable or port. Charge-only cables carry no data.
echo    %D%-%R% Developer options ^> %B%Revoke USB debugging authorizations%R%, then replug.
echo    %D%-%R% Still nothing: install the Google USB Driver or Xiaomi USB driver.
echo.
echo    %D%Turn USB debugging off again when you are done.%R%
echo.
pause
exit /b 0


:: ===========================================================================
::  SUBROUTINES
:: ===========================================================================

:header
cls
set "CRUMB=%~1"
echo.
echo !HT!
echo !H1!
echo !H2!
echo !H3!
echo !HS!
echo !H4!
echo !H5!
echo !HB!
echo    %D%!CRUMB!%R%
exit /b 0

:: Remove quotes and outer spaces; a trailing backslash would escape the
:: closing quote when passed on, so "D:\photos\" becomes "D:\photos\."
:clean_path
set "_p=!%~1!"
set "_p=!_p:"=!"
:cp_lead
if "!_p:~0,1!"==" " (set "_p=!_p:~1!" & goto cp_lead)
:cp_trail
if "!_p:~-1!"==" " (set "_p=!_p:~0,-1!" & goto cp_trail)
if "!_p:~-1!"=="\" set "_p=!_p!."
set "%~1=!_p!"
if "!_p!"=="" set "%~1="
exit /b 0

:stamp
set "STAMP="
for /f "delims=" %%t in ('""%PSEXE%" -NoLogo -NoProfile -Command "Get-Date -Format yyyy-MM-dd_HHmmss""') do set "STAMP=%%t"
if not defined STAMP set "STAMP=%RANDOM%%RANDOM%"
exit /b 0

:write_keys_file
>"%KEYS%"  echo # LSAV Decryptor - extra decryption keys
>>"%KEYS%" echo #
>>"%KEYS%" echo # One key per line: 32 hex characters (16 bytes). Text after # is a comment.
>>"%KEYS%" echo # The default MIUI Global Gallery key is built in, so it is not needed here:
>>"%KEYS%" echo #   3082046c30820354a003020102020900   (fingerprint 3e751332435bfad27569ca4efed1b602)
>>"%KEYS%" echo # Key tools in the main menu add keys here automatically.
>>"%KEYS%" echo.
exit /b 0

:: ---------------------------------------------------------------- ADB

:need_adb
if defined ADB if exist "!ADB!" exit /b 0
set "ADB="
for /f "delims=" %%a in ('where adb.exe 2^>nul') do if not defined ADB set "ADB=%%a"
if not defined ADB if exist "%ROOT%\tools\platform-tools\adb.exe" set "ADB=%ROOT%\tools\platform-tools\adb.exe"
if defined ADB exit /b 0
call :header "Setup > ADB"
echo.
echo    %Y%ADB was not found on this PC.%R%
echo.
echo    ADB ^(Android Debug Bridge^) is Google's free tool for talking to Android
echo    phones over USB. LSAV Decryptor uses it to find and copy the encrypted
echo    files. It can be downloaded now, straight from Google ^(about 7 MB^), into:
echo    %C%!ROOT!\tools\platform-tools%R%
echo.
echo    %K% Y %R%  Download it now
echo    %K% N %R%  No, go back
echo.
choice /C YN /N /M "   Press a key: "
if errorlevel 2 exit /b 1
echo.
%ENGINE_CALL% -Action GetAdb -Dest "%ROOT%\tools"
if errorlevel 1 (
    echo.
    pause
    exit /b 1
)
set "ADB=%ROOT%\tools\platform-tools\adb.exe"
timeout /t 1 >nul
exit /b 0

:: Sets SERIAL, MODEL. Returns 1 when the user goes back.
:pick_device
set "CRUMB2=%~1"
:pd_refresh
call :header "!CRUMB2! > Choose a phone"
echo.
echo    %D%Looking for phones...%R%
"!ADB!" start-server >nul 2>&1
"!ADB!" devices > "%TMPD%\devices.txt" 2>nul
set /a DN=0
for /f "usebackq tokens=1,2" %%a in ("%TMPD%\devices.txt") do (
    if /i "%%b"=="device" call :pd_add "%%a" "%%b"
    if /i "%%b"=="unauthorized" call :pd_add "%%a" "%%b"
    if /i "%%b"=="offline" call :pd_add "%%a" "%%b"
    if /i "%%b"=="recovery" call :pd_add "%%a" "%%b"
    if /i "%%b"=="sideload" call :pd_add "%%a" "%%b"
)
call :header "!CRUMB2! > Choose a phone"
echo.
if %DN% EQU 0 goto pd_none
echo    %B%Phones connected to this PC%R%
echo.
for /l %%i in (1,1,%DN%) do call :pd_show %%i
echo.
set "_keys="
set /a _nk=DN
if %_nk% GTR 9 set /a _nk=9
for /l %%i in (1,1,%_nk%) do set "_keys=!_keys!%%i"
if %DN% GTR 9 echo    %D%Only the first 9 phones can be picked. Unplug the others.%R%
echo    %K% R %R%  Refresh     %K% H %R%  Help     %K% B %R%  Back
echo.
choice /C !_keys!RHB /N /M "   Pick a phone by its number: "
set "_c=!errorlevel!"
set /a _nr=_nk+1, _nh=_nk+2, _nb=_nk+3
if !_c! EQU 0 goto pd_refresh
if !_c! EQU !_nb! exit /b 1
if !_c! EQU !_nh! (call :help & goto pd_refresh)
if !_c! GEQ !_nr! goto pd_refresh
for %%n in (!_c!) do (
    set "SERIAL=!DEV_S_%%n!"
    set "STATE=!DEV_T_%%n!"
    set "MODEL=!DEV_M_%%n!"
)
if /i "!STATE!"=="device" exit /b 0
echo.
if /i "!STATE!"=="unauthorized" (
    echo    %Y%This phone has not allowed this PC yet.%R%
    echo    Unlock it and tap %B%Allow%R% on the "Allow USB debugging?" prompt.
    echo    %D%No prompt? Unplug the cable and plug it back in.%R%
) else (
    echo    %Y%This phone is !STATE!.%R% Unplug the cable, plug it back in and refresh.
)
echo.
pause
goto pd_refresh

:pd_none
echo    %Y%No phone found.%R%
echo.
echo    Check that:
echo     %C%1%R%  The phone is unlocked and plugged in with a USB data cable
echo     %C%2%R%  USB debugging is on  %D%(press H for the steps)%R%
echo     %C%3%R%  You tapped %B%Allow%R% on the "Allow USB debugging?" prompt on the phone
echo     %C%4%R%  The phone's USB mode is %B%File transfer%R%  %D%(some PCs need it)%R%
echo.
echo    %K% R %R%  Refresh     %K% H %R%  Help     %K% B %R%  Back
echo.
choice /C RHB /N /M "   Press a key: "
if errorlevel 3 exit /b 1
if errorlevel 2 (call :help & goto pd_refresh)
goto pd_refresh

:pd_add
set /a DN+=1
set "DEV_S_%DN%=%~1"
set "DEV_T_%DN%=%~2"
set "DEV_M_%DN%=unknown phone"
if /i not "%~2"=="device" exit /b 0
set "_mk=" & set "_md=" & set "_mf=" & set "_av="
"!ADB!" -s "%~1" exec-out getprop ro.product.marketname > "%TMPD%\prop.txt" 2>nul
for /f "usebackq delims=" %%m in ("%TMPD%\prop.txt") do set "_mk=%%m"
"!ADB!" -s "%~1" exec-out getprop ro.product.model > "%TMPD%\prop.txt" 2>nul
for /f "usebackq delims=" %%m in ("%TMPD%\prop.txt") do set "_md=%%m"
"!ADB!" -s "%~1" exec-out getprop ro.product.manufacturer > "%TMPD%\prop.txt" 2>nul
for /f "usebackq delims=" %%m in ("%TMPD%\prop.txt") do set "_mf=%%m"
"!ADB!" -s "%~1" exec-out getprop ro.build.version.release > "%TMPD%\prop.txt" 2>nul
for /f "usebackq delims=" %%m in ("%TMPD%\prop.txt") do set "_av=%%m"
if defined _mk (set "_name=!_mk!") else (set "_name=!_mf! !_md!")
if defined _av set "_name=!_name!, Android !_av!"
set "DEV_M_%DN%=!_name!"
exit /b 0

:pd_show
set "_s=!DEV_S_%1!"
set "_t=!DEV_T_%1!"
set "_m=!DEV_M_%1!"
if /i "!_t!"=="device" (
    echo    %K% %1 %R%  %B%!_m!%R%   %D%!_s!%R%   %G%ready%R%
) else if /i "!_t!"=="unauthorized" (
    echo    %K% %1 %R%  !_m!   %D%!_s!%R%   %Y%tap Allow on the phone%R%
) else (
    echo    %K% %1 %R%  !_m!   %D%!_s!%R%   %Y%!_t!%R%
)
exit /b 0

:: Pull one file: RP = path on the phone. Mirrors the phone's folders.
:pull_one
set /a PI+=1
set "LP=!RP://=/!"
set "LP=!LP:~1!"
set "LP=!LP:/=\!"
set "LFILE=!PULLDIR!\!LP!"
for %%F in ("!LFILE!") do (set "LDIR=%%~dpF" & set "LNAME=%%~nxF")
if not exist "!LDIR!" mkdir "!LDIR!" >nul 2>&1
set /a PCT=PI*100/PCOUNT, BARN=PI*30/PCOUNT
set "_bar=%C%%LN%!BAR_FULL:~0,%BARN%!%D%!BAR_EMPTY:~%BARN%!%LF%%R%"
if defined NOCOLOR set "_bar=!BAR_FULL:~0,%BARN%!!BAR_EMPTY:~%BARN%!"
set "_nm=!LNAME:~0,40!"
if defined NOCOLOR (
    echo    [!PI!/!PCOUNT!] !_nm!
) else (
    <nul set /p "=%CLR%   !_bar!  !PCT!%%  %D%!PI!/!PCOUNT!%R%  !_nm!"
)
"!ADB!" -s "!SERIAL!" pull -a "!RP!" "!LFILE!" >nul 2>&1
if errorlevel 1 "!ADB!" -s "!SERIAL!" pull "!RP!" "!LFILE!" >nul 2>&1
if errorlevel 1 (
    set /a PFAIL+=1
    >>"!FAILLIST!" echo !RP!
) else (
    set /a POK+=1
)
exit /b 0
