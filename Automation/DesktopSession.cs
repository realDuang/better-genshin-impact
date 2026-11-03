using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public sealed class DesktopSessionInfo
{
    public int Id;
    public string Station = "";
    public string User = "";
    public string Domain = "";
    public int State;
    public int Protocol;
}

public static class DesktopSessions
{
    [StructLayout(LayoutKind.Sequential)]
    private struct NativeSession { public int Id; public IntPtr Station; public int State; }

    [DllImport("wtsapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool WTSEnumerateSessions(IntPtr server, int reserved, int version,
        out IntPtr sessions, out int count);
    [DllImport("wtsapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool WTSQuerySessionInformation(IntPtr server, int session, int info,
        out IntPtr buffer, out int bytes);
    [DllImport("wtsapi32.dll")]
    private static extern void WTSFreeMemory(IntPtr memory);

    private static string ReadString(int session, int info)
    {
        IntPtr buffer;
        int bytes;
        if (!WTSQuerySessionInformation(IntPtr.Zero, session, info, out buffer, out bytes)) return "";
        try { return Marshal.PtrToStringUni(buffer) ?? ""; }
        finally { WTSFreeMemory(buffer); }
    }

    private static int ReadProtocol(int session)
    {
        IntPtr buffer;
        int bytes;
        if (!WTSQuerySessionInformation(IntPtr.Zero, session, 16, out buffer, out bytes)) return -1;
        try { return bytes >= 2 ? Marshal.ReadInt16(buffer) : -1; }
        finally { WTSFreeMemory(buffer); }
    }

    public static DesktopSessionInfo[] List()
    {
        IntPtr buffer;
        int count;
        if (!WTSEnumerateSessions(IntPtr.Zero, 0, 1, out buffer, out count))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot enumerate Windows sessions");
        try
        {
            var result = new List<DesktopSessionInfo>();
            int size = Marshal.SizeOf(typeof(NativeSession));
            for (int i = 0; i < count; i++)
            {
                var item = (NativeSession)Marshal.PtrToStructure(IntPtr.Add(buffer, i * size), typeof(NativeSession));
                result.Add(new DesktopSessionInfo {
                    Id = item.Id, Station = Marshal.PtrToStringUni(item.Station) ?? "", State = item.State,
                    User = ReadString(item.Id, 5), Domain = ReadString(item.Id, 7), Protocol = ReadProtocol(item.Id)
                });
            }
            return result.ToArray();
        }
        finally { WTSFreeMemory(buffer); }
    }

    public static DesktopSessionInfo Find(int id)
    {
        foreach (var session in List()) if (session.Id == id) return session;
        return null;
    }

}

public sealed class RdpLogonState
{
    public bool TransportConnected { get; private set; }
    public bool LoginCompleted { get; private set; }
    public int? LastLogonCode { get; private set; }
    public string Failure { get; private set; }
    private readonly Queue<string> events = new Queue<string>();

    public void Observe(string name, int code)
    {
        events.Enqueue(DateTime.Now.ToString("o") + " " + name + " " + code);
        if (name == "connected") TransportConnected = true;
        if (name == "login-complete") { LoginCompleted = true; Failure = null; }
        if (name == "logon")
        {
            LastLogonCode = code;
            // -2 continues logon; the remaining nonterminal values are arbitration/UI notifications.
            if (code != -2 && code != -4 && code != -5 && code != 3)
                Failure = String.Format("RDP logon failed: {0} (0x{1:X8})", code, unchecked((uint)code));
        }
        if (name == "fatal") Failure = "RDP fatal error: " + code;
        if (name == "disconnected")
        {
            TransportConnected = false;
            LoginCompleted = false;
            Failure = Failure ?? ("RDP disconnected: " + code);
        }
    }

    public bool IsReady(DesktopSessionInfo child, string expectedUser)
    {
        return TransportConnected && LoginCompleted && Failure == null && child != null && child.State == 0 &&
            !String.IsNullOrEmpty(expectedUser) && String.Equals(child.User, expectedUser, StringComparison.OrdinalIgnoreCase);
    }

    public string[] DrainEvents()
    {
        var result = events.ToArray();
        events.Clear();
        return result;
    }
}

public sealed class ChildDesktopAx : AxHost
{
    private static readonly Guid EventInterface = new Guid("336D5562-EFA8-482E-8CB3-C5C0FC7A7DB6");
    private readonly Dictionary<int, Delegate> handlers = new Dictionary<int, Delegate>();
    private object eventSource;
    public readonly RdpLogonState Logon = new RdpLogonState();

    public ChildDesktopAx() : base("A0C63C30-F08D-4AB4-907C-34905D770C7D") { }
    public object Client { get { return GetOcx(); } }

    protected override void CreateSink()
    {
        base.CreateSink();
        eventSource = GetOcx();
        Hook(2, new Action(delegate { Logon.Observe("connected", 0); }));
        Hook(3, new Action(delegate { Logon.Observe("login-complete", 0); }));
        Hook(4, new Action<int>(delegate(int code) { Logon.Observe("disconnected", code); }));
        Hook(10, new Action<int>(delegate(int code) { Logon.Observe("fatal", code); }));
        Hook(22, new Action<int>(delegate(int code) { Logon.Observe("logon", code); }));
    }

    private void Hook(int id, Delegate handler)
    {
        ComEventsHelper.Combine(eventSource, EventInterface, id, handler);
        handlers.Add(id, handler);
    }

    protected override void DetachSink()
    {
        try
        {
            if (eventSource != null)
                foreach (var pair in handlers)
                    try { ComEventsHelper.Remove(eventSource, EventInterface, pair.Key, pair.Value); }
                    catch (InvalidComObjectException) { }
            handlers.Clear();
            eventSource = null;
        }
        finally { base.DetachSink(); }
    }
}
