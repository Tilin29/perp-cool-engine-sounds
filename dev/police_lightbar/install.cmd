@echo off
rem Copies addons\police_lightbar (this repo) into garrysmodddons\police_lightbar, where GMod mounts it
rem (it does not mount addons nested in an addon, nor, it seems, a directory junction). Restart GMod after.
robocopy "%~dp0..\..ddons\police_lightbar" "%~dp0..\..\..\police_lightbar" /MIR /NJH /NJS /NP
if %ERRORLEVEL% GEQ 8 (echo copy failed) else (echo garrysmodddons\police_lightbar is up to date)
