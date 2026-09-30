## Context

沿用已安装的 Sonokai 插件和现有主题注册表。参考已安装 VS Code 插件的 Espresso JSON，不复制工作站路径。

## Goals / Non-Goals

- 目标：让既有 Espresso 入口使用准确角色色、界面色与可重放的覆盖。
- 非目标：新增主题入口、插件或重新设计所有主题。

## Decisions

- 在主题加载后应用独立适配模块，复用既有 ColorScheme 生命周期，避免改动上游插件。
- 将 VS Code RGBA 背景合成至 editor background，满足 Neovim RGB 高亮要求。
- field/local 同色是明确的 Espresso 映射；其他主题继续遵守既有对比要求。

## Risks / Trade-offs

- 字体渲染受终端/GUI 影响；颜色值、角色和切换由回归验证，视觉记录仅表示本机检查。
- 覆盖只在 Espresso 激活，切换其他主题后不保留。
