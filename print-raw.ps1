param(
    [Parameter(Mandatory = $true)]
    [string]$PrinterName,

    [Parameter(Mandatory = $true)]
    [string]$Base64Data
)

$ErrorActionPreference = 'Stop'

Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class RawPrinter {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public class DOCINFO {
        [MarshalAs(UnmanagedType.LPWStr)] public string pDocName;
        [MarshalAs(UnmanagedType.LPWStr)] public string pOutputFile;
        [MarshalAs(UnmanagedType.LPWStr)] public string pDataType;
    }

    [DllImport("winspool.drv", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool OpenPrinter(string pPrinterName, out IntPtr phPrinter, IntPtr pDefault);

    [DllImport("winspool.drv", SetLastError = true)]
    public static extern bool ClosePrinter(IntPtr hPrinter);

    [DllImport("winspool.drv", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int StartDocPrinter(IntPtr hPrinter, int level, [In] DOCINFO di);

    [DllImport("winspool.drv", SetLastError = true)]
    public static extern bool EndDocPrinter(IntPtr hPrinter);

    [DllImport("winspool.drv", SetLastError = true)]
    public static extern bool StartPagePrinter(IntPtr hPrinter);

    [DllImport("winspool.drv", SetLastError = true)]
    public static extern bool EndPagePrinter(IntPtr hPrinter);

    [DllImport("winspool.drv", SetLastError = true)]
    public static extern bool WritePrinter(IntPtr hPrinter, IntPtr pBytes, int dwCount, out int dwWritten);

    public static void Send(string printerName, byte[] bytes) {
        IntPtr handle;
        if (!OpenPrinter(printerName, out handle, IntPtr.Zero))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "No se pudo abrir la impresora");

        try {
            var doc = new DOCINFO { pDocName = "Agendarte Ticket", pDataType = "RAW" };
            if (StartDocPrinter(handle, 1, doc) == 0)
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "No se pudo iniciar el trabajo");
            try {
                if (!StartPagePrinter(handle))
                    throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "No se pudo iniciar la página");
                try {
                    IntPtr unmanaged = Marshal.AllocHGlobal(bytes.Length);
                    try {
                        Marshal.Copy(bytes, 0, unmanaged, bytes.Length);
                        int written;
                        if (!WritePrinter(handle, unmanaged, bytes.Length, out written) || written != bytes.Length)
                            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "Windows no aceptó todos los datos");
                    } finally {
                        Marshal.FreeHGlobal(unmanaged);
                    }
                } finally {
                    EndPagePrinter(handle);
                }
            } finally {
                EndDocPrinter(handle);
            }
        } finally {
            ClosePrinter(handle);
        }
    }
}
'@

$bytes = [Convert]::FromBase64String($Base64Data)
[RawPrinter]::Send($PrinterName, $bytes)
Write-Output ("Trabajo RAW enviado a: " + $PrinterName)
