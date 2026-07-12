import { WebToNativeMessage } from "./types";

declare global {
    interface Window {
        webkit?: {
            messageHandlers?: {
                bml?: { postMessage: (message: unknown) => void };
            };
        };
        kiririnBML?: {
            onNativeMessage: (message: unknown) => void;
        };
    }
}

export function postToNative(message: WebToNativeMessage): void {
    const handler = window.webkit?.messageHandlers?.bml;
    if (handler == null) {
        // No native host attached (e.g. plain-browser debugging). Log instead of throwing.
        console.debug("[bml:web->native]", message);
        return;
    }
    handler.postMessage(message);
}

export function log(level: "debug" | "info" | "warn" | "error", message: string): void {
    postToNative({ type: "log", level, message });
}
