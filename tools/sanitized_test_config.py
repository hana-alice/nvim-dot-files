import os
from pathlib import Path


def _env_path(name: str, default: str) -> Path:
    return Path(os.environ.get(name, default))


LOCALAPPDATA = Path(os.environ.get("LOCALAPPDATA", str(Path.home() / "AppData" / "Local")))
CODELLDB_ROOT = _env_path(
    "NVIM_UE_CODELLDB_ROOT",
    str(LOCALAPPDATA / "nvim" / "data" / "codelldb" / "extension" / "extension"),
)
ENGINE_ROOT = _env_path("NVIM_UE_ENGINE_ROOT", r"D:\UE\EngineRoot")
PROJECT_ROOT = _env_path("NVIM_UE_PROJECT_ROOT", r"D:\UE\ProjectRoot")
ANDROID_PACKAGE = os.environ.get("NVIM_UE_ANDROID_PACKAGE", "com.example.game")
SYMBOL_PATH = _env_path(
    "NVIM_UE_SYMBOL_PATH",
    str(PROJECT_ROOT / "Intermediate" / "Android" / "arm64" / "jni" / "arm64-v8a" / "libUE4.so"),
)
