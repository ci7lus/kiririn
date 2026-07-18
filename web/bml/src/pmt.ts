import { Buffer } from "buffer";
// Deep imports avoid pulling in TsStream (and its Node `stream` dependency) -
// we only need single-section parsing here, not continuous TS demuxing.
// eslint-disable-next-line @typescript-eslint/no-var-requires
import TsTablePmt = require("@chinachu/aribts/lib/table/pmt");
import { AdditionalAribBXMLInfo, ComponentPMT, PMTMessage } from "../../web-bml/server/ws_api";

/**
 * Parses a raw PMT section (as delivered by Mahiron's `rawSectionHex`) into a
 * web-bml `PMTMessage`. Mirrors web-bml/server/decode_ts.ts's `pmt` handler
 * (which normally runs against aribts's live TsStream) and its
 * `decodeAdditionalAribBXMLInfo` helper, adapted for a single already-sliced
 * section buffer instead of a continuous packet stream.
 */
export function parsePMTSection(section: Uint8Array): PMTMessage | null {
    const buffer = Buffer.from(section);
    const decoded = new TsTablePmt(buffer).decode();
    if (decoded == null) {
        // CRC32 mismatch.
        return null;
    }

    const components: ComponentPMT[] = [];
    for (const stream of decoded.streams as any[]) {
        const pid: number = stream.elementary_PID;
        let bxmlInfo: AdditionalAribBXMLInfo | undefined;
        let componentId: number | undefined;
        let dataComponentId: number | undefined;

        for (const esInfo of stream.ES_info as any[]) {
            if (esInfo.descriptor_tag === 0x52) {
                // Stream identifier descriptor: PID <-> component_tag mapping.
                componentId = esInfo.component_tag as number;
            } else if (esInfo.descriptor_tag === 0xfd) {
                // Data component descriptor.
                let additionalDataComponentInfo: Buffer = esInfo.additional_data_component_info;
                dataComponentId = esInfo.data_component_id as number;
                // Some aribts versions read data_component_id as 8 bits instead of
                // the correct 16; detect and correct for that here (see
                // web-bml/server/decode_ts.ts's identical workaround). This is a
                // defensive no-op against the pinned aribts version, which already
                // reads 16 bits correctly.
                if (additionalDataComponentInfo.length + 1 === esInfo.descriptor_length) {
                    dataComponentId = (dataComponentId << 8) | additionalDataComponentInfo[0];
                    additionalDataComponentInfo = additionalDataComponentInfo.subarray(1);
                }
                // STD-B10 第2部 付録J 表J-1: 地上波(0x0C/0x0D)・BS(0x07)・CS(0x0B)のみ
                // additional_arib_bxml_info を持つ
                if (
                    dataComponentId === 0x0c ||
                    dataComponentId === 0x0d ||
                    dataComponentId === 0x07 ||
                    dataComponentId === 0x0b
                ) {
                    bxmlInfo = decodeAdditionalAribBXMLInfo(additionalDataComponentInfo);
                }
            }
        }

        if (componentId == null) {
            continue;
        }
        components.push({
            componentId,
            pid,
            bxmlInfo,
            streamType: stream.stream_type as number,
            dataComponentId,
        });
    }

    return { type: "pmt", components };
}

// Verbatim port of web-bml/server/decode_ts.ts's decodeAdditionalAribBXMLInfo
// (module-private there, so copied rather than imported).
function decodeAdditionalAribBXMLInfo(additionalDataComponentInfo: Buffer): AdditionalAribBXMLInfo {
    let off = 0;
    const transmissionFormat = ((additionalDataComponentInfo[off] & 0b11000000) >> 6) & 0b11;
    const entryPointFlag = ((additionalDataComponentInfo[off] & 0b00100000) >> 5) & 0b1;
    const bxmlInfo: AdditionalAribBXMLInfo = {
        transmissionFormat,
        entryPointFlag: !!entryPointFlag,
    };
    if (entryPointFlag) {
        const autoStartFlag = ((additionalDataComponentInfo[off] & 0b00010000) >> 4) & 0b1;
        const documentResolution = ((additionalDataComponentInfo[off] & 0b00001111) >> 0) & 0b1111;
        off++;
        const useXML = ((additionalDataComponentInfo[off] & 0b10000000) >> 7) & 0b1;
        const defaultVersionFlag = ((additionalDataComponentInfo[off] & 0b01000000) >> 6) & 0b1;
        const independentFlag = ((additionalDataComponentInfo[off] & 0b00100000) >> 5) & 0b1;
        const styleForTVFlag = ((additionalDataComponentInfo[off] & 0b00010000) >> 4) & 0b1;
        off++;
        bxmlInfo.entryPointInfo = {
            autoStartFlag: !!autoStartFlag,
            documentResolution,
            useXML: !!useXML,
            defaultVersionFlag: !!defaultVersionFlag,
            independentFlag: !!independentFlag,
            styleForTVFlag: !!styleForTVFlag,
            bmlMajorVersion: 1,
            bmlMinorVersion: 0,
        };
        if (defaultVersionFlag === 0) {
            let bmlMajorVersion = additionalDataComponentInfo[off] << 16;
            off++;
            bmlMajorVersion |= additionalDataComponentInfo[off];
            bxmlInfo.entryPointInfo.bmlMajorVersion = bmlMajorVersion;
            off++;
            let bmlMinorVersion = additionalDataComponentInfo[off] << 16;
            off++;
            bmlMinorVersion |= additionalDataComponentInfo[off];
            bxmlInfo.entryPointInfo.bmlMinorVersion = bmlMinorVersion;
            off++;
            if (useXML === 1) {
                let bxmlMajorVersion = additionalDataComponentInfo[off] << 16;
                off++;
                bxmlMajorVersion |= additionalDataComponentInfo[off];
                bxmlInfo.entryPointInfo.bxmlMajorVersion = bxmlMajorVersion;
                off++;
                let bxmlMinorVersion = additionalDataComponentInfo[off] << 16;
                off++;
                bxmlMinorVersion |= additionalDataComponentInfo[off];
                bxmlInfo.entryPointInfo.bxmlMinorVersion = bxmlMinorVersion;
                off++;
            }
        }
    } else {
        off++;
    }
    if (transmissionFormat === 0) {
        const dataEventId = ((additionalDataComponentInfo[off] & 0b11110000) >> 4) & 0b1111;
        const eventSectionFlag = ((additionalDataComponentInfo[off] & 0b00001000) >> 3) & 0b1;
        off++;
        const ondemandRetrievalFlag = ((additionalDataComponentInfo[off] & 0b10000000) >> 7) & 0b1;
        const fileStorableFlag = ((additionalDataComponentInfo[off] & 0b01000000) >> 6) & 0b1;
        const startPriority = ((additionalDataComponentInfo[off] & 0b00100000) >> 5) & 0b1;
        bxmlInfo.additionalAribCarouselInfo = {
            dataEventId,
            eventSectionFlag: !!eventSectionFlag,
            ondemandRetrievalFlag: !!ondemandRetrievalFlag,
            fileStorableFlag: !!fileStorableFlag,
            startPriority,
        };
        off++;
    } else if (transmissionFormat === 1) {
        off++;
    }
    return bxmlInfo;
}
