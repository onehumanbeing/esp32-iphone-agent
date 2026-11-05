// postinstall: downloads the esp32agent binary (binaryVersion, else this package's version) from GitHub Releases and checks its
// SHA-256 against checksums.txt. ESP32AGENT_ARCHIVE=/path installs a local build (checksums.txt next to it).
const { createHash } = require("crypto");
const { execFileSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const pkg = require("./package.json");
const version = pkg.binaryVersion || pkg.version; // a metadata-only npm release reuses the last binaries
const goos = { darwin: "darwin", linux: "linux", win32: "windows" }[process.platform];
const goarch = { x64: "amd64", arm64: "arm64" }[process.arch];
if (!goos || !goarch) throw new Error(`esp32agent: unsupported platform ${process.platform}/${process.arch}`);
const name = `esp32agent_${goos}_${goarch}.${goos === "windows" ? "zip" : "tar.gz"}`;
const base = `https://github.com/onehumanbeing/esp32-iphone-agent/releases/download/cli-v${version}`;

async function fetchBytes(url) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`esp32agent: download failed (${res.status}): ${url}`);
  return Buffer.from(await res.arrayBuffer());
}

async function main() {
  const local = process.env.ESP32AGENT_ARCHIVE;
  const archive = local ? fs.readFileSync(local) : await fetchBytes(`${base}/${name}`);
  const sums = local
    ? fs.readFileSync(process.env.ESP32AGENT_CHECKSUMS || path.join(path.dirname(local), "checksums.txt"), "utf8")
    : (await fetchBytes(`${base}/checksums.txt`)).toString("utf8");
  const line = sums.split("\n").find((l) => [name, `*${name}`].includes(l.trim().split(/\s+/)[1]));
  if (!line) throw new Error(`esp32agent: ${name} is not in checksums.txt`);
  const got = createHash("sha256").update(archive).digest("hex");
  if (line.trim().split(/\s+/)[0].toLowerCase() !== got) throw new Error(`esp32agent: checksum mismatch for ${name}`);

  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "esp32agent-"));
  const file = path.join(tmp, name);
  fs.writeFileSync(file, archive);
  execFileSync("tar", ["-xf", file, "-C", tmp]); // bsdtar on Windows 10+ reads zip too
  const exe = goos === "windows" ? "esp32agent.exe" : "esp32agent";
  const dest = path.join(__dirname, "bin", exe);
  fs.copyFileSync(path.join(tmp, exe), dest);
  fs.chmodSync(dest, 0o755);
  fs.rmSync(tmp, { recursive: true, force: true });
  try {
    execFileSync("ffmpeg", ["-version"], { stdio: "ignore" });
  } catch {
    console.warn("esp32agent: ffmpeg not found; install it for screenshots (brew/apt/dnf install ffmpeg, winget install Gyan.FFmpeg)");
  }
}

main().catch((e) => {
  console.error(e.message);
  process.exit(1);
});
