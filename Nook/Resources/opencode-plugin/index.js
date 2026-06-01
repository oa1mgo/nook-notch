import net from "node:net";

/// Path to Nook's Unix domain socket, hard-coded to match HookSocketServer.
const SOCKET_PATH = "/tmp/nook.sock";

/// Send a payload to Nook's Unix socket.
/// Failures are silently swallowed so the plugin never crashes OpenCode.
function send(payload) {
  return new Promise((resolve) => {
    try {
      const socket = new net.Socket();
      socket.connect(SOCKET_PATH, () => {
        socket.end(JSON.stringify(payload) + "\n");
      });
      socket.on("error", () => resolve());
      socket.on("close", () => resolve());
    } catch {
      resolve();
    }
  });
}

/// OpenCode server plugin entry point.
/// Catches every bus event and forwards it to Nook.
export default function server() {
  return {
    event: async ({ event }) => {
      await send({
        origin: "opencode",
        type: event.type,
        properties: event.properties,
      });
    },
  };
}
