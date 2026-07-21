import {
    BITBroadcaster,
    CurrentTime,
    ESEvent,
    ModuleFile,
    ResponseMessage,
} from "../../web-bml/server/ws_api";
import { parseMediaTypeFromString } from "../../web-bml/server/entity_parser";
import { hexToBytes } from "./hex";
import { parsePMTSection } from "./pmt";
import { log } from "./bridge";

// Mahiron's data-broadcast API (Mirakurun-compatible server) is treated as a
// fixed, unmodified upstream for this integration. All Mahiron JSON-shape
// knowledge is kept in this one file so schema drift is a single-file fix.
//
// Known quirk: `internal/stream/databroadcast.DataBroadcastProgramInfo` and
// `DataBroadcastCurrentTime` have no `json:` struct tags, so - unlike every
// other event payload, which Mahiron's API layer manually remaps to
// lowerCamelCase - their fields serialize using Go's exact (capitalized)
// field names. We don't rely on Mahiron's own `programInfo` event payload at
// all (the native side synthesizes ProgramInfoMessage from the app's own
// Playable/EPG state instead - see bridge NativeToWebMessage "programInfo"),
// so only the `currentTime` shape's PascalCase actually matters here.
//
// Module content itself never reaches this file: Mahiron expands a completed
// DSM-CC module into logical resources server-side, the native side fetches
// them, and they arrive as a "moduleResources" bridge message.

type MahironModule = {
    componentTag: number;
    moduleId: number;
    downloadId: number;
    version: number;
    size: number;
    complete: boolean;
    /** "announced" | "receiving" | "complete" | "rejected" */
    status?: string;
    rejectionReason?: string | null;
};

type ModuleRegistryEntry = { id: number; version: number; size: number };

type ComponentState = {
    downloadId: number;
    dataEventId: number;
    returnToEntry: boolean | undefined;
    modules: Map<number, ModuleRegistryEntry>;
    listAnnounced: boolean;
};

type PendingModuleResources = {
    componentTag: number;
    moduleId: number;
    downloadId: number;
    version: number;
    files: { contentLocation: string | null; contentType: string; dataBase64: string }[];
};

/**
 * Converts Mahiron's data-broadcast SSE events (and native-fetched module
 * resources) into web-bml `ResponseMessage`s, enforcing the one ordering
 * constraint web-bml itself doesn't self-heal from: a `moduleListUpdated`
 * (DII) must be emitted for a component before any `moduleDownloaded` (DDB)
 * for that same component, or web-bml's Resources cache silently drops it
 * (see client/resource.ts's cached-component lookup). `programInfo` doesn't
 * need similar buffering - web-bml queues the startup launch internally via
 * `getProgramInfoAsync()` until a ProgramInfoMessage eventually arrives.
 */
export class MahironAdapter {
    private readonly components = new Map<number, ComponentState>();
    private readonly pendingModuleData = new Map<number, PendingModuleResources[]>();
    private readonly seenEventTypes = new Set<string>();

    public constructor(private readonly emit: (message: ResponseMessage) => void) {}

    public handleSSE(event: string, data: unknown): void {
        if (!this.seenEventTypes.has(event)) {
            this.seenEventTypes.add(event);
            console.info(`[kiririn-bml] first SSE event of type: ${event}`);
        }
        // Each SSE `data:` payload is a per-type envelope like
        // `{"type":"snapshot","snapshot":{...}}` (see apiDataBroadcastEvent in
        // Mahiron's internal/web/api/data_broadcast.go) - unwrap it here.
        const envelope = data as any;
        switch (event) {
            case "snapshot":
                this.handleSnapshot(envelope?.snapshot);
                break;
            case "pmt":
                this.handlePMTEvent(envelope?.pmt);
                break;
            case "moduleListUpdated":
                this.handleModuleListEvent(envelope?.moduleList);
                break;
            case "moduleUpdated":
                this.handleModuleUpdatedEvent(envelope?.module);
                break;
            case "currentTime":
                this.emitCurrentTime(envelope?.currentTime);
                break;
            case "esEventUpdated":
                this.handleESEvent(envelope?.esEvent);
                break;
            case "bit":
                this.handleBIT(envelope?.bit);
                break;
            case "pcr":
                this.handlePCR(envelope?.pcr);
                break;
            case "programInfo":
                // Intentionally ignored: native side synthesizes ProgramInfoMessage
                // from Playable/EPG state instead of Mahiron's raw EIT hex.
                break;
            default:
                log("debug", `unhandled Mahiron SSE event: ${event}`);
        }
    }

    public handleModuleResources(payload: PendingModuleResources): void {
        const state = this.components.get(payload.componentTag);
        if (state == null || !state.listAnnounced || state.downloadId !== payload.downloadId) {
            const queue = this.pendingModuleData.get(payload.componentTag) ?? [];
            queue.push(payload);
            this.pendingModuleData.set(payload.componentTag, queue);
            return;
        }
        this.emitModuleDownloaded(payload);
    }

