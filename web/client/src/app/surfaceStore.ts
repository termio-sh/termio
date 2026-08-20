/**
 * The two bridges the shell holds: one for the attach surface, one for the
 * control channel's roster. Both are the same mechanism (see `bridge.ts`).
 *
 * This module is the React side of the boundary; `surface.ts` and `control.ts`
 * import nothing from here, which is what keeps them headless-testable.
 */

import { createBridge, useBridge, type Bridge } from "./bridge";
import { IDLE_ROSTER_STATE, type ControlClient, type RosterState } from "./control";
import { IDLE_SURFACE_STATE, type SurfaceHandle, type SurfaceState } from "./surface";

export { IDLE_ROSTER_STATE, IDLE_SURFACE_STATE };

export type SurfaceBridge = Bridge<SurfaceHandle, SurfaceState>;
export type RosterBridge = Bridge<ControlClient, RosterState>;

export function createSurfaceBridge(): SurfaceBridge {
  return createBridge<SurfaceHandle, SurfaceState>(IDLE_SURFACE_STATE);
}

export function createRosterBridge(): RosterBridge {
  return createBridge<ControlClient, RosterState>(IDLE_ROSTER_STATE);
}

export function useSurfaceState(bridge: SurfaceBridge): SurfaceState {
  return useBridge(bridge);
}

export function useRosterState(bridge: RosterBridge): RosterState {
  return useBridge(bridge);
}
