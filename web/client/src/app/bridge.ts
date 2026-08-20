/**
 * The one shape that connects an imperative object to React.
 *
 * A `SurfaceHandle` and a `ControlClient` are both created inside effects —
 * they open sockets, and opening a socket during render is how StrictMode's
 * double invoke turns into two live connections and one leak. React cannot
 * subscribe to something that does not exist yet, so it subscribes to a bridge
 * that outlives every attach, and the effect plugs the source into it.
 *
 * `getSnapshot` returns a cached object. Building a fresh one per call is the
 * classic `useSyncExternalStore` infinite-render bug.
 */

import { useSyncExternalStore } from "react";

export interface ExternalStore<S> {
  subscribe(listener: () => void): () => void;
  snapshot(): S;
}

export interface Bridge<T extends ExternalStore<S>, S> {
  attach(source: T | null): void;
  subscribe(listener: () => void): () => void;
  getSnapshot(): S;
  /** The live source, for the imperative calls — `setPalette`, `refresh`. */
  current(): T | null;
}

export function createBridge<T extends ExternalStore<S>, S>(idle: S): Bridge<T, S> {
  const listeners = new Set<() => void>();
  let source: T | null = null;
  let unsubscribe: (() => void) | null = null;
  let snapshot: S = idle;

  const publish = (): void => {
    snapshot = source ? source.snapshot() : idle;
    for (const listener of [...listeners]) listener();
  };

  return {
    attach(next: T | null): void {
      unsubscribe?.();
      source = next;
      unsubscribe = next ? next.subscribe(publish) : null;
      publish();
    },
    subscribe(listener: () => void): () => void {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    getSnapshot(): S {
      return snapshot;
    },
    current(): T | null {
      return source;
    },
  };
}

export function useBridge<T extends ExternalStore<S>, S>(bridge: Bridge<T, S>): S {
  return useSyncExternalStore(bridge.subscribe, bridge.getSnapshot, bridge.getSnapshot);
}
