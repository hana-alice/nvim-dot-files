"""Isolated real-clangd / Neovim ext_linegrid inlay-hint measurement.

No third-party Python dependencies. Does not launch project background indexing.
The UI measurement includes Neovim grid generation and RPC transport, not GPU or
terminal rendering. All generated files stay under the chosen output directory.
"""

import argparse
import json
import math
import os
from pathlib import Path
import queue
import shutil
import statistics
import struct
import subprocess
import threading
import time


def pack(value):
    if value is None:
        return b"\xc0"
    if isinstance(value, bool):
        return b"\xc3" if value else b"\xc2"
    if isinstance(value, int):
        if 0 <= value < 128:
            return bytes([value])
        return b"\xd3" + struct.pack(">q", value)
    if isinstance(value, str):
        data = value.encode("utf-8")
        return b"\xdb" + struct.pack(">I", len(data)) + data
    if isinstance(value, (tuple, list)):
        return b"\xdd" + struct.pack(">I", len(value)) + b"".join(map(pack, value))
    if isinstance(value, dict):
        return b"\xdf" + struct.pack(">I", len(value)) + b"".join(
            pack(key) + pack(item) for key, item in value.items()
        )
    raise TypeError(type(value))


def unpack(stream):
    def read(count):
        data = stream.read(count)
        if len(data) != count:
            raise EOFError("Neovim RPC stream ended")
        return data

    def number(fmt):
        return struct.unpack(fmt, read(struct.calcsize(fmt)))[0]

    tag = read(1)[0]
    if tag < 128:
        return tag
    if tag >= 224:
        return tag - 256
    if 160 <= tag < 192:
        return read(tag - 160).decode("utf-8")
    if 144 <= tag < 160:
        return [unpack(stream) for _ in range(tag - 144)]
    if 128 <= tag < 144:
        return {unpack(stream): unpack(stream) for _ in range(tag - 128)}
    if tag in (192, 194, 195):
        return {192: None, 194: False, 195: True}[tag]
    sizes = {196: ">B", 197: ">H", 198: ">I", 217: ">B", 218: ">H", 219: ">I"}
    if tag in sizes:
        data = read(number(sizes[tag]))
        return data.decode("utf-8") if tag >= 217 else data
    numbers = {202: ">f", 203: ">d", 204: ">B", 205: ">H", 206: ">I", 207: ">Q",
               208: ">b", 209: ">h", 210: ">i", 211: ">q"}
    if tag in numbers:
        return number(numbers[tag])
    if tag in (220, 221):
        return [unpack(stream) for _ in range(number(">H" if tag == 220 else ">I"))]
    if tag in (222, 223):
        return {unpack(stream): unpack(stream)
                for _ in range(number(">H" if tag == 222 else ">I"))}
    # Neovim's Buffer/Window/Tabpage handles are MessagePack extensions.
    if tag in (212, 213, 214, 215, 216):
        size = {212: 1, 213: 2, 214: 4, 215: 8, 216: 16}[tag]
    elif tag in (199, 200, 201):
        size = number({199: ">B", 200: ">H", 201: ">I"}[tag])
    else:
        raise ValueError(f"Unsupported MessagePack tag {tag}")
    read(1)
    return {"extension": read(size).hex()}


