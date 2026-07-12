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
        // ネイティブ側がWKUserScript(atDocumentStart)で注入する設定。
        // BMLBrowser生成時に確定している必要がある値だけをここで受け取る。
        kiririnBMLConfig?: {
            internetAccess?: boolean;
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
