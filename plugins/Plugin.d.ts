/**
 * プラグインのマニフェスト情報は HTML の application/json script で宣言します。
 * script の id は kiririn-plugin-manifest に固定してください。
 *
 * @example
 * <script id="kiririn-plugin-manifest" type="application/json">
 * {
 *   "name": "My Plugin",
 *   "identifier": "com.example.my-plugin",
 *   "version": "1.0.0",
 *   "author": "作者名",
 *   "url": "https://example.com",
 *   "displayAreas": ["playerOverlay", "pluginSettings"],
 *   "contextId": "my-plugin",
 *   "allowedURLPatterns": ["https://api\\.example\\.com/.*"]
 * }
 * </script>
 *
 * displayAreas に指定可能な値: playerOverlay, pluginSettings, pluginScreen
 *
 * カスタム URL スキーム:
 * - kiririn://plugins/{identifier}?url={encoded url}
 *   対象プラグインに onOpenURL({ url }) を配信します。
 *
 * identifier: プラグインの一意な識別子。Deep Link の path segment と内部プラグインIDの導出に使われるため、英数字、.、_、- のみ使用してください。
 *   同じ identifier のプラグインは同時に 1 つしか登録できません。
 *
 * contextId: WebView のオリジンに使われるサブドメインラベル（任意、小文字英数字とハイフン、1〜63文字）。
 *   未指定の場合は identifier から計算される内部プラグインID（UUIDv5）ベースのホスト名が使用されます。
 *   そのため、同じプラグインを再登録するとデータが引き継がれることがあります。
 */

export interface Genre {
    lv1: number;
    lv2?: number;
    name: string;
}

export interface Program {
    name: string;
    description: string;
    startAt: number; // Unix timestamp
    endAt: number;   // Unix timestamp
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

export interface PlayerPlaybackState {
    /** プレイヤー（ウィンドウ）の一意な ID */
    playerID: string;
    /** コンテンツの一意な ID */
    playableID: string;
    isPlaying: boolean;
    time: number; // seconds
    position: number; // 0.0 to 1.0
    rate: number;
}

export interface Playable {
    /** プレイヤー（ウィンドウ）の一意な ID */
    playerID: string;
    /** コンテンツの一意な ID */
    id: string;
    title: string;
    subtitle?: string;
    initialNetworkTime?: number;
    isSeekable: boolean;
    length?: number;
    program?: Program;
    service?: Service;
}

/**
 * プラグインが表示されている領域の情報を表します。
 */
export interface DisplayArea {
    /** 表示されている場所の種類 */
    type: "playerOverlay" | "pluginSettings" | "pluginScreen";
    /** 紐付いているプレイヤー（ウィンドウ）の一意な ID */
    playerID?: string;
    /** 表示領域の幅 (px) */
    width: number;
    /** 表示領域の高さ (px) */
    height: number;
}

export interface OpenURLPayload {
    /** Deep Link 経由で渡された URL */
    url: string;
}

export interface CaptureBlobReference {
    /** プレイヤー（ウィンドウ）の一意な ID */
    playerID: string;
    /** キャプチャ履歴の一意な ID */
    captureID: string;
    /** 取得する画像の種別 */
    variant: "original" | "composite";
    /** この画像に反映されているオーバーレイプラグインの manifest identifier 一覧 */
    overlayPluginManifestIDs: string[];
}

export interface CaptureTakenPayload {
    /** プレイヤー（ウィンドウ）の一意な ID */
    playerID: string;
    /** キャプチャ履歴の一意な ID */
    captureID: string;
    /** 撮影時刻 */
    capturedAt: Date;
    /** 取得可能な画像参照の一覧。通常は original、合成版があれば composite も含みます */
    references: CaptureBlobReference[];
}

export interface KiririnBridge {
    /**
     * 現在再生中のすべての Playable 情報を取得します。
     * メタデータ（タイトル、画像、バックエンド情報など）の配列を返します。
     */
    getPlayables(): Playable[];

