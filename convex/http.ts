import { httpRouter } from "convex/server";
import { httpAction } from "./_generated/server";
import { api } from "./_generated/api";
import { internal } from "./_generated/api";

function escapeHtml(str: string): string {
  return str
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function formatDuration(seconds: number): string {
  const mins = Math.floor(seconds / 60);
  const secs = Math.floor(seconds % 60);
  return `${mins}:${secs.toString().padStart(2, "0")}`;
}

const http = httpRouter();

http.route({
  pathPrefix: "/share/",
  method: "GET",
  handler: httpAction(async (ctx, request) => {
    const url = new URL(request.url);
    const pathParts = url.pathname.split("/");
    const token = pathParts[pathParts.length - 1];

    if (!token) {
      return new Response(notFoundPage(), {
        status: 404,
        headers: { "Content-Type": "text/html; charset=utf-8" },
      });
    }

    const recording = await ctx.runQuery(api.recordings.getByShareToken, {
      shareToken: token,
    });

    if (!recording || !recording.videoUrl) {
      return new Response(notFoundPage(), {
        status: 404,
        headers: { "Content-Type": "text/html; charset=utf-8" },
      });
    }

    const title = recording.title ?? "Untitled Recording";
    const shareUrl = request.url;
    const previewImage = recording.ogImageUrl ?? recording.thumbnailUrl;

    return new Response(
      playerPage(
        title,
        recording.duration,
        recording.videoUrl,
        previewImage,
        shareUrl,
      ),
      {
        status: 200,
        headers: { "Content-Type": "text/html; charset=utf-8" },
      },
    );
  }),
});

function notFoundPage(): string {
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Recording Not Found</title>
  <style>
    body {
      margin: 0;
      background: #0a0a0a;
      color: #ffffff;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto,
        Helvetica, Arial, sans-serif;
      display: flex;
      align-items: center;
      justify-content: center;
      min-height: 100vh;
      text-align: center;
    }
    h1 { font-size: 1.5rem; font-weight: 600; margin-bottom: 0.5rem; }
    p { color: #888; font-size: 0.95rem; }
  </style>
</head>
<body>
  <div>
    <h1>Recording Not Found</h1>
    <p>This recording may have been removed or the link is no longer valid.</p>
  </div>
</body>
</html>`;
}

function playerPage(
  title: string,
  duration: number,
  videoUrl: string,
  thumbnailUrl: string | null,
  shareUrl: string,
): string {
  const safeTitle = escapeHtml(title);
  const safeVideoUrl = escapeHtml(videoUrl);
  const safeThumbnailUrl = thumbnailUrl ? escapeHtml(thumbnailUrl) : null;
  const safeShareUrl = escapeHtml(shareUrl);
  const formattedDuration = formatDuration(duration);
  const description = `Screen recording · ${formattedDuration}`;

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>${safeTitle} — Jack</title>

  <!-- Open Graph -->
  <meta property="og:title" content="${safeTitle}" />
  <meta property="og:description" content="${description}" />
  <meta property="og:type" content="video.other" />
  <meta property="og:url" content="${safeShareUrl}" />
  <meta property="og:site_name" content="Jack" />
  <meta property="og:video" content="${safeVideoUrl}" />
  <meta property="og:video:type" content="video/mp4" />${safeThumbnailUrl ? `\n  <meta property="og:image" content="${safeThumbnailUrl}" />\n  <meta property="og:image:width" content="1280" />\n  <meta property="og:image:height" content="720" />` : ""}

  <!-- Twitter / Slack -->
  <meta name="twitter:card" content="${safeThumbnailUrl ? "summary_large_image" : "summary"}" />
  <meta name="twitter:title" content="${safeTitle}" />
  <meta name="twitter:description" content="${description}" />${safeThumbnailUrl ? `\n  <meta name="twitter:image" content="${safeThumbnailUrl}" />` : ""}
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      background: #0a0a0a;
      color: #ffffff;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto,
        Helvetica, Arial, sans-serif;
      min-height: 100vh;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      padding: 1.5rem;
    }
    .container {
      width: 100%;
      max-width: 960px;
    }
    video {
      width: 100%;
      border-radius: 12px;
      background: #111;
    }
    .info {
      margin-top: 1rem;
      display: flex;
      align-items: center;
      justify-content: space-between;
      flex-wrap: wrap;
      gap: 0.75rem;
    }
    .title {
      font-size: 1.125rem;
      font-weight: 600;
    }
    .duration {
      color: #888;
      font-size: 0.875rem;
    }
    .download {
      display: inline-flex;
      align-items: center;
      gap: 0.4rem;
      padding: 0.5rem 1rem;
      background: #ffffff;
      color: #0a0a0a;
      text-decoration: none;
      border-radius: 8px;
      font-size: 0.875rem;
      font-weight: 500;
      transition: opacity 0.15s;
    }
    .download:hover { opacity: 0.85; }
    .brand {
      margin-top: 2rem;
      color: #555;
      font-size: 0.75rem;
      text-align: center;
    }
  </style>
</head>
<body>
  <div class="container">
    <video controls autoplay playsinline src="${safeVideoUrl}"></video>
    <div class="info">
      <div>
        <div class="title">${safeTitle}</div>
        <div class="duration">${formattedDuration}</div>
      </div>
      <a class="download" href="${safeVideoUrl}" download>Download</a>
    </div>
    <div class="brand">Shared via Jack</div>
  </div>
</body>
</html>`;
}

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
