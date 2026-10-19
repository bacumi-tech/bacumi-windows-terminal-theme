// MIT License - Copyright (c) 2026 Bacumi
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
namespace BacumiPrompt {
    public sealed class ProbeResult {
        public bool Success;
        public string Output = "";
    }
    public static class NativeProbe {
        private sealed class Capture {
            internal readonly StringBuilder Text = new StringBuilder();
            internal int Overflow;
        }
        private static void Drain(StreamReader stream, Capture capture, int limit) {
            try {
                char[] buffer = new char[1024];
                int count;
                while ((count = stream.Read(buffer, 0, buffer.Length)) > 0) {
                    lock (capture.Text) {
                        if (capture.Text.Length + count > limit) {
                            Interlocked.Exchange(ref capture.Overflow, 1);
                            return;
                        }
                        capture.Text.Append(buffer, 0, count);
                    }
                }
            } catch (IOException) {} catch (ObjectDisposedException) {}
        }
        // CommandLineToArgvW-compatible quoting for ProcessStartInfo.Arguments (.NET Framework).
        private static string Quote(string value) {
            var output = new StringBuilder("\"");
            int slashes = 0;
            foreach (char c in value) {
                if (c == '\\') { slashes++; continue; }
                if (c == '"') { output.Append('\\', slashes * 2 + 1); output.Append(c); }
                else { output.Append('\\', slashes); output.Append(c); }
                slashes = 0;
            }
            output.Append('\\', slashes * 2); output.Append('"');
            return output.ToString();
        }
        [StructLayout(LayoutKind.Sequential)] private struct BasicLimit {
            public long ProcessTime, JobTime;
            public uint Flags;
            public UIntPtr MinWorkingSet, MaxWorkingSet;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass, SchedulingClass;
        }
        [StructLayout(LayoutKind.Sequential)] private struct IoCounters {
            public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes;
        }
        [StructLayout(LayoutKind.Sequential)] private struct ExtendedLimit {
            public BasicLimit Basic;
            public IoCounters Io;
            public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
        }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll")] private static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref ExtendedLimit info, uint length);
        [DllImport("kernel32.dll")] private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
        private static IntPtr CreateOwnedJob() {
            IntPtr job = CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero) return job;
            var limit = new ExtendedLimit();
            limit.Basic.Flags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            if (!SetInformationJobObject(job, 9, ref limit, (uint)Marshal.SizeOf(limit))) { CloseHandle(job); return IntPtr.Zero; }
            return job;
        }
        private static void Stop(Process process) {
            try {
                MethodInfo killTree = typeof(Process).GetMethod("Kill", new Type[] { typeof(bool) });
                if (killTree != null) killTree.Invoke(process, new object[] { true });
                else process.Kill();
            } catch {} // It may have exited between the deadline and termination.
        }
        public static ProbeResult Run(string executable, string[] arguments, string directory, int milliseconds, int outputLimit) {
            var result = new ProbeResult();
            if (milliseconds <= 0) return result;
            bool windows = Environment.OSVersion.Platform == PlatformID.Win32NT;
            var start = new ProcessStartInfo();
            start.FileName = executable;
            var commandLine = new StringBuilder();
            foreach (string argument in arguments) { if (commandLine.Length > 0) commandLine.Append(' '); commandLine.Append(Quote(argument)); }
            start.Arguments = commandLine.ToString();
            if (windows && (executable.EndsWith(".cmd", StringComparison.OrdinalIgnoreCase) || executable.EndsWith(".bat", StringComparison.OrdinalIgnoreCase))) {
                // Expand the path once from the child environment; literal % or ! in paths
                // must never become another environment expansion. Probe arguments are fixed switches.
                start.FileName = Environment.GetEnvironmentVariable("ComSpec") ?? "cmd.exe";
                start.EnvironmentVariables["BACUMI_PROMPT_PROBE_EXECUTABLE"] = executable;
                start.Arguments = "/d /s /v:off /c \"\"%BACUMI_PROMPT_PROBE_EXECUTABLE%\" " + start.Arguments + "\"";
            }
            start.WorkingDirectory = directory;
            start.UseShellExecute = false;
            start.CreateNoWindow = true;
            start.RedirectStandardInput = true;
            start.RedirectStandardOutput = true;
            start.RedirectStandardError = true;
            start.EnvironmentVariables["GOTOOLCHAIN"] = "local";
            start.EnvironmentVariables["RUSTUP_AUTO_INSTALL"] = "0";
            start.EnvironmentVariables["DOTNET_SKIP_FIRST_TIME_EXPERIENCE"] = "1";
            start.EnvironmentVariables["DOTNET_CLI_TELEMETRY_OPTOUT"] = "1";
            start.EnvironmentVariables["GIT_TERMINAL_PROMPT"] = "0";
            start.EnvironmentVariables["GCM_INTERACTIVE"] = "Never";
            IntPtr job = IntPtr.Zero;
            var process = new Process();
            process.StartInfo = start;
            var clock = Stopwatch.StartNew();
            try {
                if (windows) {
                    job = CreateOwnedJob();
                    if (job == IntPtr.Zero) return result; // No unmanaged child without tree cleanup.
                }
                process.Start();
                if (windows && !AssignProcessToJobObject(job, process.Handle)) { Stop(process); return result; }
                process.StandardInput.Close(); // EOF, never borrow the interactive terminal.
                var stdout = new Capture();
                var stderr = new Capture();
                var outputStream = process.StandardOutput;
                var errorStream = process.StandardError;
                Task output = Task.Factory.StartNew(() => Drain(outputStream, stdout, outputLimit), TaskCreationOptions.LongRunning);
                Task error = Task.Factory.StartNew(() => Drain(errorStream, stderr, 4096), TaskCreationOptions.LongRunning);
                while (clock.ElapsedMilliseconds < milliseconds) {
                    if (stdout.Overflow != 0 || stderr.Overflow != 0) break;
                    if (process.HasExited && output.IsCompleted && error.IsCompleted) {
                        if (process.ExitCode == 0 && stdout.Overflow == 0 && stderr.Overflow == 0) {
                            lock (stdout.Text) { result.Output = stdout.Text.ToString(); }
                            result.Success = true;
                        }
                        break;
                    }
                    Thread.Sleep(1);
                }
            } catch {} // Missing, inaccessible or unsupported applications omit their context.
            finally {
                if (job != IntPtr.Zero) CloseHandle(job); // Ends the entire Windows job, including detached .cmd children.
                Stop(process);
                try { process.WaitForExit(20); } catch {}
                process.Dispose();
            }
            return result;
        }
    }
}