    /**
     * 再生中の Playable 一覧（メタデータ）の更新を購読します。
     * 内容に変更があった場合のみ呼び出されます。
     */
    onPlayablesChange(callback: (playables: Playable[]) => void): void;

    /**
     * 現在再生中のすべてのプレイヤーの状態（再生中か、再生位置など）を取得します。
     */
    getPlayerStatuses(): PlayerPlaybackState[];

    /**
     * 再生状態の更新（1秒ごとの時間更新など）を購読します。
     */
    onPlayerStatusesChange(callback: (statuses: PlayerPlaybackState[]) => void): void;

    /**
     * 現在フォーカスされている（操作対象の）プレイヤー（ウィンドウ）の ID を取得します。
     */
    getFocusedPlayerID(): string | null;

    /**
     * フォーカスされているプレイヤーの ID の更新を購読します。
     */
    onFocusedPlayerIDChange(callback: (id: string | null) => void): void;

    /**
     * プレイヤー（ウィンドウ）が閉じられたイベントを購読します。
     */
    onPlayerClosed(callback: (playerID: string) => void): void;

    /**
     * 指定したプレイヤーの Playable 情報を取得します。
     * @param playerID getPlayables() などから取得できるプレイヤー ID
     */
    getPlayable(playerID: string): Playable | null;

    /**
     * 指定したプレイヤーの状態を取得します。
     * @param playerID getPlayerStatuses() などから取得できるプレイヤー ID
     */
    getPlayerStatus(playerID: string): PlayerPlaybackState | null;

    /**
     * 現在の表示領域情報を取得します。
     */
    getDisplayArea(): DisplayArea;

    /**
     * 表示領域の更新（リサイズなど）を購読します。
     */
    onDisplayAreaChange(callback: (area: DisplayArea) => void): void;

    /**
     * kiririn://plugins/{identifier}?url=... でプラグインが開かれた時のイベントを購読します。
     */
    onOpenURL(callback: (payload: OpenURLPayload) => void): void;

    /**
     * スクリーンショットが撮影された時のイベントを購読します。
     * playerID を持つコンテキストではそのプレイヤーのイベントのみ、playerID を持たないコンテキストではグローバルに受信します。
     * 画像本体は含まれず、getCaptureBlob() で後から取得します。
     */
    onCaptureTaken(callback: (payload: CaptureTakenPayload) => void): void;

    /**
     * 指定したプレイヤーを再生します。playerID を省略した場合はフォーカス中のプレイヤーを操作します。
     */
    play(playerID?: string): void;

    /**
     * 指定したプレイヤーを一時停止します。playerID を省略した場合はフォーカス中のプレイヤーを操作します。
     */
    pause(playerID?: string): void;

    /**
     * 指定したプレイヤーの再生・一時停止を切り替えます。playerID を省略した場合はフォーカス中のプレイヤーを操作します。
     */
    togglePlayPause(playerID?: string): void;

    /**
     * 指定したプレイヤーのシーク位置を設定します。playerID を省略した場合はフォーカス中のプレイヤーを操作します。
     * @param position シーク位置（0.0〜1.0）
     */
    seek(position: number, playerID?: string): void;

    /**
     * onCaptureTaken() で受け取った参照から JPEG Blob を取得します。
     */
    getCaptureBlob(ref: CaptureBlobReference): Promise<Blob | null>;

    /**
     * ホスト（Swift）側のネットワークスタック経由で HTTP(S) リクエストを送信します。
     * 通常の fetch と違い、外部オリジンへのアクセスでもブラウザの CORS 制約を受けません。
     */
    fetch(input: RequestInfo | URL, init?: RequestInit): Promise<Response>;

    /**
     * ホスト（Swift）側にメッセージを送信します。
     */
    // biome-ignore lint/suspicious/noExplicitAny: any
    sendMessage(type: string, data: any): void;
}

declare global {
    export interface Window {
        kiririn: KiririnBridge;
    }
}
