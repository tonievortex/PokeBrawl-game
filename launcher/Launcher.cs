// PokeBrawl launcher: one small program that installs Godot, keeps the game up to date from
// GitHub and starts it. Built with the C# compiler that ships with Windows (see build.ps1), so
// players need nothing installed.
//
// Every start:
//   1. Godot is downloaded the first time (a private copy: nothing is installed in the system).
//   2. GitHub is asked for the latest commit of the branch. If it is newer than the installed
//      one, the game is downloaded, copied in (only what changed) and its assets are prepared.
//   3. The game starts. Offline, the installed version starts as it is.
// Files go to %LOCALAPPDATA%\PokeBrawl (godot\, game\, installed.sha, launcher.log). Music
// (game\music) and the players' saved settings are never touched by an update.
//
// Options (all optional):  --repo=owner/name  --branch=main  --install-dir=path
//                          --no-launch (install/update only)  --force (download again)
//                          --screenshot=file.png (saves a picture of its window after a few
//                          seconds and quits; for checking how it looks)
// Any other argument goes to the game (e.g. --lang=en).

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows.Forms;

static class Program
{
	public const string DefaultRepo = "tonievortex/PokeBrawl-game";
	public const string DefaultBranch = "main";
	public const string GodotVersion = "4.7.2-stable";

	[STAThread]
	static void Main(string[] args)
	{
		ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;   // TLS 1.2
		Application.EnableVisualStyles();
		Application.SetCompatibleTextRenderingDefault(false);
		Application.Run(new LauncherForm(Options.Parse(args)));
	}
}


class Options
{
	public string Repo = Program.DefaultRepo;
	public string Branch = Program.DefaultBranch;
	public string InstallDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PokeBrawl");
	public bool NoLaunch;
	public bool Force;
	public string Screenshot = "";
	public List<string> GameArgs = new List<string>();

	public static Options Parse(string[] args)
	{
		var o = new Options();
		foreach (string a in args)
		{
			if (a.StartsWith("--repo=")) o.Repo = a.Substring(7);
			else if (a.StartsWith("--branch=")) o.Branch = a.Substring(9);
			else if (a.StartsWith("--install-dir=")) o.InstallDir = a.Substring(14);
			else if (a == "--no-launch") o.NoLaunch = true;
			else if (a == "--force") o.Force = true;
			else if (a.StartsWith("--screenshot=")) o.Screenshot = a.Substring(13);
			else o.GameArgs.Add(a);
		}
		return o;
	}
}


class LauncherForm : Form
{
	static readonly Color Ink = Color.FromArgb(244, 244, 246);
	static readonly Color Yellow = Color.FromArgb(255, 210, 31);

	readonly Options opt;
	readonly Label status = new Label();
	readonly Label info = new Label();
	readonly ProgressBar bar = new ProgressBar();
	readonly string godotDir;
	readonly string godotExe;
	readonly string godotConsole;
	readonly string gameDir;
	readonly string shaFile;
	readonly string logFile;
	string remoteMessage = "";            // the newest commit's message (first line)

	public LauncherForm(Options options)
	{
		opt = options;
		godotDir = Path.Combine(opt.InstallDir, "godot", Program.GodotVersion);
		godotExe = Path.Combine(godotDir, "Godot_v" + Program.GodotVersion + "_win64.exe");
		godotConsole = Path.Combine(godotDir, "Godot_v" + Program.GodotVersion + "_win64_console.exe");
		gameDir = Path.Combine(opt.InstallDir, "game");
		shaFile = Path.Combine(opt.InstallDir, "installed.sha");
		logFile = Path.Combine(opt.InstallDir, "launcher.log");

		Text = "PokeBrawl";
		ClientSize = new Size(560, 190);
		FormBorderStyle = FormBorderStyle.FixedSingle;
		MaximizeBox = false;
		StartPosition = FormStartPosition.CenterScreen;
		BackColor = Color.FromArgb(29, 29, 33);
		try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }

		var title = new Label();
		title.Text = "POKEBRAWL";
		title.Font = new Font("Segoe UI", 30f, FontStyle.Bold | FontStyle.Italic);
		title.ForeColor = Yellow;
		title.AutoSize = true;
		title.Location = new Point(28, 18);
		Controls.Add(title);

