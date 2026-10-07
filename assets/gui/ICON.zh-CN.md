# 应用图标：模块归一

采用用户选定的第四稿造型与 VS Code 蓝色方向：上方蓝色、下方绿色、右侧暖金色三块圆角平面组成开放的部署框架，表达多个实例的统一管理。平面间的留白保持边界清晰，绿色末端保留轻微折面。图标使用透明背景，适配深浅桌面。

`app.svg` 是可编辑矢量母版。蓝色基准为 `#007ACC`，绿色与暖金色使用轻微渐变保留选定草稿的层次；具体色值在 SVG 中定义。母版按已选造型整理干净轮廓，避免生成草稿的边缘杂点。

`app.ico` 由母版生成，包含 16、20、24、32、40、48、64、96、128、256 像素的透明 PNG 帧。每帧由四倍尺寸抗锯齿绘制后缩小；三块主要平面在小尺寸下保持清晰。

```powershell
pwsh -NoProfile -File .\scripts\New-DesktopIcon.ps1 -Destination .\assets\gui\app.ico
```

需要 PNG 审查图时，附加 `-PreviewDirectory <临时审查目录>`。脚本支持此母版使用的矩形、圆、绝对路径及母版坐标线性渐变，不作为通用 SVG 渲染器。

应用 EXE、安装器和卸载入口使用同一图标；快捷方式引用应用 EXE。WinUI 窗口显式加载随应用附带的图标，避免窗口与文件图标不一致。图标只在应用目录内使用，不修改系统主题或清理 Windows 图标缓存。

配色参考 [VS Code 官方配色](https://code.visualstudio.com/brand)。设计过程参考 [Google 身份设计](https://design.google/library/evolving-google-identity)、[Microsoft Fluent 图标设计](https://fluent2.microsoft.design/iconography/) 和 [OpenAI 品牌规范](https://openai.com/brand/) 的简洁几何、比例与小尺寸辨识思路；图形由本项目独立整理，不使用这些公司的标志。
