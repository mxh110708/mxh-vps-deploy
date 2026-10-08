using System.Text.Json;

namespace Mxh.VpsDeploy.Core;

public static class SafeFailures
{
    // Unknown exception text and remote output can contain credentials.
    public static OperationException Describe(Exception error, bool needsRecovery = false)
    {
        if (error is OperationException safe)
            return new(safe.Message, needsRecovery || safe.NeedsRecovery, safe.Code ?? "OperationRejected", safe.NextAction);
        return error switch
        {
            UnauthorizedAccessException => new("无法访问本地文件，当前账号没有所需权限。", needsRecovery, "LocalAccessDenied", "核对应用目录和管理密钥的访问权限；不要修改原始私钥权限。"),
            FileNotFoundException or DirectoryNotFoundException => new("所需的本地文件或目录不存在。", needsRecovery, "LocalFileMissing", "核对应用文件与所选私人文件的位置。"),
            JsonException or FormatException => new("步骤返回的数据或本地记录格式不符合预期。", needsRecovery, "InvalidStepData", "查看失败阶段；保留归档，核对数据格式后再继续。"),
            TimeoutException => new("当前步骤超时，尚未获得完整结果。", needsRecovery, "StepTimeout", "核对网络与任务阶段；有未确认写入时先核对事务。"),
            IOException => new("读取或写入本地文件失败。", needsRecovery, "LocalIoFailure", "核对磁盘空间、文件占用和应用目录。"),
            _ => new("当前步骤遇到未分类错误。错误类型：" + error.GetType().Name + "。", needsRecovery, "UnexpectedFailure", "查看记录中的实例、失败阶段和错误代码；保留归档以便排查。")
        };
    }
    public static OperationException Remote(CommandResult result, string description)
    {
        var reason = result.ExitCode == 127 || result.Error.Contains("command not found", StringComparison.OrdinalIgnoreCase) ? "远端缺少所需命令。" :
            result.Error.Contains("Permission denied", StringComparison.OrdinalIgnoreCase) ? "远端执行权限不足。" :
            result.Error.Contains("No space left on device", StringComparison.OrdinalIgnoreCase) ? "远端磁盘空间不足。" :
            result.Error.Contains("Could not resolve", StringComparison.OrdinalIgnoreCase) || result.Error.Contains("Temporary failure in name resolution", StringComparison.OrdinalIgnoreCase) ? "远端域名解析失败。" :
            result.Error.Contains("Connection timed out", StringComparison.OrdinalIgnoreCase) ? "远端网络请求超时。" :
            result.Error.Contains("No such file or directory", StringComparison.OrdinalIgnoreCase) ? "远端所需文件不存在。" : "远端步骤返回非零退出码。";
        return new(description + "（退出码 " + result.ExitCode + "）。" + reason, code: "RemoteStepFailed", nextAction: "核对本步骤的环境与依赖；存在未确认事务时先核对恢复状态。");
    }
}
