import { Buffer } from "buffer";
import { unzlibSync } from "fflate";
// eslint-disable-next-line @typescript-eslint/no-var-requires
import TsModuleDescriptors = require("@chinachu/aribts/lib/module_descriptors");
import {
    EntityParser,
    entityHeaderToString,
    parseMediaType,
    parseMediaTypeFromString,
} from "../../web-bml/server/entity_parser";
import { ModuleDownloadedMessage, ModuleFile } from "../../web-bml/server/ws_api";

const enum CompressionType {
    None = -1,
    Zlib = 0,
}

export type DecodedModuleInput = {
    componentTag: number;
    moduleId: number;
    version: number;
    dataEventId: number;
    /** DII moduleInfo descriptor bytes for this module (Mahiron's `info` field), base64-encoded. */
    moduleInfoBase64: string;
    /** Assembled module binary as broadcast (possibly zlib-compressed), base64-encoded. */
    dataBase64: string;
};

/**
 * Converts an already carousel-assembled module (Mahiron does the DSM-CC
 * reassembly server-side) into a web-bml `ModuleDownloadedMessage`. Mirrors
 * the DDB-completion branch of web-bml/server/decode_ts.ts (~lines 637-717),
 * minus the block reassembly itself (Mahiron already did that).
 */
export function decodeModule(input: DecodedModuleInput): ModuleDownloadedMessage {
    const moduleInfoBuffer = Buffer.from(input.moduleInfoBase64, "base64");
    let compressionType: CompressionType = CompressionType.None;
    let contentType: string | undefined;

    const descriptors = new TsModuleDescriptors(moduleInfoBuffer).decode() as any[];
    for (const info of descriptors) {
        if (info.descriptor_tag === 0x01) {
            // Type descriptor (STD-B24 第三分冊 第三編 6.2.3.1)
            contentType = (info.text_char as Buffer).toString("ascii");
        } else if (info.descriptor_tag === 0xc2) {
            // Compression Type descriptor (STD-B24 第三分冊 第三編 6.2.3.9)
            const descriptor: Buffer = info.descriptor;
            compressionType = descriptor.readInt8(0) as CompressionType;
        }
    }

    let moduleData = Buffer.from(input.dataBase64, "base64");
    if (compressionType === CompressionType.Zlib) {
        moduleData = Buffer.from(unzlibSync(moduleData));
    }

    const mediaType = contentType == null ? null : parseMediaTypeFromString(contentType).mediaType;
    const files: ModuleFile[] = [];

    if (mediaType == null || (mediaType.type === "multipart" && mediaType.subtype === "mixed")) {
        const parser = new EntityParser(moduleData);
        const mod = parser.readEntity();
        if (mod?.multipartBody == null) {
            throw new Error(
                `failed to parse module entity (component ${input.componentTag}, module ${input.moduleId})`,
            );
        }
        for (const entity of mod.multipartBody) {
            const location = entity.headers.find((x) => x.name === "content-location");
            const contentTypeHeader = entity.headers.find((x) => x.name === "content-type");
            if (location == null || contentTypeHeader == null) {
                continue;
            }
            const parsed = parseMediaType(contentTypeHeader.value);
            if (parsed.mediaType == null) {
                continue;
            }
            files.push({
                contentLocation: entityHeaderToString(location),
                contentType: parsed.mediaType,
                dataBase64: entity.body.toString("base64"),
            });
        }
    } else {
        files.push({
            contentLocation: null,
            contentType: mediaType,
            dataBase64: moduleData.toString("base64"),
        });
    }

    return {
        type: "moduleDownloaded",
        componentId: input.componentTag,
        moduleId: input.moduleId,
        files,
        version: input.version,
        dataEventId: input.dataEventId,
    };
}
