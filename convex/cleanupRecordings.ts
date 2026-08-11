import { v } from "convex/values";
import { internalMutation, internalQuery } from "./_generated/server";
import type { Id } from "./_generated/dataModel";

/**
 * One-off cleanup for the screen-recording feature that was removed in
 * `508dd43 refactor: remove screen recording feature`.
 *
 * The feature's Swift code, Convex functions and schema entry are all gone from
 * this repo, but the production deployment (`striped-walrus-412`) was never
 * redeployed afterwards, so it still runs the old bundle. As a result:
 *
 *   • the `recordings` table still holds its rows,
 *   • 33 files (11 mp4 + 11 jpeg thumbnails + 11 jpeg OG images, 592 MiB total)
 *     still sit in `_storage`,
 *   • the `GET /share/*` HTTP action is still live and still serves an
 *     autoplaying <video> plus an `og:video` meta tag pointing straight at the
 *     raw storage URLs — which Convex serves with `Cache-Control: private`, so
 *     nothing is CDN-cached and every view/unfurl re-egresses the whole file.
 *
 * `recordings` is deliberately NOT re-added to `schema.ts`; the table is dead.
 * The casts below are what let this file talk to it anyway.
 *
 * ── HOW TO RUN ───────────────────────────────────────────────────────────────
 *
 * These are internal functions, so they can only be invoked with `convex run`,
 * never from a client. They only exist on a deployment AFTER a `convex deploy`.
 *
 *   1. Deploy this file (this also drops the stale recordings/share/storage
 *      code from prod, which is itself most of the fix):
 *
 *        npx convex deploy          # NOTE: see the schema warning below first
 *
 *   2. Inspect, changing nothing:
 *
 *        npx convex run --prod cleanupRecordings:report
 *
 *   3. Dry run the purge (default — reports exactly what it *would* delete):
 *
 *        npx convex run --prod cleanupRecordings:purge
 *
 *   4. Only when you are happy with the dry-run output, and only after you
 *      have downloaded anything you want to keep:
 *
 *        npx convex run --prod cleanupRecordings:purge '{"dryRun": false}'
 *
 * ── BEFORE YOU DELETE ────────────────────────────────────────────────────────
 *
 * `cleanupRecordings:report` prints a `downloadUrl` for every file. Fetch the
 * ones you want to keep first — deletion is irreversible. Note that pulling all
 * 592 MiB back down costs one more 592 MiB of egress; the same is true of
 * `npx convex export`, so do it once and keep the copy.
 *
 * ── SCHEMA WARNING ───────────────────────────────────────────────────────────
 *
 * `schema.ts` no longer declares `recordings`, but prod still has 11 documents
 * in it. If `npx convex deploy` rejects prod over that, either purge first
 * (dashboard → Data → recordings) or temporarily set
 * `defineSchema({...}, { schemaValidation: false })` for the one deploy.
 */

/** Shape of a row in the removed `recordings` table. */
type LegacyRecording = {
  /** Off-schema table, so there is no generated `Id<"recordings">` to use. */
  _id: string;
  _creationTime: number;
  title?: string;
  duration?: number;
  shareToken?: string;
  shareEnabled?: boolean;
  storageId?: Id<"_storage">;
  thumbnailStorageId?: Id<"_storage">;
  ogImageStorageId?: Id<"_storage">;
};

/**
 * `recordings` is not in the schema, so `ctx.db.query("recordings")` does not
 * typecheck. This is the single escape hatch, isolated to one function.
 */
function legacyRecordings(db: unknown): Promise<LegacyRecording[]> {
  return (db as { query: (t: string) => { collect: () => Promise<LegacyRecording[]> } })
    .query("recordings")
    .collect();
}

function storageIdsOf(r: LegacyRecording): Id<"_storage">[] {
  return [r.storageId, r.thumbnailStorageId, r.ogImageStorageId].filter(
    (id): id is Id<"_storage">  => id !== undefined && id !== null,
  );
}

