import net from "node:net";
import fs from "node:fs";

/// Path to Nook's Unix domain socket, hard-coded to match HookSocketServer.
const SOCKET_PATH = "/tmp/nook.sock";

/// Path to the command socket — Nook connects here to send commands
/// (e.g. permission replies) back to the plugin.
/// Pid-scoped so multiple opencode instances don't contend for a single
/// socket (kernel load-balances new connections across listeners, so a
/// reply could land on the wrong instance → PermissionNotFoundError).
const INSTANCE_PID = process.pid;
const COMMAND_SOCKET_PATH = `/tmp/nook-command-${INSTANCE_PID}.sock`;

/// Debug log for plugin-side troubleshooting.
const DEBUG_LOG = "/tmp/nook-plugin-debug.log";

function logDebug(message) {
  try {
    fs.appendFileSync(DEBUG_LOG, `[${new Date().toISOString()}] pid=${INSTANCE_PID} ${message}\n`);
  } catch {}
}

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

/// Create the command socket server so Nook can send commands to us.
/// Commands are JSON objects with a `cmd` field. The only command today
/// is `permission.reply`, which carries `requestId` and `reply`
/// ("once" | "always" | "reject").
function startCommandServer(input) {
  try {
    // Clean up any stale socket from a previous run.
    try { fs.unlinkSync(COMMAND_SOCKET_PATH); } catch {}
  } catch {}

  // Remove our pid-scoped socket on exit so /tmp doesn't accumulate.
  process.on("exit", () => {
    try { fs.unlinkSync(COMMAND_SOCKET_PATH); } catch {}
  });

  const server = net.createServer((socket) => {
    let buffer = "";
    socket.on("data", (chunk) => { buffer += chunk.toString(); });
    socket.on("end", () => {
      handleCommand(buffer, input);
    });
    socket.on("error", () => {});
  });

  server.on("error", (err) => {
    logDebug(`command server error: ${err.message}`);
  });

  server.listen(COMMAND_SOCKET_PATH, () => {
    logDebug(`command server listening on ${COMMAND_SOCKET_PATH}`);
  });
}

/// Handle a single command line from Nook.
async function handleCommand(rawLine, input) {
  let cmd;
  try {
    cmd = JSON.parse(rawLine);
  } catch (err) {
    logDebug(`handleCommand parse error: ${err.message}`);
    return;
  }

  logDebug(`handleCommand cmd=${JSON.stringify(cmd)}`);

  if (cmd.cmd === "permission.reply") {
    const requestId = cmd.requestId;
    const reply = cmd.reply; // "once" | "always" | "reject"
    if (!requestId || !reply) {
      logDebug("handleCommand missing requestId or reply");
      return;
    }

    try {
      const client = input?.client;
      // opencode 1.17.20 exposes the HTTP client on `client._client`
      // (HeyApi Client). The v2 permission reply route is
      // POST /permission/{requestID}/reply. When opencode runs without a
      // serverUrl (TUI mode), `client._client` is configured with an
      // in-process fetch that hits opencode's own app — so we don't need
      // a real HTTP listener on port 4096.
      const heyApiClient = client?._client;
      if (!heyApiClient || typeof heyApiClient.post !== "function") {
        logDebug("reply FAILED: no client._client.post available");
        return;
      }

      // opencode v1 permission reply body: { reply: "once" | "always" | "reject" }
      // Nook's reply values map 1:1 — no transformation needed.
      const res = await heyApiClient.post({
        url: "/permission/{requestID}/reply",
        path: { requestID: requestId },
        body: { reply },
      });

      logDebug(`reply OK res=${JSON.stringify(res)}`);
    } catch (err) {
      logDebug(`reply FAILED: ${err.message}\n${err.stack || ""}`);
    }
  }
  else if (cmd.cmd === "question.reply") {
    const requestId = cmd.requestId;
    const sessionId = cmd.sessionId;
    const answers = cmd.answers; // string[][] — one array per question, of selected labels/free text
    if (!requestId || !sessionId || !answers) {
      logDebug("question.reply missing requestId, sessionId, or answers");
      return;
    }
    try {
      const client = input?.client;
      const heyApiClient = client?._client;
      if (!heyApiClient || typeof heyApiClient.post !== "function") {
        logDebug("question.reply FAILED: no client._client.post available");
        return;
      }
      // opencode question reply route (schema v1: question.ts). Body: { answers }
      // NOTE: URL verified against the permission.reply pattern (which uses
      // "/permission/{requestID}/reply" against the same heyApiClient base).
      // CONFIRM exact path at end-to-end test (Task 19); if the heyApi client
      // base already prefixes /api/session/:id, adjust to match.
      const res = await heyApiClient.post({
        url: "/session/{sessionID}/question/{requestID}/reply",
        path: { sessionID: sessionId, requestID: requestId },
        body: { answers },
      });
      logDebug(`question.reply OK res=${JSON.stringify(res)}`);
    } catch (err) {
      logDebug(`question.reply FAILED: ${err.message}\n${err.stack || ""}`);
    }
  }
}

