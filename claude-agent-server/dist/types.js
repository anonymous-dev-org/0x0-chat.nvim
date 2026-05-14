// JSON-RPC 2.0 + ACP wire types. Mirrors the surface 0x0.nvim's
// acp_client.lua exercises.
export function isRequest(m) {
    return "method" in m && "id" in m;
}
export function isNotification(m) {
    return "method" in m && !("id" in m);
}
export function isResponse(m) {
    return !("method" in m) && "id" in m;
}
//# sourceMappingURL=types.js.map