class Nvim:
    def __init__(self, executable, environment, log):
        self.log = log.open("wb")
        # Foreground, explicit bounded measurement; only this owned child is stopped.
        self.process = subprocess.Popen(
            [executable, "--embed", "--headless", "-u", "NONE", "-i", "NONE"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log, env=environment,
        )
        self.messages = queue.Queue()
        self.sequence = 0
        self.redraw = {"flush": 0, "grid_line": 0, "grid_scroll": 0, "hint_cells": 0}
        self.hint_highlights = set()
        self.grids = {}

        def receive():
            try:
                while True:
                    self.messages.put(unpack(self.process.stdout))
            except Exception as error:
                self.messages.put(error)

        threading.Thread(target=receive, daemon=True).start()

    def consume(self, message):
        if isinstance(message, Exception):
            raise message
        if message[:2] == [2, "redraw"]:
            for event in message[2]:
                kind = event[0]
                if kind in self.redraw:
                    self.redraw[kind] += len(event) - 1
                if kind == "grid_resize":
                    for grid, width, height in event[1:]:
                        self.grids[grid] = [[" "] * width for _ in range(height)]
                if kind == "hl_attr_define":
                    for attributes in event[1:]:
                        if any(info.get("hi_name") == "LspInlayHint" for info in attributes[3]):
                            self.hint_highlights.add(attributes[0])
                if kind == "grid_line":
                    for row in event[1:]:
                        highlight = 0
                        column = row[2]
                        for cell in row[3]:
                            if len(cell) >= 2:
                                highlight = cell[1]
                            if highlight in self.hint_highlights:
                                self.redraw["hint_cells"] += cell[2] if len(cell) >= 3 else 1
                            repeat = cell[2] if len(cell) >= 3 else 1
                            for offset in range(repeat):
                                self.grids[row[0]][row[1]][column + offset] = cell[0]
                            column += repeat

    def call(self, method, *arguments):
        self.sequence += 1
        identifier = self.sequence
        self.process.stdin.write(pack([0, identifier, method, arguments]))
        self.process.stdin.flush()
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            message = self.messages.get(timeout=max(0.01, deadline - time.monotonic()))
            self.consume(message)
            if isinstance(message, list) and message[:2] == [1, identifier]:
                if message[2]:
                    raise RuntimeError(message[2])
                return message[3]
        raise TimeoutError(method)

    def lua(self, code, *arguments):
        return self.call("nvim_exec_lua", code, arguments)

    def close(self):
        try:
            self.call("nvim_command", "qa!")
        except (EOFError, queue.Empty):
            pass
        finally:
            if self.process.poll() is None:
                self.process.terminate()
            self.process.wait(timeout=10)
            self.log.close()


def summary(samples):
    ordered = sorted(samples)
    return {"samples": len(samples), "p50_ms": round(statistics.median(samples), 3),
            "p95_ms": round(ordered[math.ceil(len(samples) * 0.95) - 1], 3),
            "max_ms": round(max(samples), 3)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--clangd", required=True)
    parser.add_argument("--nvim", default=shutil.which("nvim"))
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--samples", type=int, default=60)
    arguments = parser.parse_args()
    if arguments.samples < 10:
        parser.error("--samples must be at least 10")
    directory = arguments.output_dir.resolve()
    directory.mkdir(parents=True, exist_ok=True)
    # The generated translation unit intentionally has no external SDK/UE headers.
    lines = ["#define UCLASS()", "#define GENERATED_BODY()", "struct UObject {};",
             "struct FVector { float X, Y, Z; };", "UCLASS()",
             "struct AActor : UObject { GENERATED_BODY() };",
             "float Scale(float Value, float Factor) { return Value * Factor; }"]
    for index in range(1000):
        lines.extend([f"FVector UpdateActor{index}(float DeltaSeconds)", "{",
                      f"    auto Speed = Scale(DeltaSeconds, {index + 1}.0f);",
                      "    auto Offset = Scale(Speed, 0.5f);",
                      "    return FVector{Speed, Offset, DeltaSeconds};", "}"])
    source = directory / "InlayActor.cpp"
    source.write_text("\n".join(lines) + "\n", encoding="utf-8")
    environment = os.environ.copy()
    # No user cache, ShaDa, LSP log, or clangd cache writes outside this directory.
    for variable in ("XDG_CACHE_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME"):
        environment[variable] = str(directory / variable.lower())
    instance = Nvim(arguments.nvim, environment, directory / "nvim.stderr.log")
    result = {"fixture": "generated UE-like C++ (no real engine headers)",
              "lines": len(lines), "bytes": source.stat().st_size,
              "ui": "attached ext_linegrid 120x45; no physical frontend/GPU measurement",
              "clangd_version": subprocess.check_output(
                  [arguments.clangd, "--version"], text=True).splitlines()[0],
              "request_ms": [], "redraw_trials": []}
    try:
        instance.call("nvim_ui_attach", 120, 45,
                      {"rgb": True, "ext_linegrid": True, "ext_hlstate": True})
        result["nvim_version"] = instance.lua("return vim.version().major..'.'..vim.version().minor..'.'..vim.version().patch")
        instance.lua("vim.o.swapfile=false; vim.o.wrap=false; vim.o.number=true; vim.o.shada=''; vim.lsp.set_log_level('off'); vim.api.nvim_set_hl(0, 'LspInlayHint', {fg=0x888888})")
        instance.call("nvim_command", "edit " + source.as_posix())
        start = time.perf_counter()
        result["lsp_start"] = instance.lua("""
            local executable, root = ...
            vim.bo.filetype = 'cpp'
            _G.measure_client = vim.lsp.start({name='inlay-measure',
              cmd={executable, '--background-index=false', '--enable-config=false', '-j=2', '--log=error'},
              root_dir=root, init_options={fallbackFlags={'-std=c++17'}},
              capabilities=vim.lsp.protocol.make_client_capabilities()})
            assert(vim.wait(30000, function()
              local client = vim.lsp.get_client_by_id(_G.measure_client)
              return client and client.initialized
            end, 10), 'clangd initialize timeout')
            return true
        """, arguments.clangd, directory.as_posix())
        result["initialize_ms"] = round((time.perf_counter() - start) * 1000, 3)
        for _ in range(20):
            result["request_ms"].append(instance.lua("""
                local client = vim.lsp.get_client_by_id(_G.measure_client)
                local started = vim.uv.hrtime()
                local response = client:request_sync('textDocument/inlayHint', {
                  textDocument={uri=vim.uri_from_bufnr(0)},
                  range={start={line=0, character=0}, ['end']={line=vim.api.nvim_buf_line_count(0), character=0}}
                }, 30000, 0)
                assert(response and not response.err, vim.inspect(response))
                _G.measure_hints = response.result
                return {ms=(vim.uv.hrtime()-started)/1e6, hints=#response.result}
            """))
        result["hint_count"] = instance.lua("return #_G.measure_hints")
        result["request_cold_ms"] = round(result["request_ms"][0]["ms"], 3)
        result["request_warm"] = summary([entry["ms"] for entry in result["request_ms"][1:]])
        for enabled in (False, True, False, True):
            started = time.perf_counter()
            visible_hints = instance.lua("""
                local enabled = ...
                vim.lsp.inlay_hint.enable(enabled, {bufnr=0})
                if enabled then
                  assert(vim.wait(30000, function()
                    return #vim.lsp.inlay_hint.get({bufnr=0}) > 0
                  end, 10), 'no builtin inlay hints appeared')
                end
                vim.cmd('redraw!')
                return #vim.lsp.inlay_hint.get({bufnr=0})
            """, enabled)
            instance.call("nvim_eval", "1")
            trial = {"enabled": enabled, "builtin_hints": visible_hints,
                     "enable_to_grid_ms": round((time.perf_counter() - started) * 1000, 3)}
            baseline = instance.redraw.copy()
            samples = []
            for index in range(arguments.samples):
                line = 20 + (index * 83) % (len(lines) - 80)
                started = time.perf_counter()
                instance.lua("local line=...; vim.api.nvim_win_set_cursor(0,{line,0}); vim.cmd('normal! zz'); vim.cmd('redraw!')", line)
                # Drain the UI flush that Neovim emits after the execution reply.
                instance.call("nvim_eval", "1")
                samples.append((time.perf_counter() - started) * 1000)
            trial["cursor_redraw_rpc"] = summary(samples)
            trial["grid_events"] = {key: value - baseline[key] for key, value in instance.redraw.items()}
            screen_lines = ["".join(row) for grid in instance.grids.values() for row in grid]
            trial["screen_hint_example"] = next((line.strip() for line in screen_lines
                                                if "Value:" in line or "Factor:" in line), None)
            assert bool(trial["screen_hint_example"]) == enabled, "grid must visibly show hints iff enabled"
            result["redraw_trials"].append(trial)
        result["diagnostic_count"] = instance.lua("return #vim.diagnostic.get(0)")
    finally:
        instance.close()
    output = directory / "result.json"
    output.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