/// OpenCode server plugin entry point.
/// opencode calls `server(input, options)` directly with the plugin input
/// (including `client`). We capture `input` in the closure so the command
/// socket handler can use it later for permission replies.
  const PLUGIN_VERSION = "1.5.0";
export default function server(input) {
  logDebug(`nook plugin v${PLUGIN_VERSION} loaded serverUrl=${input?.serverUrl?.toString() ?? "undefined"} argv=${JSON.stringify(process.argv ?? [])}`);
  // Start listening for commands from Nook as soon as the plugin loads.
  startCommandServer(input);

  // Mirror opencode's own "external server" detection (tui.ts:233-249):
  // a real TCP listener exists only when --port/--hostname/--mdns is given.
  // Without those flags opencode uses an in-process transport and binds
  // nothing; PluginInput.serverUrl then fabricates http://localhost:4096
  // (opencode issue #39561), so the URL alone is not a reliable signal.
  // Fall back on serverUrl.hostname as a sanity check for the common
  // `opencode --port` case (default hostname 127.0.0.1).
  const hasExternalServer = () => {
    try {
      const argv = process.argv ?? [];
      if (argv.includes("--port") || argv.includes("--hostname") || argv.includes("--mdns")) {
        return true;
      }
      const host = input?.serverUrl?.hostname;
      return !!host && host !== "localhost" && host !== "opencode.internal";
    } catch {
      return false;
    }
  };

  // Get the actual server port from input.serverUrl (provided by OpenCode).
  // serverUrl is set after the HTTP server starts, so it may be undefined briefly.
  // URL.port returns a string (e.g. "4096") — coerce to a number so Nook's
  // Int parsing doesn't drop the event.
  // Returns null when opencode is running without a real HTTP server
  // (TUI mode without --port). Callers must treat null as "no server".
  const getServerPort = () => {
    try {
      if (!hasExternalServer()) return null;
      const raw = input?.serverUrl?.port;
      if (raw === undefined || raw === null || raw === "") return null;
      const port = Number(raw);
      return Number.isFinite(port) && port > 0 ? port : null;
    } catch {
      return null;
    }
  };

  // Send server port to Nook. Retry until Nook's socket is ready.
  // Nook might not be listening on /tmp/nook.sock when the plugin first loads.
  let retryCount = 0;
  const maxRetries = 30; // 30 * 2s = 60s
  const sendServerPort = () => {
    if (retryCount >= maxRetries) return;
    retryCount++;
    const port = getServerPort();
    // port 0 signals "no HTTP server" so Nook doesn't treat it as real.
    const reportedPort = port ?? 0;
    logDebug(`sending serverPort=${reportedPort}${port === null ? " (no serverUrl)" : ""} (attempt ${retryCount})`);
    send({
      origin: "opencode",
      type: "serverPort",
      properties: { port: reportedPort, pid: INSTANCE_PID },
    }).then(() => {
      if (retryCount < maxRetries) {
        setTimeout(sendServerPort, 2000);
      }
    });
  };
  // Initial attempt + retries every 2s
  sendServerPort();

  // Self-heal: when opencode resumes a pre-existing session it never emits
  // session.created/updated on the bus, so Nook would never register the
  // session and would drop all its events. Proactively report the current
  // session (via the in-process client) so Nook can self-heal.
  const extractSessionId = (status) => {
    if (!status || typeof status !== "object") return null;
    // Direct field: { sessionID: "ses_xxx" }
    if (typeof status.sessionID === "string" && status.sessionID.startsWith("ses_")) {
      return status.sessionID;
    }
    let obj = status;
    if (status.data && typeof status.data === "object") obj = status.data;
    if (typeof obj.sessionID === "string" && obj.sessionID.startsWith("ses_")) {
      return obj.sessionID;
    }
    const keys = Object.keys(obj).filter((k) => typeof k === "string" && k.startsWith("ses_"));
    return keys.length > 0 ? keys[0] : null;
  };
  // Fallback when status() returns empty (opencode v1.18.x server/port mode).
  // List all sessions and pick the most recently updated one.
  const listAndPickSession = async () => {
    try {
      const client = input?.client;
      if (!client || typeof client.session?.list !== "function") return null;
      const res = await client.session.list();
      const sessions = res?.data || res;
      if (!Array.isArray(sessions) || sessions.length === 0) return null;
      const sorted = [...sessions].sort((a, b) => {
        const ta = a.time?.updated ?? a.time?.created ?? 0;
        const tb = b.time?.updated ?? b.time?.created ?? 0;
        return tb - ta;
      });
      const top = sorted[0];
      return top?.id || null;
    } catch (err) {
      logDebug(`listAndPickSession error: ${err.message}`);
      return null;
    }
  };

  const reportCurrentSession = async () => {
    const client = input?.client;
    if (!client || typeof client.session?.status !== "function") {
      logDebug("reportCurrentSession: no session.status available");
      return false;
    }
    try {
      const status = await client.session.status();
      logDebug(`reportCurrentSession status=${JSON.stringify(status)}`);
      var sessionId = extractSessionId(status);
      // Fallback: status() returned empty — try listing sessions and pick the
      // most-recent one. opencode v1.18.x server mode returns empty status().
      if (!sessionId) {
        logDebug("reportCurrentSession: status empty, falling back to session.list()");
        sessionId = await listAndPickSession();
      }
      if (!sessionId) {
        logDebug("reportCurrentSession: no current session yet");
        return false;
      }
      const cwd = input?.directory || process.cwd();
      await send({
        origin: "opencode",
        type: "session.started",
        properties: { sessionID: sessionId, cwd, pid: INSTANCE_PID },
      });
      logDebug(`reportCurrentSession sent session.started sessionID=${sessionId} cwd=${cwd}`);
      return true;
    } catch (err) {
      logDebug(`reportCurrentSession FAILED: ${err.message}\n${err.stack || ""}`);
      return false;
    }
  };
  let reportAttempts = 0;
  const maxReportAttempts = 30;
  const tryReportCurrentSession = async () => {
    if (reportAttempts >= maxReportAttempts) return;
    reportAttempts++;
    try {
      const ok = await reportCurrentSession();
      if (ok) {
        logDebug("reportCurrentSession succeeded, stopping retries");
        return;
      }
    } catch (err) {
      logDebug(`tryReportCurrentSession error: ${err.message}`);
    }
    if (reportAttempts < maxReportAttempts) {
      setTimeout(tryReportCurrentSession, 2000);
    }
  };
  tryReportCurrentSession();

  // opencode's working directory for this plugin instance. Injected into every
  // forwarded event so Nook can self-heal session registration immediately
  // (see ensureSessionRegistered), without waiting for session.created/
  // session.updated or the plugin's delayed session.started probe.
  const instanceCwd = input?.directory || process.cwd();

  return {
    event: async ({ event }) => {
      if (event.type === "permission.asked") {
        logDebug(`permission.asked pid=${INSTANCE_PID} props=${JSON.stringify(event.properties)}`);
      }
      // Merge pid + cwd into forwarded properties so Nook can route per-instance
      // (permission replies, serverPort association) and register the session
      // on first sighting even before opencode emits session.created/updated.
      const props = (typeof event.properties === "object" && event.properties !== null)
        ? { ...event.properties, pid: INSTANCE_PID, cwd: instanceCwd }
        : { pid: INSTANCE_PID, cwd: instanceCwd };
      await send({
        origin: "opencode",
        type: event.type,
        properties: props,
      });
    },
  };
}
