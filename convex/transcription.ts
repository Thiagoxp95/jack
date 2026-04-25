import { v } from "convex/values";
import { action } from "./_generated/server";

/**
 * Removes `<think>...</think>` reasoning blocks emitted by Qwen3 and other
 * thinking models. Returns `null` if an unclosed `<think>` is found, which
 * indicates the response was truncated mid-reasoning and no final answer exists.
 */
function stripThinkBlocks(content: string): string | null {
  let result = content;
  while (true) {
    const startIdx = result.indexOf("<think>");
    if (startIdx === -1) return result;
    const endIdx = result.indexOf("</think>", startIdx + 7);
    if (endIdx === -1) return null;
    result = result.slice(0, startIdx) + result.slice(endIdx + 8);
  }
}

export const cleanup = action({
  args: {
    text: v.string(),
    prompt: v.string(),
    model: v.string(),
  },
  handler: async (_ctx, args) => {
    const apiKey = process.env.OPENROUTER_API_KEY;
    if (!apiKey) throw new Error("OPENROUTER_API_KEY not configured");

    // Qwen3 emits <think>...</think> reasoning by default and will burn through the
    // token budget before producing a final answer. Append the Qwen3-documented /no_think
    // switch when a Qwen3 model is selected — disables reasoning at the chat-template level.
    const isQwen3 = /qwen-?3/i.test(args.model);
    const systemPrompt = isQwen3 ? `${args.prompt}\n\n/no_think` : args.prompt;

    const response = await fetch(
      "https://openrouter.ai/api/v1/chat/completions",
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${apiKey}`,
        },
        body: JSON.stringify({
          model: args.model,
          temperature: 0,
          max_tokens: Math.max(256, Math.ceil(args.text.length / 2)),
          messages: [
            { role: "system", content: systemPrompt },
            { role: "user", content: `<dictation>${args.text}</dictation>` },
          ],
          provider: {
            order: ["Groq", "Cerebras"],
            allow_fallbacks: false,
          },
        }),
      },
    );

    if (!response.ok) {
      const errText = await response.text();
      throw new Error(`OpenRouter error ${response.status}: ${errText}`);
    }

    const json = await response.json();
    const content = json.choices?.[0]?.message?.content;
    if (typeof content !== "string") {
      throw new Error("No content in OpenRouter response");
    }

    // Defense in depth: strip <think>...</think> blocks if the provider ignored /no_think.
    // An unclosed <think> means reasoning was truncated mid-thought — fall back to the
    // original text rather than pasting partial reasoning.
    const stripped = stripThinkBlocks(content);
    if (stripped === null) {
      return args.text;
    }
    const cleaned = stripped.trim();

    // Reject chatbot responses — the model answered instead of cleaning
    const lower = cleaned.toLowerCase();
    const chatPatterns = [
      /^i am a /,
      /^i'm a /,
      /^as an? (ai|language|text|dictation|model)/,
      /^i do not /,
      /^i don't /,
      /^please provide/,
      /^certainly/,
      /^here'?s the/,
      /^i'?d be happy/,
      /^i cannot/,
      /^i can'?t/,
      /^sure[,!]/,
      /^the cleaned/,
      /^the corrected/,
    ];
    for (const pattern of chatPatterns) {
      if (pattern.test(lower)) {
        // Model went off-script, return original text
        return args.text;
      }
    }

    // If output is way longer than input, model is rambling
    if (cleaned.length > args.text.length * 2 + 100) {
      return args.text;
    }

    return cleaned;
  },
});

export const transcribe = action({
  args: {
    audioBase64: v.string(),
    model: v.string(),
  },
  handler: async (_ctx, args) => {
    const apiKey = process.env.OPENAI_API_KEY;
    if (!apiKey) throw new Error("OPENAI_API_KEY not configured");

    const binaryString = atob(args.audioBase64);
    const bytes = new Uint8Array(binaryString.length);
    for (let i = 0; i < binaryString.length; i++) {
      bytes[i] = binaryString.charCodeAt(i);
    }
    const blob = new Blob([bytes], { type: "audio/wav" });

    const formData = new FormData();
    formData.append("file", blob, "recording.wav");
    formData.append("model", args.model);

    const response = await fetch(
      "https://api.openai.com/v1/audio/transcriptions",
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${apiKey}`,
        },
        body: formData,
      },
    );

    if (!response.ok) {
      const errText = await response.text();
      throw new Error(`OpenAI transcription error ${response.status}: ${errText}`);
    }

    const json = await response.json();
    const text = json.text;
    if (typeof text !== "string") {
      throw new Error("No text in OpenAI transcription response");
    }

    return text.trim();
  },
});

export const transcribeAquaVoice = action({
  args: {
    audioBase64: v.string(),
    model: v.string(),
  },
  handler: async (_ctx, args) => {
    const apiKey = process.env.AQUAVOICE_API_KEY;
    if (!apiKey) throw new Error("AQUAVOICE_API_KEY not configured");

    const binaryString = atob(args.audioBase64);
    const bytes = new Uint8Array(binaryString.length);
    for (let i = 0; i < binaryString.length; i++) {
      bytes[i] = binaryString.charCodeAt(i);
    }
    const blob = new Blob([bytes], { type: "audio/wav" });

    const formData = new FormData();
    formData.append("file", blob, "recording.wav");
    formData.append("model", args.model);

    const response = await fetch(
      "https://api.aquavoice.com/api/v1/audio/transcriptions",
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${apiKey}`,
        },
        body: formData,
      },
    );

    if (!response.ok) {
      const errText = await response.text();
      throw new Error(`AquaVoice transcription error ${response.status}: ${errText}`);
    }

    const json = await response.json();
    const text = json.text;
    if (typeof text !== "string") {
      throw new Error("No text in AquaVoice transcription response");
    }

    return text.trim();
  },
});

export const transcribeNvidia = action({
  args: {
    audioBase64: v.string(),
  },
  handler: async (_ctx, args) => {
    const apiKey = process.env.NVIDIA_API_KEY;
    const endpoint = process.env.NVIDIA_ASR_URL;
    if (!apiKey) throw new Error("NVIDIA_API_KEY not configured");
    if (!endpoint) throw new Error("NVIDIA_ASR_URL not configured");

    const binaryString = atob(args.audioBase64);
    const bytes = new Uint8Array(binaryString.length);
    for (let i = 0; i < binaryString.length; i++) {
      bytes[i] = binaryString.charCodeAt(i);
    }
    const blob = new Blob([bytes], { type: "audio/wav" });

    const response = await fetch(endpoint, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        Accept: "application/json",
      },
      body: blob,
    });

    if (!response.ok) {
      const errText = await response.text();
      throw new Error(`NVIDIA transcription error ${response.status}: ${errText}`);
    }

    const json = await response.json();
    const text =
      json.text ?? json.results?.[0]?.alternatives?.[0]?.transcript;
    if (typeof text !== "string") {
      throw new Error("No text in NVIDIA transcription response");
    }

    return text.trim();
  },
});
