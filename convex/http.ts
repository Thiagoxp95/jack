import { httpRouter } from "convex/server";
import { httpAction } from "./_generated/server";
import { internal } from "./_generated/api";

const http = httpRouter();

// ── POST /chat/stream — Streaming chat completions via OpenRouter ────────────
http.route({
  path: "/chat/stream",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    // 1. Parse & validate body
    let body: { threadId?: string; messageContent?: string };
    try {
      body = await request.json();
    } catch {
      return new Response(
        JSON.stringify({ error: "Invalid JSON body" }),
        { status: 400, headers: { "Content-Type": "application/json" } },
      );
    }

    const { threadId, messageContent } = body;
    if (!threadId || !messageContent) {
      return new Response(
        JSON.stringify({ error: "Missing threadId or messageContent" }),
        { status: 400, headers: { "Content-Type": "application/json" } },
      );
    }

    // 2. Require Authorization header
    const authHeader = request.headers.get("Authorization");
    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: "Missing Authorization header" }),
        { status: 401, headers: { "Content-Type": "application/json" } },
      );
    }

    // 3. Check for API key
    const openRouterKey = process.env.OPENROUTER_API_KEY;
    if (!openRouterKey) {
      return new Response(
        JSON.stringify({ error: "OPENROUTER_API_KEY not configured" }),
        { status: 500, headers: { "Content-Type": "application/json" } },
      );
    }

    // 4. Save user message (internal — no auth needed, HTTP action validates auth)
    await ctx.runMutation(internal.chats.internalSendMessage, {
      threadId: threadId as any,
      content: messageContent,
    });

    // 5. Load the thread to get model
    const thread = await ctx.runQuery(internal.chats.internalGetThread, {
      threadId: threadId as any,
    });
    if (!thread) {
      return new Response(
        JSON.stringify({ error: "Thread not found" }),
        { status: 404, headers: { "Content-Type": "application/json" } },
      );
    }

    // 6. Load message history
    const messages = await ctx.runQuery(internal.chats.internalGetMessages, {
      threadId: threadId as any,
    });

    // 7. Build OpenRouter request
    const openRouterMessages = messages.map(
      (m: { role: string; content: string }) => ({
        role: m.role,
        content: m.content,
      }),
    );

    const openRouterResponse = await fetch(
      "https://openrouter.ai/api/v1/chat/completions",
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${openRouterKey}`,
        },
        body: JSON.stringify({
          model: thread.model,
          messages: openRouterMessages,
          stream: true,
        }),
      },
    );

    if (!openRouterResponse.ok) {
      const errText = await openRouterResponse.text();
      return new Response(
        JSON.stringify({ error: "OpenRouter error", details: errText }),
        { status: 502, headers: { "Content-Type": "application/json" } },
      );
    }

    if (!openRouterResponse.body) {
      return new Response(
        JSON.stringify({ error: "No response body from OpenRouter" }),
        { status: 502, headers: { "Content-Type": "application/json" } },
      );
    }

    // 8. Stream SSE back to client, accumulating the full content
    const reader = openRouterResponse.body.getReader();
    const decoder = new TextDecoder();
    let fullContent = "";
    let buffer = "";

    const stream = new ReadableStream({
      async pull(controller) {
        const { done, value } = await reader.read();

        if (done) {
          // Send terminal event and close.
          // The client saves the assistant message via mutation after streaming.
          controller.enqueue(new TextEncoder().encode("data: [DONE]\n\n"));
          controller.close();
          return;
        }

        const chunk = decoder.decode(value, { stream: true });
        // Forward raw SSE chunk to client
        controller.enqueue(value);

        // Parse SSE lines from this chunk to accumulate content
        buffer += chunk;
        const lines = buffer.split("\n");
        // Keep the last potentially incomplete line in the buffer
        buffer = lines.pop() ?? "";

        for (const line of lines) {
          if (!line.startsWith("data: ")) continue;
          const data = line.slice(6).trim();
          if (data === "[DONE]") continue;
          try {
            const parsed = JSON.parse(data);
            const delta = parsed.choices?.[0]?.delta?.content;
            if (delta) {
              fullContent += delta;
            }
          } catch {
            // Not valid JSON — skip
          }
        }
      },
    });

    return new Response(stream, {
      status: 200,
      headers: {
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
        Connection: "keep-alive",
      },
    });
  }),
});

export default http;
