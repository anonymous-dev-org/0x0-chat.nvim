// Anthropic SDK adapter: wraps client.messages.create({ stream: true })
// behind a small interface so the Session can be tested without a real
// API key.
import Anthropic from "@anthropic-ai/sdk";
/** Real SDK-backed client. ANTHROPIC_API_KEY must be set in env. */
export function makeAnthropicClient(opts) {
    const apiKey = opts?.apiKey ?? process.env.ANTHROPIC_API_KEY;
    if (!apiKey) {
        throw new Error("ANTHROPIC_API_KEY not set");
    }
    const client = new Anthropic({ apiKey });
    return {
        async *stream(req) {
            const stream = await client.messages.create({
                model: req.model,
                max_tokens: req.max_tokens,
                system: req.system,
                messages: req.messages,
                tools: req.tools,
                stream: true,
            }, { signal: req.signal });
            for await (const event of stream) {
                yield event;
            }
        },
    };
}
//# sourceMappingURL=claude.js.map