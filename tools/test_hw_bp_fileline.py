"""
Minimal standalone LLDB test: file+line HW BP on Android.
Tests whether LLDB can hit a hardware breakpoint set by file+line after ASLR fix.
"""
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import tools.android_lldb_probe as probe
from tools.sanitized_test_config import ENGINE_ROOT as TEST_ENGINE_ROOT

SYMBOLS = str(probe.DEFAULT_SYMBOLS)
BREAK_FILE = "VulkanCommandBuffer.cpp"
BREAK_LINE = 334
ENGINE_ROOT = str(TEST_ENGINE_ROOT)


def main():
    probe.ensure_adb_ready()
    probe.cleanup_device()
    probe.stage_platform_bits(probe.AS2024_LLDB_SERVER)

    pid = probe.resolve_pid()
    bridge, connect_uri, _, serial = probe.start_platform_server(pid)
    print(f"pid={pid} serial={serial}")

    # Verify game is in foreground
    top = subprocess.run(["adb", "shell", "dumpsys activity activities | grep topResumedActivity"],
                         capture_output=True, text=True, timeout=5)
    print(f"topActivity: {top.stdout.strip()}")

    # Build LLDB command script
    # Key: attach FIRST, then fix ASLR, then set BP, then continue
    commands = [
        "settings set auto-confirm true",
        "settings set plugin.jit-loader.gdb.enable off",
        "settings set stop-disassembly-display never",
        "settings set target.inline-breakpoint-strategy always",
        "settings set target.move-to-nearest-code true",
        "platform select remote-android",
        f'platform connect "{connect_uri}"',
        f'target create "{SYMBOLS}"',
    ]
    for p_str in probe.DEFAULT_EXEC_SEARCH:
        commands.append(f'settings append target.exec-search-paths "{p_str}"')
    commands.extend([
        f"process attach -p {pid}",
        "settings set target.process.thread.step-avoid-regexp ''",
        "process handle SIGSTOP -p true -s false -n false",
        "process handle SIGSEGV -p true -s false -n false",
        "process handle SIGBUS -p true -s false -n false",
        "process handle SIGPIPE -p true -s false -n false",
    ])

    # ASLR fix: read /proc/maps, apply correct slide
    aslr_fix = (
        'script exec("'
        'ci=lldb.debugger.GetCommandInterpreter()\\n'
        'ro=lldb.SBCommandReturnObject()\\n'
        f"ci.HandleCommand(\\'platform shell cat /proc/{pid}/maps\\',ro)\\n"
        "o=ro.GetOutput() if ro.Succeeded() else \\'\\'\\n"
        "lines=[l for l in o.splitlines() if \\'libUE4.so\\' in l]\\n"
        "base=int(lines[0].split(\\'-\\')[0],16) if lines else 0\\n"
        "ci.HandleCommand(\\'target modules load --file libUE4.so --slide 0x%x\\'%base,lldb.SBCommandReturnObject()) if base else None"
        '")'
    )
    commands.append(aslr_fix)
    commands.extend([
        "image list libUE4.so",
        # Now set HW BP by file+line
        f'breakpoint set -H --file "{BREAK_FILE}" --line {BREAK_LINE}',
        "breakpoint list -v",
        # Continue and wait
        "process continue",
    ])

    # Write command file
    cmd_file = Path(__file__).parent / "test_hw_bp_fileline_cmds.txt"
    cmd_file.write_text("\n".join(commands), encoding="utf-8")
    print(f"\nLLDB commands written to {cmd_file}")
    print(f"Commands:\n" + "\n".join(f"  {c[:120]}" for c in commands))

    # Run LLDB
    print(f"\n=== Running LLDB (waiting up to 60s for BP hit) ===")
    lldb_exe = str(probe.NDK_LLDB)
    try:
        proc = subprocess.Popen(
            [lldb_exe, "--batch", "--source", str(cmd_file)],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True,
        )
        start = time.time()
        output_lines = []
        while time.time() - start < 90:
            line = proc.stdout.readline()
            if not line:
                break
            line = line.rstrip()
            output_lines.append(line)
            print(line)
            # Check for breakpoint hit
            if "stop reason = breakpoint" in line:
                print("\n*** BREAKPOINT HIT! ***")
                # Read a few more lines for stack trace
                for _ in range(20):
                    extra = proc.stdout.readline()
                    if not extra:
                        break
                    print(extra.rstrip())
                break
        else:
            print("\n*** TIMEOUT: no breakpoint hit in 90s ***")

        proc.kill()
        proc.wait(timeout=5)
    except Exception as e:
        print(f"LLDB error: {e}")
    finally:
        if bridge:
            try:
                bridge.kill()
                bridge.communicate(timeout=3)
            except:
                pass
        probe.cleanup_device()


if __name__ == "__main__":
    main()
