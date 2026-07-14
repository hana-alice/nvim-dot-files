# lua/ — Lua 代码层总规则

> 父级：`../AGENTS.md`（根强制入口：SESSION START + Definition of Done）。
> 本文件是 `lua/` 下所有代码的**父级规则**；子目录 `AGENTS.md` 只写相对本文件的**增量**。
> 某目录无本地规则时，适用最近祖先目录的规则（回落语义）。

## 用途

本仓所有运行时 Lua 代码。LazyVim 作为库，自研引擎在此（`ue.lua` + `ue/` + `utils/` + `workarounds/`）。

## 承重约束（全 lua/ 适用，权威见 docs/CONSTRAINTS.md）

- **公共 API 挂 `M.*`、可 headless 自验证**（`nvim --headless -l`）。→ C4.4
- **async 优先于阻塞**：多秒等待可接受，阻塞主线程 = bug。→ C4.2 / P6
- **AST/treesitter 优先于 regex** 处理结构化代码问题。→ C4.1
- **不引入新依赖**，除非 change 明确论证必要性。
- **immutable 优先**：返回新表，不就地改入参（除非性能热点且注明）。
- **不做无关重构 / 不格式化无关文件**。

## 禁止（指针，权威见 docs/CONSTRAINTS.md §一）

- 不全局覆盖 `vim.lsp.handlers`（走 `utils/lsp_fallback.lua` 或 `workarounds/clangd/*`）→ P3
- 不写 inline workaround（进 `workarounds/<scope>/<name>.lua`）→ P4
- 不对 64 位值用 `string.format("%x", addr)`（LuaJIT 截 32 位）→ P7

## 改动后（Definition of Done，权威见根 AGENTS.md）

改完按范围跑回归（映射见 `../tests/AGENTS.md`）+ 记 `../docs/changelog.md`。

## 先读

`../docs/CONSTRAINTS.md`、`../docs/architecture/overview.md`、对应子目录 `AGENTS.md`。
