/**
 * kiririn のプラグインページで利用できる app-specific bridge です。
 *
 * このファイルが説明するのは `window.kiririn` だけです。
 * WebExtension 標準 API は WebKit が提供するものを利用してください。
 *
 * 利用可能な表示面:
 * - `kiririn.overlay.page`
 * - `kiririn.panel.page`
 * - `options_ui.page`
 *
 * Deep Link:
 * - `kiririn://plugins/{browser_specific_settings.kiririn.id}`
 *   Deep Link URL 全体が `onDeeplinkOpened({ url })` に配送されます。
 */

export interface Genre {
    lv1: number;
    lv2?: number;
    name: string;
}

export interface Program {
    name: string;
    description: string;
    startAt: number;
    endAt: number;
    duration: number;
    eventId?: number;
    extended: [string, string][];
    genres: Genre[];
}

export interface ServiceType {
    value: number;
    description: string;
}

export interface Channel {
    id: string;
    type: string;
}

export interface Service {
    name: string;
    serviceId: number;
    networkId: number;
    type: ServiceType;
    channel?: Channel;
}

export interface PlayerDisplayRect {
    /** プレイヤー表示領域の幅を1とした左端座標。 */
    x: number;
    /** プレイヤー表示領域の高さを1とした上端座標。 */
    y: number;
    /** プレイヤー表示領域の幅を1とした表示幅。 */
    width: number;
    /** プレイヤー表示領域の高さを1とした表示高さ。 */
    height: number;
}

export interface PlayerPlaybackState {
    playerID: string;
    playableID: string;
    isPlaying: boolean;
    time: number;
    position: number;
    rate: number;
    /**
     * プレイヤー領域内でテレビ画面として使われる描画領域の正規化座標です。
     * データ放送表示中はデータ放送コンテンツの描画領域、それ以外は全面を示します。
     */
    televisionDisplayRect: PlayerDisplayRect;
    /**
     * プレイヤー領域内で映像が実際に表示されている領域の正規化座標です。
     * データ放送に映像プレーンがない場合を含め、映像が全面表示されるときは全面を示します。
     */
    videoDisplayRect: PlayerDisplayRect;
}

export interface Playable {
    playerID: string;
    id: string;
    title: string;
    subtitle?: string;
    initialNetworkTime?: number;
    isSeekable: boolean;
    length?: number;
    program?: Program;
    service?: Service;
}

export interface KiririnRuntimeInfo {
    platform: "iOS" | "macOS";
    osVersion: string;
    appVersion: string | null;
    buildVersion: string;
    bundleIdentifier: string | null;
    bridgeVersion: number;
    displayAreaType: "overlay" | "options" | "panel";
    playerID: string | null;
}

export interface DeeplinkOpenedPayload {
    url: string;
}

export type CaptureVariant = "original" | "composite";

export interface CaptureVariantMetadata {
    type: CaptureVariant;
    overlayPluginManifestIDs: string[];
}

export interface CaptureMetadata {
    captureID: string;
    playerID: string;
    capturedAt: Date;
    variants: CaptureVariantMetadata[];
}

export interface CaptureTakenPayload extends CaptureMetadata {}

export interface KiririnPluginBridge {
    getPlayables(): Playable[];
    onPlayablesChange(callback: (playables: Playable[]) => void): void;

    getPlayerStatuses(): PlayerPlaybackState[];
    onPlayerStatusesChange(callback: (statuses: PlayerPlaybackState[]) => void): void;

    getFocusedPlayerID(): string | null;
    onFocusedPlayerIDChange(callback: (id: string | null) => void): void;
    onPlayerClosed(callback: (playerID: string) => void): void;

    getPlayable(playerID: string): Playable | null;
    getPlayerStatus(playerID: string): PlayerPlaybackState | null;

    getRuntimeInfo(): KiririnRuntimeInfo;

    onDeeplinkOpened(callback: (payload: DeeplinkOpenedPayload) => void): void;
    onCaptureTaken(callback: (payload: CaptureTakenPayload) => void): void;

    play(playerID?: string): void;
    pause(playerID?: string): void;
    togglePlayPause(playerID?: string): void;
    /** 0〜1の再生位置へ移動します。バイト数ベースのシークです。 */
    seek(position: number, playerID?: string): void;
    /** 指定した再生時刻（秒）へ移動します。リモートファイルでの精度は保証されません。 */
    seekToTime(time: number, playerID?: string): void;

    getCaptureBlob(captureID: string, variant: CaptureVariant): Promise<Blob | null>;

    // biome-ignore lint/suspicious/noExplicitAny: plugin message payload
    sendMessage(type: string, data: any): void;
}

export type KiririnBridge = KiririnPluginBridge;

declare global {
    interface Window {
        kiririn: KiririnPluginBridge;
    }
}

export {};
