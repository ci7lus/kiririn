import { InputCancelReason, InputCharacterType } from "../../web-bml/client/bml_browser";
import { ProgramInfoMessage } from "../../web-bml/server/ws_api";

// Swift -> JS (window.kiririnBML.onNativeMessage)
export type NativeToWebMessage =
    | { type: "init"; programInfo: ProgramInfoMessage | null; postalCode: string | null }
    | { type: "sse"; event: string; data: unknown }
    | {
          type: "moduleData";
          componentTag: number;
          moduleId: number;
          downloadId: number;
          version: number;
          moduleInfoB64: string;
          dataBase64: string;
      }
    | { type: "programInfo"; programInfo: ProgramInfoMessage }
    | { type: "key"; action: "down" | "up"; aribKeyCode: number }
    | { type: "audioOutput"; volume: number; muted: boolean }
    | { type: "inputResult"; requestId: number; value: string }
    | { type: "inputCancel"; requestId: number }
    | { type: "reset" };

// JS -> Swift (webkit.messageHandlers.bml.postMessage)
export type WebToNativeMessage =
    | { type: "ready" }
    | { type: "loaded"; width: number; height: number; profile: string }
    | { type: "videoRect"; x: number; y: number; width: number; height: number }
    | { type: "invisible"; value: boolean }
    | { type: "receiving"; value: boolean }
    | { type: "usedKeyList"; groups: string[] }
    | { type: "postalCodeChanged"; postalCode: string | null }
    | {
          type: "inputRequest";
          requestId: number;
          characterType: InputCharacterType;
          allowedCharacters?: string;
          maxLength: number;
          value: string;
          inputMode: "text" | "password";
          multiline: boolean;
      }
    | { type: "inputCancelled"; requestId: number; reason: InputCancelReason }
    | { type: "error"; message: string; code?: string }
    | { type: "log"; level: "debug" | "info" | "warn" | "error"; message: string };
