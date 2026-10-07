using System;
using System.IO;
using System.IO.Pipes;
using System.Text;

// A small .NET Framework helper for the Windows OpenSSH askpass process contract.
// Neither the credential nor the prompt is written to a file or environment variable.
internal static class VpsDeployAskPass
{
    private static int Main(string[] arguments)
    {
        try {
            string name=Environment.GetEnvironmentVariable("MXH_VPS_GUI_ASKPASS_PIPE");
            if(String.IsNullOrEmpty(name) || !name.StartsWith("mxh-vps-askpass-",StringComparison.Ordinal)) return 1;
            using(var pipe=new NamedPipeClientStream(".",name,PipeDirection.InOut)) {
                pipe.Connect(5000);
                using(var reader=new BinaryReader(pipe,Encoding.UTF8,true))
                using(var writer=new BinaryWriter(pipe,Encoding.UTF8,true)) {
                    writer.Write(arguments.Length==0 ? "SSH credential" : arguments[0]);writer.Flush();
                    if(!reader.ReadBoolean()) return 1;
                    Console.OutputEncoding=new UTF8Encoding(false);
                    Console.WriteLine(reader.ReadString());
                }
            }
            return 0;
        } catch(Exception error) { Console.Error.WriteLine("Graphical SSH credential bridge: " + error.GetType().Name); return 1; }
    }
}