    private handleSnapshot(snapshot: any): void {
        if (snapshot == null) {
            return;
        }
        if (snapshot.pmt?.rawSectionHex) {
            this.handlePMTHex(snapshot.pmt.rawSectionHex);
        }
        for (const component of (snapshot.components ?? []) as any[]) {
            this.applyComponentModules(component);
        }
        const currentTime = readCurrentTime(snapshot.currentTime);
        if (currentTime != null) {
            this.emit({ type: "currentTime", timeUnixMillis: currentTime } satisfies CurrentTime);
        }
        this.handlePCR(snapshot.pcr);
        this.handleBIT(snapshot.bit);
    }

    private handlePMTEvent(pmt: any): void {
        if (pmt?.rawSectionHex) {
            this.handlePMTHex(pmt.rawSectionHex);
        }
        for (const component of (pmt?.components ?? []) as any[]) {
            this.applyComponentModules(component);
        }
    }

    private handlePMTHex(hex: string): void {
        const message = parsePMTSection(hexToBytes(hex));
        if (message == null) {
            log("warn", "failed to parse PMT section (CRC mismatch?)");
            return;
        }
        this.emit(message);
    }

    private applyComponentModules(component: any): void {
        const modules = (component?.modules ?? []) as MahironModule[];
        if (modules.length === 0) {
            return;
        }
        this.applyModuleList(
            component.componentTag,
            component.carousel?.downloadId ?? modules[0].downloadId,
            modules,
            component.dataEventId,
            component.returnToEntry,
        );
    }

    private handleModuleListEvent(list: any): void {
        if (list == null) {
            return;
        }
        this.applyModuleList(
            list.componentTag,
            list.downloadId,
            (list.modules ?? []) as MahironModule[],
            list.dataEventId,
            list.returnToEntry,
        );
    }

    private handleModuleUpdatedEvent(mod: MahironModule): void {
        if (mod == null) {
            return;
        }
        let state = this.components.get(mod.componentTag);
        if (state == null || state.downloadId !== mod.downloadId) {
            // New data event (or mid-stream join) seen via a single-module
            // event: start fresh state but DO NOT announce - web-bml treats
            // moduleListUpdated as the authoritative full DII list and
            // revokes every cached module absent from it (and fails pending
            // fetches for them). Announcing a partial list here nukes the
            // component's cache and leaves the content stuck on
            // データ取得中. Wait for the full list from Mahiron's own
            // moduleListUpdated/snapshot; module resources received meanwhile
            // are queued via pendingModuleData.
            state = {
                downloadId: mod.downloadId,
                dataEventId: dataEventIdFromDownloadId(mod.downloadId),
                returnToEntry: undefined,
                modules: new Map(),
                listAnnounced: false,
            };
            this.components.set(mod.componentTag, state);
        }
        if (mod.status === "rejected") {
            // Refused by Mahiron's receiver and never fetchable. Keeping it in
            // the DII list web-bml sees would leave content waiting on it stuck
            // on データ取得中; dropping it fails those fetches fast instead.
            log(
                "warn",
                `module rejected by receiver (component ${mod.componentTag}, module ${mod.moduleId}): ${mod.rejectionReason ?? "unknown"}`,
            );
            if (state.modules.delete(mod.moduleId) && state.listAnnounced) {
                this.announceModuleList(mod.componentTag, state);
            }
            return;
        }
        const existing = state.modules.get(mod.moduleId);
        const changed = existing == null || existing.version !== mod.version || existing.size !== mod.size;
        state.modules.set(mod.moduleId, { id: mod.moduleId, version: mod.version, size: mod.size });
        if (changed && state.listAnnounced) {
            // Safe: state.modules holds the full list (seeded by
            // snapshot/moduleListUpdated) with this one entry refreshed.
            this.announceModuleList(mod.componentTag, state);
        }
    }

    private applyModuleList(
        componentTag: number,
        downloadId: number,
        modules: MahironModule[],
        dataEventId: unknown,
        returnToEntry: unknown,
    ): void {
        const state: ComponentState = {
            downloadId,
            dataEventId:
                typeof dataEventId === "number"
                    ? dataEventId
                    : dataEventIdFromDownloadId(downloadId),
            returnToEntry: typeof returnToEntry === "boolean" ? returnToEntry : undefined,
            modules: new Map(),
            listAnnounced: false,
        };
        for (const m of modules) {
            // Rejected modules are announced by the DII but can never be
            // fetched - see handleModuleUpdatedEvent.
            if (m.status === "rejected") {
                log(
                    "warn",
                    `module rejected by receiver (component ${componentTag}, module ${m.moduleId}): ${m.rejectionReason ?? "unknown"}`,
                );
                continue;
            }
            state.modules.set(m.moduleId, { id: m.moduleId, version: m.version, size: m.size });
        }
        this.components.set(componentTag, state);
        this.announceModuleList(componentTag, state);
    }

