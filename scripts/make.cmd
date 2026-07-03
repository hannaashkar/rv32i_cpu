@echo off
rem Forward make invocations into the MSYS2 UCRT64 environment.
rem Usage (from repo root, PowerShell or cmd):  scripts\make.cmd test
set CHERE_INVOKING=1
set MSYSTEM=UCRT64
C:\Users\ASUS\tools\msys64\usr\bin\bash.exe -lc "make %*"
