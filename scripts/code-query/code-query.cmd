@echo off
REM Windows shim — invoke code_query.py with a clean Python environment.
REM We unset PYTHONPATH/PYTHONHOME to dodge the uv-installed-Python SRE
REM mismatch trap that sometimes leaks into a normal cmd session.
setlocal
set "HERE=%~dp0"
set "PYTHONPATH="
set "PYTHONHOME="
REM Prefer Python312 explicitly; fall back to py launcher, then `python`.
set "CQ_PY=C:\Users\lizeqiang\AppData\Local\Programs\Python\Python312\python.exe"
if not exist "%CQ_PY%" (
    where py >nul 2>&1 && set "CQ_PY=py -3"
)
if not defined CQ_PY set "CQ_PY=python"
"%CQ_PY%" "%HERE%code_query.py" %*
endlocal
