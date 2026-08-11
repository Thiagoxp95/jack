/* eslint-disable */
/**
 * Generated `api` utility.
 *
 * THIS CODE IS AUTOMATICALLY GENERATED.
 *
 * To regenerate, run `npx convex dev`.
 * @module
 */

import type * as chats from "../chats.js";
import type * as cleanupRecordings from "../cleanupRecordings.js";
import type * as http from "../http.js";
import type * as notes from "../notes.js";
import type * as spaces from "../spaces.js";
import type * as todoLists from "../todoLists.js";
import type * as todos from "../todos.js";
import type * as transcription from "../transcription.js";
import type * as users from "../users.js";

import type {
  ApiFromModules,
  FilterApi,
  FunctionReference,
} from "convex/server";

declare const fullApi: ApiFromModules<{
  chats: typeof chats;
  cleanupRecordings: typeof cleanupRecordings;
  http: typeof http;
  notes: typeof notes;
  spaces: typeof spaces;
  todoLists: typeof todoLists;
  todos: typeof todos;
  transcription: typeof transcription;
  users: typeof users;
}>;

/**
 * A utility for referencing Convex functions in your app's public API.
 *
 * Usage:
 * ```js
 * const myFunctionReference = api.myModule.myFunction;
 * ```
 */
export declare const api: FilterApi<
  typeof fullApi,
  FunctionReference<any, "public">
>;

/**
 * A utility for referencing Convex functions in your app's internal API.
 *
 * Usage:
 * ```js
 * const myFunctionReference = internal.myModule.myFunction;
 * ```
 */
export declare const internal: FilterApi<
  typeof fullApi,
  FunctionReference<any, "internal">
>;

export declare const components: {};
