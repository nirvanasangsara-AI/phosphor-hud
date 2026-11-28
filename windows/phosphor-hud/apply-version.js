const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const version = fs.readFileSync(path.resolve(__dirname, "../../VERSION"), "utf8").trim();
if (!/^[0-9]+(\.[0-9]+){1,3}$/.test(version)) {
  console.error(`VERSION must look like 0.2.1, found: ${version}`);
  process.exit(1);
}

const args = process.argv.slice(2);
if (args.length === 0) args.push("build");
const cli = path.join(__dirname, "node_modules", "@tauri-apps", "cli", "tauri.js");
const result = spawnSync(
  process.execPath,
  [cli, ...args, "--config", JSON.stringify({ version })],
  { stdio: "inherit", cwd: __dirname }
);
process.exit(result.status == null ? 1 : result.status);
