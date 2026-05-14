// Newline-delimited JSON-RPC 2.0 framer over a Readable/Writable pair.
// No Content-Length headers — matches what acp_transport.lua expects.
export class Transport {
    buffer = "";
    listeners = [];
    writeFn;
    constructor(writeFn) {
        this.writeFn = writeFn;
    }
    /** Feed raw stdin bytes (as a UTF-8 string). Splits on \n; partial trailing
     * line is held until the next call. */
    feed(chunk) {
        this.buffer += chunk;
        let nlIdx = this.buffer.indexOf("\n");
        while (nlIdx !== -1) {
            const line = this.buffer.slice(0, nlIdx).trim();
            this.buffer = this.buffer.slice(nlIdx + 1);
            if (line.length > 0) {
                this.dispatchLine(line);
            }
            nlIdx = this.buffer.indexOf("\n");
        }
    }
    /** Emit an outbound JSON-RPC message. */
    send(msg) {
        this.writeFn(JSON.stringify(msg) + "\n");
    }
    onMessage(fn) {
        this.listeners.push(fn);
    }
    dispatchLine(line) {
        let parsed;
        try {
            parsed = JSON.parse(line);
        }
        catch {
            // Malformed line: drop. We can't respond because we may not know the id.
            return;
        }
        if (!isMessage(parsed)) {
            return;
        }
        for (const l of this.listeners) {
            l(parsed);
        }
    }
}
function isMessage(v) {
    if (!v || typeof v !== "object")
        return false;
    const m = v;
    return m.jsonrpc === "2.0";
}
//# sourceMappingURL=transport.js.map