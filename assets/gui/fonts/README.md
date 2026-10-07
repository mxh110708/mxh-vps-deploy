# 桌面字体

- **Schibsted Grotesk**：原版（Route 风格）界面字体，继续作为初始默认；中文使用系统回退，保留 `SchibstedGrotesk-OFL.txt`。
- **霞鹜文楷**：另一套内置界面字体，官方 `lxgw/LxgwWenKai` 的原始 `LXGWWenKai-Regular.ttf`，版本 **1.522**。下载地址：<https://github.com/lxgw/LxgwWenKai/releases/tag/v1.522>。SHA256：`39ad71264b588165b469e35e6afb162a378dacd1f95348160240ba9038ac3009`。许可全文：`LXGWWenKai-OFL.txt`。未修改、合并或子集化。
- **Source Serif 4**：侧栏品牌文字，保留 `SourceSerif4-OFL.txt`。

自定义 TTF/OTF 在应用内导入，存放于 `private/fonts/`，不进入源码、安装包的受管文件清单或公开发布。字体只在应用内加载，不安装到 Windows。升级和保留数据卸载会保留它们；彻底卸载会随私人数据删除。
