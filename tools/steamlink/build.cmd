@echo off
rem Builds SDCoopSteamLink.exe into mods\SDCoop\steamlink (see build.ps1).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" %*
