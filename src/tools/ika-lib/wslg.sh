# ika: WSLg task bar pins and jump lists.
# Sourced by src/tools/ika, in its order; see there.

# WSLg gives each window the relaunch command C:\Program Files\WSL\\wslg.exe
# ... without quotes, so a task bar pin made from the window starts
# "C:\Program" and Windows offers to delete it. This repairs such pins, under
# the user's "User Pinned" folder: the target becomes wslg.exe, and the pin
# keeps the window's app ID, which puts the window on the pin's button. It also
# removes the shortcuts Windows made for WSLg windows of a distribution that is
# no longer registered: the app ID leaves the distribution out, so Ika's window
# in another one would show that distribution's name, missing icon and command.
# It runs in the background, when a window closes (after the user may have
# pinned it) and at start, and does nothing outside WSLg.
repair_wslg_taskbar_pins() {
  local powershell

  [[ "${IKA_ON_WSLG}" == true ]] || return 0
  powershell="$(windows_powershell)" || return 0
  mkdir -p "${CVD_TMP_DIR}"
  (
    detach_background_job 9
    flock -n 9 || exit 0
    with_timeout 60 "${powershell}" -NoProfile -NonInteractive -ExecutionPolicy Bypass \
      -EncodedCommand "$(wslg_pin_repair_script | iconv -t UTF-16LE | base64 -w 0)" \
      </dev/null 2>/dev/null | tr -d '\r' | while IFS= read -r line; do
        [[ -n "${line}" ]] && log "${line}"
      done
  ) 9>"${CVD_TMP_DIR}/wslg-pins.lock" &
  disown "$!" 2>/dev/null || true
}

# Prints the PowerShell program of repair_wslg_taskbar_pins: one line per pin
# it repaired.
wslg_pin_repair_script() {
  cat <<'EOF'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Add-Type @"
using System; using System.Text; using System.Runtime.InteropServices; using System.Runtime.InteropServices.ComTypes;
[ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IShellLinkW {
  void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder f, int n, IntPtr fd, uint fl); void GetIDList(out IntPtr p); void SetIDList(IntPtr p);
  void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder s, int n); void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string s);
  void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder s, int n); void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string s);
  void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder s, int n); void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string s);
  void GetHotkey(out short h); void SetHotkey(short h); void GetShowCmd(out int c); void SetShowCmd(int c);
  void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder s, int n, out int i); void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string s, int i);
  void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string s, uint r); void Resolve(IntPtr h, uint f);
  void SetPath([MarshalAs(UnmanagedType.LPWStr)] string s); }
public static class IkaPin {
  public static bool Repair(string file) {
    IShellLinkW l = (IShellLinkW)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("00021401-0000-0000-C000-000000000046")));
    IPersistFile pf = (IPersistFile)l; pf.Load(file, 2);
    StringBuilder p = new StringBuilder(1024), a = new StringBuilder(4096);
    l.GetPath(p, p.Capacity, IntPtr.Zero, 0x4); l.GetArguments(a, a.Capacity);
    string cmd = p.ToString() + " " + a.ToString();
    int i = cmd.IndexOf(@"\wslg.exe ", StringComparison.OrdinalIgnoreCase);
    if (!p.ToString().Equals(@"C:\Program", StringComparison.OrdinalIgnoreCase) || !a.ToString().StartsWith(@"Files\WSL\") || i < 0) return false;
    l.SetPath(cmd.Substring(0, i + 9).Replace(@"\\", @"\")); l.SetArguments(cmd.Substring(i + 10)); pf.Save(file, true);
    return true; }
  // The distribution a wslg.exe shortcut starts, or null
  public static string Distro(string file) {
    IShellLinkW l = (IShellLinkW)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("00021401-0000-0000-C000-000000000046")));
    ((IPersistFile)l).Load(file, 0);
    StringBuilder p = new StringBuilder(1024), a = new StringBuilder(4096);
    l.GetPath(p, p.Capacity, IntPtr.Zero, 0x4); l.GetArguments(a, a.Capacity);
    if (!p.ToString().EndsWith(@"\wslg.exe", StringComparison.OrdinalIgnoreCase)) return null;
    var m = System.Text.RegularExpressions.Regex.Match(a.ToString(), "^(?:-d|--distribution) +(?:\"([^\"]+)\"|(\\S+))");
    return m.Success ? m.Groups[1].Value + m.Groups[2].Value : null; }
}
"@
$distros = @(Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' -ErrorAction SilentlyContinue |
  ForEach-Object { $_.GetValue('DistributionName') } | Where-Object { $_ })
