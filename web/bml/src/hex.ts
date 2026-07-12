export function hexToBytes(hex: string): Uint8Array {
    const clean = hex.length % 2 === 0 ? hex : "0" + hex;
    const bytes = new Uint8Array(clean.length / 2);
    for (let i = 0; i < bytes.length; i++) {
        bytes[i] = parseInt(clean.substring(i * 2, i * 2 + 2), 16);
    }
    return bytes;
}
