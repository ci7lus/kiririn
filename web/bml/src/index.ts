import {
    BMLBrowser,
    BMLBrowserFontFace,
    InputApplication,
    InputApplicationLaunchOptions,
    InputCancelReason,
} from "../../web-bml/client/bml_browser";
import { AribKeyCode } from "../../web-bml/client/content";
import { ComponentPMT, ResponseMessage } from "../../web-bml/server/ws_api";
import { postToNative, log } from "./bridge";
import { createIP } from "./ip";
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
const postalCodeStorageKey = "nvram_prefix=receiverinfo%2Fzipcode";

// kiririn-bmlスキームのオリジンではWebKitがlocalStorageをディスクへ永続化
// しないので、web-bmlの書き込み(NVRAM・放送局DB)を全部ネイティブへミラー
// する。起動時はネイティブがWKUserScript(atDocumentStart、このバンドルより
// 先に実行される=ここのフックを経由しない)でミラー内容をシードし直す。
const originalSetItem = Storage.prototype.setItem;
Storage.prototype.setItem = function (key: string, value: string): void {
    originalSetItem.call(this, key, value);
    if (this === localStorage) {
        postToNative({ type: "storageChanged", key, value });
    }
};

const originalRemoveItem = Storage.prototype.removeItem;
Storage.prototype.removeItem = function (key: string): void {
    originalRemoveItem.call(this, key);
    if (this === localStorage) {
        postToNative({ type: "storageChanged", key, value: null });
    }
};

const roundGothic: BMLBrowserFontFace = { source: `url(${roundGothicRegularUrl})` };
const boldRoundGothic: BMLBrowserFontFace = { source: `url(${roundGothicBoldUrl})` };
const squareGothic: BMLBrowserFontFace = { source: `url(${squareGothicRegularUrl})` };

// web-bml re-invokes setReceivingStatus with the same value on every pending
// fetch-queue change; dedupe so the bridge only sees transitions.
let lastReceivingStatus: boolean | null = null;

// 実機でいう「通信中...」表示。GET(通信コンテンツ取得)とPOST(電文送信)を
// まとめてひとつのバッジとしてネイティブへ通知する。
let networkingGet = false;
let networkingPost = false;
let lastNetworkingStatus: boolean | null = null;
function postNetworkingStatus(): void {
    const networking = networkingGet || networkingPost;
    if (networking !== lastNetworkingStatus) {
        lastNetworkingStatus = networking;
        postToNative({ type: "networking", value: networking });
    }
}

const audioContext = new AudioContext();
const audioGain = audioContext.createGain();
audioGain.connect(audioContext.destination);

class KiririnInputApplication implements InputApplication {
    private nextRequestId = 1;
    private activeRequest: { id: number; callback: (value: string) => void } | null = null;

    launch(options: InputApplicationLaunchOptions): void {
        if (this.activeRequest != null) {
            postToNative({
                type: "inputCancelled",
                requestId: this.activeRequest.id,
                reason: "other",
            });
        }
        const requestId = this.nextRequestId++;
        this.activeRequest = { id: requestId, callback: options.callback };
        postToNative({
            type: "inputRequest",
            requestId,
            characterType: options.characterType,
            allowedCharacters: options.allowedCharacters,
            maxLength: options.maxLength,
            value: options.value,
            inputMode: options.inputMode,
            // web-bml currently marks HTMLInputElement requests as multiline;
            // match its existing overlay input behavior and use one line here.
            multiline: false,
        });
    }

    cancel(reason: InputCancelReason): void {
        const request = this.activeRequest;
        if (request == null) return;
        this.activeRequest = null;
        postToNative({ type: "inputCancelled", requestId: request.id, reason });
    }

    submit(requestId: number, value: string): void {
        const request = this.takeRequest(requestId);
        request?.callback(value);
    }

    dismiss(requestId: number): void {
        this.takeRequest(requestId);
    }

    private takeRequest(requestId: number): { id: number; callback: (value: string) => void } | null {
        if (this.activeRequest?.id !== requestId) return null;
        const request = this.activeRequest;
        this.activeRequest = null;
        return request;
    }
}

const inputApplication = new KiririnInputApplication();

// 最新PMTのES一覧 (componentTag↔PID対応)。setMainAudioStreamでコンポーネント
// タグをネイティブプレイヤーの音声トラック指定へ変換するのに使う。PIDはVLCの
// TrackId照合用、序数はPMT内の同種ES中の並び順(TrackIdの形式が期待と違った
// ときのフォールバック)。
let lastPMTComponents: ComponentPMT[] | null = null;
const audioStreamTypes = new Set([0x03, 0x04, 0x0f, 0x11]); // MPEG-1/2 / AAC ADTS / LATM

function findPMTComponent(
    componentId: number,
    streamTypes: Set<number>,
): { pid: number; index: number } | null {
    if (lastPMTComponents == null) {
        return null;
    }
    const sameKind = lastPMTComponents.filter((c) => streamTypes.has(c.streamType));
    const index = sameKind.findIndex((c) => c.componentId === componentId);
    if (index < 0) {
        return null;
    }
    return { pid: sameKind[index].pid, index };
}

