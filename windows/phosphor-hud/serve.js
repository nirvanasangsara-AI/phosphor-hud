// Tiny static server so `npm run tauri dev` can load the HUD without a bundler.
const http = require("http");
const fs = require("fs");
const path = require("path");

const root = path.join(__dirname, "ui");
const types = { ".html": "text/html", ".css": "text/css", ".js": "text/javascript", ".png": "image/png" };

http
  .createServer((req, res) => {
    const url = new URL(req.url || "/", "http://127.0.0.1");
    let file = path.join(root, decodeURIComponent(url.pathname));
    if (!file.startsWith(root)) {
      res.writeHead(403);
      res.end();
      return;
    }
    if (fs.existsSync(file) && fs.statSync(file).isDirectory()) file = path.join(file, "index.html");
    fs.readFile(file, (err, data) => {
      if (err) {
        res.writeHead(404);
        res.end("not found");
        return;
      }
      res.writeHead(200, { "Content-Type": types[path.extname(file)] || "application/octet-stream" });
      res.end(data);
    });
  })
  .listen(1420, "127.0.0.1");
