import type { RpcMessage } from "./types";
type Listener = (msg: RpcMessage) => void;
export declare class Transport {
    private buffer;
    private listeners;
    private writeFn;
    constructor(writeFn: (chunk: string) => void);
    /** Feed raw stdin bytes (as a UTF-8 string). Splits on \n; partial trailing
     * line is held until the next call. */
    feed(chunk: string): void;
    /** Emit an outbound JSON-RPC message. */
    send(msg: RpcMessage): void;
    onMessage(fn: Listener): void;
    private dispatchLine;
}
export {};