function emitToBrowser(message: ResponseMessage): void {
    if (message.type === "pmt") {
        lastPMTComponents = message.components;
    }
    bmlBrowser.emitMessage(message);
}

const bmlBrowser = new BMLBrowser({
    containerElement: stage,
    mediaElement,
    fonts: { roundGothic, boldRoundGothic, squareGothic },
    videoPlaneModeEnabled: true,
    audioNodeProvider: {
        getAudioDestinationNode: () => audioGain,
    },
    inputApplication,
    epg: {
        tune(originalNetworkId, transportStreamId, serviceId) {
            postToNative({ type: "tune", originalNetworkId, transportStreamId, serviceId });
            return true;
        },
    },
    // BMLからの音声ES切替 (object.setMainAudioStream)。VLC側のトラック切替に
    // つなぐ。bmlBrowser.setMainAudioStreamの呼び出しで内部状態を更新し
    // MainAudioStreamChangedイベントを発火させる(eventQueue経由なので再入安全)。
    setMainAudioStreamCallback: (componentId, channelId) => {
        const resolved = findPMTComponent(componentId, audioStreamTypes);
        if (lastPMTComponents != null && resolved == null) {
            // PMT既知でそのcomponentTagの音声ESが存在しない: 失敗
            return false;
        }
        postToNative({
            type: "setMainAudioStream",
            componentId,
            channelId: channelId ?? null,
            pid: resolved?.pid ?? null,
            audioIndex: resolved?.index ?? null,
        });
        bmlBrowser.setMainAudioStream(componentId, channelId);
        return true;
    },
    // 設定でインターネット接続が無効のときはipごと渡さない: web-bmlは
    // ip.get等のnullチェックで通信コンテンツ対応/非対応を判定するので、
    // 未対応の受信機として正しく振る舞う(getBrowserSupportも0を返す)。
    ip: window.kiririnBMLConfig?.internetAccess === true ? createIP() : undefined,
    indicator: {
        setUrl() {},
        // 実機でいう画面下の「データ取得中...」表示 - ネイティブ側でバッジ表示する
        setReceivingStatus(receiving: boolean) {
            if (receiving !== lastReceivingStatus) {
                lastReceivingStatus = receiving;
                postToNative({ type: "receiving", value: receiving });
            }
        },
        setNetworkingGetStatus(get: boolean) {
            networkingGet = get;
            postNetworkingStatus();
        },
        setNetworkingPostStatus(post: boolean) {
            networkingPost = post;
            postNetworkingStatus();
        },
        setEventName() {},
    },
    showErrorMessage: (title, message, code) => {
        postToNative({ type: "error", message: `${title}: ${message}`, code });
    },
});

let adapter = new MahironAdapter(emitToBrowser);

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
    postLayoutRects();
}
window.addEventListener("resize", reapplyStageScale);
// The WKWebView may still be zero-sized (or resize without a window resize
// event) around document load; ResizeObserver catches every geometry change.
new ResizeObserver(reapplyStageScale).observe(document.documentElement);

// Always measure the stage and video plane fresh instead of trusting videochanged's
// payload: web-bml fires videochanged during document load, BEFORE the stage
// transform for the new document is applied (the load event comes after),
// and it doesn't re-fire when only the transform changes. Re-measuring here
// (and re-posting on load/resize) keeps the native rect in real WKWebView
// points. A document without a video object clears the rect (native side
// then shows the video full-bleed).
function postLayoutRects(): void {
    const stageRect = stage.getBoundingClientRect();
    const videoElement = bmlBrowser.getVideoElement();
    const videoRect = videoElement?.getBoundingClientRect();
    postToNative({
        type: "layoutRects",
        stageX: stageRect.x,
        stageY: stageRect.y,
        stageWidth: stageRect.width,
        stageHeight: stageRect.height,
        videoX: videoRect?.x ?? 0,
        videoY: videoRect?.y ?? 0,
        videoWidth: videoRect?.width ?? 0,
        videoHeight: videoRect?.height ?? 0,
    });
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
    postLayoutRects();
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
    postLayoutRects();
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
                if (message.postalCode == null) {
                    localStorage.removeItem(postalCodeStorageKey);
                } else {
                    localStorage.setItem(postalCodeStorageKey, window.btoa(message.postalCode));
                }
                if (message.programInfo != null) {
                    bmlBrowser.emitMessage(message.programInfo);
                }
                break;
            case "sse":
                adapter.handleSSE(message.event, message.data);
                break;
            case "moduleResources":
                adapter.handleModuleResources({
                    componentTag: message.componentTag,
                    moduleId: message.moduleId,
                    downloadId: message.downloadId,
                    version: message.version,
                    files: message.files,
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
            case "audioOutput":
                audioGain.gain.value = message.muted ? 0 : message.volume / 100;
                break;
            case "inputResult":
                inputApplication.submit(message.requestId, message.value);
                break;
            case "inputCancel":
                inputApplication.dismiss(message.requestId);
                break;
            case "reset":
                lastPMTComponents = null;
                adapter = new MahironAdapter(emitToBrowser);
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
