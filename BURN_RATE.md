# Burn Rate Animation Feature

## 概述

在 CodexBar 现有的额度监控基础上，增加 token burn rate（消耗速率）的实时可视化。根据当前烧 token 的速度，menubar 图标展示不同档位的动画，让用户一眼感知 coding agent 的活跃程度和消耗强度。

## 动机

CodexBar 当前显示的是静态的额度剩余（session/weekly meter bar），但缺少"正在烧多快"的实时感知。当多个 agent 同时跑，或者单个 agent 在做大量 reasoning 时，用户想知道当前的消耗速率，而不只是剩余量。

## 核心功能

### 1. Burn Rate 计算

- 数据源：复用 CodexBar 现有的 provider usage 数据
- 计算方式：滑动窗口（如最近 60s）内的 token 增量 / 时间 = tokens/min
- 按 provider 分别计算，也提供聚合值
- 可选：区分 input/output token 的 rate（output 更贵）

### 2. 动画档位

根据 burn rate 映射到不同的视觉状态：

| 档位 | 条件 | 视觉效果 |
|------|------|----------|
| Idle | 0 tokens/min | 静态图标，无动画，默认冷色（系统 template） |
| Low | < 1K tokens/min | 缓慢呼吸脉动，色温微暖（蓝绿） |
| Medium | 1K-10K tokens/min | 中速脉动，色温偏暖（黄绿） |
| High | 10K-50K tokens/min | 快速脉动，橙色 |
| Burning | > 50K tokens/min | 高频脉动，红色 |

阈值可在 Settings 中自定义。

### 3. 动画方案（已定）

**独立 menubar icon**，与现有的额度 meter bar icon 完全分离。

- 使用 SF Symbol `flame.fill` 作为 burn rate 专用图标
- 利用 SF Symbols 的 `variableValue`（0.0-1.0）控制火焰视觉大小，映射 burn tier
- 颜色随 tier 变化：idle=灰色/隐藏, low=蓝绿, medium=黄绿, high=橙色, burning=红色
- Idle 时图标变灰或完全隐藏（可在 Settings 中选择）
- 点击展开独立的 burn rate menu：当前速率、$/hr 估算、迷你 sparkline
- 不修改现有 meter bar 的渲染逻辑，两个 icon 各自独立

### 4. 全屏效果（Stretch Goal）

除了 menubar icon，burn rate 还可以通过全屏视觉效果传达，给用户沉浸式的"烧钱感知"。

**屏幕边缘火焰光晕**
- 透明无交互的 overlay window（`NSWindow`，level 设为 overlay，`ignoresMouseEvents = true`）
- 屏幕底部/四周泛出火焰光晕，类似游戏低血量时的屏幕边缘泛红
- burn rate 越高，光晕越亮、范围越大、颜色越暖
- idle 时完全透明不存在

**Menubar 着火效果**
- menubar 底部渗出 Balatro 风格的像素火焰，往下窜
- 火焰高度和强度映射 burn tier
- 用 Metal shader 或预渲染序列帧实现，噪声扰动 + 黄→橙→红渐变

**档位映射**

| 档位 | Menubar Icon | 屏幕效果 |
|------|-------------|---------|
| Idle | 灰色火焰 / 隐藏 | 无 |
| Low | 蓝绿色小火焰 | 无 |
| Medium | 黄绿色火焰 | 屏幕底部微弱暖光 |
| High | 橙色火焰 | 屏幕边缘明显暖光晕 |
| Burning | 红色火焰 | menubar 像素火焰 + 屏幕边缘烈焰 |

**技术要点**
- overlay window 必须不拦截鼠标事件、不抢焦点
- shader 性能要求低（简单的噪声火焰），不应影响正常使用
- 全屏效果默认关闭，Settings 中可独立开启
- 多显示器支持：每个屏幕独立 overlay

### 5. Menu 扩展

点击展开的 menu card 中增加：
- 当前 burn rate 数值（tokens/min）
- 折算成本（$/hr，基于各 provider 的 token 单价）
- 最近 N 分钟的 burn rate 迷你图表（sparkline）

## 技术要点

- 现有的 provider polling 机制需要支持更高频率（burn rate 需要至少 10-15s 级别的采样）
- menubar 图标动画用 `NSImage` 序列帧或 Core Animation
- 需要确认各 provider 的 usage 数据刷新频率是否支持实时 rate 计算
- 本地 JSONL 日志解析（Codex/Claude CLI）天然支持高频采样

## 待定

- 是否支持声音提醒（超过某个 rate 阈值时）
- 是否在 Widget 中也展示 burn rate
