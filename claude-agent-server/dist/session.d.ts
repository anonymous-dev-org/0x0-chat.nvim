import { type ClaudeClient } from "./claude";
import { ALL_TOOLS } from "./tools";
import type { ConfigOption, SessionUpdate, StopReason } from "./types";
export interface SessionDeps {
    sessionId: string;
    notify: (update: SessionUpdate) => void;
    request: <T = unknown>(method: string, params: unknown) => Promise<T>;
}
export interface SessionOptions {
    defaultModel: string;
    models: string[];
    claude?: ClaudeClient;
    systemPrompt?: string;
    maxToolIterations?: number;
    maxTokens?: number;
}
export declare class Session {
    readonly id: string;
    readonly cwd: string;
    private model;
    private mode;
    private readonly models;
    private readonly history;
    private readonly deps;
    private claudeOverride;
    private claudeInstance;
    private readonly system;
    private readonly maxToolIterations;
    private readonly maxTokens;
    private abortController;
    private state;
    constructor(id: string, cwd: string, deps: SessionDeps, opts: SessionOptions);
    configOptions(): ConfigOption[];
    setModel(modelId: string): void;
    setMode(mode: string): void;
    cancel(): void;
    prompt(promptBlocks: {
        type: string;
        text?: string;
        uri?: string;
    }[]): Promise<StopReason>;
    /** Return the active abort signal, or a pre-aborted one if no
     * controller is set. Never substitutes a never-firing signal. (T1.9) */
    private activeSignal;
    private runOneRound;
    private dispatchTools;
}
export { ALL_TOOLS };
