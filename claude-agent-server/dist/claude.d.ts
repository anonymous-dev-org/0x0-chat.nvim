import type { MessageParam, RawMessageStreamEvent, ToolUnion } from "@anthropic-ai/sdk/resources/messages";
export interface ClaudeStreamRequest {
    model: string;
    max_tokens: number;
    system?: string;
    messages: MessageParam[];
    tools?: ToolUnion[];
    signal?: AbortSignal;
}
export interface ClaudeClient {
    stream(req: ClaudeStreamRequest): AsyncIterable<RawMessageStreamEvent>;
}
/** Real SDK-backed client. ANTHROPIC_API_KEY must be set in env. */
export declare function makeAnthropicClient(opts?: {
    apiKey?: string;
}): ClaudeClient;
