import type { ToolDefinition } from "./types";
interface ReadFileInput {
    path: string;
    line?: number;
    limit?: number;
}
interface ReadFileOutput {
    content: string;
}
interface WriteFileInput {
    path: string;
    content: string;
}
interface WriteFileOutput {
    ok: true;
}
export declare const readFile: ToolDefinition<ReadFileInput, ReadFileOutput>;
export declare const writeFile: ToolDefinition<WriteFileInput, WriteFileOutput>;
export declare const ALL_TOOLS: ToolDefinition[];
export declare function toolByName(name: string): ToolDefinition | undefined;
/** Anthropic SDK Tool shape. Cast keeps the schema flexible while
 * satisfying the InputSchema constraint (root type must be "object"). */
export declare function toAnthropicTools(): {
    name: string;
    description: string;
    input_schema: {
        type: "object";
        properties?: Record<string, unknown>;
        required?: string[];
    };
}[];
export {};
