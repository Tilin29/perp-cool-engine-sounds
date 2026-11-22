@echo off
rem Copies addons\police_lightbar (this repo) into garrysmod\addons\police_lightbar, where GMod mounts it
rem (it does not mount addons nested in an addon, nor, it seems, a directory junction). Restart GMod after.
robocopy "%~dp0..\..\addons\police_lightbar" "%~dp0..\..\..\police_lightbar" /MIR /NJH /NJS /NP
if %ERRORLEVEL% GEQ 8 (echo copy failed) else (echo garrysmod\addons\police_lightbar is up to date)
