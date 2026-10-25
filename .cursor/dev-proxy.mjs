/**
 * Same-origin development proxy.
 * The rewards dashboard calls relative /api paths. Outside Replit those
 * requests need one origin in front of the Vite app and the preview API.
 */
import http from "node:http";
import net from "node:net";

const listenPort = Number(process.env.PROXY_PORT || 4173);
const uiPort = Number(process.env.UI_PORT || 3000);
const apiPort = Number(process.env.API_PORT || 8080);
const brandPort = Number(process.env.BRAND_PORT || 3001);

function targetPort(url) {
  const path = url || "/";
  if (path === "/api" || path.startsWith("/api/") || path.startsWith("/api?")) return apiPort;
  if (path.startsWith("/darkswap-brand")) return brandPort;
  return uiPort;
}

function headerLines(headers) {
  const lines = [];
  for (const [key, value] of Object.entries(headers)) {
    if (Array.isArray(value)) {
      for (const item of value) lines.push(`${key}: ${item}`);
    } else if (value != null) {
      lines.push(`${key}: ${value}`);
    }
  }
  return lines;
}

const server = http.createServer((req, res) => {
  const port = targetPort(req.url);
  const upstream = http.request(
    {
      hostname: "127.0.0.1",
      port,
      path: req.url,
      method: req.method,
      headers: req.headers,
    },
    (up) => {
      res.writeHead(up.statusCode || 502, up.headers);
      up.pipe(res);
    },
  );
  upstream.on("error", () => {
    if (!res.headersSent) res.writeHead(502, { "content-type": "text/plain" });
    res.end("upstream unavailable");
  });
  req.pipe(upstream);
});

server.on("upgrade", (req, socket, head) => {
  const port = targetPort(req.url);
  const upstream = net.connect(port, "127.0.0.1", () => {
    upstream.write(
      `${req.method} ${req.url} HTTP/1.1\r\n${headerLines(req.headers).join("\r\n")}\r\n\r\n`,
    );
    if (head?.length) upstream.write(head);
    upstream.pipe(socket);
    socket.pipe(upstream);
  });
  const closeBoth = () => {
    socket.destroy();
    upstream.destroy();
  };
  upstream.on("error", closeBoth);
  socket.on("error", closeBoth);
});

server.listen(listenPort, "0.0.0.0", () => {
  console.log(`rewards dev proxy listening on ${listenPort}`);
});
