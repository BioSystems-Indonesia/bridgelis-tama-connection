/**
 * Node.js ESM entry for bridgeLIS Tama Connection (Node >= 18).
 * Re-exports the CommonJS facade so both module systems share one implementation.
 */
import facade from './index.cjs';

export const { LisClient, LisError } = facade;