/**
 * Read-only. Lists every `_storage` file, says which recording (if any) points
 * at it, and totals the bytes. Files with `referencedBy: null` are orphans —
 * nothing can ever reach them again.
 */
export const report = internalQuery({
  args: {},
  handler: async (ctx) => {
    const recordings = await legacyRecordings(ctx.db);

    const owner = new Map<string, { title: string; field: string }>();
    for (const r of recordings) {
      const title = r.title ?? "(untitled)";
      if (r.storageId) owner.set(r.storageId, { title, field: "video" });
      if (r.thumbnailStorageId)
        owner.set(r.thumbnailStorageId, { title, field: "thumbnail" });
      if (r.ogImageStorageId)
        owner.set(r.ogImageStorageId, { title, field: "ogImage" });
    }

    const files = await ctx.db.system.query("_storage").collect();

    let totalBytes = 0;
    let orphanBytes = 0;
    const rows = [];
    for (const f of files) {
      totalBytes += f.size;
      const ref = owner.get(f._id) ?? null;
      if (!ref) orphanBytes += f.size;
      rows.push({
        storageId: f._id,
        contentType: f.contentType ?? null,
        sizeBytes: f.size,
        referencedBy: ref,
        downloadUrl: await ctx.storage.getUrl(f._id),
      });
    }
    rows.sort((a, b) => b.sizeBytes - a.sizeBytes);

    return {
      recordingCount: recordings.length,
      shareEnabledCount: recordings.filter((r) => r.shareEnabled).length,
      fileCount: files.length,
      totalBytes,
      totalMiB: +(totalBytes / 1048576).toFixed(2),
      orphanBytes,
      orphanMiB: +(orphanBytes / 1048576).toFixed(2),
      files: rows,
    };
  },
});

/**
 * DESTRUCTIVE when `dryRun` is false. Deletes every file reachable from the
 * `recordings` table plus the rows themselves.
 *
 * `dryRun` defaults to true, so an argument-less invocation is always safe.
 *
 * `includeOrphans` additionally deletes `_storage` files that no recording row
 * points at. Leave it false unless `report` shows orphans you recognise —
 * anything a future feature uploads would also look like an orphan here.
 */
export const purge = internalMutation({
  args: {
    dryRun: v.optional(v.boolean()),
    includeOrphans: v.optional(v.boolean()),
  },
  handler: async (ctx, args) => {
    const dryRun = args.dryRun ?? true;
    const includeOrphans = args.includeOrphans ?? false;

    const recordings = await legacyRecordings(ctx.db);

    const referenced = new Set<string>();
    for (const r of recordings) {
      for (const id of storageIdsOf(r)) referenced.add(id);
    }

    const targets: Id<"_storage">[] = [];
    let bytes = 0;
    let orphanCount = 0;

    for (const f of await ctx.db.system.query("_storage").collect()) {
      const isOrphan = !referenced.has(f._id);
      if (isOrphan && !includeOrphans) continue;
      if (isOrphan) orphanCount += 1;
      targets.push(f._id);
      bytes += f.size;
    }

    if (!dryRun) {
      for (const id of targets) {
        await ctx.storage.delete(id);
      }
      for (const r of recordings) {
        // Same off-schema escape hatch as `legacyRecordings`.
        await ctx.db.delete(r._id as Id<"users">);
      }
    }

    return {
      dryRun,
      includeOrphans,
      wouldDeleteFiles: targets.length,
      wouldDeleteOrphans: orphanCount,
      wouldDeleteRecordings: recordings.length,
      wouldFreeBytes: bytes,
      wouldFreeMiB: +(bytes / 1048576).toFixed(2),
      note: dryRun
        ? "DRY RUN — nothing was deleted. Re-run with {\"dryRun\": false} to apply."
        : "Deleted.",
    };
  },
});
