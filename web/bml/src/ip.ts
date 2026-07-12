import { IP } from "../../web-bml/client/bml_browser";

// 通信コンテンツ(データ放送のインターネット接続機能)のIP実装。web-bml純正
// サーバーの /api/get・/api/post・/api/confirm に相当するHTTPプロキシを
// ネイティブ側のBMLURLSchemeHandlerが kiririn-bml://app/ip/* で提供する。
// ページ自身が kiririn-bml://app オリジンなので、このfetchは同一オリジン
// 扱いになりCORS・ATSの制約を受けずステータスやヘッダーもそのまま読める。
export function createIP(): IP {
    return {
        // 403 = Ethernet/DHCP (ARIB TR-B14/B24のgetConnectionType値)
        getConnectionType: () => 403,
        isIPConnected: () => 1,
        async get(uri) {
            try {
                const res = await fetch("/ip/get?url=" + encodeURIComponent(uri));
                return {
                    statusCode: res.status,
                    headers: res.headers,
                    response: new Uint8Array(await res.arrayBuffer()),
                };
            } catch {
                return {};
            }
        },
        async transmitTextDataOverIP(uri, body) {
            try {
                const res = await fetch("/ip/post?url=" + encodeURIComponent(uri), {
                    method: "POST",
                    body,
                });
                return {
                    resultCode: 1,
                    statusCode: res.status.toString(),
                    response: new Uint8Array(await res.arrayBuffer()),
                };
            } catch {
                return { resultCode: NaN, statusCode: "", response: new Uint8Array() };
            }
        },
        async confirmIPNetwork(destination, isICMP, timeoutMillis) {
            try {
                const res = await fetch(
                    "/ip/confirm?" +
                        new URLSearchParams({
                            destination,
                            isICMP: isICMP ? "true" : "false",
                            timeoutMillis: timeoutMillis.toString(),
                        }),
                );
                if (!res.ok) {
                    return null;
                }
                return await res.json();
            } catch {
                return null;
            }
        },
    };
}
