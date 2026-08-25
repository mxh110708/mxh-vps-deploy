# 模块开发

`modules/*.ps1` 每个文件返回一个模块定义 Hashtable：

```powershell
@{
    Id          = 'example'
    Name        = '示例模块'
    Order       = 500
    Roles       = @('RealityEntry', 'MonitorOnly')
    Requires    = @('audit')
    IsEnabled   = { param($Context) $true }
    Invoke      = { param($Context) }
}
```

核心按 `Order` 排序，并验证 `Id` 唯一、依赖存在且位于之前。删除模块文件即可移除功能；新增模块不需要修改入口脚本。

## 约定

- 远端 Bash 放在 `assets/remote`，必须通过 `bash -n`；
- 远端脚本从 `VPS_PARAM_*` 环境变量读取参数，不从 argv 读取秘密；
- 禁止 `set -x`、打印环境变量或把秘密写入临时日志；
- 修改配置前建立时间戳备份；应用前执行语法检查；
- 模块失败时抛出错误，由核心停止后续模块；
- 幂等优先：重复运行不得无故轮换凭据、端口或覆盖已完成状态；
- 需要特殊供应商脚本的功能，应做成显式模块，不能塞进通用基础模块。

## 状态

每完成一个模块，核心更新实例私有目录中的 `deployment-state.json`。继续模式默认跳过已成功模块。维护模式可用 `-OnlyModule` 显式重跑，但会显示风险确认。
