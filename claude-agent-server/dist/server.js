// JSON-RPC server: registers handlers for ACP methods, routes inbound
// messages through Transport, correlates outbound requests with their
// responses, and exposes a `notify()` for streaming session updates.
import { Session } from "./session";
import { isNotification, isRequest, isResponse } from "./types";
/** Construct a Server bound to an existing Transport. The transport is
 * what reads stdin / writes stdout; the Server is purely about message
 * semantics. */
export function createServer(transport, opts) {
    const agentInfo = {
        name: opts.agentName ?? "claude-agent-server",
        version: opts.agentVersion ?? "0.1.0",
    };
    const agentCapabilities = {
        serverManagedRepoMap: false,
        agentMemory: false,
        customTools: [],
    };
    const sessions = new Map();
    const requestTimeoutMs = opts.requestTimeoutMs ?? 30000;
    // Outbound request correlation: id → resolver
    let nextId = 1;
    const pending = new Map();
    const send = (msg) => transport.send(msg);
    const notify = (method, params) => {
        send({ jsonrpc: "2.0", method, params });
    };
    const request = (method, params) => new Promise((resolve, reject) => {
        const id = nextId++;
        const sessionId = params && typeof params === "object" && "sessionId" in params
            ? String(params.sessionId)
            : undefined;
        const timer = setTimeout(() => {
            if (pending.has(id)) {
                pending.delete(id);
                reject({ code: -32001, message: `request ${method} timed out after ${requestTimeoutMs}ms` });
            }
        }, requestTimeoutMs);
        pending.set(id, {
            resolve: v => resolve(v),
            reject,
            sessionId,
            timer,
        });
        send({ jsonrpc: "2.0", id, method, params });
    });
    const rejectPendingForSession = (sessionId) => {
        for (const [id, p] of pending) {
            if (p.sessionId === sessionId) {
                clearTimeout(p.timer);
                pending.delete(id);
                p.reject({ code: -32001, message: "session cancelled" });
            }
        }
    };
    const closeSession = (sessionId) => {
        const s = sessions.get(sessionId);
        if (s) {
            s.cancel();
            sessions.delete(sessionId);
        }
        rejectPendingForSession(sessionId);
    };
    const shutdownAll = () => {
        for (const sessionId of [...sessions.keys()]) {
            closeSession(sessionId);
        }
    };
    const respond = (id, result) => {
        send({ jsonrpc: "2.0", id, result });
    };
    const respondError = (id, code, message) => {
        send({ jsonrpc: "2.0", id, error: { code, message } });
    };
    const emitSessionUpdate = (sessionId, update) => {
        const params = { sessionId, update };
        notify("session/update", params);
    };
    const makeDeps = opts.makeSessionDeps ??
        ((sessionId) => ({
            sessionId,
            notify: update => emitSessionUpdate(sessionId, update),
            request: (method, params) => request(method, params),
        }));
    const handleInitialize = async (params) => {
        return {
            protocolVersion: params.protocolVersion ?? "2025-01",
            agentInfo,
            agentCapabilities,
        };
    };
    const handleSessionNew = async (params) => {
        const sessionId = `cas-${Date.now()}-${Math.floor(Math.random() * 1e9)}`;
        const deps = makeDeps(sessionId);
        const session = new Session(sessionId, params.cwd, deps, {
            defaultModel: opts.defaultModel ?? "claude-sonnet-4-6",
            models: opts.models ?? ["claude-opus-4-7", "claude-sonnet-4-6", "claude-haiku-4-5"],
        });
        sessions.set(sessionId, session);
        return { sessionId, configOptions: session.configOptions() };
    };
    const handleSessionPrompt = async (params) => {
        const session = sessions.get(params.sessionId);
        if (!session) {
            throw new Error("unknown sessionId: " + params.sessionId);
        }
        const stopReason = await session.prompt(params.prompt);
        return { stopReason };
    };
    const handleSessionCancel = (params) => {
        const session = sessions.get(params.sessionId);
        if (session) {
            session.cancel();
            // Also free pending fs/* requests tied to this session (T2.4).
            rejectPendingForSession(params.sessionId);
        }
    };
    const handleSessionClose = (params) => {
        // T2.5: explicit close that drops the session from the map.
        closeSession(params.sessionId);
    };
    const handleSessionSetModel = async (params) => {
        const session = sessions.get(params.sessionId);
        if (!session) {
            throw new Error("unknown sessionId: " + params.sessionId);
        }
        session.setModel(params.modelId);
        return { configOptions: session.configOptions() };
    };
    const handleSessionSetConfigOption = async (params) => {
        const session = sessions.get(params.sessionId);
        if (!session) {
            throw new Error("unknown sessionId: " + params.sessionId);
        }
        if (params.configId === "model") {
            session.setModel(params.value);
        }
        else if (params.configId === "mode") {
            session.setMode(params.value);
        }
        return { configOptions: session.configOptions() };
    };
    const handlers = {
        initialize: p => handleInitialize(p),
        "session/new": p => handleSessionNew(p),
        "session/prompt": p => handleSessionPrompt(p),
        "session/set_model": p => handleSessionSetModel(p),
        "session/set_config_option": p => handleSessionSetConfigOption(p),
    };
    const notificationHandlers = {
        "session/cancel": p => handleSessionCancel(p),
        "session/close": p => handleSessionClose(p),
    };
    const handleInbound = async (msg) => {
        if (isResponse(msg)) {
            const p = pending.get(msg.id);
            if (!p)
                return;
            pending.delete(msg.id);
            clearTimeout(p.timer);
            if (msg.error) {
                p.reject(msg.error);
            }
            else {
                p.resolve(msg.result);
            }
            return;
        }
        if (isNotification(msg)) {
            const h = notificationHandlers[msg.method];
            if (h) {
                try {
                    h(msg.params);
                }
                catch {
                    // Notifications can't surface errors.
                }
            }
            return;
        }
        if (isRequest(msg)) {
            const req = msg;
            const h = handlers[req.method];
            if (!h) {
                respondError(req.id, -32601, "method not found: " + req.method);
                return;
            }
            try {
                const result = await h(req.params);
                respond(req.id, result);
            }
            catch (e) {
                const message = e && typeof e === "object" && "message" in e ? String(e.message) : String(e);
                respondError(req.id, -32000, message);
            }
        }
    };
    transport.onMessage(msg => {
        void handleInbound(msg);
    });
    return { send, request, notify, handleInbound, shutdownAll };
}
//# sourceMappingURL=server.js.map