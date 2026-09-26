@echo off
rem Runs pp with Python; falls back to the py launcher when "python" is missing or too old.
python -c "import sys; sys.exit(sys.version_info < (3, 9))" 2>nul
if errorlevel 1 (py -3 "%~dp0pp" %*) else (python "%~dp0pp" %*)
