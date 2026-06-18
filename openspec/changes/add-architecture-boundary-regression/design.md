# Design — architecture-boundary-regression (DRAFT / exploration archive)

> 本文件捕获 `/opsx:explore` 的思考过程与未决策点，**不是已批准设计**。

## Context

来源：对照《AI 长期软件工程手册》（飞书 docx `OiE4dVswhoUMOtxC43AcFUQin9f`，
2026-06-15）对本仓做符合度盘点。本仓在「AI 长期工程化」上已命中手册约 70%，
decisions/lessons/CONSTRAINTS 的「踩坑→约束→出处指针」知识库甚至比手册模板更
成熟。唯一明确缺口是手册 §7.2/§8.6 的「边界可执行」——边界写在文档里，但没有
机器门禁。

探索三轮收敛：
- **A 阶段**（grep require 图谱）：误以为有 3 条「底层反向 require("ue")」。
- **A1 阶段**（实读 config/pipeline/platforms）：3 条全是注释里的字符串，实际是
  模范 DI 解耦。grep 无语义 → 假阳性。教训直接写进 proposal 铁律。
- **A2 阶段**（对照 structure_spec + openspec 格式）：起草 spec delta + 落点 +
  本决策清单。

## Goals

- 把 P3 / R1 / R5 / DI-seam 这几条**已声明**的边界，变成会在违规时变红的回归。
- 复用仓内既有 treesitter，不引新依赖。
- 与 `structure-discoverability-regression` 同形：锁「已达成的干净状态」，防腐烂。

## Non-goals

- 不发明新边界规则（只锁文档已声明的）。
- 不处理 `lua/ue.lua` 上帝模块的 fan-out（它不违反任何声明边界，是有意的中枢；
  手册 §8.6 视角下是健康风险，但拆它是另一个量级的工程，不在此 change）。
- 不覆盖手册中对本仓不适用的部分（SLO/RUNBOOK/DB 迁移/SBOM/前端门禁等，N/A）。

## Approach（落地时）

1. `boundaries_spec.lua` 内置一张**规则常量表**，每条带指回 CONSTRAINTS 条目号
   的注释（P3/R1/R5）。表项形如：受管 glob、检测的 AST 节点类型、白名单。
2. 用 `vim.treesitter.get_parser` + lua 语法的 query 抓：
   - `require("...")` 的 **string-literal 实参**（function_call → arguments →
     string）——天然跳过注释与拼接式动态 require。
   - `vim.lsp.handlers[...] = ...` 的 **assignment LHS 下标**（区分赋值 vs 读取）。
   - OS 探测调用：`vim.fn.has("win32"/"win64"/...)`、`vim.uv/vim.loop.os_uname`、
     `jit.os` 比较。
3. 按规则表逐文件判定，违规收集 文件:行，用例 FAIL 并打印全部命中（与
   structure_spec 的 dangling 报告风格一致）。
4. 注释/字符串内的同形文本由 AST 天然排除（**铁律**，A1 实证必需）。

## Open decisions（阻塞落地，只有仓主能拍）

### 决策甲 — cdb/pipeline.lua 的 OS 分支怎么处置

实测命中：`python_exe()` 与 `copy_file()` 内用 `vim.fn.has("win32")` 选
python 可执行名 / copy 命令。这是「OS 分支出现在 platform/ 之外」的**真实**违规。

- **选项 1（收口）**：在 4 个平台驱动加 `python_exe()` / `copy(src,dst)`，pipeline
  改调 `driver().*`。更纯，但要动 pipeline + windows/macos/linux/stub 五处。
- **选项 2（白名单）**：把这两处列入 R1 白名单 + 加 `-- NOTE: intentional` 注释。
  零运行时改动，承认这是合理例外（pipeline 是子进程编排，本就贴近 OS）。

→ 决定 R1 这条规则是「严格红线」还是「带白名单的红线」。

### 决策乙 — core 零依赖要不要「升格为承重约束」

现状 `ue/core/**` 零上层依赖。锁它 = 把现状固化成契约。
- 收益：core 纯净性被机器保证。
- 成本：未来 core 若**合理**需要 require 某同层 util，门禁会挡，需改规则表。

→ 愿不愿意为「core 必须纯」付这个未来摩擦成本。

### 决策丙 — 要不要引入仓内首个「扫描自身源码的 AST 扫描器」

仓里有 treesitter，但没有「拿 TS 扫自己 lua 源码」的先例。这是
boundaries_spec 区别于其它 spec 的唯一新增复杂度与维护面。
- 全量 AST：正确，但是新基础设施。
- 降级 MVP：「剥离注释/字符串后的行扫描」(强于 grep、弱于 AST)——**违反 C4**，
  需显式破例，不推荐。
- 不做：以现有纪律 + code review + 文件头自律注释，哨兵边际价值或许不足以
  justify 新基础设施。「等出现第 2 条真实违规再做」是站得住的结论。

→ 这是最终的 go/no-go。

## Risks

| 风险 | 缓解 |
|---|---|
| 扫描器用错手段（正则）→ 误报模范 DI 文件 | 铁律：必须 AST；proposal 已记 A1 实证 |
| 规则表与 CONSTRAINTS 漂移 | spec 末条要求两处交叉引用、同步增删 |
| core 升格后挡住未来合理依赖（乙） | 规则表可改；或乙选「不升格、仅观测」 |
| 新增 AST 用例拖慢全量回归 | 单次解析 95 个 lua 文件，预期 <1s；可测后定夺 |

## 决策矩阵（探索终点速查）

```
            高 ROI
              │
   本 change ●│         （缺口2 SDD分级 ● 更省，零新基础设施）
  (防回归,0存量,         │
   需AST新设施)          │
  ────────────┼──────────────── 实现成本/新基础设施
              │
   手册不适用项 ○（SLO/RUNBOOK/迁移/SBOM…，N/A，别做）
            低 ROI
```

最终建议：本 change 价值真实但成本集中在「决策丙」。若仓主认为现有纪律已足，
**保持本 draft 归档、改做缺口 2（SDD 分级，零新基础设施）** 是更优的下一步。
