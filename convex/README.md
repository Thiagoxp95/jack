# Jack Convex backend

The optional [Convex](https://convex.dev) backend powering Jack's cloud features: chat, cloud transcription, spaces, notes/todos sync, and shareable recording links. Core dictation in the app works without it.

## Tables

Defined in `schema.ts`:

- `users` — Clerk-linked user records
- `spaces`, `space_members`, `space_invitations` — shared workspaces and membership
- `notes` — synced voice notes
- `recordings` — screen recordings and share tokens
- `todoLists`, `todos` — todo sync
- `chatThreads`, `chatMessages` — AI chat history

## Required environment variables

Set these in the Convex dashboard (Settings → Environment Variables):

- `OPENROUTER_API_KEY` — chat and LLM-based transcription/todo extraction
- `OPENAI_API_KEY` — cloud audio transcription (Whisper)
- `CLERK_JWT_ISSUER_DOMAIN` — your Clerk app's JWT issuer domain (used by `auth.config.ts`)

Optional (alternative transcription providers in `transcription.ts`): `AQUAVOICE_API_KEY`, `NVIDIA_API_KEY`, `NVIDIA_ASR_URL`.

## Deploying

```bash
npx convex dev      # develop against a dev deployment (writes .env.local)
npx convex deploy   # deploy to production
```

Then point the app at your deployment's `.convex.cloud` and `.convex.site` URLs — see the `AppConfig` overrides in the top-level README.
