using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Principal;
using Microsoft.Data.Analysis;
using Microsoft.SqlServer.CSharpExtension.SDK;

namespace SqlServerLab.Acceptance
{
    // Synthetic SQL data roundtrip and worker-isolation observation only.
    public sealed class Probe : AbstractSqlServerExtensionExecutor
    {
        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool GetTokenInformation(IntPtr token, int kind,
            out int value, int length, out int returnedLength);

        public override DataFrame Execute(DataFrame input, Dictionary<string, dynamic> sqlParams)
        {
            if (!OperatingSystem.IsWindows() || input == null || input.Columns.Count != 1)
                throw new InvalidOperationException("CSHARP_PROBE_INPUT_INVALID");
            int appContainer;
            using (WindowsIdentity identity = WindowsIdentity.GetCurrent())
            {
                int returnedLength;
                if (!GetTokenInformation(identity.Token, 29, out appContainer, sizeof(int), out returnedLength)
                    || returnedLength != sizeof(int))
                    throw new InvalidOperationException("CSHARP_PROBE_TOKEN_QUERY_FAILED");
            }
            var ids = new PrimitiveDataFrameColumn<int>("id");
            var doubled = new PrimitiveDataFrameColumn<int>("doubled");
            var versions = new PrimitiveDataFrameColumn<int>("runtimeMajor");
            var isolated = new PrimitiveDataFrameColumn<int>("appContainer");
            var workers = new PrimitiveDataFrameColumn<int>("workerPid");
            using (Process process = Process.GetCurrentProcess())
            {
                for (long index = 0; index < input.Rows.Count; index++)
                {
                    int value = Convert.ToInt32(input.Columns[0][index]);
                    ids.Append(value);
                    doubled.Append(checked(value * 2));
                    versions.Append(Environment.Version.Major);
                    isolated.Append(appContainer);
                    workers.Append(process.Id);
                }
            }
            return new DataFrame(ids, doubled, versions, isolated, workers);
        }
    }
}
