param([string]$FilePath)

# 引数が空の場合は環境変数から取得（ロングパス制限回避策）
if (-not $FilePath -and $env:FIX_MTIME_TARGET_FILE_B64) {
    $FilePath = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:FIX_MTIME_TARGET_FILE_B64))
}
if (-not $FilePath -and $env:FIX_MTIME_TARGET_FILE) {
    $FilePath = $env:FIX_MTIME_TARGET_FILE
}

if (-not $FilePath) { exit }

# ロングパスプレフィックス (\\?\) の除去と正規化パスの取得
try {
    $resolvedPath = (Get-Item -LiteralPath $FilePath -ErrorAction Stop).FullName
} catch {
    $resolvedPath = $FilePath
    if ($resolvedPath.StartsWith("\\?\")) {
        $resolvedPath = $resolvedPath.Substring(4)
    }
}

Add-Type -ReferencedAssemblies "System.Security" -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Cryptography.Pkcs;

public class AuthenticodeUtil {
    [DllImport("crypt32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool CryptQueryObject(
        int dwObjectType,
        string pvObject,
        int dwExpectedContentTypeFlags,
        int dwExpectedFormatTypeFlags,
        int dwFlags,
        IntPtr pdwMsgAndCertEncodingType,
        IntPtr pdwContentType,
        IntPtr pdwFormatType,
        ref IntPtr phCertStore,
        ref IntPtr phMsg,
        ref IntPtr ppvContext);

    [DllImport("crypt32.dll", SetLastError = true)]
    public static extern bool CryptMsgGetParam(
        IntPtr hCryptMsg,
        int dwParamType,
        int dwIndex,
        IntPtr pvData,
        ref int pcbData);

    [DllImport("crypt32.dll")]
    public static extern bool CryptMsgClose(IntPtr hCryptMsg);

    [DllImport("crypt32.dll")]
    public static extern bool CertCloseStore(IntPtr hCertStore, int dwFlags);

    public const int CERT_QUERY_OBJECT_FILE = 0x00000001;
    public const int CERT_QUERY_CONTENT_FLAG_PKCS7_SIGNED_EMBED = 1 << 10;
    public const int CERT_QUERY_FORMAT_FLAG_BINARY = 1 << 1;
    public const int CMSG_ENCODED_MESSAGE = 29;

    public static string GetTimestamp(string filePath) {
        IntPtr hCertStore = IntPtr.Zero;
        IntPtr hCryptMsg = IntPtr.Zero;
        IntPtr ppvContext = IntPtr.Zero;

        try {
            bool res = CryptQueryObject(
                CERT_QUERY_OBJECT_FILE,
                filePath,
                CERT_QUERY_CONTENT_FLAG_PKCS7_SIGNED_EMBED,
                CERT_QUERY_FORMAT_FLAG_BINARY,
                0,
                IntPtr.Zero,
                IntPtr.Zero,
                IntPtr.Zero,
                ref hCertStore,
                ref hCryptMsg,
                ref ppvContext);

            if (!res || hCryptMsg == IntPtr.Zero) return null;

            int cbData = 0;
            if (!CryptMsgGetParam(hCryptMsg, CMSG_ENCODED_MESSAGE, 0, IntPtr.Zero, ref cbData) || cbData <= 0) return null;
            byte[] msgBytes = new byte[cbData];
            IntPtr pBytes = Marshal.AllocHGlobal(cbData);
            try {
                if (!CryptMsgGetParam(hCryptMsg, CMSG_ENCODED_MESSAGE, 0, pBytes, ref cbData)) return null;
                Marshal.Copy(pBytes, msgBytes, 0, cbData);
            } finally {
                Marshal.FreeHGlobal(pBytes);
            }

            SignedCms cms = new SignedCms();
            cms.Decode(msgBytes);

            foreach (SignerInfo signer in cms.SignerInfos) {
                // 1. カウンター署名 (Authenticode タイムスタンプ)
                foreach (SignerInfo cs in signer.CounterSignerInfos) {
                    foreach (CryptographicAttributeObject attr in cs.SignedAttributes) {
                        if (attr.Oid.Value == "1.2.840.113549.1.9.5") {
                            foreach (Pkcs9SigningTime t in attr.Values) {
                                return t.SigningTime.ToLocalTime().ToString("yyyy/MM/dd HH:mm:ss");
                            }
                        }
                    }
                }
                // 2. RFC 3161 タイムスタンプトークン
                foreach (CryptographicAttributeObject attr in signer.UnsignedAttributes) {
                    if (attr.Oid.Value == "1.3.6.1.4.1.311.3.3.1") {
                        foreach (AsnEncodedData val in attr.Values) {
                            SignedCms tst = new SignedCms();
                            tst.Decode(val.RawData);
                            byte[] content = tst.ContentInfo.Content;
                            for (int i = 0; i < content.Length - 16; i++) {
                                if (content[i] == 0x18) {
                                    int len = content[i + 1];
                                    if (len >= 14 && len <= 19 && i + 2 + len <= content.Length) {
                                        string s = System.Text.Encoding.ASCII.GetString(content, i + 2, len);
                                        if (s.Length >= 14) {
                                            int yr = int.Parse(s.Substring(0, 4));
                                            int mo = int.Parse(s.Substring(4, 2));
                                            int dy = int.Parse(s.Substring(6, 2));
                                            int hr = int.Parse(s.Substring(8, 2));
                                            int mn = int.Parse(s.Substring(10, 2));
                                            int sc = int.Parse(s.Substring(12, 2));
                                            DateTime utc = new DateTime(yr, mo, dy, hr, mn, sc, DateTimeKind.Utc);
                                            return utc.ToLocalTime().ToString("yyyy/MM/dd HH:mm:ss");
                                        }
                                    }
                                }
                            }
                            foreach (SignerInfo tstSigner in tst.SignerInfos) {
                                foreach (CryptographicAttributeObject tattr in tstSigner.SignedAttributes) {
                                    if (tattr.Oid.Value == "1.2.840.113549.1.9.5") {
                                        foreach (Pkcs9SigningTime t in tattr.Values) {
                                            return t.SigningTime.ToLocalTime().ToString("yyyy/MM/dd HH:mm:ss");
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                // 3. 署名自体の signingTime
                foreach (CryptographicAttributeObject attr in signer.SignedAttributes) {
                    if (attr.Oid.Value == "1.2.840.113549.1.9.5") {
                        foreach (Pkcs9SigningTime t in attr.Values) {
                            return t.SigningTime.ToLocalTime().ToString("yyyy/MM/dd HH:mm:ss");
                        }
                    }
                }
            }
            return null;
        } catch {
            return null;
        } finally {
            if (hCryptMsg != IntPtr.Zero) CryptMsgClose(hCryptMsg);
            if (hCertStore != IntPtr.Zero) CertCloseStore(hCertStore, 0);
        }
    }
}
'@

$str = [AuthenticodeUtil]::GetTimestamp($resolvedPath)
if ($str) {
    Write-Output $str
}