    private announceModuleList(componentTag: number, state: ComponentState): void {
        state.listAnnounced = true;
        this.emit({
            type: "moduleListUpdated",
            componentId: componentTag,
            modules: [...state.modules.values()],
            dataEventId: state.dataEventId,
            returnToEntryFlag: state.returnToEntry,
        });
        this.flushPendingModuleData(componentTag);
    }

    private flushPendingModuleData(componentTag: number): void {
        const queue = this.pendingModuleData.get(componentTag);
        if (queue == null || queue.length === 0) {
            return;
        }
        this.pendingModuleData.delete(componentTag);
        for (const payload of queue) {
            this.handleModuleResources(payload);
        }
    }

    // Mahiron expands the module entity (zlib, multipart, Type descriptor)
    // itself, so this only has to restore web-bml's MediaType shape - the
    // parameters it drops are unused by web-bml outside multipart boundaries.
    private emitModuleDownloaded(payload: PendingModuleResources): void {
        const files: ModuleFile[] = [];
        for (const file of payload.files) {
            const contentType = parseMediaTypeFromString(file.contentType).mediaType;
            if (contentType == null) {
                log(
                    "warn",
                    `skipping resource with unparsable content type "${file.contentType}" (component ${payload.componentTag}, module ${payload.moduleId})`,
                );
                continue;
            }
            // A module that maps directly to a single resource is referenced
            // as /<component>/<module> with no filename, and web-bml keys it
            // by a null contentLocation (the non-multipart branch of
            // web-bml/server/decode_ts.ts). Mahiron sends null for exactly
            // that case, so it passes straight through.
            files.push({
                contentLocation: file.contentLocation,
                contentType,
                dataBase64: file.dataBase64,
            });
        }
        this.emit({
            type: "moduleDownloaded",
            componentId: payload.componentTag,
            moduleId: payload.moduleId,
            files,
            version: payload.version,
            dataEventId:
                this.components.get(payload.componentTag)?.dataEventId ??
                dataEventIdFromDownloadId(payload.downloadId),
        });
    }

    // ES event messages (DSM-CC stream descriptor sections, Mahiron PR #33).
    // web-bml dedupes repeated firings itself (beitem.internalMessageVersion),
    // so re-transmitted sections can be forwarded as-is. Events with an
    // unsupported timeMode arrive as type "event" and are ignored by web-bml.
    private handleESEvent(esEvent: any): void {
        if (esEvent == null) {
            return;
        }
        const events = ((esEvent.events ?? []) as any[]).map((event) =>
            event.type === "nptReference"
                ? event
                : { ...event, privateDataByte: byteArray(event.privateDataByte) },
        );
        this.emit({
            type: "esEventUpdated",
            componentId: esEvent.componentId,
            dataEventId: esEvent.dataEventId,
            events: events as ESEvent[],
        });
    }

    private handleBIT(bit: any): void {
        if (bit == null) {
            return;
        }
        const broadcasters: BITBroadcaster[] = ((bit.broadcasters ?? []) as any[]).map((b) => ({
            broadcasterId: b.broadcasterId,
            broadcasterName: b.broadcasterName ?? null,
            services: b.services ?? [],
            affiliations: byteArray(b.affiliations),
            affiliationBroadcasters: b.affiliationBroadcasters ?? [],
            terrestrialBroadcasterId: b.terrestrialBroadcasterId ?? undefined,
        }));
        this.emit({ type: "bit", originalNetworkId: bit.originalNetworkId, broadcasters });
    }

    private handlePCR(pcr: any): void {
        if (pcr == null || typeof pcr.pcrBase !== "number") {
            return;
        }
        this.emit({ type: "pcr", pcrBase: pcr.pcrBase, pcrExtension: pcr.pcrExtension ?? 0 });
    }

    private emitCurrentTime(data: unknown): void {
        const value = readCurrentTime(data);
        if (value != null) {
            this.emit({ type: "currentTime", timeUnixMillis: value } satisfies CurrentTime);
        }
    }
}

function dataEventIdFromDownloadId(downloadId: number): number {
    return (downloadId >>> 28) & 15;
}

// Byte-array fields (BIT affiliations, ES event privateDataByte) arrive as
// JSON number arrays (Mahiron PR #35), matching web-bml's expected number[]
// (e.g. Uint8Array.from(privateDataByte) in content.ts).
function byteArray(value: unknown): number[] {
    return Array.isArray(value) ? value : [];
}

// See the module-level comment: DataBroadcastCurrentTime has no json tags,
// so Mahiron serializes it with its literal Go field name. Accept both in
// case that's ever fixed upstream.
function readCurrentTime(data: any): number | null {
    if (data == null) {
        return null;
    }
    const value = data.JSTTimeUnixMilli ?? data.jstTimeUnixMilli;
    return typeof value === "number" ? value : null;
}
