import { type SessionDeps } from "./session";
import { Transport } from "./transport";
import type { RpcMessage } from "./types";
export interface ServerOptions {
    agentName?: string;
    agentVersion?: string;
    defaultModel?: string;
    models?: string[];
    /** Per outbound request timeout in ms. Default 30s. (T2.4) */
    requestTimeoutMs?: number;
    makeSessionDeps?: (sessionId: string) => SessionDeps;
}
export interface ServerHandle {
    send: (msg: RpcMessage) => void;
    request: <T = unknown>(method: string, params: unknown) => Promise<T>;
    notify: (method: string, params: unknown) => void;
    handleInbound: (msg: RpcMessage) => Promise<void>;
    /** Cancel and remove every active session. Called by the stdio entry on
     * graceful shutdown. (T2.6) */
    shutdownAll: () => void;
}
/** Construct a Server bound to an existing Transport. The transport is
 * what reads stdin / writes stdout; the Server is purely about message
 * semantics. */
export declare function createServer(transport: Transport, opts: ServerOptions): ServerHandle;
