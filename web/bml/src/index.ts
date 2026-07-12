import { BMLBrowser, BMLBrowserFontFace } from "../../web-bml/client/bml_browser";
import { AribKeyCode } from "../../web-bml/client/content";
import { postToNative, log } from "./bridge";
import { MahironAdapter } from "./mahiron";
import { NativeToWebMessage } from "./types";

import roundGothicRegularUrl from "../../web-bml/fonts/KosugiMaru-Regular.woff2";
import roundGothicBoldUrl from "../../web-bml/fonts/KosugiMaru-Bold.woff2";
import squareGothicRegularUrl from "../../web-bml/fonts/Kosugi-Regular.woff2";

const stage = document.getElementById("stage")!;
// Dummy media element: BMLBrowser accepts one but never actually reads it in
// the current web-bml (video-plane positioning is driven entirely by the
// internal <object arib-type="video/X-arib-mpeg2"> element + the
// `videochanged` event). Real video is rendered natively by VLC outside this
// WKWebView; this exists purely to satisfy BMLBrowserOptions.
const mediaElement = document.createElement("div");

const roundGothic: BMLBrowserFontFace = { source: `url(${roundGothicRegularUrl})` };
const boldRoundGothic: BMLBrowserFontFace = { source: `url(${roundGothicBoldUrl})` };
const squareGothic: BMLBrowserFontFace = { source: `url(${squareGothicRegularUrl})` };

// web-bml re-invokes setReceivingStatus with the same value on every pending
// fetch-queue change; dedupe so the bridge only sees transitions.
let lastReceivingStatus: boolean | null = null;

const bmlBrowser = new BMLBrowser({
    containerElement: stage,
    mediaElement,
    fonts: { roundGothic, boldRoundGothic, squareGothic },
    videoPlaneModeEnabled: true,
    indicator: {
        setUrl() {},
        // 実機でいう画面下の「データ取得中...」表示 - ネイティブ側でバッジ表示する
        setReceivingStatus(receiving: boolean) {
            if (receiving !== lastReceivingStatus) {
                lastReceivingStatus = receiving;
                postToNative({ type: "receiving", value: receiving });
            }
        },
        setNetworkingGetStatus() {},
        setNetworkingPostStatus() {},
        setEventName() {},
    },
    showErrorMessage: (title, message, code) => {
        postToNative({ type: "error", message: `${title}: ${message}`, code });
    },
});

let adapter = new MahironAdapter((message) => bmlBrowser.emitMessage(message));

function applyStageScale(width: number, height: number): void {
    stage.style.width = `${width}px`;
    stage.style.height = `${height}px`;
    const scale = Math.min(window.innerWidth / width, window.innerHeight / height);
    const offsetX = (window.innerWidth - width * scale) / 2;
    const offsetY = (window.innerHeight - height * scale) / 2;
    stage.style.transform = `translate(${offsetX}px, ${offsetY}px) scale(${scale})`;
}

let lastResolution: { width: number; height: number } | null = null;
function reapplyStageScale(): void {
    if (lastResolution != null) {
        applyStageScale(lastResolution.width, lastResolution.height);
    }
    postVideoRect();
}
window.addEventListener("resize", reapplyStageScale);
// The WKWebView may still be zero-sized (or resize without a window resize
// event) around document load; ResizeObserver catches every geometry change.
new ResizeObserver(reapplyStageScale).observe(document.documentElement);

// Always measure the video plane fresh instead of trusting videochanged's
// payload: web-bml fires videochanged during document load, BEFORE the stage
// transform for the new document is applied (the load event comes after),
// and it doesn't re-fire when only the transform changes. Re-measuring here
// (and re-posting on load/resize) keeps the native rect in real WKWebView
// points. A document without a video object clears the rect (native side
// then shows the video full-bleed).
function postVideoRect(): void {
    const videoElement = bmlBrowser.getVideoElement();
    if (videoElement == null) {
        postToNative({ type: "videoRect", x: 0, y: 0, width: 0, height: 0 });
        return;
    }
    const rect = videoElement.getBoundingClientRect();
    postToNative({ type: "videoRect", x: rect.x, y: rect.y, width: rect.width, height: rect.height });
}

bmlBrowser.addEventListener("load", (evt) => {
    lastResolution = evt.detail.resolution;
    applyStageScale(evt.detail.resolution.width, evt.detail.resolution.height);
    console.info(
        `[kiririn-bml] load: resolution=${evt.detail.resolution.width}x${evt.detail.resolution.height}` +
            ` profile=${evt.detail.profile} inner=${window.innerWidth}x${window.innerHeight}` +
            ` transform=${stage.style.transform}`,
    );
    // The transform for this document was just (re)applied; re-measure the
    // video plane so any videochanged fired mid-load (pre-transform) is
    // corrected, and documents without a video object clear the stale rect.
    postVideoRect();
    postToNative({
        type: "loaded",
        width: evt.detail.resolution.width,
        height: evt.detail.resolution.height,
        profile: evt.detail.profile,
    });
});

bmlBrowser.addEventListener("videochanged", (evt) => {
    const rect = evt.detail.boundingRect;
    console.info(
        `[kiririn-bml] videochanged: ${rect.x},${rect.y} ${rect.width}x${rect.height}`,
    );
    postVideoRect();
});

bmlBrowser.addEventListener("invisible", (evt) => {
    console.info(`[kiririn-bml] invisible: ${evt.detail}`);
    postToNative({ type: "invisible", value: evt.detail });
});

bmlBrowser.addEventListener("usedkeylistchanged", (evt) => {
    postToNative({ type: "usedKeyList", groups: [...evt.detail.usedKeyList] });
});

window.kiririnBML = {
    onNativeMessage(raw: unknown) {
        const message = raw as NativeToWebMessage;
        switch (message.type) {
            case "init":
                if (message.programInfo != null) {
                    bmlBrowser.emitMessage(message.programInfo);
                }
                break;
            case "sse":
                adapter.handleSSE(message.event, message.data);
                break;
            case "moduleData":
                adapter.handleModuleData({
                    componentTag: message.componentTag,
                    moduleId: message.moduleId,
                    downloadId: message.downloadId,
                    version: message.version,
                    moduleInfoBase64: message.moduleInfoB64,
                    dataBase64: message.dataBase64,
                });
                break;
            case "programInfo":
                bmlBrowser.emitMessage(message.programInfo);
                break;
            case "key": {
                const code = message.aribKeyCode as AribKeyCode;
                if (message.action === "down") {
                    bmlBrowser.content.processKeyDown(code);
                } else {
                    bmlBrowser.content.processKeyUp(code);
                }
                break;
            }
            case "reset":
                adapter = new MahironAdapter((m) => bmlBrowser.emitMessage(m));
                break;
            default:
                log("warn", `unhandled native message: ${JSON.stringify(message)}`);
        }
    },
};

console.info(
    "[kiririn-bml] adapter initialized; native bridge:",
    window.webkit?.messageHandlers?.bml != null ? "connected" : "MISSING",
);
postToNative({ type: "ready" });
