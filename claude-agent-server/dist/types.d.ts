export interface RpcRequest<P = unknown> {
    jsonrpc: "2.0";
    id: number | string;
    method: string;
    params?: P;
}
export interface RpcNotification<P = unknown> {
    jsonrpc: "2.0";
    method: string;
    params?: P;
}
export interface RpcResponse<R = unknown> {
    jsonrpc: "2.0";
    id: number | string;
    result?: R;
    error?: {
        code: number;
        message: string;
        data?: unknown;
    };
}
export type RpcMessage = RpcRequest | RpcNotification | RpcResponse;
export declare function isRequest(m: RpcMessage): m is RpcRequest;
export declare function isNotification(m: RpcMessage): m is RpcNotification;
export declare function isResponse(m: RpcMessage): m is RpcResponse;
export interface InitializeParams {
    protocolVersion: string;
    clientInfo?: {
        name: string;
        version: string;
    };
    clientCapabilities?: {
        fs?: {
            readTextFile?: boolean;
            writeTextFile?: boolean;
        };
        terminal?: boolean;
        repoMap?: {
            digest: string;
        };
    };
}
export interface AgentCapabilities {
    serverManagedRepoMap?: boolean;
    agentMemory?: boolean;
    customTools?: string[];
}
export interface InitializeResult {
    protocolVersion: string;
    agentInfo: {
        name: string;
        version: string;
    };
    agentCapabilities: AgentCapabilities;
}
export interface McpServer {
    name: string;
    command?: string;
    url?: string;
    type?: "stdio" | "http";
}
export interface SessionNewParams {
    cwd: string;
    mcpServers: McpServer[];
}
export interface ConfigOptionItem {
    value: string;
    name?: string;
    description?: string;
}
export interface ConfigOption {
    category: "mode" | "model";
    currentValue: string;
    options: ConfigOptionItem[];
}
export interface SessionNewResult {
    sessionId: string;
    configOptions: ConfigOption[];
}
export interface PromptBlock {
    type: "text" | "resource_link" | "image";
    text?: string;
    uri?: string;
    name?: string;
    mimeType?: string;
}
export interface SessionPromptParams {
    sessionId: string;
    prompt: PromptBlock[];
}
export type StopReason = "end_turn" | "cancelled" | "max_tokens" | "tool_use" | "error";
export interface SessionPromptResult {
    stopReason: StopReason;
}
export interface SessionCancelParams {
    sessionId: string;
}
export interface SessionSetModelParams {
    sessionId: string;
    modelId: string;
}
export interface SessionSetConfigOptionParams {
    sessionId: string;
    configId: string;
    value: string;
}
export interface SessionSetConfigOptionResult {
    configOptions?: ConfigOption[];
}
export type ToolStatus = "pending" | "in_progress" | "completed" | "failed";
export type ToolContent = {
    type: "text";
    text: string;
} | {
    type: "diff";
    oldText?: string;
    newText: string;
    path?: string;
};
export type ToolKind = "read" | "edit" | "delete" | "move" | "search" | "execute" | "think" | "fetch" | "other";
export interface ToolCallStart {
    sessionUpdate: "tool_call";
    toolCallId: string;
    kind: ToolKind | string;
    title: string;
    status: ToolStatus;
    rawInput?: Record<string, unknown>;
    content?: ToolContent[];
    locations?: {
        path: string;
        line?: number;
    }[];
}
export interface ToolCallUpdate {
    sessionUpdate: "tool_call_update";
    toolCallId: string;
    status?: ToolStatus;
    content?: ToolContent[];
}
export interface AgentMessageChunk {
    sessionUpdate: "agent_message_chunk";
    content: {
        text: string;
    };
}
export interface AgentThoughtChunk {
    sessionUpdate: "agent_thought_chunk";
    content: {
        text: string;
    };
}
export interface ConfigOptionUpdate {
    sessionUpdate: "config_option_update";
    configOptions: ConfigOption[];
}
export type SessionUpdate = AgentMessageChunk | AgentThoughtChunk | ToolCallStart | ToolCallUpdate | ConfigOptionUpdate;
export interface SessionUpdateParams {
    sessionId: string;
    update: SessionUpdate;
}
export interface PermissionOption {
    optionId: string;
    name: string;
    kind: "allow_once" | "allow_always" | "reject_once" | "reject_always";
}
export interface RequestPermissionParams {
    sessionId: string;
    toolCall: {
        toolCallId: string;
        kind: string;
        title: string;
        rawInput?: unknown;
        content?: ToolContent[];
    };
    options: PermissionOption[];
}
export interface RequestPermissionResult {
    outcome: {
        outcome: "selected" | "cancelled";
        optionId?: string;
    };
}
export interface FsReadTextFileParams {
    sessionId: string;
    path: string;
    line?: number;
    limit?: number;
}
export interface FsReadTextFileResult {
    content: string;
}
export interface FsWriteTextFileParams {
    sessionId: string;
    path: string;
    content: string;
}
export type FsWriteTextFileResult = Record<string, never>;
export interface ToolDefinition<I = unknown, O = unknown> {
    name: string;
    description: string;
    input_schema: Record<string, unknown>;
    kind: ToolKind | string;
    dispatch: (input: I, ctx: ToolContext) => Promise<O>;
}
export interface ToolContext {
    sessionId: string;
    request: <T = unknown>(method: string, params: unknown) => Promise<T>;
    notify: (update: SessionUpdate) => void;
    signal: AbortSignal;
}