Get-ChildItem "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned" -Recurse -Filter *.lnk -ErrorAction SilentlyContinue |
  ForEach-Object { try {
    if ([IkaPin]::Repair($_.FullName)) { "repaired the task bar pin $($_.BaseName)" }
    # Windows keeps the shortcut it made for a WSLg window's app ID after the
    # distribution is gone, and the task bar takes the name, icon and command
    # of another distribution's window with the same app ID from it.
    $distro = [IkaPin]::Distro($_.FullName)
    if ($distros.Count -gt 0 -and $distro -and $distros -notcontains $distro -and
        $_.FullName -like '*\ImplicitAppShortcuts\*') {
      Remove-Item -LiteralPath $_.FullName
      "removed the task bar shortcut $($_.BaseName) of the removed WSL distribution $distro"
    } } catch { } }
EOF
}

# Prints the right-click actions of the desktop entry FILE, in the order of its
# Actions key, as NAME<TAB>EXEC lines.
desktop_entry_actions() {
  local file="$1"
  local action
  local -a actions=()

  IFS=';' read -r -a actions \
    <<<"$(sed -n '/^\[Desktop Entry\]/,/^\[Desktop Action /s/^Actions=//p' "${file}" | head -n1)"
  for action in "${actions[@]}"; do
    [[ -n "${action}" ]] || continue
    awk -v group="[Desktop Action ${action}]" '
      $0 == group { in_group = 1; next }
      /^\[/ { in_group = 0 }
      in_group && /^Name=/ { name = substr($0, 6) }
      in_group && /^Exec=/ { exec = substr($0, 6) }
      END { if (name != "" && exec != "") printf "%s\t%s\n", name, exec }' "${file}"
  done
}

# On WSLg, gives the task bar button of the window the desktop entry FILE
# opens the entry's right-click actions, as Linux desktops show them: a jump
# list, with each action run by wslg.exe in this distribution. Windows keeps a
# jump list under the app ID of the windows it is for, which a WSLg window
# gets from WSLg (Microsoft.RemoteApp. and a hash): the job waits up to 30
# seconds for the window, the one whose relaunch command runs the entry's
# Exec, and reads its app ID. Windows keeps the list, for a button pinned
# from the window too. Runs in the background, and does nothing outside WSLg.
set_wslg_jump_list() {
  local file="$1"
  local powershell
  local exec
  local data

  [[ "${IKA_ON_WSLG}" == true && -n "${WSL_DISTRO_NAME:-}" && -f "${file}" ]] || return 0
  exec="$(sed -n '/^\[Desktop Entry\]/,/^\[Desktop Action /s/^Exec=//p' "${file}" | head -n1)"
  [[ -n "${exec}" ]] || return 0
  powershell="$(windows_powershell)" || return 0
  data="$(printf '%s\n%s\n%s\n' "${WSL_DISTRO_NAME}" "${exec}" "$(desktop_entry_actions "${file}")" \
    | base64 -w 0)"
  (
    detach_background_job
    with_timeout 60 "${powershell}" -NoProfile -NonInteractive -ExecutionPolicy Bypass \
      -EncodedCommand "$( { printf "\$data = '%s'\n" "${data}"; wslg_jump_list_script; } \
        | iconv -t UTF-16LE | base64 -w 0)" \
      </dev/null 2>/dev/null | tr -d '\r' | while IFS= read -r line; do
        [[ -n "${line}" ]] && log "${line}"
      done
  ) &
  disown "$!" 2>/dev/null || true
}

# Prints the PowerShell program of set_wslg_jump_list, which reads $data: the
# distribution, the entry's Exec and its actions (NAME<TAB>EXEC), one a line,
# in base64.
wslg_jump_list_script() {
  cat <<'EOF'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$lines = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($data)) -split "`n" | Where-Object { $_ }
if ($lines.Count -lt 3) { exit }
$distro = $lines[0]; $exec = $lines[1]
$names = @(); $execs = @()
foreach ($line in $lines[2..($lines.Count - 1)]) { $f = $line -split "`t", 2; $names += $f[0]; $execs += $f[1] }
Add-Type @"
using System; using System.Text; using System.Runtime.InteropServices;
[ComImport, Guid("6332DEBF-87B5-4670-90C0-5E57B408A49E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface ICustomDestinationList {
  void SetAppID([MarshalAs(UnmanagedType.LPWStr)] string id);
  void BeginList(out uint max, ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out object removed);
  void AppendCategory([MarshalAs(UnmanagedType.LPWStr)] string name, [MarshalAs(UnmanagedType.Interface)] object items);
  void AppendKnownCategory(int c); void AddUserTasks([MarshalAs(UnmanagedType.Interface)] object items);
  void CommitList(); void GetRemovedDestinations(ref Guid riid, out object o);
  void DeleteList([MarshalAs(UnmanagedType.LPWStr)] string id); void AbortList(); }
[ComImport, Guid("5632B1A4-E38A-400A-928A-D4CD63230295"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IObjectCollection {
  void GetCount(out uint c); void GetAt(uint i, ref Guid riid, out object o);
  void AddObject([MarshalAs(UnmanagedType.Interface)] object o); void AddFromArray(object a); void RemoveObjectAt(uint i); void Clear(); }
[ComImport, Guid("92CA9DCD-5622-4BBA-A805-5E9F541BD8C9"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IObjectArray { void GetCount(out uint c); void GetAt(uint i, ref Guid riid, out object o); }
[ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IShellLinkW {
  void GetPath(IntPtr f, int n, IntPtr fd, uint fl); void GetIDList(out IntPtr p); void SetIDList(IntPtr p);
  void GetDescription(IntPtr s, int n); void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string s);
  void GetWorkingDirectory(IntPtr s, int n); void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string s);
  void GetArguments(IntPtr s, int n); void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string s);
  void GetHotkey(out short h); void SetHotkey(short h); void GetShowCmd(out int c); void SetShowCmd(int c);
  void GetIconLocation(IntPtr s, int n, out int i); void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string s, int i);
  void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string s, uint r); void Resolve(IntPtr h, uint f);
  void SetPath([MarshalAs(UnmanagedType.LPWStr)] string s); }
[StructLayout(LayoutKind.Sequential)] public struct PROPERTYKEY { public Guid fmtid; public uint pid; }
[StructLayout(LayoutKind.Explicit, Size = 24)] public struct PROPVARIANT { [FieldOffset(0)] public ushort vt; [FieldOffset(8)] public IntPtr p; }
[ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IPropertyStore {
  int GetCount(out uint c); int GetAt(uint i, out PROPERTYKEY k); int GetValue(ref PROPERTYKEY k, out PROPVARIANT v);
  int SetValue(ref PROPERTYKEY k, ref PROPVARIANT v); int Commit(); }
public static class IkaJump {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("shell32.dll")] static extern int SHGetPropertyStoreForWindow(IntPtr h, ref Guid riid, out IPropertyStore s);
  static readonly Guid AppUserModel = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
  static string Get(IPropertyStore s, Guid f, uint pid) {
    var k = new PROPERTYKEY { fmtid = f, pid = pid }; PROPVARIANT v;
    return s.GetValue(ref k, out v) == 0 && v.vt == 31 ? Marshal.PtrToStringUni(v.p) : null; }
  // The app ID, relaunch command and icon of the window whose relaunch
  // command runs EXEC in DISTRO, or null
  public static string[] Find(string distro, string exec) {
    string[] found = null;
    EnumWindows((h, l) => {
      if (!IsWindowVisible(h)) return true;
      Guid iid = typeof(IPropertyStore).GUID; IPropertyStore s;
      if (SHGetPropertyStoreForWindow(h, ref iid, out s) != 0) return true;
      string id = Get(s, AppUserModel, 5), command = Get(s, AppUserModel, 2), icon = Get(s, AppUserModel, 3);
      Marshal.ReleaseComObject(s);
      if (id == null || command == null || !id.StartsWith("Microsoft.RemoteApp.")) return true;
      int i = command.IndexOf(@"\wslg.exe -d " + distro + " ", StringComparison.OrdinalIgnoreCase);
      if (i < 0 || !command.EndsWith(" -- " + exec)) return true;
      found = new string[] { id, command.Substring(0, i + 9).Replace(@"\\", @"\"), icon ?? "" };
      return false; }, IntPtr.Zero);
    return found; }
  static object Link(string title, string path, string args, string icon) {
    var l = (IShellLinkW)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("00021401-0000-0000-C000-000000000046")));
    l.SetPath(path); l.SetArguments(args);
    if (icon != "") l.SetIconLocation(icon, 0);
    var s = (IPropertyStore)l;
    var k = new PROPERTYKEY { fmtid = new Guid("F29F85E0-4FF9-1068-AB91-08002B27B3D9"), pid = 2 };
    var v = new PROPVARIANT { vt = 31, p = Marshal.StringToCoTaskMemUni(title) };
    s.SetValue(ref k, ref v); s.Commit(); Marshal.FreeCoTaskMem(v.p);
    return l; }
  public static void Set(string id, string wslg, string distro, string icon, string[] names, string[] execs) {
    var list = (ICustomDestinationList)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("77F10CF0-3DB5-4966-B520-B7C54FD35ED6")));
    list.SetAppID(id); uint max; object removed; Guid iid = typeof(IObjectArray).GUID;
    list.BeginList(out max, ref iid, out removed);
    var tasks = (IObjectCollection)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("2D3468C1-36A7-43B6-AC24-D3F02FD9607A")));
    for (int i = 0; i < names.Length; i++)
      tasks.AddObject(Link(names[i], wslg, "-d " + distro + " --cd \"~\" -- " + execs[i], icon));
    list.AddUserTasks(tasks); list.CommitList(); }
}
"@
$deadline = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $deadline) {
  $window = [IkaJump]::Find($distro, $exec)
  if ($window) {
    [IkaJump]::Set($window[0], $window[1], $distro, $window[2], $names, $execs)
    "task bar jump list of '$exec': $($names -join ', ')"
    exit
  }
  Start-Sleep -Milliseconds 500
}
"no task bar jump list: no window of '$exec' in 30 seconds"
EOF
}

