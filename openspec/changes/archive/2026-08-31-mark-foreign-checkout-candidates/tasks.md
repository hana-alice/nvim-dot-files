## 1. 归属判定复用（不另写谓词）

- [ ] 1.1 复用 `CORE_RT.foreign_buffer_key`（或其纯函数化封装）判定候选是否属于当前
      project/engine；MUST NOT 新写一套前缀比较。
- [ ] 1.2 未 pin 项目时判定恒为"非 foreign"（无 pin 即无外部概念）。
- [ ] 1.3 判定必须廉价：纯字符串前缀比较，禁止 fs 调用/子进程（P6、K17 教训）。

## 2. picker 标注

- [ ] 2.1 `lua/plugins/snacks.lua`：已 pin 时为 foreign 候选加可见标记。
- [ ] 2.2 标记必须在**一屏内可辨认**（不能只靠完整路径尾部差异）。
- [ ] 2.3 默认保留候选；提供配置降权/过滤，默认不丢弃。

## 3. 回归

- [ ] 3.1 用例：foreign 候选被标记；pin 内候选不标记；未 pin 时不标记。
- [ ] 3.2 用例：判定为纯函数、无 fs 访问（扫描实现，禁止 fs_stat/system）。
- [ ] 3.3 分范围 `ue_goto_behavior` `ue_paths` `utils` `smoke`；提交前全量。
- [ ] 3.4 **MUST NOT 由 agent 启动 clangd / 真实索引构建验证**（沿用用户约束）。

## 4. 收尾

- [ ] 4.1 门禁：`ue.lua` ≤10562；新增/改动文件 ≤800 行。
- [ ] 4.2 changelog + spec 一致性处置。
