@echo off
rem Builds refgen.exe (host reference) with MSVC x64. XRoar sources: reference\xroar\src
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" >nul
set X=%~dp0..\..\reference\xroar\src
cl /nologo /O2 /std:c11 /W1 /D"ssize_t=long long" /I"%~dp0stubs" /I"%~dp0." /I"%X%" /I"%X%\src" /I"%X%\portalib" "%~dp0refgen.c" "%X%\src\mc6809\mc6809.c" "%X%\portalib\delegate.c" /Fe"%~dp0refgen.exe" /Fo"%~dp0\" 