		status.ForeColor = Ink;
		status.Font = new Font("Segoe UI", 11f);
		status.AutoSize = false;
		status.Size = new Size(504, 26);
		status.AutoEllipsis = true;
		status.Location = new Point(30, 112);
		status.Text = "Starting...";
		Controls.Add(status);

		// What the newest update is about: the commit's message.
		info.ForeColor = Color.FromArgb(156, 156, 168);
		info.Font = new Font("Segoe UI", 9.5f);
		info.AutoSize = false;
		info.Size = new Size(504, 22);
		info.AutoEllipsis = true;
		info.Location = new Point(32, 82);
		Controls.Add(info);

		bar.Location = new Point(30, 146);
		bar.Size = new Size(500, 18);
		bar.Style = ProgressBarStyle.Marquee;
		Controls.Add(bar);

		Shown += delegate { Task.Run(new Action(Run)); };

		if (opt.Screenshot != "")
		{
			var shot = new System.Windows.Forms.Timer();
			shot.Interval = 6000;
			shot.Tick += delegate
			{
				shot.Stop();
				using (var bmp = new Bitmap(Width, Height))
				{
					DrawToBitmap(bmp, new Rectangle(0, 0, Width, Height));
					bmp.Save(opt.Screenshot, System.Drawing.Imaging.ImageFormat.Png);
				}
				Environment.Exit(0);
			};
			shot.Start();
		}
	}


	// ------------------------------------------------------------ UI helpers

	void UI(Action a)
	{
		try
		{
			if (IsDisposed) return;
			if (InvokeRequired) BeginInvoke(a); else a();
		}
		catch (ObjectDisposedException) { }
		catch (InvalidOperationException) { }
	}

	void Say(string text, int percent)
	{
		Log(text);
		UI(delegate
		{
			status.Text = text;
			if (percent < 0)
			{
				bar.Style = ProgressBarStyle.Marquee;
			}
			else
			{
				bar.Style = ProgressBarStyle.Continuous;
				bar.Value = Math.Max(0, Math.Min(100, percent));
			}
		});
	}

	void Log(string text)
	{
		try
		{
			Directory.CreateDirectory(opt.InstallDir);
			File.AppendAllText(logFile, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + text + "\r\n");
		}
		catch { }
	}


	// ------------------------------------------------------------ the work

	void Run()
	{
		try
		{
			Log("--- start (repo " + opt.Repo + ", branch " + opt.Branch + ")");
			Directory.CreateDirectory(opt.InstallDir);
			// Ask GitHub first: what the newest update is about shows from the very start.
			Say("Looking for updates...", -1);
			string remote = RemoteSha();
			if (remote != null && remoteMessage != "")
			{
				string line = "Latest change (" + remote.Substring(0, 7) + "): " + remoteMessage;
				Log(line);
				UI(delegate { info.Text = line; });
			}
			EnsureGodot();

			string have = File.Exists(shaFile) ? File.ReadAllText(shaFile).Trim() : "";
			bool installed = File.Exists(Path.Combine(gameDir, "project.godot")) && have != "";

			if (remote == null)
			{
				if (!installed)
					throw new Exception("Could not reach GitHub and the game is not installed yet. Check your connection.");
				Say("No connection to GitHub: starting the installed version.", -1);
			}
			else if (opt.Force || !installed || remote != have)
			{
				UpdateGame(remote);
				ImportGame();
				File.WriteAllText(shaFile, remote);
			}
			else if (!CacheReady())
			{
				ImportGame();
			}

			if (opt.NoLaunch)
			{
				Say("Done.", 100);
				Finish(0);
				return;
			}
			Say("Starting the game...", 100);
			StartGame();
			Finish(0);
		}
		catch (Exception e)
		{
			Log("ERROR: " + e);
			UI(delegate { MessageBox.Show(this, e.Message + "\r\n\r\nDetails: " + logFile, "PokeBrawl", MessageBoxButtons.OK, MessageBoxIcon.Error); });
			Finish(1);
		}
	}

	void Finish(int code)
	{
		Environment.ExitCode = code;
		UI(delegate { Close(); });
	}


	// ------------------------------------------------------------ Godot

	void EnsureGodot()
	{
		if (File.Exists(godotExe) && File.Exists(godotConsole)) return;
		string url = "https://github.com/godotengine/godot/releases/download/" + Program.GodotVersion +
			"/Godot_v" + Program.GodotVersion + "_win64.exe.zip";
		string zip = Path.Combine(Path.GetTempPath(), "pokebrawl_godot.zip");
		Download(url, zip, "Downloading Godot " + Program.GodotVersion);
		Say("Unpacking Godot...", -1);
		Directory.CreateDirectory(godotDir);
		using (ZipArchive archive = ZipFile.OpenRead(zip))
		{
			foreach (ZipArchiveEntry e in archive.Entries)
			{
				if (e.Name == "") continue;
				e.ExtractToFile(Path.Combine(godotDir, e.Name), true);
			}
		}
		File.Delete(zip);
		if (!File.Exists(godotExe))
			throw new Exception("Godot was downloaded but its program was not found in " + godotDir);
	}

	void ImportGame()
	{
		// Godot reads the assets once (and again after an update) before the game can run.
		Say("Preparing the game files (a minute the first time)...", 0);
		var psi = new ProcessStartInfo(godotConsole, "--headless --path \"" + gameDir + "\" --import --quit");
		psi.UseShellExecute = false;
		psi.CreateNoWindow = true;
		psi.RedirectStandardOutput = true;
		psi.RedirectStandardError = true;
		var percent = new Regex(@"\[\s*(\d+)%");
		using (Process p = Process.Start(psi))
		{
			DataReceivedEventHandler onLine = delegate (object s, DataReceivedEventArgs ev)
			{
				if (ev.Data == null) return;
				Match m = percent.Match(ev.Data);
				if (m.Success)
				{
					int v = int.Parse(m.Groups[1].Value);
					UI(delegate { bar.Style = ProgressBarStyle.Continuous; bar.Value = Math.Max(0, Math.Min(100, v)); });
				}
			};
			p.OutputDataReceived += onLine;
			p.ErrorDataReceived += delegate { };
			p.BeginOutputReadLine();
			p.BeginErrorReadLine();
			p.WaitForExit();
			Log("import exit code " + p.ExitCode);
		}
		if (!CacheReady())
			throw new Exception("Godot could not prepare the game files.");
	}

	bool CacheReady()
	{
		return File.Exists(Path.Combine(gameDir, ".godot", "global_script_class_cache.cfg"));
	}

	void StartGame()
	{
		var args = new StringBuilder("--path \"" + gameDir + "\" --");
		foreach (string a in opt.GameArgs)
			args.Append(' ').Append(a.Contains(" ") ? "\"" + a + "\"" : a);
		var psi = new ProcessStartInfo(godotExe, args.ToString());
		psi.UseShellExecute = false;
		psi.WorkingDirectory = gameDir;
		Process.Start(psi);
	}


	// ------------------------------------------------------------ GitHub

	/// The commit of the branch on GitHub, or null if it cannot be reached. Its message (first
	/// line) goes to `remoteMessage`, to show what the update is about.
	string RemoteSha()
	{
		try
		{
			var req = (HttpWebRequest)WebRequest.Create("https://api.github.com/repos/" + opt.Repo + "/commits/" + opt.Branch);
			req.UserAgent = "PokeBrawl-Launcher";
			req.Accept = "application/vnd.github+json";
			req.Timeout = 15000;
			using (var resp = (HttpWebResponse)req.GetResponse())
			using (var rd = new StreamReader(resp.GetResponseStream(), Encoding.UTF8))
			{
				string json = rd.ReadToEnd();
				Match sha = Regex.Match(json, "\"sha\"\\s*:\\s*\"([0-9a-f]{40})\"");
				// The first "message" in the answer is the commit's own (the author's fields come before it).
				Match msg = Regex.Match(json, "\"message\"\\s*:\\s*\"((?:\\\\.|[^\"\\\\])*)\"");
				if (msg.Success)
				{
					string text = Regex.Unescape(msg.Groups[1].Value).Replace("\r", "");
					int nl = text.IndexOf('\n');
					remoteMessage = (nl >= 0 ? text.Substring(0, nl) : text).Trim();
				}
				return sha.Success ? sha.Groups[1].Value : null;
			}
		}
		catch (Exception e)
		{
			Log("could not ask GitHub: " + e.Message);
			return null;
		}
	}

	void UpdateGame(string sha)
	{
		string tmp = Path.Combine(Path.GetTempPath(), "pokebrawl_" + Guid.NewGuid().ToString("N"));
		Directory.CreateDirectory(tmp);
		try
		{
			string zip = Path.Combine(tmp, "game.zip");
			Download("https://github.com/" + opt.Repo + "/archive/" + sha + ".zip", zip, "Downloading the game (" + sha.Substring(0, 7) + ")");
			Say("Unpacking the game...", -1);
			string unpacked = Path.Combine(tmp, "x");
			ZipFile.ExtractToDirectory(zip, unpacked);
			string[] roots = Directory.GetDirectories(unpacked);
			string src = roots.Length > 0 ? Path.Combine(roots[0], "game") : "";
			if (src == "" || !File.Exists(Path.Combine(src, "project.godot")))
				throw new Exception("The repository " + opt.Repo + " has no game\\project.godot");
			Say("Installing the update...", -1);
			Mirror(src, gameDir);
		}
		finally
		{
			try { Directory.Delete(tmp, true); } catch { }
		}
	}

	/// Makes `dst` look like `src`, touching only what changed. The import cache (.godot) and
	/// the music folder stay as they are.
	static void Mirror(string src, string dst)
	{
		Directory.CreateDirectory(dst);
		bool musicThere = Directory.Exists(Path.Combine(dst, "music"));
		var keep = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
		foreach (string f in Directory.GetFiles(src, "*", SearchOption.AllDirectories))
		{
			string rel = f.Substring(src.Length + 1);
			string top = rel.Split('\\')[0];
			if (top == ".godot" || (top == "music" && musicThere)) continue;
			keep.Add(rel);
			string target = Path.Combine(dst, rel);
			Directory.CreateDirectory(Path.GetDirectoryName(target));
			if (!File.Exists(target) || !SameFile(f, target))
				File.Copy(f, target, true);
		}
		foreach (string f in Directory.GetFiles(dst, "*", SearchOption.AllDirectories))
		{
			string rel = f.Substring(dst.Length + 1);
			string top = rel.Split('\\')[0];
			if (top == ".godot" || top == "music") continue;
			if (!keep.Contains(rel))
				File.Delete(f);
		}
		foreach (string d in Directory.GetDirectories(dst, "*", SearchOption.AllDirectories))
		{
			string rel = d.Substring(dst.Length + 1);
			string top = rel.Split('\\')[0];
			if (top == ".godot" || top == "music" || !Directory.Exists(d)) continue;
			if (Directory.GetFileSystemEntries(d).Length == 0)
				Directory.Delete(d);
		}
	}

	static bool SameFile(string a, string b)
	{
		var fa = new FileInfo(a);
		var fb = new FileInfo(b);
		if (fa.Length != fb.Length) return false;
		using (var sa = fa.OpenRead())
		using (var sb = fb.OpenRead())
		{
			var ba = new byte[65536];
			var bb = new byte[65536];
			while (true)
			{
				int na = sa.Read(ba, 0, ba.Length);
				int nb = sb.Read(bb, 0, bb.Length);
				if (na != nb) return false;
				if (na == 0) return true;
				for (int i = 0; i < na; i++)
					if (ba[i] != bb[i]) return false;
			}
		}
	}

	void Download(string url, string to, string label)
	{
		Say(label + "...", 0);
		var req = (HttpWebRequest)WebRequest.Create(url);
		req.UserAgent = "PokeBrawl-Launcher";
		req.Timeout = 30000;
		req.ReadWriteTimeout = 60000;
		string part = to + ".part";
		using (var resp = (HttpWebResponse)req.GetResponse())
		using (Stream input = resp.GetResponseStream())
		using (FileStream output = File.Create(part))
		{
			long total = resp.ContentLength;
			long done = 0;
			var buffer = new byte[65536];
			int last = -1;
			int n;
			while ((n = input.Read(buffer, 0, buffer.Length)) > 0)
			{
				output.Write(buffer, 0, n);
				done += n;
				if (total > 0)
				{
					int pct = (int)(done * 100 / total);
					if (pct != last)
					{
						last = pct;
						Say(string.Format("{0}... {1} / {2} MB", label, done / 1048576, total / 1048576), pct);
					}
				}
			}
		}
		if (File.Exists(to)) File.Delete(to);
		File.Move(part, to);
	}
}

